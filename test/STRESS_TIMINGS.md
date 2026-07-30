# Executor Timing Summary

- Generated: `2026-07-30 18:17:59 EDT`
- Mode: `vm`
- Execute records parsed: `34`
- Unique action digests: `34`
- Source log: `/var/folders/p4/xn8y5q_j24l5xwgwd_jx5c340000gn/T/actiond-vm-e2e.BbaPL1/darwin-actiond-vm.log`
- Command: `ACTIOND_E2E_KEEP_TMP=1 ACTIOND_REPO_BAZEL_FLAGS="--config=remote --config=executor_timing_logs" tools/e2e.sh vm`

## Stage Timing

All timing values are milliseconds unless noted.

| Stage                 |   Min |   p25 |   p50 |   p75 |    p95 |  Mean |    Max | Share of summed total |
| --------------------- | ----: | ----: | ----: | ----: | -----: | ----: | -----: | --------------------: |
| total                 | 1.847 | 3.912 | 5.596 | 8.848 | 21.592 | 9.518 | 86.606 |                100.0% |
| input fetch/setup     | 0.272 | 0.293 | 0.321 | 0.732 |  1.862 | 0.684 |  3.117 |                  7.2% |
| execute               | 1.346 | 3.138 | 4.595 | 6.383 | 12.631 | 7.477 | 85.866 |                 78.6% |
| output upload/collect | 0.062 | 0.141 | 0.459 | 1.138 |  6.805 | 1.357 |  9.963 |                 14.3% |

## Mount And Output Counts

| Metric             | Min | p25 | p50 | p75 | p95 | Mean | Max |
| ------------------ | --: | --: | --: | --: | --: | ---: | --: |
| bind mounts        |   4 |   4 |   4 |   4 |   4 |  4.0 |   4 |
| output files       |   1 |   1 |   1 |   1 |   1 |  3.8 |  97 |
| output directories |   0 |   1 |   1 |   1 |   1 |  0.9 |   1 |

## Stage Timing By Stress Case

| Stress Case                | Actions | Total p25 | Total p50 | Total p75 | Total p95 | Input p50 | Execute p50 | Output p50 | Mounts p50 |
| -------------------------- | ------: | --------: | --------: | --------: | --------: | --------: | ----------: | ---------: | ---------: |
| aggregate                  |       1 |     2.992 |     2.992 |     2.992 |     2.992 |     0.290 |       2.641 |      0.062 |          4 |
| bare_individual_files      |       4 |     3.336 |     3.721 |     5.416 |     9.118 |     0.315 |       2.384 |      0.773 |          4 |
| filesystem_regression      |       1 |    86.606 |    86.606 |    86.606 |    86.606 |     0.302 |      85.866 |      0.438 |          4 |
| generated_file_producer    |       1 |    16.612 |    16.612 |    16.612 |    16.612 |     0.658 |       7.656 |      8.298 |          4 |
| generated_individual_files |       4 |     4.039 |     4.612 |     5.226 |     5.991 |     0.362 |       3.832 |      0.349 |          4 |
| generated_tree_producer    |       1 |    21.361 |    21.361 |    21.361 |    21.361 |     1.572 |       9.825 |      9.963 |          4 |
| generated_tree_reuse       |       8 |     5.076 |     5.596 |     7.510 |     8.772 |     0.294 |       5.170 |      0.139 |          4 |
| mixed_all                  |       1 |    22.021 |    22.021 |    22.021 |    22.021 |     0.299 |      17.843 |      3.879 |          4 |
| nested_individual_files    |       8 |     5.928 |     8.349 |    11.552 |    12.181 |     0.934 |       5.306 |      1.091 |          4 |
| source_dir_tree            |       4 |     3.784 |     4.313 |     5.136 |     6.114 |     0.549 |       3.534 |      0.420 |          4 |
| symlink_input_consumer     |       1 |     1.847 |     1.847 |     1.847 |     1.847 |     0.295 |       1.346 |      0.206 |          4 |

## Visible Overhead Estimate

`process/io` is excluded here because it is mostly the action process runtime plus stdout/stderr drain.

| Metric                    |   Min |   p25 |   p50 |   p75 |   p95 |  Mean |    Max | Share of summed total |
| ------------------------- | ----: | ----: | ----: | ----: | ----: | ----: | -----: | --------------------: |
| fixed overhead, no wait   | 0.922 | 1.711 | 2.634 | 5.190 | 9.093 | 3.660 | 13.723 |                 38.5% |
| fixed overhead, with wait | 0.922 | 1.711 | 2.634 | 5.190 | 9.093 | 3.660 | 13.723 |                 38.5% |

