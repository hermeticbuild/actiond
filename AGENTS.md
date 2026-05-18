# Agent Notes

## Required Checks

Run the normal repository checks before finalizing code changes:

```bash
bazel build //...
bazel test //...
```

For execution changes, also run the e2e harness:

```bash
tools/e2e.sh linux
```

On macOS, use Docker for the Linux chroot path:

```bash
tools/docker/run_linux_e2e.sh
```

For the Virtualization.framework path on macOS, run:

```bash
tools/e2e.sh vm
```

To exercise single-binary embedded artifacts instead of passing the runtime,
kernel, and initramfs paths explicitly, set:

```bash
ACTIOND_E2E_STANDALONE=1 tools/docker/run_linux_e2e.sh
ACTIOND_E2E_STANDALONE=1 tools/e2e.sh vm
```

Do not claim the VM path was tested unless `tools/e2e.sh vm` completed.

The VM guest mounts the host CAS share read-only at `/host-cas` and uses a
tmpfs overlay at `/cas` for guest-side writes. actiondfs reads input blobs from
`/host-cas/blobs/sha256` to avoid overlay/virtiofs stale-handle behavior. The
host imports guest-produced blobs and then asks the guest to delete the staging
upperdir copy once `/host-cas` is visible from inside the guest, so downstream
actions read the stable host-visible copy. VM e2e therefore validates
API-visible execution behavior for one running VM.

## Stress Workspace

The `test/` directory is a standalone Bazel workspace used by `tools/e2e.sh`.
It generates a remote-execution workload with many bare file inputs, nested
individual file inputs, source-directory inputs declared as directory entries,
declared tree-artifact inputs, output files, and output directories. Several
actions intentionally reuse the same generated output directory so the timing
summary can compare tree-artifact reuse against nested individual-file inputs.
The harness copies a Linux `e2e_action_tool` binary into
`test/tool/action-tool` before invoking Bazel against actiond.

The stress timing parser has its own test in the standalone workspace:

```bash
(cd test && bazel test //:parse_timings_test)
```

When collecting executor timing data, keep the e2e temp directory so the
actiond log survives:

```bash
ACTIOND_E2E_KEEP_TMP=1 tools/e2e.sh vm
```

To compare the two in-kernel actiondfs lookup implementations back-to-back,
run:

```bash
tools/e2e.sh vm-fs-compare
```

That mode runs the stress workspace with `actiondfs`, `actiondfs_hybrid16`,
`actiondfs_hybrid32`, and `actiondfs_hybrid64`, keeps the VM logs, and writes
parsed summaries under the printed comparison directory.

Then update the timing summary next to the stress workspace:

```bash
test/parse_timings.py /path/to/actiond.log \
  --mode vm \
  --command 'ACTIOND_E2E_KEEP_TMP=1 tools/e2e.sh vm' \
  --output test/STRESS_TIMINGS.md
```

Keep `test/STRESS_TIMINGS.md` current whenever the stress workload, executor
timing instrumentation, execroot materialization, VM proxying, or output import
path changes.

## LLVM Smoke

For a more realistic VM remote-execution smoke than the small local stress
workspace, run `@llvm-project//llvm:llvm-tblgen` from
`/Users/dzbarsky/bootstrapped2` against `darwin-actiond serve-vm`. Do not use
`//runtimes:resource_directory` as the default smoke; it is too small and less
representative.

Use actiond as both executor and cache, keep BuildBuddy BES from the
`bootstrapped2` `.bazelrc`, and disable remote cache compression because actiond
does not support it yet. Use the musl Linux target and host platforms so the
smoke avoids glibc runtime actions and exec tools built by the smoke are Linux
arm64 musl binaries:

```bash
cd /Users/dzbarsky/bootstrapped2
bazel clean --expunge
bazel build --config=prebuilt @llvm-project//llvm:llvm-tblgen \
  --platforms=//platforms:linux_arm64_musl \
  --host_platform=//platforms:linux_arm64_musl \
  --remote_executor=grpc://127.0.0.1:8998 \
  --remote_cache=grpc://127.0.0.1:8998 \
  --experimental_remote_downloader= \
  --experimental_remote_downloader_local_fallback=true \
  --noremote_cache_compression \
  --noremote_accept_cached \
  --remote_local_fallback=false \
  --remote_upload_local_results=false \
  --disk_cache= \
  --spawn_strategy=remote \
  --genrule_strategy=remote \
  --jobs=8
```

The same command is wrapped by:

```bash
e2e/llvm_tblgen_smoke.sh
```

To compare the in-kernel actiondfs lookup implementations on this workload,
use:

```bash
e2e/llvm_fs_compare.sh
```

That script starts a fresh VM worker for each filesystem type, runs the same
`llvm-tblgen` smoke, writes parsed timing summaries under the printed output
directory, and records the latest output root in
`/tmp/actiond-last-llvm-fs-compare-path`. Keep
`e2e/LLVM_ACTIONDFS_FS_COMPARISON.md` current when changing actiondfs lookup or
materialization behavior.
