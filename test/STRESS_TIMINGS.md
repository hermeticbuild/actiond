# Stress Timing Summary

- Generated: `2026-05-17 23:34:51 EDT`
- Mode: `vm`
- Execute records parsed: `31`
- Unique action digests: `31`
- Source log: `/var/folders/p4/xn8y5q_j24l5xwgwd_jx5c340000gn/T/actiond-vm-e2e.Zlax1n/darwin-actiond-vm.log`
- Command: `ACTIOND_E2E_KEEP_TMP=1 tools/e2e.sh vm`
- Bazel elapsed: `9.116s`
- Workload: //:stress_all

## Stage Timing

All timing values are milliseconds unless noted.

| Stage                   |    Min |     p25 |     p50 |     p75 |     p95 |    Mean |     Max | Share of summed total |
| ----------------------- | -----: | ------: | ------: | ------: | ------: | ------: | ------: | --------------------: |
| total                   | 54.826 | 177.763 | 220.408 | 417.973 | 487.370 | 278.802 | 546.684 |                100.0% |
| input fetch/materialize |  1.888 |   3.543 |   4.144 |   5.927 |  10.695 |   5.604 |  23.592 |                  2.0% |
| execute                 | 46.077 | 157.115 | 191.088 | 386.328 | 437.533 | 242.648 | 466.497 |                 87.0% |
| output upload/collect   |  3.439 |   5.709 |  10.910 |  26.991 | 107.473 |  30.550 | 155.415 |                 11.0% |

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
| bare_individual_files      |       4 |   403.057 |   413.252 |   415.975 |   420.771 |     4.031 |     386.328 |     22.596 |          2 |
| generated_file_producer    |       1 |   491.066 |   491.066 |   491.066 |   491.066 |    23.592 |     367.877 |     99.596 |          2 |
| generated_individual_files |       4 |    55.304 |    55.722 |    56.181 |    56.660 |     3.170 |      46.404 |      6.059 |          2 |
| generated_tree_producer    |       1 |   546.684 |   546.684 |   546.684 |   546.684 |     4.205 |     387.065 |    155.415 |          2 |
| generated_tree_reuse       |       8 |   154.694 |   177.763 |   184.103 |   200.769 |     5.667 |     166.762 |      5.357 |          2 |
| mixed_all                  |       1 |   483.674 |   483.674 |   483.674 |   483.674 |     1.888 |     466.497 |     15.289 |          2 |
| nested_individual_files    |       8 |   182.904 |   263.584 |   322.154 |   341.841 |     4.127 |     180.867 |     74.058 |          2 |
| source_dir_tree            |       4 |   451.966 |   452.216 |   453.111 |   455.151 |     3.309 |     436.767 |     12.126 |          2 |

## Visible Overhead Estimate

`process/io` is excluded here because it is mostly the action process runtime plus stdout/stderr drain.

| Metric                    |    Min |    p25 |    p50 |     p75 |     p95 |   Mean |     Max | Share of summed total |
| ------------------------- | -----: | -----: | -----: | ------: | ------: | -----: | ------: | --------------------: |
| fixed overhead, no wait   |  9.032 | 10.263 | 15.182 |  51.309 | 129.103 | 39.835 | 178.046 |                 14.3% |
| fixed overhead, with wait | 13.783 | 30.784 | 46.250 | 118.225 | 186.892 | 77.395 | 240.300 |                 27.8% |

## Runner Timing

These values split the `execute` bucket. `process/io` starts after child setup signals right before `execve`; it includes the action process runtime and stdout/stderr drain.

| Runner Stage   |    Min |     p25 |     p50 |     p75 |     p95 |    Mean |     Max | Share of execute |
| -------------- | -----: | ------: | ------: | ------: | ------: | ------: | ------: | ---------------: |
| parent prepare |  0.048 |   0.058 |   0.074 |   0.174 |  16.911 |   2.833 |  18.532 |             1.2% |
| fork           |  0.064 |   0.082 |   0.114 |   0.238 |   0.950 |   0.249 |   1.250 |             0.1% |
| child setup    |  0.004 |   0.148 |   0.305 |   0.508 |   2.108 |   0.595 |   4.224 |             0.2% |
| process/io     | 41.031 | 129.365 | 153.061 | 296.336 | 418.575 | 201.391 | 420.070 |            83.0% |
| wait           |  4.616 |  18.174 |  34.693 |  57.788 |  81.260 |  37.560 |  82.382 |            15.5% |
| stdio digest   |  0.001 |   0.002 |   0.004 |   0.005 |   0.009 |   0.004 |   0.014 |             0.0% |

