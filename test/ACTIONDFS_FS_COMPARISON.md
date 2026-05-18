# actiondfs Filesystem Comparison

- Generated: `2026-05-17`
- Command: `ACTIOND_KERNEL_DOCKER_CONTEXT=colima tools/e2e.sh vm-fs-compare`
- Comparison output: `/var/folders/p4/xn8y5q_j24l5xwgwd_jx5c340000gn/T/actiond-vm-fs-compare.pYcljo`
- Workload: `test/` stress workspace, 31 remote actions
- Order: `actiondfs`, `actiondfs_hybrid32`

## Variants

`actiondfs` keeps REAPI-canonical file and directory lists and does pure binary
search in files, then directories.

`actiondfs_hybrid32` uses the same canonical file and directory lists, but
stops binary search once the remaining range is at most 32 and then finishes
with a linear scan.

`actiondfs_vec` is still registered as a compatibility name for the threshold
32 hybrid, but it is not included in this default comparison to avoid duplicate
measurements.

## Summary

All values are milliseconds except action counts.

| Variant              | Total p50 | Total Mean | Input p50 | Execute p50 | Process/IO p50 | Output p50 |
| -------------------- | --------: | ---------: | --------: | ----------: | -------------: | ---------: |
| `actiondfs`          |   212.221 |    262.181 |    10.081 |     179.811 |        146.976 |     15.704 |
| `actiondfs_hybrid32` |   225.179 |    247.695 |     5.708 |     190.027 |        158.936 |     16.573 |

## Stage Timing

All values are milliseconds.

| Stage                   | Variant              |    Min |     p25 |     p50 |     p75 |     p95 |    Mean |     Max |
| ----------------------- | -------------------- | -----: | ------: | ------: | ------: | ------: | ------: | ------: |
| total                   | `actiondfs`          | 174.218 | 189.213 | 212.221 | 316.713 | 409.221 | 262.181 | 488.106 |
| total                   | `actiondfs_hybrid32` |  67.433 | 170.318 | 225.179 | 324.223 | 450.352 | 247.695 | 523.696 |
| input fetch/materialize | `actiondfs`          |   1.580 |   4.093 |  10.081 |  17.916 |  20.472 |  10.259 |  21.012 |
| input fetch/materialize | `actiondfs_hybrid32` |   1.742 |   4.339 |   5.708 |  23.343 |  25.770 |  10.519 |  26.588 |
| execute                 | `actiondfs`          | 149.911 | 163.523 | 179.811 | 247.286 | 317.332 | 219.715 | 468.837 |
| execute                 | `actiondfs_hybrid32` |  57.845 | 150.930 | 190.027 | 271.811 | 383.726 | 212.467 | 501.424 |
| output upload/collect   | `actiondfs`          |   4.500 |  10.084 |  15.704 |  34.961 | 107.212 |  32.208 | 166.419 |
| output upload/collect   | `actiondfs_hybrid32` |   5.216 |  12.360 |  16.573 |  19.630 |  76.981 |  24.708 | 182.914 |

## Runner Timing

`process/io` includes the action process runtime plus lazy CAS reads issued by
the action through the mounted filesystem.

| Runner Stage   | Variant              |    Min |     p25 |     p50 |     p75 |     p95 |    Mean |     Max |
| -------------- | -------------------- | -----: | ------: | ------: | ------: | ------: | ------: | ------: |
| parent prepare | `actiondfs`          |  0.048 |   0.065 |   0.080 |   0.476 |  15.018 |   3.380 |  15.948 |
| parent prepare | `actiondfs_hybrid32` |  0.050 |   0.058 |   0.067 |   0.082 |   0.417 |   0.682 |  17.970 |
| fork           | `actiondfs`          |  0.074 |   0.101 |   0.146 |   0.362 |   0.579 |   0.262 |   1.238 |
| fork           | `actiondfs_hybrid32` |  0.047 |   0.084 |   0.105 |   0.129 |   0.482 |   0.151 |   0.678 |
| child setup    | `actiondfs`          |  0.003 |   0.188 |   0.364 |   0.632 |   1.360 |   0.489 |   2.262 |
| child setup    | `actiondfs_hybrid32` |  0.004 |   0.238 |   0.342 |   0.408 |   0.727 |   0.349 |   0.879 |
| process/io     | `actiondfs`          | 131.546 | 140.372 | 146.976 | 227.122 | 304.499 | 195.753 | 425.801 |
| process/io     | `actiondfs_hybrid32` |  52.735 | 126.620 | 158.936 | 245.637 | 356.065 | 188.335 | 447.717 |
| wait           | `actiondfs`          |  9.775 |  13.763 |  18.998 |  20.426 |  39.143 |  19.812 |  58.578 |
| wait           | `actiondfs_hybrid32` |  4.866 |  17.037 |  21.003 |  28.499 |  48.609 |  22.934 |  53.196 |
| stdio digest   | `actiondfs`          |  0.001 |   0.002 |   0.002 |   0.003 |   0.006 |   0.003 |   0.007 |
| stdio digest   | `actiondfs_hybrid32` |  0.001 |   0.002 |   0.003 |   0.004 |   0.006 |   0.003 |   0.008 |

## Interpretation

This stress run does not show a clear win from switching the default away from
pure binary search. `actiondfs_hybrid32` had the best total mean and lower
median input fetch/materialize time, while `actiondfs` had the best median
total, execute, process/io, and output upload numbers.

The right next step is to run `e2e/llvm_fs_compare.sh` on the larger LLVM smoke
before promoting any thresholded variant to production default.
