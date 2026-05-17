# actiondfs Filesystem Comparison

- Generated: `2026-05-17`
- Command: `ACTIOND_KERNEL_DOCKER_CONTEXT=colima tools/e2e.sh vm-fs-compare`
- Comparison output: `/var/folders/p4/xn8y5q_j24l5xwgwd_jx5c340000gn/T/actiond-vm-fs-compare.hysAIo`
- Workload: `test/` stress workspace, 31 remote actions
- Order: `actiondfs_vec`, `actiondfs`, `actiondfs_bucket`

## Variants

`actiondfs_vec` keeps one child vector per directory and does a linear scan.

`actiondfs` keeps REAPI-canonical file and directory lists and does binary
search in files, then directories.

`actiondfs_bucket` keeps REAPI-canonical file and directory lists, builds an
optional 256-entry first-byte index for lists with at least 32 entries, then
does a local linear scan inside the selected bucket.

The bucket index uses `u32 starts[256]` per indexed list. Name byte `1` maps to
`[starts[0], starts[1])`, byte `255` maps to `[starts[254], starts[255])`, and
`starts[255]` is the final count sentinel. Since actiondfs rejects empty names
and embedded NULs, no valid child name starts with byte `0`.

## Stage Timing

All values are milliseconds.

| Stage                   | Variant             |     Min |     p25 |     p50 |     p75 |     p95 |    Mean |     Max |
| ----------------------- | ------------------- | ------: | ------: | ------: | ------: | ------: | ------: | ------: |
| total                   | `actiondfs_vec`     |  73.072 | 173.659 | 182.669 | 283.363 | 437.958 | 228.434 | 543.082 |
| total                   | `actiondfs`         |  57.542 | 202.322 | 288.933 | 324.852 | 404.365 | 260.779 | 579.484 |
| total                   | `actiondfs_bucket`  | 152.118 | 217.772 | 593.790 | 713.020 | 851.045 | 504.134 | 955.328 |
| input fetch/materialize | `actiondfs_vec`     |   2.211 |   4.371 |   6.221 |   8.083 |  23.293 |   7.705 |  25.089 |
| input fetch/materialize | `actiondfs`         |   1.822 |   3.586 |   4.767 |  22.457 |  23.719 |  10.620 |  25.532 |
| input fetch/materialize | `actiondfs_bucket`  |   2.940 |   4.202 |   6.433 |  27.634 |  30.606 |  12.442 |  30.757 |
| execute                 | `actiondfs_vec`     |  65.014 | 161.479 | 171.243 | 248.632 | 319.158 | 198.767 | 493.414 |
| execute                 | `actiondfs`         |  48.182 | 159.525 | 244.680 | 276.183 | 323.731 | 224.879 | 563.268 |
| execute                 | `actiondfs_bucket`  | 134.253 | 188.880 | 460.384 | 652.118 | 763.549 | 432.015 | 765.625 |
| output upload/collect   | `actiondfs_vec`     |   3.593 |   6.087 |   8.177 |  16.493 |  60.478 |  21.961 | 279.771 |
| output upload/collect   | `actiondfs`         |   3.835 |  11.106 |  16.935 |  27.794 |  68.715 |  25.279 | 177.801 |
| output upload/collect   | `actiondfs_bucket`  |   6.562 |  21.531 |  27.761 | 101.099 | 171.217 |  59.677 | 272.668 |

## Runner Timing

`process/io` includes the action process runtime plus lazy CAS reads issued by
the action through the mounted filesystem.

| Runner Stage   | Variant             |     Min |     p25 |     p50 |     p75 |     p95 |    Mean |     Max |
| -------------- | ------------------- | ------: | ------: | ------: | ------: | ------: | ------: | ------: |
| parent prepare | `actiondfs_vec`     |   0.057 |   0.073 |   0.102 |  15.248 |  25.347 |   6.326 |  33.630 |
| parent prepare | `actiondfs`         |   0.049 |   0.063 |   0.069 |   0.136 |  16.843 |   1.771 |  18.031 |
| parent prepare | `actiondfs_bucket`  |   0.051 |   0.070 |   0.123 |   0.391 |  22.374 |   5.152 |  23.594 |
| fork           | `actiondfs_vec`     |   0.083 |   0.127 |   0.179 |   0.774 |   1.109 |   0.457 |   1.762 |
| fork           | `actiondfs`         |   0.063 |   0.109 |   0.168 |   0.255 |   0.666 |   0.240 |   0.891 |
| fork           | `actiondfs_bucket`  |   0.083 |   0.121 |   0.159 |   0.498 |   0.762 |   0.304 |   0.833 |
| child setup    | `actiondfs_vec`     |   0.003 |   0.198 |   0.398 |   0.695 |   1.495 |   0.517 |   2.235 |
| child setup    | `actiondfs`         |   0.003 |   0.218 |   0.321 |   0.468 |   0.770 |   0.354 |   1.153 |
| child setup    | `actiondfs_bucket`  |   0.002 |   0.203 |   0.288 |   0.579 |   1.794 |   0.581 |   3.034 |
| process/io     | `actiondfs_vec`     |  57.606 | 131.545 | 145.718 | 217.523 | 301.294 | 173.412 | 444.883 |
| process/io     | `actiondfs`         |  42.832 | 135.018 | 199.138 | 247.346 | 306.405 | 194.913 | 532.666 |
| process/io     | `actiondfs_bucket`  | 125.507 | 164.493 | 419.440 | 541.034 | 743.140 | 386.332 | 745.566 |
| wait           | `actiondfs_vec`     |   5.074 |  15.681 |  18.131 |  20.816 |  23.616 |  18.037 |  48.153 |
| wait           | `actiondfs`         |   3.848 |  18.335 |  27.653 |  39.795 |  45.403 |  27.585 |  57.141 |
| wait           | `actiondfs_bucket`  |   7.747 |  20.441 |  25.004 |  30.248 | 112.059 |  39.624 | 113.488 |
| stdio digest   | `actiondfs_vec`     |   0.001 |   0.001 |   0.002 |   0.003 |   0.006 |   0.004 |   0.065 |
| stdio digest   | `actiondfs`         |   0.001 |   0.002 |   0.003 |   0.004 |   0.006 |   0.003 |   0.007 |
| stdio digest   | `actiondfs_bucket`  |   0.001 |   0.002 |   0.004 |   0.006 |   0.009 |   0.004 |   0.011 |

## Interpretation

This run does not justify switching production VM execution to
`actiondfs_bucket`. Median input materialization stayed small, but median
`process/io` was much worse than both existing variants, which means the cost
appeared while the action was traversing or reading through the mounted
filesystem.

The likely workload issue is that many stress inputs share the same first byte
or prefix, so a first-byte bucket often degenerates into scanning a large local
range. The result is still useful as an explicit benchmark variant, but
`actiondfs_vec` remains the fastest variant in this run.
