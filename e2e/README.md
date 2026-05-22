# E2E Smoke Tests

This directory holds heavier, repo-adjacent smoke tests that are useful when
changing the VM executor but should not be part of the normal `tools/e2e.sh`
stress workspace.

## LLVM tblgen VM Smoke

`llvm_tblgen_smoke.sh` builds `@llvm-project//llvm:llvm-tblgen` from this
repo's `@llvm` module dependency against an already-running actiond VM worker.
It uses `@llvm//platforms:linux_arm64_musl` for both the target and host
platforms, so generated exec tools are Linux arm64 musl binaries that can run
inside the VM. The smoke builds with `-c opt --strip=always
--stripopt=--strip-all`:

```bash
e2e/llvm_tblgen_smoke.sh
```

Start `darwin-actiond serve-vm` on `127.0.0.1:8998` before running it. The
script runs `bazel clean --expunge` by default so a fresh worker CAS gets a full
upload.

VM mode expects a writable ext4 CAS image attached as virtio-blk. The runner
creates one automatically with `tools/create_ext4_image.sh`; set
`ACTIOND_VM_CAS_IMAGE=/path/cas.ext4` to reuse a persistent image, and
`ACTIOND_VM_CAS_IMAGE_SIZE_MIB=8192` to override the default sparse size. If
the host lacks `mkfs.ext4`, the helper formats through Docker; set
`ACTIOND_EXT4_IMAGE_DOCKER_IMAGE` to use an image that already contains
`mkfs.ext4` and avoid package installation during the run.

## LLVM VM Smoke Runner

`run_llvm_vm_smoke.sh` starts a fresh VM worker, runs the LLVM tblgen smoke,
then runs the same target locally on the macOS host with the same musl target
platform. It writes parsed VM timing summaries and a mac-host elapsed-time
summary under an output directory:

```bash
e2e/run_llvm_vm_smoke.sh
```

By default it uses an 8 CPU, 4096 MiB VM. The last output directory is written
to `/tmp/actiond-last-llvm-vm-smoke-path`. Set `ACTIOND_LLVM_SMOKE_MAC_HOST=0`
to skip the mac-host baseline, or `ACTIOND_LLVM_SMOKE_VM=0` to run only the
mac-host baseline. The runner defaults to `ACTIOND_LLVM_SMOKE_JOBS=8` for
stable comparisons; set it to an empty value to let Bazel choose its default.
By default the VM run first builds
`//e2e:llvm_exec_warmup`, which transitions `@llvm-project//llvm:llvm-min-tblgen`
to the Linux-musl exec configuration. Aquery shows that target exactly matches
the Linux exec-config action set used by the VM `llvm-tblgen` build, so the
subsequent measured build is mostly target actions and is closer to the
mac-host action count. Set `ACTIOND_LLVM_SMOKE_WARMUP_TARGET=` to disable the
warmup, or point it at another label to test a different pre-measure build. The
current checked-in timing summary is in `LLVM_VM_SMOKE_TIMINGS.md`.

Use this LLVM runner as the primary performance comparison for actiondfs changes
to lookup, readdir, read, splice, caching, or execroot materialization.
The standalone stress workspace is still useful for focused synthetic coverage,
but LLVM timing is the repo's canonical actiondfs before/after signal.
When `darwin-actiond serve-vm` logs `vm bridge timing` lines, the parser also
includes raw TCP-to-vsock byte and read/write counts in the VM summary.

Both VM and mac-host runs set the target platform to
`@llvm//platforms:linux_arm64_musl`. The VM run also sets the host platform to
Linux musl because host tools execute inside the VM. The mac-host run leaves the
host platform as macOS, otherwise Bazel would build Linux host tools and then
try to execute them locally on Darwin. Some Bazel output paths still include
`darwin_arm64-opt`; check the compile command target triple, not just the output
directory name.

Do not use `@llvm//runtimes:resource_directory` as the default warmup. Aquery
shows it accounts for only part of the VM/mac configured-action gap: the VM
`llvm-tblgen` graph has 5,341 configured actions, the mac-host graph has 3,637,
and `@llvm//runtimes:resource_directory` has 597. The remaining gap comes
mostly from Linux-musl exec-configuration actions needed by the VM build. The
`//e2e:llvm_exec_warmup` aquery has 2,713 configured actions and the same
2,403 action keys as the Linux exec-config subset of `llvm-tblgen`. As a split
warmup, `resource_directory` also exposes Bazel TreeArtifact materialization
differences that can make the later link miss `libclang_rt.builtins.a`.
