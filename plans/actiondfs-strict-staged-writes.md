# Strict Staged Writes for actiondfs

## Goal

Make the default VM action input filesystem avoid overlayfs while preserving strict,
predictable action semantics:

- action inputs are immutable
- new outputs can be created under input directories
- writes are staged outside CAS until output collection
- actions that mutate inputs opt into the existing overlayfs compatibility path

This should reduce per-action mount work, remove overlayfs lookup/write overhead
from the common path, and make output collection cheaper for normal Bazel actions.

## Current Shape

VM execution currently uses actiondfs as a read-only lower filesystem and overlayfs
as the writable exec root:

1. The guest worker enables actiondfs by default.
2. The executor creates an actiondfs workspace beside the action work root.
3. The child mount namespace mounts actiondfs read-only at a lower target.
4. The child mounts overlayfs at `/workspace` with actiondfs as `lowerdir`.
5. The action reads inputs from actiondfs and writes outputs into overlay `upperdir`.
6. After execution, the parent mounts the same actiondfs + overlay pair again.
7. Output collection walks the merged overlay view and uploads declared outputs.

This is compatible, but it pays for overlayfs on every default action and duplicates
the merged mount setup during output collection.

## Target Semantics

Default strict actiondfs mode:

- CAS-backed input files are read-only.
- CAS-backed input directories are readable.
- New staged children may be created under input directories.
- Creating a path that already exists in the input tree fails.
- Mutating, truncating, deleting, chmoding, renaming, or replacing an input-backed
  path fails.
- Staged paths can be read, written, renamed, unlinked, chmoded, and collected as
  outputs.
- There is no copy-up, no whiteout support, and no hiding of lower/input entries.

Compatibility overlay mode:

- Existing actiondfs + overlayfs behavior remains available.
- An action opts into it with:

```python
execution_requirements = {"mutates_inputs": "1"}
```

This mode is for actions that rewrite inputs, rename temp files over inputs, delete
inputs, or declare outputs that overlap input files.

## Execution Mode Selection

Add an action platform helper:

```zig
fn actionMutatesInputs(platform: ?reapi.Platform) bool
```

Treat any platform property named `mutates_inputs` as true. Values such as `1`,
`true`, and `yes` should be accepted; absent or false-like values should keep the
default strict mode.

Executor selection:

- no chroot or actiondfs disabled: existing materialized input path
- actiondfs enabled and no `mutates_inputs`: strict staged actiondfs
- actiondfs enabled and `mutates_inputs`: existing actiondfs + overlayfs path

Log the selected input mode in execution timing:

```text
input_mode=materialized|actiondfs_strict|actiondfs_overlay
```

## actiondfs Mount Model

Extend actiondfs mount options:

```text
root=<input-root-directory-digest-hash>,cas=<cas-blob-root>,stage=<stage-root>
```

Behavior:

- `stage=` absent: current read-only actiondfs behavior
- `stage=` present: writable staged mode

In staged mode:

- do not mark the superblock `SB_RDONLY`
- do not mount actiondfs with `MS_RDONLY`
- keep input-backed nodes logically immutable
- store new writable paths under `stage-root`

The existing read-only path should remain valid and simple, both for overlay
compatibility and for debugging.

## Kernel Data Model

Add node origin:

```c
enum actiondfs_node_origin {
    ACTIONDFS_NODE_INPUT,
    ACTIONDFS_NODE_STAGED,
};
```

Input nodes keep the current digest/hash/size backing.

Staged nodes refer to a path under `stage-root`. They do not have CAS digests until
output collection hashes them.

Directory lookup becomes a strict union:

- check staged children first
- check input children second
- reject creation if an input child already exists
- reject rename over an input child
- reject unlink/rmdir of an input child

Directory readdir emits staged entries and input entries, skipping duplicates.
Duplicates should only exist defensively because strict creation and rename should
prevent staged paths from shadowing inputs.

## Writable VFS Operations

Add staged directory inode operations:

- `.create`
- `.mkdir`
- `.symlink`
- `.unlink`
- `.rmdir`
- `.rename`
- `.setattr`
- `.mknod`, either staged-only or explicit `-EPERM`
- `.link`, staged-only if needed by tests

File behavior:

- opening an input-backed file for write, append, or truncate returns `-EROFS`
- writing to an input-backed file returns `-EROFS`
- mutating input file metadata returns `-EROFS`
- staged file opens delegate to the backing staged file
- staged reads, writes, splice, and mmap delegate to the staged backing file
- input reads keep using the current CAS-backed file path

Do not hash or install staged files into CAS on close. Staged files remain ordinary
scratch files until output collection.

## Workspace Layout

Keep the overlay workspace for compatibility:

```text
<work>.actiondfs/lower
<work>.actiondfs/upper
<work>.actiondfs/work
```

Add strict staged mode:

```text
<work>.actiondfs/stage
```

Strict mode mounts actiondfs directly at `/workspace` with:

```text
root=<input-root>,cas=<cas-blob-root>,stage=<stage-path>
```

No overlay mount is used in strict mode.

## Runner Changes