## Runner Timing

These values split the `execute` bucket. `process/io` starts after child setup signals right before `execve`; it includes the action process runtime and stdout/stderr drain.

| Runner Stage   |   Min |   p25 |   p50 |   p75 |    p95 |  Mean |    Max | Share of execute |
| -------------- | ----: | ----: | ----: | ----: | -----: | ----: | -----: | ---------------: |
| parent prepare | 0.040 | 0.045 | 0.049 | 0.057 |  0.100 | 0.058 |  0.203 |             0.8% |
| fork           | 0.067 | 0.092 | 0.109 | 0.156 |  1.824 | 0.342 |  2.783 |             4.6% |
| child setup    | 0.002 | 0.544 | 1.066 | 1.555 |  2.927 | 1.218 |  4.730 |            16.3% |
| process/io     | 0.105 | 1.535 | 2.722 | 4.976 | 10.942 | 5.841 | 80.997 |            78.1% |
| wait           | 0.000 | 0.000 | 0.000 | 0.000 |  0.000 | 0.000 |  0.000 |             0.0% |
| stdio digest   | 0.000 | 0.000 | 0.000 | 0.000 |  0.001 | 0.000 |  0.001 |             0.0% |

| Stress Case                | Digest         | Parent Prep |  Fork | Child Setup | Process/IO |  Wait | Stdio Digest | Setup Signaled |
| -------------------------- | -------------- | ----------: | ----: | ----------: | ---------: | ----: | -----------: | -------------- |
| aggregate                  | `531499425ba1` |       0.047 | 0.105 |       0.427 |      2.051 | 0.000 |        0.000 | True           |
| bare_individual_files      | `4dfded667523` |       0.060 | 0.120 |       0.444 |      1.529 | 0.000 |        0.000 | True           |
| bare_individual_files      | `91b290b62cf9` |       0.049 | 0.096 |       0.561 |      1.491 | 0.000 |        0.001 | True           |
| bare_individual_files      | `a65352596937` |       0.054 | 0.070 |       0.442 |      2.568 | 0.000 |        0.000 | True           |
| bare_individual_files      | `ee8f5e8ccce1` |       0.046 | 0.086 |       0.624 |      1.792 | 0.000 |        0.000 | True           |
| filesystem_regression      | `d28c89b62ab2` |       0.043 | 0.087 |       4.730 |     80.997 | 0.000 |        0.000 | True           |
| generated_file_producer    | `a1e8a56eb257` |       0.074 | 0.090 |       1.561 |      5.925 | 0.000 |        0.000 | True           |
| generated_individual_files | `14eed6a406a0` |       0.044 | 0.067 |       1.319 |      1.357 | 0.000 |        0.000 | True           |
| generated_individual_files | `7cda6d5de197` |       0.049 | 0.159 |       3.036 |      1.479 | 0.000 |        0.001 | True           |
| generated_individual_files | `d0f36724e5c0` |       0.051 | 0.101 |       1.775 |      2.525 | 0.000 |        0.000 | True           |
| generated_individual_files | `d2dd425c67cf` |       0.048 | 0.112 |       1.463 |      1.552 | 0.000 |        0.001 | True           |
| generated_tree_producer    | `cd5680b62147` |       0.043 | 0.082 |       2.062 |      7.633 | 0.000 |        0.000 | True           |
| generated_tree_reuse       | `0ca41d6371f8` |       0.043 | 0.076 |       0.643 |      3.248 | 0.000 |        0.000 | True           |
| generated_tree_reuse       | `65fc05d2421b` |       0.042 | 0.128 |       0.344 |      3.031 | 0.000 |        0.000 | True           |
| generated_tree_reuse       | `7952d1b17b5f` |       0.045 | 0.108 |       1.096 |      2.419 | 0.000 |        0.000 | True           |
| generated_tree_reuse       | `b866619f2e83` |       0.041 | 0.504 |       0.239 |      4.197 | 0.000 |        0.000 | True           |
| generated_tree_reuse       | `db8495a88c1c` |       0.135 | 0.111 |       1.580 |      3.460 | 0.000 |        0.000 | True           |
| generated_tree_reuse       | `e652390a3757` |       0.060 | 0.147 |       0.539 |      5.013 | 0.000 |        0.000 | True           |
| generated_tree_reuse       | `f898b88e8806` |       0.042 | 0.100 |       0.620 |      7.778 | 0.000 |        0.000 | True           |
| generated_tree_reuse       | `fa3cf567d406` |       0.066 | 0.096 |       0.975 |      5.422 | 0.000 |        0.000 | True           |
| mixed_all                  | `be4a1954bc6c` |       0.203 | 0.099 |       0.715 |     16.817 | 0.000 |        0.000 | True           |
| nested_individual_files    | `062c10b5bb96` |       0.040 | 0.076 |       1.093 |      6.000 | 0.000 |        0.001 | True           |
| nested_individual_files    | `0b94d4fb63fc` |       0.058 | 2.662 |       0.002 |      6.964 | 0.000 |        0.000 | True           |
| nested_individual_files    | `40fe49279c9f` |       0.046 | 0.114 |       1.050 |      4.572 | 0.000 |        0.000 | True           |
| nested_individual_files    | `42efdfabf2c4` |       0.053 | 0.729 |       2.869 |      1.083 | 0.000 |        0.000 | True           |
| nested_individual_files    | `7c3a4e1e703b` |       0.045 | 0.106 |       0.409 |      1.002 | 0.000 |        0.000 | True           |
| nested_individual_files    | `99cad005580b` |       0.052 | 2.783 |       1.686 |      4.867 | 0.000 |        0.000 | True           |
| nested_individual_files    | `ca2ed43c0d8a` |       0.058 | 1.372 |       1.081 |      2.295 | 0.000 |        0.000 | True           |
| nested_individual_files    | `f3aa1f29ef28` |       0.047 | 0.079 |       1.315 |      1.601 | 0.000 |        0.000 | True           |
| source_dir_tree            | `2f1264644774` |       0.080 | 0.191 |       1.536 |      0.462 | 0.000 |        0.001 | True           |
| source_dir_tree            | `9e67e0ecc571` |       0.054 | 0.484 |       1.096 |      3.812 | 0.000 |        0.000 | True           |
| source_dir_tree            | `baa7f7f64245` |       0.049 | 0.250 |       2.729 |      0.105 | 0.000 |        0.000 | True           |
| source_dir_tree            | `c5f34558150f` |       0.050 | 0.137 |       0.850 |      2.876 | 0.000 |        0.000 | True           |
| symlink_input_consumer     | `1ee4fbe0e858` |       0.046 | 0.116 |       0.508 |      0.665 | 0.000 |        0.000 | True           |

