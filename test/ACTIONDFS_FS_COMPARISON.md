# actiondfs Filesystem Comparison

- Generated: `2026-05-17 22:19 EDT`
- Command: `ACTIOND_KERNEL_DOCKER_CONTEXT=colima tools/e2e.sh vm-fs-compare`
- Comparison output: `/var/folders/p4/xn8y5q_j24l5xwgwd_jx5c340000gn/T/actiond-vm-fs-compare.BaqQmo`
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

## Summary

All values are milliseconds except action counts.

| Variant              | Total p50 | Total Mean | Input p50 | Execute p50 | Process/IO p50 | Output p50 |
| -------------------- | --------: | ---------: | --------: | ----------: | -------------: | ---------: |
| `actiondfs_old`      |   222.453 |    303.296 |     5.478 |     176.500 |        146.204 |     12.569 |
| `actiondfs`          |   208.601 |    266.484 |     4.949 |     180.355 |        145.986 |     19.685 |

## Stage Timing

All values are milliseconds.

| Stage                   | Variant              |    Min |     p25 |     p50 |     p75 |     p95 |    Mean |     Max |
| ----------------------- | -------------------- | -----: | ------: | ------: | ------: | ------: | ------: | ------: |
| total                   | `actiondfs_old`      | 70.900 | 179.445 | 222.453 | 447.894 | 595.294 | 303.296 | 649.256 |
| total                   | `actiondfs`          | 80.320 | 178.535 | 208.601 | 350.206 | 512.489 | 266.484 | 724.537 |
| input fetch/materialize | `actiondfs_old`      |  3.581 |   3.913 |   5.478 |  22.226 |  23.294 |  12.356 |  23.602 |
| input fetch/materialize | `actiondfs`          |  2.598 |   4.160 |   4.949 |   6.144 |   9.744 |   5.480 |  10.879 |
| execute                 | `actiondfs_old`      | 55.872 | 157.432 | 176.500 | 398.892 | 472.351 | 253.756 | 631.259 |
| execute                 | `actiondfs`          | 69.365 | 152.027 | 180.355 | 272.234 | 448.344 | 218.634 | 500.941 |
| output upload/collect   | `actiondfs_old`      |  6.540 |   9.083 |  12.569 |  27.593 | 175.647 |  37.184 | 192.427 |
| output upload/collect   | `actiondfs`          |  3.851 |   8.152 |  19.685 |  27.961 | 133.412 |  42.370 | 442.434 |

## Runner Timing

`process/io` includes the action process runtime plus lazy CAS reads issued by
the action through the mounted filesystem.

| Runner Stage   | Variant              |    Min |     p25 |     p50 |     p75 |     p95 |    Mean |     Max |
| -------------- | -------------------- | -----: | ------: | ------: | ------: | ------: | ------: | ------: |
| parent prepare | `actiondfs_old`      |  0.052 |   0.066 |   0.078 |   0.258 |  14.711 |   2.144 |  15.576 |
| parent prepare | `actiondfs`          |  0.054 |   0.069 |   0.085 |   0.103 |   0.975 |   0.788 |  19.245 |
| fork           | `actiondfs_old`      |  0.079 |   0.158 |   0.463 |   0.728 |   1.276 |   0.532 |   1.952 |
| fork           | `actiondfs`          |  0.081 |   0.137 |   0.280 |   0.452 |   0.731 |   0.338 |   1.704 |
| child setup    | `actiondfs_old`      |  0.002 |   0.146 |   0.402 |   0.580 |   0.796 |   0.375 |   1.018 |
| child setup    | `actiondfs`          |  0.003 |   0.247 |   0.317 |   0.478 |   0.657 |   0.350 |   0.955 |
| process/io     | `actiondfs_old`      | 51.129 | 141.950 | 146.204 | 357.249 | 455.927 | 226.801 | 548.742 |
| process/io     | `actiondfs`          | 62.797 | 128.300 | 145.986 | 232.042 | 415.322 | 189.997 | 456.671 |
| wait           | `actiondfs_old`      |  4.156 |  12.824 |  15.864 |  38.140 |  51.566 |  23.889 |  80.930 |
| wait           | `actiondfs`          |  5.922 |  18.568 |  27.895 |  36.251 |  44.759 |  27.143 |  50.150 |
| stdio digest   | `actiondfs_old`      |  0.001 |   0.002 |   0.003 |   0.004 |   0.006 |   0.003 |   0.009 |
| stdio digest   | `actiondfs`          |  0.001 |   0.002 |   0.002 |   0.004 |   0.012 |   0.004 |   0.021 |

## Interpretation

This stress run shows the cached `actiondfs` implementation reducing median and
mean total time, and the compact materialized-child list cuts input
fetch/materialization versus the no-cache baseline. Output collection is still
noisy because producer actions can dominate the small 31-action workload, so
the larger LLVM smoke remains the decisive comparison.
