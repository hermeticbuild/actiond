# LLVM VM Smoke Timings

This file records the most recent checked-in LLVM VM smoke run. Re-run it with:

```bash
e2e/run_llvm_vm_smoke.sh
```

The script starts a fresh `darwin-actiond serve-vm` worker, runs `bazel clean
--expunge`, builds `@llvm-project//llvm:llvm-tblgen` from this repo's `@llvm`
module dependency, and writes parsed timing summaries under the printed output
directory. The VM build uses `@llvm//platforms:linux_arm64_musl` for both target
and host platform so generated exec tools run inside the Linux VM without glibc.
The runner also records a mac-host baseline with the same target platform and
the default macOS host platform. The latest output root is written to
`/tmp/actiond-last-llvm-vm-smoke-path`.

## Latest Checked-In Result

- Generated: `2026-05-18 13:00:56 EDT`
- Command: `e2e/run_llvm_vm_smoke.sh`
- Output root: `/var/folders/p4/xn8y5q_j24l5xwgwd_jx5c340000gn/T/actiond-llvm-vm-smoke.EEFec4`
- Workload: `@llvm-project//llvm:llvm-tblgen`, jobs=8
- Target platform: `@llvm//platforms:linux_arm64_musl`
- VM host platform: `@llvm//platforms:linux_arm64_musl`
- Build mode: `-c opt --strip=always --stripopt=--strip-all`
- VM Bazel elapsed: `300.779s`
- VM executions: `4123`
- VM Bazel processes: `4516 processes: 393 internal, 4123 remote`
- Mac-host Bazel elapsed: `166.081s`
- Mac-host processes: `3012 processes: 360 internal, 2652 darwin-sandbox`

## VM Stage Timing

All values are milliseconds.

| Stage                   |    Min |     p25 |     p50 |     p75 |      p95 |    Mean |      Max |
| ----------------------- | -----: | ------: | ------: | ------: | -------: | ------: | -------: |
| total                   | 30.333 | 212.291 | 256.234 | 347.178 | 1972.917 | 498.411 | 7526.967 |
| input fetch/materialize |  0.854 |   2.453 |   3.335 |   4.843 |    9.008 |   4.241 |  143.079 |
| execute                 | 22.469 | 206.056 | 248.409 | 337.717 | 1955.649 | 489.251 | 7507.600 |
| output upload/collect   |  0.620 |   1.756 |   2.492 |   4.122 |   10.856 |   4.919 | 2517.356 |

## Runner Timing

`process/io` includes the action process runtime, stdout/stderr drain, and lazy
filesystem reads issued by the action through the mounted actiondfs tree.

| Runner Stage   |    Min |     p25 |     p50 |     p75 |      p95 |    Mean |      Max |
| -------------- | -----: | ------: | ------: | ------: | -------: | ------: | -------: |
| parent prepare |  0.073 |   0.114 |   0.140 |   0.179 |    0.434 |   0.234 |   27.927 |
| fork           |  0.088 |   0.183 |   0.214 |   0.255 |    0.512 |   0.258 |    6.784 |
| child setup    |  0.003 |   0.210 |   0.279 |   0.439 |    1.270 |   0.448 |   13.591 |
| process/io     | 19.156 | 200.725 | 242.952 | 331.349 | 1854.414 | 472.591 | 7471.247 |
| wait           |  0.207 |   2.850 |   4.052 |   6.716 |   88.697 |  15.648 |  351.268 |
| stdio digest   |  0.001 |   0.002 |   0.002 |   0.003 |    0.005 |   0.004 |    0.642 |

## Notes

The `execute` bucket dominates this workload. With lazy actiondfs inputs, most
filesystem page and metadata misses happen while the child process is running,
so that time appears in `execute`, primarily in `process/io`, rather than in
`input fetch/materialize`.

The mac-host baseline uses the default macOS host platform. The log shows Bazel
running `darwin-sandbox` actions; the script only fixes the target platform to
the same Linux arm64 musl platform for an apples-to-apples target build.