Replace the single overlay-specific runner mount type with a mode-aware shape:

```zig
pub const ActiondfsMount = union(enum) {
    strict: ActiondfsStrictMount,
    overlay: ActiondfsOverlayMount,
};
```

Runner behavior:

- strict mode mounts actiondfs directly at the workspace target
- overlay mode mounts actiondfs at the lower target, then overlayfs at the workspace
  target
- runtime bind mounts still happen after actiondfs setup

## Output Collection

Collection becomes mode-dependent:

- materialized inputs: collect from the exec root
- overlay compatibility: mount merged actiondfs + overlay view and collect as today
- strict staged actiondfs: collect directly from `stage-root`

If a declared output path already exists as an input-backed file, strict mode should
fail clearly and tell users to set `mutates_inputs`.

This remains valid:

```text
input directory: src/
declared output: src/generated.o
```

as long as `src/generated.o` did not exist in the input tree.

## README Documentation

Document the default strict behavior and the opt-in escape hatch:

```python
execution_requirements = {"mutates_inputs": "1"}
```

The README should state:

- default VM execution treats inputs as immutable
- creating new outputs under input directories is allowed
- modifying, deleting, or replacing inputs fails
- `mutates_inputs` opts into overlayfs compatibility
- overlay mode is required for tools that rewrite source files or declare outputs
  overlapping input files

## Tests

Kernel/actiondfs tests or VM smoke cases:

- read input file
- create new file at root
- create new file under input directory
- open input with `O_TRUNC` fails
- write existing input fails
- unlink input fails
- rename staged file over input fails
- rename staged temp to new output succeeds
- readdir shows both input and staged entries
- collect staged output file
- collect staged output directory

Executor tests:

- `mutates_inputs` platform property detection
- strict mode selected by default
- overlay mode selected with `mutates_inputs`
- declared output overlapping input fails in strict mode
- same overlap uses overlay when `mutates_inputs` is present

## Next Performance Phase

### Compile-Time Instrumented Counters

Goal: keep the rich actiondfs counters for profiling runs, but make the common
path pay nothing when profiling is disabled.

Plan:

- Build the same source twice:
  - `actiondfs`: default filesystem with `ACTIONDFS_ENABLE_STATS=0`; counter
    call sites compile to no-ops.
  - `actiondfs_instrumented`: wrapper translation unit with
    `ACTIONDFS_ENABLE_STATS=1` and filesystem name `actiondfs_instrumented`.
- Keep `/proc/actiondfs_stats` only in the instrumented build.
- Make the Bazel `--//:executor_timing_logs` build setting generate the
  actiondfs filesystem name used by guest mounts, so timing builds mount
  `actiondfs_instrumented` and no-log builds mount `actiondfs`.
- Consider replacing instrumented global atomic counters with per-CPU counters
  if profiling runs show contention inside the instrumented filesystem.
- Keep derived expensive values in userspace parsers where possible rather than
  incrementing extra hot counters.

Expected result: normal `actiondfs` lookup/read/write hot paths have no counter
branches or atomic increments. `actiondfs_instrumented` keeps profiling
available with the cost isolated to explicit stats runs.

Validation:

- Build the VM kernel and standalone VM worker.
- Run VM e2e once with `--config=executor_timing_logs` and stats snapshots to
  prove `/proc/actiondfs_stats` is wired.
- Run LLVM smoke with `ACTIOND_LLVM_SMOKE_EXECUTOR_TIMING_LOGS=0` for canonical
  no-counter performance numbers, and use the default timing build when
  measuring counters or collecting analysis snapshots.

### Staged Open/Write Fast Path

Goal: reduce action-time staged-write overhead before optimizing output
collection, because LLVM timing shows `execute/process_io` dominates while
`output_upload/collect` is already much smaller.

Current shape:

- `kernel/actiondfs/actiondfs.c:2960` creates the real staged file, but does
  not keep it open.
- `kernel/actiondfs/actiondfs.c:3384` mostly validates writable input behavior.
- `kernel/actiondfs/actiondfs.c:1612` reopens the real staged backing file for
  each write, then closes it.

Plan:

1. Add a per-open `file->private_data` context for staged files.
   - On open, resolve/open the real staged backing file once.
   - On `write_iter`, reuse that backing file.
   - On release, `fput()` it.
   - Also reuse it for staged `read_iter`, `mmap`, `splice_read`, and
     `copy_file_range` where possible.
2. Add `atomic_open` after the per-open context is solid.
   - This combines lookup/create/open for `open(O_CREAT|...)`.
   - This is what can help the single-write case.
   - Per-open backing reuse mostly helps multi-write files; `atomic_open` helps
     avoid the create-then-open path walk even when the file gets only one
     write.
3. Add `stage_dir_ready` or equivalent on actiondfs directory nodes.
   - Counters show `stage_ensure_dir_created=0` but
     `stage_ensure_dir_existing=103548`.
   - That means we are repeatedly walking already-existing parent dirs.
   - Once a parent's stage directory exists, mark it and skip future ensure
     walks for that parent.
