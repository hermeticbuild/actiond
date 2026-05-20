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
