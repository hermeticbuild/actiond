# Stress Timing Summary

- Generated: `2026-05-17 18:46:09 EDT`
- Mode: `vm-actiondfs-canonical`
- Execute records parsed: `31`
- Unique action digests: `31`
- Source log: `/var/folders/p4/xn8y5q_j24l5xwgwd_jx5c340000gn/T/actiond-vm-e2e.ffyuiU/darwin-actiond-vm.log`
- Command: `ACTIOND_ACTIONDFS_FSTYPE=actiondfs ACTIOND_E2E_KEEP_TMP=1 tools/e2e.sh vm`

## Stage Timing

All timing values are milliseconds unless noted.

| Stage                   |    Min |     p25 |     p50 |     p75 |     p95 |    Mean |     Max | Share of summed total |
| ----------------------- | -----: | ------: | ------: | ------: | ------: | ------: | ------: | --------------------: |
| total                   | 75.541 | 203.967 | 340.903 | 450.995 | 572.528 | 338.675 | 623.072 |                100.0% |
| input fetch/materialize |  2.264 |   6.096 |   6.771 |  30.493 |  34.261 |  14.963 |  35.274 |                  4.4% |
| execute                 | 51.645 | 177.447 | 300.716 | 396.419 | 510.782 | 297.885 | 581.118 |                 88.0% |
| output upload/collect   |  6.822 |  11.045 |  13.273 |  22.149 |  84.400 |  25.827 | 198.428 |                  7.6% |

## Input And Mount Counts

| Metric             | Min | p25 | p50 | p75 | p95 | Mean | Max |
| ------------------ | --: | --: | --: | --: | --: | ---: | --: |
| file inputs        |   0 |   0 |   0 |   0 |   0 |  0.0 |   0 |
| directory inputs   |   0 |   0 |   0 |   0 |   0 |  0.0 |   0 |
| bind mounts        |   1 |   1 |   1 |   1 |   1 |  1.0 |   1 |
| actiondfs mounts   |   1 |   1 |   1 |   1 |   1 |  1.0 |   1 |
| output files       |   1 |   1 |   1 |   1 |   1 |  4.1 |  97 |
| output directories |   0 |   1 |   1 |   1 |   1 |  1.0 |   1 |

## Stage Timing By Stress Case

| Stress Case                | Actions | Total p25 | Total p50 | Total p75 | Total p95 | Input p50 | Execute p50 | Output p50 | Mounts p50 |
| -------------------------- | ------: | --------: | --------: | --------: | --------: | --------: | ----------: | ---------: | ---------: |
| bare_individual_files      |       4 |   448.870 |   449.098 |   450.098 |   452.252 |    30.025 |     396.419 |     23.356 |          2 |
| generated_file_producer    |       1 |   539.967 |   539.967 |   539.967 |   539.967 |    30.290 |     391.294 |    118.383 |          2 |
| generated_individual_files |       4 |    76.609 |    77.132 |    77.336 |    77.426 |     2.364 |      59.945 |     15.160 |          2 |
| generated_tree_producer    |       1 |   623.072 |   623.072 |   623.072 |   623.072 |     3.992 |     420.651 |    198.428 |          2 |
| generated_tree_reuse       |       8 |   199.075 |   203.967 |   254.023 |   258.381 |     6.424 |     177.447 |     18.509 |          2 |
| mixed_all                  |       1 |   598.855 |   598.855 |   598.855 |   598.855 |     2.748 |     581.118 |     14.989 |          2 |
| nested_individual_files    |       8 |   339.459 |   341.427 |   346.339 |   350.446 |    31.407 |     301.286 |     10.352 |          2 |
| source_dir_tree            |       4 |   531.480 |   540.143 |   543.636 |   545.687 |    20.222 |     497.352 |     11.413 |          2 |

## Visible Overhead Estimate

`process/io` is excluded here because it is mostly the action process runtime plus stdout/stderr drain.