## VM Bridge Timing

These are raw TCP-to-vsock pump connection measurements logged by `darwin-actiond serve-vm`.

- Bridge connections logged: `4`
- Total client to guest bytes: `1.37 MiB`
- Total guest to client bytes: `0.30 MiB`
- Pump errors: read=`0`, write=`0`

| Bridge Metric          |     Min |     p25 |      p50 |      p75 |      p95 |     Mean |      Max |
| ---------------------- | ------: | ------: | -------: | -------: | -------: | -------: | -------: |
| connection elapsed     | 517.872 | 536.204 | 2019.130 | 4001.256 | 5214.005 | 2518.331 | 5517.192 |
| client to guest KiB    |     0.0 |   210.4 |    287.9 |    429.1 |    750.6 |    351.7 |    831.0 |
| guest to client KiB    |     0.0 |    44.9 |     73.7 |    104.6 |    145.4 |     75.8 |    155.6 |
| client to guest reads  |       1 |     264 |      418 |      487 |      497 |    334.0 |      500 |
| client to guest writes |       1 |     264 |      418 |      487 |      497 |    334.0 |      500 |
| guest to client reads  |       0 |     154 |      224 |      248 |      262 |    178.5 |      266 |
| guest to client writes |       0 |     154 |      224 |      248 |      262 |    178.5 |      266 |

## Per Action

