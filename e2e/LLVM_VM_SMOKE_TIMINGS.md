# LLVM VM Smoke Timings

This file records the most recent checked-in LLVM VM smoke run. Re-run it with:

```bash
e2e/run_llvm_vm_smoke.sh
```

The script starts a fresh `darwin-actiond serve-vm` worker, runs `bazel clean
--expunge`, builds `@llvm-project//llvm:llvm-tblgen`, and writes parsed timing
summaries under the printed output directory. The latest output root is also
written to `/tmp/actiond-last-llvm-vm-smoke-path`.

## Latest Checked-In Result

- Generated: `2026-05-18 10:02:31 EDT`
- Command: `e2e/run_llvm_vm_smoke.sh`
- Output root: `/var/folders/p4/xn8y5q_j24l5xwgwd_jx5c340000gn/T/actiond-llvm-vm-smoke.SWSmmb`
- Workload: `@llvm-project//llvm:llvm-tblgen`, jobs=8
- Bazel elapsed: `304.864s`
- Remote executions: `4469`

## Stage Timing

All values are milliseconds.

| Stage                   |    Min |     p25 |     p50 |     p75 |      p95 |     Mean |       Max |
| ----------------------- | -----: | ------: | ------: | ------: | -------: | -------: | --------: |
| total                   | 12.576 | 189.657 | 226.411 | 302.125 | 1703.820 |  438.992 | 26658.858 |
| input fetch/materialize |  1.018 |   2.289 |   2.905 |   3.863 |    6.785 |    3.488 |   134.219 |
| execute                 | 10.616 | 183.923 | 220.207 | 296.086 | 1687.573 |  430.824 | 26546.206 |
| output upload/collect   |  0.537 |   1.569 |   2.225 |   3.667 |   11.510 |    4.680 |  1904.868 |

## Runner Timing

`process/io` includes the action process runtime, stdout/stderr drain, and lazy
filesystem reads issued by the action through the mounted actiondfs tree.

| Runner Stage   |    Min |     p25 |     p50 |     p75 |      p95 |    Mean |       Max |
| -------------- | -----: | ------: | ------: | ------: | -------: | ------: | --------: |
| parent prepare |  0.058 |   0.109 |   0.134 |   0.165 |    0.391 |   0.194 |    21.353 |
| fork           |  0.087 |   0.169 |   0.199 |   0.235 |    0.487 |   0.238 |     6.692 |
| child setup    |  0.002 |   0.189 |   0.234 |   0.349 |    0.971 |   0.371 |    13.146 |
| process/io     | 10.034 | 179.942 | 215.072 | 290.392 | 1586.686 | 416.418 | 26536.243 |
| wait           |  0.107 |   2.535 |   3.575 |   5.696 |   77.100 |  13.543 |   368.954 |
| stdio digest   |  0.001 |   0.002 |   0.002 |   0.003 |    0.005 |   0.004 |     0.640 |

## Notes

The `execute` bucket dominates this workload. With lazy actiondfs inputs, most
filesystem page and metadata misses happen while the child process is running,
so that time appears in `execute`, primarily in `process/io`, rather than in
`input fetch/materialize`.
