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

- Generated: `2026-05-17 22:41:51 EDT`
- Command: `e2e/run_llvm_vm_smoke.sh`
- Output root: `/var/folders/p4/xn8y5q_j24l5xwgwd_jx5c340000gn/T/actiond-llvm-vm-smoke.Vk9Dbf`
- Workload: `@llvm-project//llvm:llvm-tblgen`, jobs=8
- Bazel elapsed: `620.721s`
- Remote executions: `4469`

## Stage Timing

All values are milliseconds.

| Stage                   |    Min |     p25 |     p50 |     p75 |      p95 |     Mean |       Max |
| ----------------------- | -----: | ------: | ------: | ------: | -------: | -------: | --------: |
| total                   | 45.761 | 701.078 | 800.298 | 950.756 | 2406.383 | 1003.787 | 27935.951 |
| input fetch/materialize |  0.985 |   1.885 |   2.103 |   2.437 |    3.939 |    2.418 |    73.556 |
| execute                 | 34.034 | 696.485 | 795.768 | 946.027 | 2396.762 |  997.764 | 27823.196 |
| output upload/collect   |  0.421 |   1.293 |   1.548 |   2.187 |   10.043 |    3.605 |  1308.378 |

## Runner Timing

`process/io` includes the action process runtime, stdout/stderr drain, and lazy
filesystem reads issued by the action through the mounted actiondfs tree.

| Runner Stage   |    Min |     p25 |     p50 |     p75 |      p95 |    Mean |       Max |
| -------------- | -----: | ------: | ------: | ------: | -------: | ------: | --------: |
| parent prepare |  0.067 |   0.101 |   0.118 |   0.146 |    0.278 |   0.183 |    27.492 |
| fork           |  0.087 |   0.195 |   0.209 |   0.239 |    0.376 |   0.232 |     4.477 |
| child setup    |  0.003 |   0.193 |   0.215 |   0.260 |    0.532 |   0.284 |     6.574 |
| process/io     | 32.872 | 693.490 | 792.274 | 941.553 | 2324.544 | 986.606 | 27814.140 |
| wait           |  0.005 |   2.157 |   2.865 |   4.315 |   62.205 |  10.397 |   211.695 |
| stdio digest   |  0.001 |   0.002 |   0.002 |   0.003 |    0.005 |   0.003 |     0.572 |

## Notes

The `execute` bucket dominates this workload. With lazy actiondfs inputs, most
filesystem page and metadata misses happen while the child process is running,
so that time appears in `execute`, primarily in `process/io`, rather than in
`input fetch/materialize`.
