# actiondfs Filesystem Comparison

- Generated: `2026-05-17`
- Command: `ACTIOND_KERNEL_DOCKER_CONTEXT=colima tools/e2e.sh vm-fs-compare`
- Comparison output: `/var/folders/p4/xn8y5q_j24l5xwgwd_jx5c340000gn/T/actiond-vm-fs-compare.2KsHgT`
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
| `actiondfs`          |   213.050 |    230.114 |     4.648 |     173.632 |        147.844 |     14.846 |
| `actiondfs_hybrid32` |   191.476 |    229.118 |     4.686 |     155.197 |        132.488 |      9.499 |

## Stage Timing

All values are milliseconds.

| Stage                   | Variant              |    Min |     p25 |     p50 |     p75 |     p95 |    Mean |     Max |
| ----------------------- | -------------------- | -----: | ------: | ------: | ------: | ------: | ------: | ------: |
| total                   | `actiondfs`          |  67.849 | 170.895 | 213.050 | 271.862 | 379.961 | 230.114 | 521.574 |
| total                   | `actiondfs_hybrid32` |  65.616 | 158.740 | 191.476 | 287.867 | 414.326 | 229.118 | 618.178 |
| input fetch/materialize | `actiondfs`          |   1.582 |   4.172 |   4.648 |  22.294 |  24.994 |  12.470 |  25.196 |
| input fetch/materialize | `actiondfs_hybrid32` |   1.775 |   3.669 |   4.686 |  22.847 |  25.319 |  11.371 |  25.707 |
| execute                 | `actiondfs`          |  60.311 | 151.353 | 173.632 | 228.087 | 309.218 | 193.672 | 505.102 |
| execute                 | `actiondfs_hybrid32` |  54.669 | 141.130 | 155.197 | 239.198 | 345.622 | 195.286 | 600.986 |
| output upload/collect   | `actiondfs`          |   2.672 |   6.549 |  14.846 |  28.213 |  66.218 |  23.972 | 164.697 |
| output upload/collect   | `actiondfs_hybrid32` |   3.342 |   6.294 |   9.499 |  22.117 |  86.178 |  22.462 | 172.980 |

## Runner Timing

`process/io` includes the action process runtime plus lazy CAS reads issued by
the action through the mounted filesystem.

| Runner Stage   | Variant              |    Min |     p25 |     p50 |     p75 |     p95 |    Mean |     Max |
| -------------- | -------------------- | -----: | ------: | ------: | ------: | ------: | ------: | ------: |
| parent prepare | `actiondfs`          |  0.054 |   0.061 |   0.085 |   0.584 |  18.677 |   4.133 |  19.010 |
| parent prepare | `actiondfs_hybrid32` |  0.049 |   0.056 |   0.068 |   0.641 |  16.566 |   3.863 |  18.751 |
| fork           | `actiondfs`          |  0.057 |   0.097 |   0.138 |   0.286 |   0.909 |   0.280 |   1.223 |
| fork           | `actiondfs_hybrid32` |  0.085 |   0.137 |   0.383 |   0.775 |   1.451 |   0.550 |   2.110 |
| child setup    | `actiondfs`          |  0.003 |   0.143 |   0.285 |   0.438 |   0.708 |   0.312 |   0.756 |
| child setup    | `actiondfs_hybrid32` |  0.003 |   0.115 |   0.220 |   0.361 |   0.799 |   0.271 |   1.057 |
| process/io     | `actiondfs`          | 54.692 | 126.203 | 147.844 | 175.140 | 291.219 | 163.796 | 456.516 |
| process/io     | `actiondfs_hybrid32` | 48.480 | 120.250 | 132.488 | 209.512 | 313.107 | 170.366 | 555.595 |
| wait           | `actiondfs`          |  4.533 |  16.084 |  18.363 |  36.141 |  51.235 |  25.138 |  51.672 |
| wait           | `actiondfs_hybrid32` |  5.139 |  12.754 |  16.318 |  25.893 |  46.151 |  20.221 |  49.102 |
| stdio digest   | `actiondfs`          |  0.001 |   0.002 |   0.002 |   0.003 |   0.005 |   0.002 |   0.005 |
| stdio digest   | `actiondfs_hybrid32` |  0.001 |   0.002 |   0.002 |   0.002 |   0.005 |   0.002 |   0.006 |

## Interpretation

With the shared parsed Directory cache enabled, this stress run favors
`actiondfs_hybrid32` on median total, execute, process/io, wait, and output
upload timing. The difference is still small relative to VM and workload noise,
so the default remains `actiondfs` until the larger LLVM smoke shows the same
shape.

The right next step is to run `e2e/llvm_fs_compare.sh` on the larger LLVM smoke
before promoting any thresholded variant to production default.
