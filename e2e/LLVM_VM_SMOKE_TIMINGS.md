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

- Generated: `2026-05-17 23:33:58 EDT`
- Command: `e2e/run_llvm_vm_smoke.sh`
- Output root: `/var/folders/p4/xn8y5q_j24l5xwgwd_jx5c340000gn/T/actiond-llvm-vm-smoke.UoFQR7`
- Workload: `@llvm-project//llvm:llvm-tblgen`, jobs=8
- Bazel elapsed: `632.048s`
- Remote executions: `4469`

## Stage Timing

All values are milliseconds.

| Stage                   |    Min |     p25 |     p50 |     p75 |      p95 |     Mean |       Max |
| ----------------------- | -----: | ------: | ------: | ------: | -------: | -------: | --------: |
| total                   | 35.303 | 729.248 | 840.234 | 995.507 | 2426.904 | 1024.392 | 26461.370 |
| input fetch/materialize |  0.866 |   1.920 |   2.150 |   2.524 |    3.854 |    2.431 |    49.391 |
| execute                 | 29.586 | 725.049 | 835.964 | 989.951 | 2417.001 | 1018.403 | 26348.139 |
| output upload/collect   |  0.611 |   1.296 |   1.552 |   2.200 |    9.434 |    3.558 |  1758.227 |

## Runner Timing

`process/io` includes the action process runtime, stdout/stderr drain, and lazy
filesystem reads issued by the action through the mounted actiondfs tree.

| Runner Stage   |    Min |     p25 |     p50 |     p75 |      p95 |    Mean |       Max |
| -------------- | -----: | ------: | ------: | ------: | -------: | ------: | --------: |
| parent prepare |  0.063 |   0.098 |   0.114 |   0.139 |    0.299 |   0.160 |    19.061 |
| fork           |  0.071 |   0.201 |   0.240 |   0.272 |    0.391 |   0.253 |     2.104 |
| child setup    |  0.003 |   0.193 |   0.216 |   0.260 |    0.529 |   0.277 |     5.537 |
| process/io     | 28.666 | 721.681 | 831.834 | 984.308 | 2353.963 | 1007.170 | 26339.150 |
| wait           |  0.006 |   2.176 |   2.874 |   4.404 |   63.035 |  10.481 |   243.954 |
| stdio digest   |  0.001 |   0.002 |   0.003 |   0.003 |    0.005 |   0.004 |     0.659 |

## Notes

The `execute` bucket dominates this workload. With lazy actiondfs inputs, most
filesystem page and metadata misses happen while the child process is running,
so that time appears in `execute`, primarily in `process/io`, rather than in
`input fetch/materialize`.
