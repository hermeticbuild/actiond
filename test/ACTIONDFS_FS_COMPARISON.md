# actiondfs Filesystem Comparison

- Generated: `2026-05-17 21:26 EDT`
- Command: `ACTIOND_KERNEL_DOCKER_CONTEXT=colima tools/e2e.sh vm-fs-compare`
- Comparison output: `/var/folders/p4/xn8y5q_j24l5xwgwd_jx5c340000gn/T/actiond-vm-fs-compare.OtoPzq`
- Workload: `test/` stress workspace, 31 remote actions
- Order: `actiondfs_old`, `actiondfs`

This is a small e2e sanity comparison for the standalone stress workspace.
Use `e2e/LLVM_ACTIONDFS_FS_COMPARISON.md` for performance decisions.

## Variants

`actiondfs_old` keeps REAPI-canonical file and directory lists and does pure
binary search in files, then directories, without using the shared parsed
Directory cache.

`actiondfs` uses the shared parsed Directory cache for non-root directories and
materializes per-mount VFS child nodes only for paths that are actually looked
up.

`actiondfs_hybrid32` and `actiondfs_vec` are still registered as experiment
names for the threshold-32 hybrid lookup implementation.

## Summary

All values are milliseconds except action counts.

| Variant              | Total p50 | Total Mean | Input p50 | Execute p50 | Process/IO p50 | Output p50 |
| -------------------- | --------: | ---------: | --------: | ----------: | -------------: | ---------: |
| `actiondfs_old`      |   205.737 |    253.350 |     5.421 |     167.137 |        137.799 |     24.480 |
| `actiondfs`          |   219.455 |    234.130 |    17.638 |     194.087 |        173.095 |     14.111 |

## Stage Timing

All values are milliseconds.

| Stage                   | Variant              |    Min |     p25 |     p50 |     p75 |     p95 |    Mean |     Max |
| ----------------------- | -------------------- | -----: | ------: | ------: | ------: | ------: | ------: | ------: |
| total                   | `actiondfs_old`      | 70.457 | 172.583 | 205.737 | 298.500 | 510.482 | 253.350 | 563.909 |
| total                   | `actiondfs`          | 62.311 | 173.701 | 219.455 | 277.860 | 379.504 | 234.130 | 535.783 |
| input fetch/materialize | `actiondfs_old`      |  1.798 |   4.651 |   5.421 |  16.953 |  18.823 |   9.316 |  20.992 |
| input fetch/materialize | `actiondfs`          |  2.188 |   6.468 |  17.638 |  19.035 |  20.378 |  13.944 |  21.166 |
| execute                 | `actiondfs_old`      | 60.181 | 149.883 | 167.137 | 248.011 | 401.788 | 203.722 | 545.615 |
| execute                 | `actiondfs`          | 49.486 | 155.070 | 194.087 | 224.164 | 318.753 | 197.085 | 504.594 |
| output upload/collect   | `actiondfs_old`      |  6.079 |  12.346 |  24.480 |  38.788 | 149.513 |  40.312 | 273.137 |
| output upload/collect   | `actiondfs`          |  2.794 |   5.693 |  14.111 |  27.414 |  78.489 |  23.101 | 154.377 |

## Runner Timing

`process/io` includes the action process runtime plus lazy CAS reads issued by
the action through the mounted filesystem.

| Runner Stage   | Variant              |    Min |     p25 |     p50 |     p75 |     p95 |    Mean |     Max |
| -------------- | -------------------- | -----: | ------: | ------: | ------: | ------: | ------: | ------: |
| parent prepare | `actiondfs_old`      |  0.048 |   0.067 |   0.074 |   0.099 |  10.125 |   1.420 |  10.929 |
| parent prepare | `actiondfs`          |  0.056 |   0.062 |   0.080 |   5.999 |  19.744 |   4.169 |  20.378 |
| fork           | `actiondfs_old`      |  0.081 |   0.115 |   0.224 |   0.513 |   0.829 |   0.337 |   1.042 |
| fork           | `actiondfs`          |  0.049 |   0.123 |   0.285 |   0.544 |   1.664 |   0.508 |   1.887 |
| child setup    | `actiondfs_old`      |  0.006 |   0.219 |   0.315 |   0.484 |   0.896 |   0.413 |   2.113 |
| child setup    | `actiondfs`          |  0.003 |   0.192 |   0.355 |   0.569 |   1.297 |   0.457 |   1.973 |
| process/io     | `actiondfs_old`      | 55.152 | 132.203 | 137.799 | 184.896 | 324.247 | 168.537 | 495.816 |
| process/io     | `actiondfs`          | 44.001 | 130.166 | 173.095 | 191.140 | 291.075 | 172.169 | 457.405 |
| wait           | `actiondfs_old`      |  4.728 |  16.010 |  26.778 |  51.936 |  61.675 |  32.995 |  88.231 |
| wait           | `actiondfs`          |  4.536 |  14.859 |  16.664 |  27.984 |  33.558 |  19.761 |  46.404 |
| stdio digest   | `actiondfs_old`      |  0.001 |   0.002 |   0.003 |   0.006 |   0.008 |   0.004 |   0.020 |
| stdio digest   | `actiondfs`          |  0.001 |   0.002 |   0.002 |   0.005 |   0.006 |   0.004 |   0.017 |

## Interpretation

This stress run shows the cached `actiondfs` implementation reducing mean total
time and output collection time, but median input and process/io are worse than
`actiondfs_old`. The small stress workspace is noisy and has only 31 actions,
so the larger LLVM smoke is the decisive comparison.
