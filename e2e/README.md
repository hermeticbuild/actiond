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
mac-host baseline. Set `ACTIOND_LLVM_SMOKE_WARMUP_TARGET=<label>` to run a
pre-measure VM build and parse only the actiond log slice after that warmup.
The current checked-in timing summary is in `LLVM_VM_SMOKE_TIMINGS.md`.

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
mostly from Linux-musl exec-configuration actions needed by the VM build. As a
split warmup, `resource_directory` also exposes Bazel TreeArtifact
materialization differences that can make the later link miss
`libclang_rt.builtins.a`.
