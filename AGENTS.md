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

On macOS, the Docker-backed kernel build always reuses Docker named volumes for
the localized kernel source and `O=` directory:

```bash
ACTIOND_KERNEL_DOCKER_CONTEXT=colima bazel build //vm:linux_kernel_zst
```

The first run still builds the full kernel. Later runs should reuse Kbuild state
for actiondfs-only edits without changing Bazel action environment. If the cache
looks suspicious, remove the printed `actiond-kernel-src-*` and
`actiond-kernel-out-*` Docker volumes and rerun the same command.

The VM guest owns the REAPI CAS and ActionCache on a writable ext4 disk image
attached as a virtio block device and mounted at `/cas`. The host-side
`darwin-actiond serve-vm` does not keep a second host CAS in VM mode; it
forwards CAS, ByteStream, ActionCache, Capabilities, and Execute requests over
vsock to `linux-actiond` in the guest. VM e2e therefore validates API-visible
execution behavior for one running VM and a native guest filesystem.

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

When investigating actiondfs behavior inside a running guest, read
`/proc/actiondfs_stats`. It reports VM-lifetime counters for directory cache
hits/misses, parses, lookups, readdir, CAS blob opens, backing reads, splice
reads, mmap calls, and stale retry events.

Then update the timing summary next to the stress workspace:

```bash
test/parse_timings.py /path/to/actiond.log \
  --mode vm \
  --command 'ACTIOND_E2E_KEEP_TMP=1 tools/e2e.sh vm' \
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

The same command is wrapped by:

```bash
e2e/llvm_tblgen_smoke.sh
```

To run the LLVM VM smoke from a fresh worker and collect timing summaries, use:

```bash
e2e/run_llvm_vm_smoke.sh
```

That script starts a fresh VM worker, runs the same `llvm-tblgen` smoke, writes
parsed timing summaries under the printed output directory, and records the
latest output root in `/tmp/actiond-last-llvm-vm-smoke-path`.
The parser also includes raw TCP-to-vsock bridge byte/read/write counts when
`darwin-actiond serve-vm` logs `vm bridge timing` lines.

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
