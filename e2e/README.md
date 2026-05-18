# E2E Smoke Tests

This directory holds heavier, repo-adjacent smoke tests that are useful when
changing the VM executor but should not be part of the normal `tools/e2e.sh`
stress workspace.

## LLVM tblgen VM Smoke

`llvm_tblgen_smoke.sh` builds `@llvm-project//llvm:llvm-tblgen` from
`/Users/dzbarsky/bootstrapped2` against an already-running actiond VM worker.
It uses the bootstrapped workspace's musl Linux target and host platforms so the
build avoids glibc runtime actions and generated exec tools are Linux arm64
musl binaries:

```bash
e2e/llvm_tblgen_smoke.sh
```

Start `darwin-actiond serve-vm` on `127.0.0.1:8998` before running it. The
script runs `bazel clean --expunge` by default so a fresh worker CAS gets a full
upload.

## LLVM actiondfs Comparison

`llvm_fs_compare.sh` starts a fresh VM worker for each requested actiondfs
filesystem type, runs the LLVM tblgen smoke, and writes parsed timing summaries
under a comparison directory:

```bash
e2e/llvm_fs_compare.sh
```

By default it compares `actiondfs`, `actiondfs_hybrid16`,
`actiondfs_hybrid32`, and `actiondfs_hybrid64` with an 8 CPU, 4096 MiB VM. The
last output directory is written to
`/tmp/actiond-last-llvm-fs-compare-path`. The current checked-in comparison is
in `LLVM_ACTIONDFS_FS_COMPARISON.md`.
