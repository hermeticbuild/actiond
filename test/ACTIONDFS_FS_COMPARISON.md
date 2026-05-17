# actiondfs Filesystem Comparison

- Generated: `2026-05-17`
- Command: `ACTIOND_KERNEL_DOCKER_CONTEXT=colima tools/e2e.sh vm-fs-compare`
- Comparison output: `/var/folders/p4/xn8y5q_j24l5xwgwd_jx5c340000gn/T/actiond-vm-fs-compare.2xU8Xc`
- Workload: `test/` stress workspace, 31 remote actions
- Order: `actiondfs_vec` first, canonical `actiondfs` second

`actiondfs_vec` is the linear vector lookup variant. `actiondfs` is the
canonical REAPI-aware variant that keeps files and directories in their sorted
proto order and uses binary search inside each list.

## Stage Timing

All values are milliseconds.

| Stage                   | Variant        |     Min |     p25 |     p50 |     p75 |     p95 |    Mean |     Max |
| ----------------------- | -------------- | ------: | ------: | ------: | ------: | ------: | ------: | ------: |
| total                   | `actiondfs_vec` | 119.847 | 209.242 | 261.208 | 371.298 | 496.155 | 296.341 | 634.789 |
| total                   | `actiondfs`     |  75.541 | 203.967 | 340.903 | 450.995 | 572.528 | 338.675 | 623.072 |
| input fetch/materialize | `actiondfs_vec` |   1.650 |   4.621 |   6.117 |  18.666 |  25.094 |  10.905 |  28.623 |
| input fetch/materialize | `actiondfs`     |   2.264 |   6.096 |   6.771 |  30.493 |  34.261 |  14.963 |  35.274 |
| execute                 | `actiondfs_vec` | 102.181 | 188.330 | 223.031 | 309.958 | 399.707 | 256.878 | 612.272 |
| execute                 | `actiondfs`     |  51.645 | 177.447 | 300.716 | 396.419 | 510.782 | 297.885 | 581.118 |
| output upload/collect   | `actiondfs_vec` |   4.850 |  14.837 |  17.605 |  28.449 |  89.666 |  28.558 | 180.625 |
| output upload/collect   | `actiondfs`     |   6.822 |  11.045 |  13.273 |  22.149 |  84.400 |  25.827 | 198.428 |

## Runner Timing

`process/io` includes the action process runtime plus lazy CAS reads issued by
the action through the mounted filesystem.

| Runner Stage   | Variant        |    Min |     p25 |     p50 |     p75 |     p95 |    Mean |     Max |
| -------------- | -------------- | -----: | ------: | ------: | ------: | ------: | ------: | ------: |
| parent prepare | `actiondfs_vec` |  0.048 |   0.060 |   0.066 |   0.078 |  11.263 |   1.520 |  22.108 |
| parent prepare | `actiondfs`     |  0.049 |   0.067 |   0.091 |   0.390 |  24.133 |   4.683 |  24.846 |
| fork           | `actiondfs_vec` |  0.051 |   0.094 |   0.147 |   0.307 |   0.768 |   0.273 |   1.205 |
| fork           | `actiondfs`     |  0.088 |   0.130 |   0.283 |   0.555 |   0.993 |   0.392 |   1.232 |
| child setup    | `actiondfs_vec` |  0.003 |   0.204 |   0.299 |   0.466 |   1.175 |   0.522 |   5.102 |
| child setup    | `actiondfs`     |  0.003 |   0.169 |   0.242 |   0.504 |   0.882 |   0.345 |   1.177 |
| process/io     | `actiondfs_vec` | 58.914 | 162.754 | 185.326 | 291.827 | 382.669 | 228.551 | 557.989 |
| process/io     | `actiondfs`     | 47.126 | 155.359 | 279.877 | 375.402 | 477.328 | 270.452 | 534.838 |
| wait           | `actiondfs_vec` | 13.140 |  16.511 |  20.154 |  26.686 |  52.317 |  25.986 |  55.166 |
| wait           | `actiondfs`     |  3.948 |  16.475 |  19.294 |  21.817 |  41.199 |  21.984 |  74.150 |
| stdio digest   | `actiondfs_vec` |  0.002 |   0.002 |   0.004 |   0.005 |   0.009 |   0.004 |   0.011 |
| stdio digest   | `actiondfs`     |  0.002 |   0.002 |   0.002 |   0.004 |   0.008 |   0.003 |   0.012 |

## Interpretation

This run does not show the canonical filesystem beating the vector variant.
Median total time was `79.695 ms` higher for `actiondfs`; median input
fetch/materialization was only `0.654 ms` higher, while median `process/io` was
`94.551 ms` higher. That points at lazy path traversal or file read behavior
during the action, not at the fixed mount/setup path.

Keep both variants available for now. Re-run this comparison before deleting
either implementation, ideally with repeated back-to-back pairs or alternating
order to control for VM/cache warming effects.
