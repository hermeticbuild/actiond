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

The VM kernel is built by `linux.bzl` from the kernel archive declared in
`MODULE.bazel`; do not reintroduce the old Docker-backed Kbuild path. During
local linux.bzl development, keep the `local_path_override` in `MODULE.bazel`
pointing at `/Users/dzbarsky/linux.bzl` and verify the kernel with the remote
Bazel config:

```bash
bazel build --config=remote //vm:linux_kernel_zst
```

Use `--config=remote` for large kernel/package Bazel builds from this repo
unless the user explicitly asks for a local-only build.
For `tools/e2e.sh` repo-side build steps, pass it through with:

```bash
ACTIOND_REPO_BAZEL_FLAGS=--config=remote tools/e2e.sh vm
```

The VM guest owns the REAPI CAS and ActionCache on a writable ext4 disk image
attached as a virtio block device and mounted at `/cas`. In VM mode there is a
single guest-owned CAS; `darwin-actiond serve-vm` forwards CAS, ByteStream,
ActionCache, Capabilities, and Execute traffic over vsock to `linux-actiond` in
the guest. VM e2e therefore validates API-visible execution behavior for one
running VM and a native guest filesystem.

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
ACTIOND_E2E_KEEP_TMP=1 ACTIOND_REPO_BAZEL_FLAGS="--config=remote --config=executor_timing_logs" tools/e2e.sh vm
```

When investigating actiondfs behavior inside a running guest, enable stats
before reading `/proc/actiondfs_stats`. The normal `actiondfs` filesystem has
stats compiled out; `--actiondfs-stats` makes the guest mount
`actiondfs_instrumented` instead. For VM e2e, setting
`ACTIOND_E2E_ACTIONDFS_STATS_PATH=/path/to/stats.txt` passes that flag to
`serve-vm` and writes snapshots. The proc file reports VM-lifetime counters for
directory cache hits/misses, parses, lookups, readdir, CAS blob opens, backing
reads, splice reads, mmap calls, and stale retry events.

Then update the timing summary next to the stress workspace:

```bash
test/parse_timings.py /path/to/actiond.log \
  --mode vm \
  --command 'ACTIOND_E2E_KEEP_TMP=1 ACTIOND_REPO_BAZEL_FLAGS="--config=remote --config=executor_timing_logs" tools/e2e.sh vm' \
  --output test/STRESS_TIMINGS.md
```

Keep `test/STRESS_TIMINGS.md` current when the synthetic stress workload itself
changes or when you need targeted coverage for source directories, generated
tree artifacts, nested individual inputs, or output directory handling. Do not
use the stress summary as the primary actiondfs performance comparison; use the
LLVM smoke below for that.

## LLVM Smoke

For a more realistic VM remote-execution smoke than the small local stress
workspace, run `@llvm-project//llvm:llvm-tblgen` from this repo's `@llvm`
module dependency against `darwin-actiond serve-vm`. Do not use
`@llvm//runtimes:resource_directory` as the default smoke; it is too small and
less representative.

Use actiond as both executor and cache, and disable remote cache compression
because actiond does not support it yet. Use the musl Linux target and host
platforms so the smoke avoids glibc runtime actions and exec tools built by the
smoke are Linux arm64 musl binaries:

```bash
cd /Users/dzbarsky/actiond
bazel clean --expunge
bazel build @llvm-project//llvm:llvm-tblgen \
  --platforms=@llvm//platforms:linux_arm64_musl \
  --host_platform=@llvm//platforms:linux_arm64_musl \
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

The same smoke is wrapped by:

```bash
e2e/llvm_tblgen_smoke.sh
```

The standalone wrapper only passes `--jobs` when `ACTIOND_LLVM_SMOKE_JOBS` is
set. The fresh-worker runner below defaults that variable to `8` for stable
before/after comparisons; set it to an empty value to measure Bazel's own
default job count.

To run the LLVM VM smoke from a fresh worker and collect timing summaries, use:

```bash
e2e/run_llvm_vm_smoke.sh
```

That script starts a fresh VM worker, runs the same `llvm-tblgen` smoke, writes
parsed timing summaries under the printed output directory, and records the
latest output root in `/tmp/actiond-last-llvm-vm-smoke-path`.
The parser also includes raw TCP-to-vsock bridge byte/read/write counts when
`darwin-actiond serve-vm` logs `vm bridge timing` lines.
The runner leaves actiondfs stats and stats snapshots disabled by default to
reduce benchmark noise; set `ACTIOND_LLVM_SMOKE_ACTIONDFS_STATS=1` to mount
`actiondfs_instrumented` and collect `/proc/actiondfs_stats` snapshots.
Executor timing logs are compiled out by default with
`--//:executor_timing_logs=false`; this runner enables them by default for
parsed timing summaries. Set `ACTIOND_LLVM_SMOKE_EXECUTOR_TIMING_LOGS=0` to
build the no-log server path, in which case the VM timing markdown is skipped.

For actiondfs performance work, this LLVM smoke is the canonical before/after
measurement. Keep `e2e/LLVM_VM_SMOKE_TIMINGS.md` current when changing
actiondfs lookup, readdir, read, splice, mmap, caching, or materialization
behavior. The stress timings are secondary synthetic coverage.

The VM runner defaults `ACTIOND_LLVM_SMOKE_WARMUP_TARGET` to
`//e2e:llvm_exec_warmup`. That target uses a custom `cfg = "exec"` wrapper
around `@llvm-project//llvm:llvm-min-tblgen`; aquery showed it has the same
2,403 action keys as the Linux-musl exec-config subset of the VM
`llvm-tblgen` build. Keep this warmup if you need VM and mac-host measurements
to have closer action counts.

The mac-host baseline in that runner uses the same Linux musl target platform,
but intentionally keeps the host platform as default macOS. Do not set the
local mac-host baseline to `--host_platform=@llvm//platforms:linux_arm64_musl`;
Bazel would build Linux host tools and then try to run them on Darwin.

If you suspect a setup target explains a VM/mac action-count gap, validate it
with `bazel aquery` before changing the warmup. The checked comparison showed
the VM `llvm-tblgen` graph has 5,341 configured actions, the mac-host graph has
3,637, and `@llvm//runtimes:resource_directory` has only 597, so it is not the
whole gap. That target also exposed a split-invocation TreeArtifact issue when
used as a warmup.