| Stress Case                | Digest         | Parent Prep |  Fork | Child Setup | Process/IO |   Wait | Stdio Digest | Setup Signaled |
| -------------------------- | -------------- | ----------: | ----: | ----------: | ---------: | -----: | -----------: | -------------- |
| bare_individual_files      | `249502cd8713` |       0.093 | 0.331 |       0.257 |    304.551 | 82.382 |        0.002 | True           |
| bare_individual_files      | `ad55f25cb61f` |      16.750 | 1.177 |       1.496 |    285.480 | 81.177 |        0.009 | True           |
| bare_individual_files      | `c5541e308a49` |       0.075 | 0.146 |       0.461 |    288.692 | 62.075 |        0.005 | True           |
| bare_individual_files      | `d56cf6590fef` |      18.532 | 0.090 |       2.720 |    283.850 | 81.342 |        0.003 | True           |
| generated_file_producer    | `bc2e603f3e0b` |       0.099 | 0.087 |       4.224 |    303.980 | 59.479 |        0.002 | True           |
| generated_individual_files | `0e2aba08daac` |       0.074 | 0.140 |       0.281 |     42.100 |  5.106 |        0.001 | True           |
| generated_individual_files | `93f6d1fb4bbc` |       0.065 | 0.124 |       0.280 |     41.111 |  4.616 |        0.003 | True           |
| generated_individual_files | `b2f28122427f` |       0.064 | 0.084 |       0.132 |     41.031 |  4.751 |        0.002 | True           |
| generated_individual_files | `ef2aa47738bc` |       0.054 | 0.193 |       0.395 |     41.117 |  4.819 |        0.002 | True           |
| generated_tree_producer    | `2dd6c1952601` |      17.073 | 0.064 |       1.286 |    306.373 | 62.254 |        0.004 | True           |
| generated_tree_reuse       | `04ba19135981` |       0.054 | 0.181 |       0.004 |    140.936 | 50.398 |        0.004 | True           |
| generated_tree_reuse       | `127fae4ead86` |       0.060 | 0.073 |       0.138 |    115.574 | 18.622 |        0.003 | True           |
| generated_tree_reuse       | `762b1b9f7d16` |       0.053 | 0.072 |       0.224 |    120.401 | 21.170 |        0.002 | True           |
| generated_tree_reuse       | `7b6fae59491f` |       0.055 | 0.076 |       0.083 |    132.316 | 34.978 |        0.002 | True           |
| generated_tree_reuse       | `7cf4273ba27b` |       0.052 | 0.071 |       0.396 |    138.417 | 52.137 |        0.004 | True           |
| generated_tree_reuse       | `8c4f3e7cd4e7` |       0.054 | 0.079 |       0.110 |    130.890 | 34.890 |        0.005 | True           |
| generated_tree_reuse       | `cef27a1e7fc8` |       0.056 | 0.179 |       0.004 |    122.030 | 20.901 |        0.002 | True           |
| generated_tree_reuse       | `e21d712e10ce` |       0.246 | 0.644 |       0.005 |    131.882 | 34.693 |        0.004 | True           |
| mixed_all                  | `8bf959095e33` |       0.048 | 0.072 |       0.400 |    420.070 | 45.891 |        0.005 | True           |
| nested_individual_files    | `463d1d3b7519` |       0.075 | 0.080 |       0.169 |    153.061 | 19.928 |        0.002 | True           |
| nested_individual_files    | `750c16854c4f` |       0.072 | 0.091 |       0.544 |    127.839 | 19.618 |        0.007 | True           |
| nested_individual_files    | `921deac3abf2` |       0.101 | 0.423 |       0.408 |    155.407 | 16.812 |        0.014 | True           |
| nested_individual_files    | `c0c6c0286d7a` |       0.087 | 0.438 |       0.518 |    141.766 | 77.713 |        0.002 | True           |
| nested_individual_files    | `c3eeebf452a8` |      16.360 | 0.282 |       0.006 |    159.054 | 69.536 |        0.004 | True           |
| nested_individual_files    | `c46382f1c163` |      16.339 | 1.250 |       1.481 |    154.275 | 56.098 |        0.008 | True           |
| nested_individual_files    | `c82d276ce20b` |       0.070 | 0.156 |       0.305 |    153.537 | 18.573 |        0.007 | True           |
| nested_individual_files    | `cbd9737de7fa` |       0.285 | 0.094 |       0.442 |    134.889 | 52.667 |        0.003 | True           |
| source_dir_tree            | `13ad68143150` |       0.670 | 0.101 |       0.498 |    417.729 | 17.406 |        0.004 | True           |
| source_dir_tree            | `7457f233803f` |       0.062 | 0.092 |       0.261 |    418.756 | 17.171 |        0.009 | True           |
| source_dir_tree            | `835056696b6a` |       0.074 | 0.724 |       0.158 |    417.607 | 19.378 |        0.002 | True           |
| source_dir_tree            | `ba00a2e83069` |       0.068 | 0.114 |       0.753 |    418.393 | 17.775 |        0.006 | True           |

## Per Action

