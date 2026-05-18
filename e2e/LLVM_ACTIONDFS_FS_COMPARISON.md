# LLVM actiondfs Filesystem Comparison

This file records the most recent checked-in LLVM VM smoke comparison. Re-run
it with:

```bash
e2e/llvm_fs_compare.sh
```

The current script compares `actiondfs_old` and `actiondfs`. Each run
starts a fresh `darwin-actiond serve-vm` worker, runs `bazel clean --expunge`,
builds `@llvm-project//llvm:llvm-tblgen`, and writes parsed timing summaries
under the printed comparison directory. The latest comparison output root is
also written to `/tmp/actiond-last-llvm-fs-compare-path`.

## Latest Checked-In Result

Generated on 2026-05-17 after adding the `actiondfs_old` no-cache baseline and
sparse per-mount cached child materialization in `actiondfs`.

- Command: `e2e/llvm_fs_compare.sh`
- Comparison output: `/var/folders/p4/xn8y5q_j24l5xwgwd_jx5c340000gn/T/actiond-llvm-fs-compare.aYzE13`
- Workload: `@llvm-project//llvm:llvm-tblgen`, jobs=8
- Actions: 4,469 remote executions per variant

## Summary

All timing values are milliseconds except Bazel elapsed.

| FS                   | Bazel elapsed | Total p50 | Total mean | Input p50 | Fixed/no-wait p50 | Process/IO p50 | Output p50 |
| -------------------- | ------------: | --------: | ---------: | --------: | ----------------: | -------------: | ---------: |
| `actiondfs_old`      |      624.272s |   797.786 |   1003.265 |     2.136 |             5.703 |        787.329 |      2.740 |
| `actiondfs`          |      612.943s |   793.774 |    994.546 |     2.087 |             4.401 |        786.047 |      1.504 |

## Stage Timing

| Stage                   | FS                   |    Min |     p25 |     p50 |     p75 |      p95 |    Mean |       Max |
| ----------------------- | -------------------- | -----: | ------: | ------: | ------: | -------: | ------: | --------: |
| total                   | `actiondfs_old`      | 25.014 | 698.771 | 797.786 | 946.038 | 2492.443 | 1003.265 | 28090.655 |
| total                   | `actiondfs`          | 33.243 | 701.693 | 793.774 | 931.148 | 2474.662 |  994.546 | 27703.582 |
| input fetch/materialize | `actiondfs_old`      |  1.127 |   1.900 |   2.136 |   2.531 |    4.041 |    2.496 |   154.973 |
| input fetch/materialize | `actiondfs`          |  0.899 |   1.870 |   2.087 |   2.406 |    3.638 |    2.315 |    28.714 |
| execute                 | `actiondfs_old`      | 22.032 | 693.336 | 791.743 | 940.094 | 2477.791 |  995.640 | 27978.339 |
| execute                 | `actiondfs`          | 27.829 | 697.494 | 789.602 | 927.126 | 2461.397 |  988.315 | 27593.837 |
| output upload/collect   | `actiondfs_old`      |  0.801 |   2.222 |   2.740 |   4.477 |   13.472 |    5.129 |  1683.380 |
| output upload/collect   | `actiondfs`          |  0.458 |   1.282 |   1.504 |   2.042 |   10.099 |    3.916 |  2137.459 |

## Runner Timing

`process/io` includes the action process runtime plus lazy CAS reads issued by
the action through the mounted filesystem.

| Runner Stage   | FS                   |    Min |     p25 |     p50 |     p75 |      p95 |    Mean |       Max |
| -------------- | -------------------- | -----: | ------: | ------: | ------: | -------: | ------: | --------: |
| parent prepare | `actiondfs_old`      |  0.065 |   0.100 |   0.114 |   0.142 |    0.296 |   0.175 |    28.489 |
| parent prepare | `actiondfs`          |  0.060 |   0.098 |   0.115 |   0.142 |    0.384 |   0.177 |    26.622 |
| fork           | `actiondfs_old`      |  0.061 |   0.189 |   0.208 |   0.237 |    0.352 |   0.225 |     1.266 |
| fork           | `actiondfs`          |  0.070 |   0.218 |   0.281 |   0.324 |    0.477 |   0.290 |     1.754 |
| child setup    | `actiondfs_old`      |  0.002 |   0.189 |   0.212 |   0.254 |    0.501 |   0.270 |     5.201 |
| child setup    | `actiondfs`          |  0.003 |   0.189 |   0.211 |   0.254 |    0.551 |   0.272 |     5.175 |
| process/io     | `actiondfs_old`      | 21.405 | 689.278 | 787.329 | 933.913 | 2405.297 | 984.404 | 27969.079 |
| process/io     | `actiondfs`          | 26.794 | 694.074 | 786.047 | 922.350 | 2395.695 | 977.294 | 27584.076 |
| wait           | `actiondfs_old`      |  0.212 |   2.436 |   3.164 |   4.623 |   61.153 |  10.508 |   217.380 |
| wait           | `actiondfs`          |  0.339 |   2.127 |   2.800 |   4.202 |   63.575 |  10.222 |   125.217 |
| stdio digest   | `actiondfs_old`      |  0.001 |   0.002 |   0.002 |   0.003 |    0.004 |   0.003 |     0.932 |
| stdio digest   | `actiondfs`          |  0.001 |   0.002 |   0.003 |   0.003 |    0.005 |   0.003 |     0.895 |

## Interpretation

Cached `actiondfs` beat the no-cache `actiondfs_old` baseline by 11.329s of
Bazel wall time, about 1.8%. Median total action time improved by 4.012ms,
median fixed overhead without wait improved by 1.302ms, and median output
collection improved by 1.236ms. The p95 and mean totals also improved.

The gain is real but modest because `process/io` dominates this workload. The
cache mostly trims repeated Directory parsing and per-mount child allocation,
then shows up as lower fixed overhead and fewer long input-materialization
outliers.