4. Add staged-negative lookup filtering.
   - Latest stats showed about 1.37M staged inode lookup negatives.
   - Track whether an actiondfs directory has any staged children.
   - If it definitely has none, skip the underlying staged lookup and go
     straight to input lookup.
   - Mark/update this on create, mkdir, rename, unlink, and rmdir.

Validation:

- Add counters for staged opens per staged write, atomic-open hits, skipped
  ensure-dir calls, and skipped staged-negative lookups.
- Run 3x LLVM smoke before/after and compare `execute/process_io`, staged
  backing opens, ensure-dir components, and lookup negative rates.

### Digest Hints and Promotion

Goal: avoid post-action output hashing only when actiondfs can prove a digest
exactly. Avoid magic path semantics such as `rename(file, "/cas/FINALIZE")`.
That couples actiondfs to a magic CAS path, has awkward return semantics for
the digest, and creates strange races/security boundaries. If kernel-assisted
finalization is worth doing, make it explicit with ioctl or xattr, not magic
rename.

Current userspace path in `src/cas.zig:295`:

1. Open staged file.
2. Read file to SHA-256 it.
3. Chmod to CAS mode.
4. Rename into final CAS path if same filesystem.

That already avoids a second copy. The unavoidable part is hashing unless we
know the digest from how the output was produced.

Plan:

1. First do cheap userspace cleanup.
   - Use `fstat` from the already-open fd instead of a separate path stat.
   - Check whether the final CAS blob exists before chmod/rename for the common
     duplicate case.
   - Cache created CAS shard dirs.
   - Split timing counters for `digest_ns`, `mkdir_ns`, `chmod_ns`,
     `rename_ns`, and `existing_ns`.
2. Add an optional kernel digest hint, not finalization.
   - actiondfs tracks `node->known_digest` only when exact.
   - Invalidate on arbitrary write, truncate, mmap-write risk, rename
     replacement, and similar mutations.
   - Expose via ioctl/xattr: "digest known?" plus digest/size.
   - Userspace collection uses the hint, otherwise falls back to current
     hashing.
3. Start with the cleanest known-digest case.
   - `copy_file_range` from a CAS input file, full source, offset 0 to empty
     output.
   - Then the output digest is exactly the input digest.
   - This probably matches `copy_to_directory`-style copies and avoids hashing
     duplicated outputs.
4. Only consider kernel "promote to CAS" after digest hints prove useful.
   - An ioctl like `ACTIONDFS_IOC_PROMOTE_TO_CAS` is cleaner than magic rename.
   - But if it still has to read and hash in kernel, it mainly avoids userspace
     copies, not the hash work.

Implementation notes:

- Use an explicit trusted metadata channel, likely a `trusted.actiondfs.sha256`
  xattr on the real staged file, for exact digest hints.
- Start with exact digest propagation for full-file `copy_file_range`:
  - source is a CAS-backed input
  - copy starts at source offset `0`
  - destination is empty or overwritten from offset `0`
  - copied byte count equals the CAS blob size
- Invalidate the digest xattr on arbitrary writes, truncates, partial copies,
  writable mmap risks, and overwrite/rename cases.
- Teach CAS output collection to trust validated actiondfs digest hints:
  - stat size must match hinted size
  - final CAS path must exist or the staged file can be chmodded and renamed
    directly to that path
  - fallback remains the current userspace `digestFile` path
- Only prototype a general `digest=write` mode after measuring xattr hit rate.
  Hashing arbitrary writes correctly means hashing the exact bytes written; a
  naive iov hash before `backing_file_write_iter` is not enough because user
  memory can change between the hash copy and the backing write copy.

Validation:

- Add CAS collection counters for digest-hint hits, misses, invalidations, and
  bytes skipped.
- Run LLVM smoke and inspect whether `copy_to_directory` outputs produce enough
  exact digest hints to matter.
- Do not add kernel-side CAS finalization unless digest hints show real value
  and userspace rename/chmod still appears in timing.

End-to-end smoke:

- LLVM build in default strict mode
- synthetic mutating action fails by default
- same synthetic action passes with `mutates_inputs`

## Expected Performance Impact

Strict staged actiondfs should improve default VM execution by:

- removing one overlay mount per action
- removing parent-side actiondfs + overlay remount for output collection
- avoiding overlayfs lookup/write overhead
- making output collection direct from the stage tree

The main risk is replacing mature overlayfs behavior with custom staged write
logic. The implementation should avoid global locks on normal staged reads/writes
and should cache backing staged file handles per opened staged inode where that is
safe.

## Implementation Order

1. Add strict/overlay actiondfs mode selection in the executor, still defaulting to
   overlay.
2. Add actiondfs `stage=` mount parsing and superblock mode handling.
3. Add staged create/read/write/unlink/rename support in actiondfs.
4. Add strict-mode runner mount handling.
5. Add strict-mode output collection from `stage-root`.
6. Add tests for strict mutation rejection and staged output collection.
7. Flip default VM actiondfs mode to strict.
8. Document `mutates_inputs` in the README.
9. Run LLVM and synthetic mutation e2e measurements against strict and overlay
   modes.