| Metric                    |    Min |    p25 |    p50 |    p75 |     p95 |   Mean |     Max | Share of summed total |
| ------------------------- | -----: | -----: | -----: | -----: | ------: | -----: | ------: | --------------------: |
| fixed overhead, no wait   | 14.762 | 22.251 | 43.381 | 48.783 | 104.140 | 46.213 | 225.995 |                 13.6% |
| fixed overhead, with wait | 28.396 | 46.748 | 62.313 | 72.080 | 131.134 | 68.197 | 242.163 |                 20.1% |

## Runner Timing

These values split the `execute` bucket. `process/io` starts after child setup signals right before `execve`; it includes the action process runtime and stdout/stderr drain.

| Runner Stage   |    Min |     p25 |     p50 |     p75 |     p95 |    Mean |     Max | Share of execute |
| -------------- | -----: | ------: | ------: | ------: | ------: | ------: | ------: | ---------------: |
| parent prepare |  0.049 |   0.067 |   0.091 |   0.390 |  24.133 |   4.683 |  24.846 |             1.6% |
| fork           |  0.088 |   0.130 |   0.283 |   0.555 |   0.993 |   0.392 |   1.232 |             0.1% |
| child setup    |  0.003 |   0.169 |   0.242 |   0.504 |   0.882 |   0.345 |   1.177 |             0.1% |
| process/io     | 47.126 | 155.359 | 279.877 | 375.402 | 477.328 | 270.452 | 534.838 |            90.8% |
| wait           |  3.948 |  16.475 |  19.294 |  21.817 |  41.199 |  21.984 |  74.150 |             7.4% |
| stdio digest   |  0.002 |   0.002 |   0.002 |   0.004 |   0.008 |   0.003 |   0.012 |             0.0% |

