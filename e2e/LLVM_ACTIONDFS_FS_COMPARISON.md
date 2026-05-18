# LLVM actiondfs Filesystem Comparison

This file records the most recent checked-in LLVM VM smoke comparison. Re-run
it with:

```bash
e2e/llvm_fs_compare.sh
```

The current script compares `actiondfs` and `actiondfs_hybrid32`. Each run
starts a fresh `darwin-actiond serve-vm` worker, runs `bazel clean --expunge`,
builds `@llvm-project//llvm:llvm-tblgen`, and writes parsed timing summaries
under the printed comparison directory. The latest comparison output root is
also written to `/tmp/actiond-last-llvm-fs-compare-path`.

## Latest Checked-In Result

Generated on 2026-05-17 after enabling the shared parsed Directory cache.

- Command: `e2e/llvm_fs_compare.sh`
- Comparison output: `/var/folders/p4/xn8y5q_j24l5xwgwd_jx5c340000gn/T/actiond-llvm-fs-compare.92FZsl`
- Workload: `@llvm-project//llvm:llvm-tblgen`, jobs=8
- Actions: 4,469 remote executions per variant

## Summary

All timing values are milliseconds except Bazel elapsed.

| FS                   | Bazel elapsed | Total p50 | Total mean | Input p50 | Fixed/no-wait p50 | Process/IO p50 | Output p50 |
| -------------------- | ------------: | --------: | ---------: | --------: | ----------------: | -------------: | ---------: |
| `actiondfs`          |      609.392s |   814.256 |    989.512 |     2.089 |             4.425 |        805.868 |      1.524 |
| `actiondfs_hybrid32` |      618.077s |   798.814 |    997.906 |     2.032 |             4.257 |        791.084 |      1.472 |

## Stage Timing

| Stage                   | FS                   |    Min |     p25 |     p50 |     p75 |      p95 |    Mean |       Max |
| ----------------------- | -------------------- | -----: | ------: | ------: | ------: | -------: | ------: | --------: |
| total                   | `actiondfs`          | 35.166 | 718.151 | 814.256 | 940.497 | 2335.747 | 989.512 | 27636.321 |
| total                   | `actiondfs_hybrid32` | 40.534 | 704.760 | 798.814 | 921.346 | 2337.044 | 997.906 | 27322.631 |
| input fetch/materialize | `actiondfs`          |  1.178 |   1.879 |   2.089 |   2.397 |    3.433 |   2.277 |    21.974 |
| input fetch/materialize | `actiondfs_hybrid32` |  0.984 |   1.838 |   2.032 |   2.325 |    3.847 |   2.341 |    84.229 |
| execute                 | `actiondfs`          | 29.035 | 713.859 | 810.177 | 935.265 | 2325.293 | 983.696 | 27524.079 |
| execute                 | `actiondfs_hybrid32` | 16.577 | 701.109 | 795.213 | 917.373 | 2327.627 | 992.228 | 27211.286 |
| output upload/collect   | `actiondfs`          |  0.579 |   1.300 |   1.524 |   2.090 |    9.561 |   3.539 |  1305.125 |
| output upload/collect   | `actiondfs_hybrid32` |  0.529 |   1.257 |   1.472 |   2.068 |    9.457 |   3.337 |  1476.515 |

## Runner Timing

`process/io` includes the action process runtime plus lazy CAS reads issued by
the action through the mounted filesystem.

| Runner Stage   | FS                   |    Min |     p25 |     p50 |     p75 |      p95 |    Mean |       Max |
| -------------- | -------------------- | -----: | ------: | ------: | ------: | -------: | ------: | --------: |
| parent prepare | `actiondfs`          |  0.065 |   0.097 |   0.112 |   0.138 |    0.310 |   0.151 |    19.183 |
| parent prepare | `actiondfs_hybrid32` |  0.064 |   0.097 |   0.113 |   0.140 |    0.245 |   0.165 |    22.418 |
| fork           | `actiondfs`          |  0.069 |   0.211 |   0.252 |   0.289 |    0.424 |   0.267 |     4.339 |
| fork           | `actiondfs_hybrid32` |  0.077 |   0.191 |   0.234 |   0.278 |    0.387 |   0.248 |     2.784 |
| child setup    | `actiondfs`          |  0.003 |   0.192 |   0.213 |   0.252 |    0.528 |   0.275 |     4.811 |
| child setup    | `actiondfs_hybrid32` |  0.003 |   0.191 |   0.210 |   0.246 |    0.529 |   0.281 |     7.498 |
| process/io     | `actiondfs`          | 28.177 | 710.122 | 805.868 | 930.227 | 2263.243 | 972.641 | 27515.412 |
| process/io     | `actiondfs_hybrid32` | 15.691 | 697.243 | 791.084 | 912.769 | 2264.761 | 981.049 | 27200.838 |
| wait           | `actiondfs`          |  0.004 |   2.491 |   3.212 |   4.642 |   61.345 |  10.303 |   176.440 |
| wait           | `actiondfs_hybrid32` |  0.008 |   2.403 |   3.100 |   4.559 |   60.373 |  10.425 |   241.022 |
| stdio digest   | `actiondfs`          |  0.001 |   0.002 |   0.002 |   0.003 |    0.004 |   0.003 |     0.557 |
| stdio digest   | `actiondfs_hybrid32` |  0.001 |   0.002 |   0.002 |   0.003 |    0.004 |   0.003 |     0.564 |

## Interpretation

`actiondfs_hybrid32` improved the median per-action path slightly, especially
`process/io`, but the full Bazel wall-clock still favored canonical
`actiondfs` by 8.685s, about 1.4%. The difference is small enough that the
production default should stay `actiondfs` until repeated LLVM runs show a
consistent wall-clock win for the hybrid.