| Stress Case                | Digest         |  Total | Input | Execute | Output | Bind Mounts |        Outputs |
| -------------------------- | -------------- | -----: | ----: | ------: | -----: | ----------: | -------------: |
| aggregate                  | `531499425ba1` |  2.992 | 0.290 |   2.641 |  0.062 |           4 |  1 file, 0 dir |
| bare_individual_files      | `4dfded667523` |  2.637 | 0.307 |   2.167 |  0.163 |           4 |  1 file, 1 dir |
| bare_individual_files      | `91b290b62cf9` |  3.873 | 0.286 |   2.205 |  1.382 |           4 |  1 file, 1 dir |
| bare_individual_files      | `a65352596937` |  3.568 | 0.323 |   3.138 |  0.108 |           4 |  1 file, 1 dir |
| bare_individual_files      | `ee8f5e8ccce1` | 10.044 | 1.480 |   2.564 |  6.000 |           4 |  1 file, 1 dir |
| filesystem_regression      | `d28c89b62ab2` | 86.606 | 0.302 |  85.866 |  0.438 |           4 |  1 file, 1 dir |
| generated_file_producer    | `a1e8a56eb257` | 16.612 | 0.658 |   7.656 |  8.298 |           4 | 97 file, 0 dir |
| generated_individual_files | `14eed6a406a0` |  3.203 | 0.279 |   2.794 |  0.130 |           4 |  1 file, 1 dir |
| generated_individual_files | `7cda6d5de197` |  6.182 | 0.883 |   4.732 |  0.567 |           4 |  1 file, 1 dir |
| generated_individual_files | `d0f36724e5c0` |  4.907 | 0.354 |   4.457 |  0.096 |           4 |  1 file, 1 dir |
| generated_individual_files | `d2dd425c67cf` |  4.318 | 0.370 |   3.207 |  0.740 |           4 |  1 file, 1 dir |
| generated_tree_producer    | `cd5680b62147` | 21.361 | 1.572 |   9.825 |  9.963 |           4 |  1 file, 1 dir |
| generated_tree_reuse       | `0ca41d6371f8` |  5.425 | 0.272 |   4.018 |  1.135 |           4 |  1 file, 1 dir |
| generated_tree_reuse       | `65fc05d2421b` |  3.959 | 0.275 |   3.551 |  0.132 |           4 |  1 file, 1 dir |
| generated_tree_reuse       | `7952d1b17b5f` |  4.118 | 0.293 |   3.684 |  0.140 |           4 |  1 file, 1 dir |
| generated_tree_reuse       | `b866619f2e83` |  5.395 | 0.295 |   4.984 |  0.115 |           4 |  1 file, 1 dir |
| generated_tree_reuse       | `db8495a88c1c` |  5.768 | 0.293 |   5.355 |  0.119 |           4 |  1 file, 1 dir |
| generated_tree_reuse       | `e652390a3757` |  8.346 | 2.299 |   5.766 |  0.280 |           4 |  1 file, 1 dir |
| generated_tree_reuse       | `f898b88e8806` |  9.001 | 0.319 |   8.545 |  0.137 |           4 |  1 file, 1 dir |
| generated_tree_reuse       | `fa3cf567d406` |  7.232 | 0.512 |   6.577 |  0.143 |           4 |  1 file, 1 dir |
| mixed_all                  | `be4a1954bc6c` | 22.021 | 0.299 |  17.843 |  3.879 |           4 |  1 file, 1 dir |
| nested_individual_files    | `062c10b5bb96` | 11.356 | 0.276 |   7.215 |  3.865 |           4 |  1 file, 1 dir |
| nested_individual_files    | `0b94d4fb63fc` | 12.140 | 1.407 |   9.689 |  1.044 |           4 |  1 file, 1 dir |
| nested_individual_files    | `40fe49279c9f` |  8.310 | 1.369 |   5.801 |  1.139 |           4 |  1 file, 1 dir |
| nested_individual_files    | `42efdfabf2c4` |  6.340 | 0.292 |   4.744 |  1.304 |           4 |  1 file, 1 dir |
| nested_individual_files    | `7c3a4e1e703b` |  2.352 | 0.283 |   1.567 |  0.502 |           4 |  1 file, 1 dir |
| nested_individual_files    | `99cad005580b` | 12.204 | 1.626 |   9.395 |  1.183 |           4 |  1 file, 1 dir |
| nested_individual_files    | `ca2ed43c0d8a` |  8.388 | 3.117 |   4.811 |  0.460 |           4 |  1 file, 1 dir |
| nested_individual_files    | `f3aa1f29ef28` |  4.694 | 0.499 |   3.265 |  0.929 |           4 |  1 file, 1 dir |
| source_dir_tree            | `2f1264644774` |  3.445 | 0.678 |   2.279 |  0.488 |           4 |  1 file, 1 dir |
| source_dir_tree            | `9e67e0ecc571` |  6.358 | 0.750 |   5.460 |  0.148 |           4 |  1 file, 1 dir |
| source_dir_tree            | `baa7f7f64245` |  3.897 | 0.298 |   3.140 |  0.458 |           4 |  1 file, 1 dir |
| source_dir_tree            | `c5f34558150f` |  4.729 | 0.420 |   3.927 |  0.382 |           4 |  1 file, 1 dir |
| symlink_input_consumer     | `1ee4fbe0e858` |  1.847 | 0.295 |   1.346 |  0.206 |           4 |  1 file, 1 dir |

## Notes

- Every action uses actiondfs, so input trees are represented by mounted REAPI root digests rather than flattened input counters.
- Some CAS metadata and file read cost appears in the action `process/io` bucket because actiondfs loads inputs lazily.