| Stress Case                | Digest         | Parent Prep |  Fork | Child Setup | Process/IO |   Wait | Stdio Digest | Setup Signaled |
| -------------------------- | -------------- | ----------: | ----: | ----------: | ---------: | -----: | -----------: | -------------- |
| bare_individual_files      | `249502cd8713` |       0.079 | 0.104 |       0.165 |    376.249 | 19.661 |        0.004 | True           |
| bare_individual_files      | `ad55f25cb61f` |       0.109 | 0.130 |       0.873 |    373.485 | 21.955 |        0.002 | True           |
| bare_individual_files      | `c5541e308a49` |       0.061 | 0.452 |       0.642 |    374.554 | 19.105 |        0.003 | True           |
| bare_individual_files      | `d56cf6590fef` |      22.135 | 1.065 |       0.004 |    378.954 | 20.574 |        0.002 | True           |
| generated_file_producer    | `bc2e603f3e0b` |       0.288 | 0.389 |       0.432 |    373.133 | 17.026 |        0.005 | True           |
| generated_individual_files | `0e2aba08daac` |       0.395 | 0.106 |       0.252 |     47.879 | 13.582 |        0.003 | True           |
| generated_individual_files | `93f6d1fb4bbc` |       0.057 | 0.454 |       0.031 |     47.126 |  3.948 |        0.011 | True           |
| generated_individual_files | `b2f28122427f` |       0.065 | 0.133 |       0.215 |     47.423 |  9.807 |        0.004 | True           |
| generated_individual_files | `ef2aa47738bc` |       0.049 | 0.335 |       0.173 |     47.924 | 14.149 |        0.002 | True           |
| generated_tree_producer    | `2dd6c1952601` |      22.338 | 1.232 |       0.003 |    380.901 | 16.168 |        0.002 | True           |
| generated_tree_reuse       | `04ba19135981` |       0.067 | 0.136 |       0.662 |    167.335 | 74.150 |        0.003 | True           |
| generated_tree_reuse       | `127fae4ead86` |       0.067 | 0.822 |       0.208 |    155.583 | 20.854 |        0.002 | True           |
| generated_tree_reuse       | `762b1b9f7d16` |       0.102 | 0.780 |       0.576 |    144.560 | 31.034 |        0.002 | True           |
| generated_tree_reuse       | `7b6fae59491f` |       0.091 | 0.211 |       1.177 |    155.135 | 20.716 |        0.002 | True           |
| generated_tree_reuse       | `7cf4273ba27b` |       0.889 | 0.375 |       0.109 |    164.052 | 36.964 |        0.004 | True           |
| generated_tree_reuse       | `8c4f3e7cd4e7` |       0.084 | 0.524 |       0.892 |    162.870 | 35.908 |        0.002 | True           |
| generated_tree_reuse       | `cef27a1e7fc8` |       0.069 | 0.273 |       0.206 |    151.007 | 21.698 |        0.002 | True           |
| generated_tree_reuse       | `e21d712e10ce` |       0.079 | 0.775 |       0.099 |    151.137 | 18.811 |        0.003 | True           |
| mixed_all                  | `8bf959095e33` |       0.101 | 0.124 |       0.300 |    534.838 | 45.434 |        0.006 | True           |
| nested_individual_files    | `463d1d3b7519` |       0.385 | 0.662 |       0.237 |    275.120 | 13.681 |        0.004 | True           |
| nested_individual_files    | `750c16854c4f` |       0.386 | 0.131 |       0.191 |    278.853 | 17.927 |        0.002 | True           |
| nested_individual_files    | `921deac3abf2` |       0.068 | 0.359 |       0.140 |    282.872 | 18.406 |        0.002 | True           |
| nested_individual_files    | `c0c6c0286d7a` |      24.581 | 0.124 |       0.388 |    277.880 | 19.294 |        0.003 | True           |
| nested_individual_files    | `c3eeebf452a8` |      24.846 | 0.199 |       0.178 |    285.484 | 16.781 |        0.002 | True           |
| nested_individual_files    | `c46382f1c163` |       0.057 | 0.100 |       0.379 |    279.877 | 15.471 |        0.002 | True           |
| nested_individual_files    | `c82d276ce20b` |       0.060 | 0.104 |       0.249 |    285.334 | 14.946 |        0.002 | True           |
| nested_individual_files    | `cbd9737de7fa` |      23.503 | 0.921 |       0.004 |    285.158 | 17.794 |        0.002 | True           |
| source_dir_tree            | `13ad68143150` |       0.067 | 0.088 |       0.709 |    472.383 | 21.445 |        0.003 | True           |
| source_dir_tree            | `7457f233803f` |       0.074 | 0.170 |       0.242 |    476.343 | 21.937 |        0.002 | True           |
| source_dir_tree            | `835056696b6a` |       0.322 | 0.283 |       0.611 |    472.240 | 22.456 |        0.005 | True           |
| source_dir_tree            | `ba00a2e83069` |      23.686 | 0.586 |       0.364 |    478.313 | 19.812 |        0.012 | True           |

## Per Action

