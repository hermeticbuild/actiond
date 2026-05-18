# actiondfs Filesystem Comparison

- Generated: `2026-05-17`
- Command: `ACTIOND_KERNEL_DOCKER_CONTEXT=colima tools/e2e.sh vm-fs-compare`
- Comparison output: `/var/folders/p4/xn8y5q_j24l5xwgwd_jx5c340000gn/T/actiond-vm-fs-compare.oCwCXo`
- Workload: `test/` stress workspace, 31 remote actions
- Order: `actiondfs`, `actiondfs_hybrid16`, `actiondfs_hybrid32`, `actiondfs_hybrid64`

## Variants

`actiondfs` keeps REAPI-canonical file and directory lists and does pure binary
search in files, then directories.

`actiondfs_hybrid16`, `actiondfs_hybrid32`, and `actiondfs_hybrid64` use the
same canonical file and directory lists, but stop binary search once the
remaining range is at most the threshold and then finish with a linear scan.

`actiondfs_vec` is still registered as a compatibility name for the threshold
32 hybrid, but it is not included in this default comparison to avoid duplicate
measurements.

## Summary

All values are milliseconds except action counts.

| Variant              | Total p50 | Total Mean | Input p50 | Execute p50 | Process/IO p50 | Output p50 |
| -------------------- | --------: | ---------: | --------: | ----------: | -------------: | ---------: |
| `actiondfs`          |   216.540 |    273.055 |     6.574 |     178.418 |        132.765 |     12.776 |
| `actiondfs_hybrid16` |   229.909 |    241.697 |     5.949 |     209.060 |        177.731 |     14.440 |
| `actiondfs_hybrid32` |   226.652 |    247.440 |     4.044 |     172.241 |        143.551 |     26.993 |
| `actiondfs_hybrid64` |   281.471 |    259.695 |     4.758 |     252.333 |        234.011 |     18.458 |

## Stage Timing

All values are milliseconds.

| Stage                   | Variant              |    Min |     p25 |     p50 |     p75 |     p95 |    Mean |     Max |
| ----------------------- | -------------------- | -----: | ------: | ------: | ------: | ------: | ------: | ------: |
| total                   | `actiondfs`          | 56.521 | 160.536 | 216.540 | 386.531 | 514.358 | 273.055 | 558.720 |
| total                   | `actiondfs_hybrid16` | 58.597 | 177.907 | 229.909 | 294.237 | 406.291 | 241.697 | 550.412 |
| total                   | `actiondfs_hybrid32` | 62.467 | 189.300 | 226.652 | 327.538 | 454.285 | 247.440 | 544.734 |
| total                   | `actiondfs_hybrid64` | 58.694 | 193.261 | 281.471 | 312.736 | 380.894 | 259.695 | 647.626 |
| input fetch/materialize | `actiondfs`          |  1.369 |   4.857 |   6.574 |  10.684 |  18.387 |   8.161 |  18.958 |
| input fetch/materialize | `actiondfs_hybrid16` |  2.994 |   3.872 |   5.949 |  23.867 |  26.540 |  10.965 |  28.395 |
| input fetch/materialize | `actiondfs_hybrid32` |  1.614 |   3.124 |   4.044 |  15.558 |  18.464 |   8.160 |  18.997 |
| input fetch/materialize | `actiondfs_hybrid64` |  1.952 |   3.940 |   4.758 |   8.929 |  18.756 |   7.377 |  19.236 |
| execute                 | `actiondfs`          | 49.202 | 140.193 | 178.418 | 353.575 | 443.928 | 228.060 | 539.744 |
| execute                 | `actiondfs_hybrid16` | 48.737 | 146.566 | 209.060 | 257.738 | 349.679 | 208.448 | 528.745 |
| execute                 | `actiondfs_hybrid32` | 52.565 | 147.861 | 172.241 | 224.753 | 334.699 | 192.584 | 527.509 |
| execute                 | `actiondfs_hybrid64` | 48.958 | 153.352 | 252.333 | 279.553 | 328.790 | 226.642 | 630.492 |
| output upload/collect   | `actiondfs`          |  4.998 |   6.683 |  12.776 |  20.956 | 136.295 |  36.834 | 188.768 |
| output upload/collect   | `actiondfs_hybrid16` |  4.490 |   7.717 |  14.440 |  18.769 |  70.081 |  22.283 | 167.453 |
| output upload/collect   | `actiondfs_hybrid32` |  6.543 |  10.738 |  26.993 |  66.489 | 153.092 |  46.696 | 274.937 |
| output upload/collect   | `actiondfs_hybrid64` |  5.624 |  13.292 |  18.458 |  22.444 |  74.959 |  25.676 | 136.221 |