| Stress Case                | Digest         |   Total |  Input | Execute |  Output | File Inputs | Dir Inputs | Bind Mounts | Outputs        |
| -------------------------- | -------------- | ------: | -----: | ------: | ------: | ----------: | ---------: | ----------: | -------------- |
| bare_individual_files      | `249502cd8713` | 413.977 |  3.653 | 387.626 |  22.697 |           0 |          0 |           2 | 1 file, 1 dir  |
| bare_individual_files      | `ad55f25cb61f` | 412.528 |  3.931 | 386.101 |  22.496 |           0 |          0 |           2 | 1 file, 1 dir  |
| bare_individual_files      | `c5541e308a49` | 374.646 |  9.992 | 351.471 |  13.183 |           0 |          0 |           2 | 1 file, 1 dir  |
| bare_individual_files      | `d56cf6590fef` | 421.970 |  4.132 | 386.554 |  31.284 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_file_producer    | `bc2e603f3e0b` | 491.066 | 23.592 | 367.877 |  99.596 |           0 |          0 |           2 | 97 file, 0 dir |
| generated_individual_files | `0e2aba08daac` |  56.779 |  3.051 |  47.714 |   6.014 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_individual_files | `93f6d1fb4bbc` |  55.464 |  2.627 |  46.219 |   6.618 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_individual_files | `b2f28122427f` |  54.826 |  3.498 |  46.077 |   5.252 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_individual_files | `ef2aa47738bc` |  55.981 |  3.288 |  46.589 |   6.103 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_tree_producer    | `2dd6c1952601` | 546.684 |  4.205 | 387.065 | 155.415 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_tree_reuse       | `04ba19135981` | 200.640 |  5.570 | 191.588 |   3.482 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_tree_reuse       | `127fae4ead86` | 145.506 |  6.089 | 134.523 |   4.894 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_tree_reuse       | `762b1b9f7d16` | 155.042 |  6.452 | 141.929 |   6.661 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_tree_reuse       | `7b6fae59491f` | 178.590 |  5.317 | 167.535 |   5.739 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_tree_reuse       | `7cf4273ba27b` | 200.839 |  6.313 | 191.088 |   3.439 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_tree_reuse       | `8c4f3e7cd4e7` | 177.818 |  5.764 | 166.039 |   6.014 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_tree_reuse       | `cef27a1e7fc8` | 153.650 |  5.392 | 143.187 |   5.070 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_tree_reuse       | `e21d712e10ce` | 177.707 |  4.579 | 167.485 |   5.644 |           0 |          0 |           2 | 1 file, 1 dir  |
| mixed_all                  | `8bf959095e33` | 483.674 |  1.888 | 466.497 |  15.289 |           0 |          0 |           2 | 1 file, 1 dir  |
| nested_individual_files    | `463d1d3b7519` | 183.033 |  4.144 | 173.323 |   5.565 |           0 |          0 |           2 | 1 file, 1 dir  |
| nested_individual_files    | `750c16854c4f` | 220.408 | 10.569 | 148.192 |  61.647 |           0 |          0 |           2 | 1 file, 1 dir  |
| nested_individual_files    | `921deac3abf2` | 182.515 |  3.626 | 173.211 |   5.679 |           0 |          0 |           2 | 1 file, 1 dir  |
| nested_individual_files    | `c0c6c0286d7a` | 315.871 |  8.862 | 220.538 |  86.470 |           0 |          0 |           2 | 1 file, 1 dir  |
| nested_individual_files    | `c3eeebf452a8` | 342.293 |  3.899 | 245.250 |  93.144 |           0 |          0 |           2 | 1 file, 1 dir  |
| nested_individual_files    | `c46382f1c163` | 341.001 |  4.111 | 229.472 | 107.418 |           0 |          0 |           2 | 1 file, 1 dir  |
| nested_individual_files    | `c82d276ce20b` | 182.159 |  3.588 | 172.673 |   5.898 |           0 |          0 |           2 | 1 file, 1 dir  |
| nested_individual_files    | `cbd9737de7fa` | 306.759 | 10.820 | 188.411 | 107.529 |           0 |          0 |           2 | 1 file, 1 dir  |
| source_dir_tree            | `13ad68143150` | 451.346 |  3.304 | 436.416 |  11.626 |           0 |          0 |           2 | 1 file, 1 dir  |
| source_dir_tree            | `7457f233803f` | 452.261 |  3.269 | 436.366 |  12.625 |           0 |          0 |           2 | 1 file, 1 dir  |
| source_dir_tree            | `835056696b6a` | 452.172 |  3.314 | 437.948 |  10.910 |           0 |          0 |           2 | 1 file, 1 dir  |
| source_dir_tree            | `ba00a2e83069` | 455.661 |  4.895 | 437.119 |  13.646 |           0 |          0 |           2 | 1 file, 1 dir  |

## Notes

- This run observed `directory_inputs=0` for every action. Actions with `actiondfs_mounts>0` are using the lazy actiondfs input-root path, so their input tree is represented by the mounted REAPI root digest rather than by flattened file or directory counters.
- For actiondfs actions, some CAS directory/file read cost moves from input fetch/materialization into the action `process/io` bucket because metadata and pages are loaded lazily.