| Stress Case                | Digest         |   Total |  Input | Execute |  Output | File Inputs | Dir Inputs | Bind Mounts | Outputs        |
| -------------------------- | -------------- | ------: | -----: | ------: | ------: | ----------: | ---------: | ----------: | -------------- |
| bare_individual_files      | `249502cd8713` | 452.790 | 30.217 | 396.270 |  26.302 |           0 |          0 |           2 | 1 file, 1 dir  |
| bare_individual_files      | `ad55f25cb61f` | 448.995 | 30.695 | 396.568 |  21.732 |           0 |          0 |           2 | 1 file, 1 dir  |
| bare_individual_files      | `c5541e308a49` | 448.495 | 29.834 | 394.830 |  23.831 |           0 |          0 |           2 | 1 file, 1 dir  |
| bare_individual_files      | `d56cf6590fef` | 449.200 |  3.572 | 422.747 |  22.881 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_file_producer    | `bc2e603f3e0b` | 539.967 | 30.290 | 391.294 | 118.383 |           0 |          0 |           2 | 97 file, 0 dir |
| generated_individual_files | `0e2aba08daac` |  77.448 |  2.273 |  62.228 |  12.947 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_individual_files | `93f6d1fb4bbc` |  75.541 |  2.454 |  51.645 |  21.441 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_individual_files | `b2f28122427f` |  77.299 |  2.264 |  57.662 |  17.373 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_individual_files | `ef2aa47738bc` |  76.966 |  2.605 |  62.640 |  11.720 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_tree_producer    | `2dd6c1952601` | 623.072 |  3.992 | 420.651 | 198.428 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_tree_reuse       | `04ba19135981` | 256.258 |  6.771 | 242.363 |   7.124 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_tree_reuse       | `127fae4ead86` | 202.165 |  6.255 | 177.546 |  18.363 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_tree_reuse       | `762b1b9f7d16` | 205.770 |  6.116 | 177.087 |  22.566 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_tree_reuse       | `7b6fae59491f` | 202.078 |  6.076 | 177.347 |  18.654 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_tree_reuse       | `7cf4273ba27b` | 259.524 |  6.699 | 202.409 |  50.416 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_tree_reuse       | `8c4f3e7cd4e7` | 253.278 |  6.601 | 200.292 |  46.385 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_tree_reuse       | `cef27a1e7fc8` | 190.068 |  6.189 | 173.269 |  10.610 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_tree_reuse       | `e21d712e10ce` | 184.867 |  6.592 | 170.928 |   7.347 |           0 |          0 |           2 | 1 file, 1 dir  |
| mixed_all                  | `8bf959095e33` | 598.855 |  2.748 | 581.118 |  14.989 |           0 |          0 |           2 | 1 file, 1 dir  |
| nested_individual_files    | `463d1d3b7519` | 330.297 | 31.764 | 290.117 |   8.416 |           0 |          0 |           2 | 1 file, 1 dir  |
| nested_individual_files    | `750c16854c4f` | 340.175 | 35.274 | 297.503 |   7.398 |           0 |          0 |           2 | 1 file, 1 dir  |
| nested_individual_files    | `921deac3abf2` | 345.193 | 31.050 | 301.855 |  12.288 |           0 |          0 |           2 | 1 file, 1 dir  |
| nested_individual_files    | `c0c6c0286d7a` | 337.309 |  8.198 | 322.289 |   6.822 |           0 |          0 |           2 | 1 file, 1 dir  |
| nested_individual_files    | `c3eeebf452a8` | 349.776 |  9.009 | 327.494 |  13.273 |           0 |          0 |           2 | 1 file, 1 dir  |
| nested_individual_files    | `c46382f1c163` | 340.903 | 31.764 | 295.975 |  13.164 |           0 |          0 |           2 | 1 file, 1 dir  |
| nested_individual_files    | `c82d276ce20b` | 341.950 | 33.656 | 300.716 |   7.578 |           0 |          0 |           2 | 1 file, 1 dir  |
| nested_individual_files    | `cbd9737de7fa` | 350.806 |  9.403 | 327.393 |  14.010 |           0 |          0 |           2 | 1 file, 1 dir  |
| source_dir_tree            | `13ad68143150` | 537.505 | 31.254 | 494.708 |  11.542 |           0 |          0 |           2 | 1 file, 1 dir  |
| source_dir_tree            | `7457f233803f` | 546.200 | 34.865 | 498.780 |  12.555 |           0 |          0 |           2 | 1 file, 1 dir  |
| source_dir_tree            | `835056696b6a` | 513.405 |  6.197 | 495.924 |  11.283 |           0 |          0 |           2 | 1 file, 1 dir  |
| source_dir_tree            | `ba00a2e83069` | 542.781 |  9.190 | 522.785 |  10.806 |           0 |          0 |           2 | 1 file, 1 dir  |

## Notes

- This run observed `directory_inputs=0` for every action. Actions with `actiondfs_mounts>0` are using the lazy actiondfs input-root path, so their input tree is represented by the mounted REAPI root digest rather than by flattened file or directory counters.
- For actiondfs actions, some CAS directory/file read cost moves from input fetch/materialization into the action `process/io` bucket because metadata and pages are loaded lazily.