## Runner Timing

`process/io` includes the action process runtime plus lazy CAS reads issued by
the action through the mounted filesystem.

| Runner Stage   | Variant              |    Min |     p25 |     p50 |     p75 |     p95 |    Mean |     Max |
| -------------- | -------------------- | -----: | ------: | ------: | ------: | ------: | ------: | ------: |
| parent prepare | `actiondfs`          |  0.052 |   0.065 |   0.081 |   0.230 |  10.650 |   1.554 |  12.915 |
| parent prepare | `actiondfs_hybrid16` |  0.054 |   0.069 |   0.089 |   0.532 |  20.566 |   4.636 |  21.153 |
| parent prepare | `actiondfs_hybrid32` |  0.056 |   0.063 |   0.068 |   0.102 |   4.838 |   0.687 |   9.373 |
| parent prepare | `actiondfs_hybrid64` |  0.056 |   0.066 |   0.078 |   0.147 |   0.747 |   0.479 |  10.262 |
| fork           | `actiondfs`          |  0.082 |   0.130 |   0.242 |   0.464 |   0.854 |   0.333 |   1.240 |
| fork           | `actiondfs_hybrid16` |  0.088 |   0.130 |   0.159 |   0.493 |   1.444 |   0.433 |   1.519 |
| fork           | `actiondfs_hybrid32` |  0.078 |   0.094 |   0.120 |   0.184 |   0.885 |   0.232 |   1.282 |
| fork           | `actiondfs_hybrid64` |  0.072 |   0.116 |   0.143 |   0.426 |   0.855 |   0.303 |   1.198 |
| child setup    | `actiondfs`          |  0.003 |   0.144 |   0.253 |   0.463 |   0.924 |   0.331 |   1.247 |
| child setup    | `actiondfs_hybrid16` |  0.003 |   0.219 |   0.405 |   0.594 |   0.913 |   0.429 |   1.238 |
| child setup    | `actiondfs_hybrid32` |  0.003 |   0.208 |   0.332 |   0.479 |   3.029 |   0.662 |   5.411 |
| child setup    | `actiondfs_hybrid64` |  0.003 |   0.225 |   0.318 |   0.462 |   0.639 |   0.350 |   0.661 |
| process/io     | `actiondfs`          | 43.318 | 122.262 | 132.765 | 277.221 | 427.101 | 196.312 | 489.904 |
| process/io     | `actiondfs_hybrid16` | 44.346 | 130.072 | 177.731 | 229.571 | 310.118 | 184.397 | 479.845 |
| process/io     | `actiondfs_hybrid32` | 47.163 | 127.354 | 143.551 | 195.390 | 314.640 | 168.320 | 478.377 |
| process/io     | `actiondfs_hybrid64` | 44.308 | 136.461 | 234.011 | 247.303 | 280.897 | 202.845 | 581.058 |
| wait           | `actiondfs`          |  5.166 |  13.497 |  21.566 |  42.014 |  69.060 |  29.479 |  71.287 |
| wait           | `actiondfs_hybrid16` |  4.069 |  11.133 |  17.392 |  22.570 |  35.442 |  18.523 |  48.387 |
| wait           | `actiondfs_hybrid32` |  4.918 |  15.324 |  22.848 |  28.382 |  39.725 |  22.661 |  48.311 |
| wait           | `actiondfs_hybrid64` |  4.125 |  15.871 |  18.553 |  30.699 |  43.209 |  22.637 |  48.999 |
| stdio digest   | `actiondfs`          |  0.001 |   0.002 |   0.004 |   0.006 |   0.018 |   0.016 |   0.355 |
| stdio digest   | `actiondfs_hybrid16` |  0.001 |   0.002 |   0.003 |   0.004 |   0.008 |   0.004 |   0.010 |
| stdio digest   | `actiondfs_hybrid32` |  0.001 |   0.002 |   0.003 |   0.006 |   0.012 |   0.005 |   0.026 |
| stdio digest   | `actiondfs_hybrid64` |  0.001 |   0.002 |   0.003 |   0.005 |   0.014 |   0.007 |   0.099 |

## Interpretation

This stress run does not show a clear win from switching the default away from
pure binary search. `actiondfs_hybrid32` had the best median execute bucket, but
`actiondfs` had the best median total and process/io numbers. The total mean
favored `actiondfs_hybrid16`, mostly from lower output and wait tails.

The right next step is to run `e2e/llvm_fs_compare.sh` on the larger LLVM smoke
before promoting any thresholded variant to production default.
