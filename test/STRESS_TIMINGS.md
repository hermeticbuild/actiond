# Executor Timing Summary

- Generated: `2026-08-01 23:08:06 EDT`
- Mode: `vm`
- Execute records parsed: `37`
- Unique action digests: `37`
- Source log: `/private/var/folders/p4/xn8y5q_j24l5xwgwd_jx5c340000gn/T/actiond-vm-e2e.d5iHEX/darwin-actiond-vm.log`
- Command: `ACTIOND_E2E_KEEP_TMP=1 ACTIOND_REPO_BAZEL_FLAGS="--config=remote --config=executor_timing_logs" tools/e2e.sh vm`

## Stage Timing

All timing values are milliseconds unless noted.

| Stage                 |   Min |    p25 |    p50 |    p75 |    p95 |   Mean |     Max | Share of summed total |
| --------------------- | ----: | -----: | -----: | -----: | -----: | -----: | ------: | --------------------: |
| total                 | 1.886 | 12.985 | 17.967 | 26.434 | 54.587 | 23.937 | 105.540 |                100.0% |
| input fetch/setup     | 0.232 |  0.321 |  0.399 |  0.697 |  4.007 |  1.078 |   9.242 |                  4.5% |
| execute               | 1.538 | 10.747 | 16.541 | 24.216 | 51.809 | 21.702 | 102.521 |                 90.7% |
| output upload/collect | 0.060 |  0.139 |  0.486 |  1.117 |  4.199 |  1.157 |  10.068 |                  4.8% |

## Mount And Output Counts

| Metric             | Min | p25 | p50 | p75 | p95 | Mean | Max |
| ------------------ | --: | --: | --: | --: | --: | ---: | --: |
| bind mounts        |   2 |   4 |   4 |   4 |   4 |  3.9 |   4 |
| output files       |   1 |   1 |   1 |   1 |   1 |  3.6 |  97 |
| output directories |   0 |   1 |   1 |   1 |   1 |  0.9 |   1 |

## Stage Timing By Stress Case

| Stress Case                | Actions | Total p25 | Total p50 | Total p75 | Total p95 | Input p50 | Execute p50 | Output p50 | Mounts p50 |
| -------------------------- | ------: | --------: | --------: | --------: | --------: | --------: | ----------: | ---------: | ---------: |
| aggregate                  |       1 |    12.985 |    12.985 |    12.985 |    12.985 |     0.300 |      12.625 |      0.060 |          4 |
| bare_individual_files      |       4 |    22.180 |    25.206 |    27.570 |    28.142 |     0.406 |      23.426 |      0.368 |          4 |
| filesystem_regression      |       1 |   105.540 |   105.540 |   105.540 |   105.540 |     0.947 |     102.521 |      2.071 |          4 |
| generated_file_producer    |       1 |    42.392 |    42.392 |    42.392 |    42.392 |     9.242 |      24.742 |      8.408 |          4 |
| generated_individual_files |       4 |    10.012 |    10.295 |    12.001 |    15.814 |     0.323 |       9.114 |      0.443 |          4 |
| generated_tree_producer    |       1 |    45.624 |    45.624 |    45.624 |    45.624 |     0.377 |      35.180 |     10.068 |          4 |
| generated_tree_reuse       |       8 |    15.657 |    18.662 |    21.268 |    22.079 |     0.580 |      17.102 |      0.213 |          4 |
| mixed_all                  |       1 |    12.815 |    12.815 |    12.815 |    12.815 |     0.321 |      10.046 |      2.448 |          4 |
| nested_individual_files    |       8 |    16.920 |    19.062 |    29.772 |    39.481 |     0.455 |      16.524 |      0.784 |          4 |
| pids_one_regression        |       1 |    16.760 |    16.760 |    16.760 |    16.760 |     1.012 |      15.606 |      0.142 |          4 |
| source_dir_tree            |       4 |    16.374 |    22.200 |    42.434 |    80.835 |     0.553 |      21.679 |      0.166 |          4 |
| symlink_input_consumer     |       1 |     5.609 |     5.609 |     5.609 |     5.609 |     0.331 |       5.061 |      0.217 |          4 |
| timeout_recovery           |       1 |    22.593 |    22.593 |    22.593 |    22.593 |     0.643 |      21.843 |      0.107 |          4 |
| unknown                    |       1 |     1.886 |     1.886 |     1.886 |     1.886 |     0.232 |       1.538 |      0.117 |          2 |

## Visible Overhead Estimate

`process/io` is excluded here because it is mostly the action process runtime plus stdout/stderr drain.

| Metric                    |   Min |   p25 |    p50 |    p75 |    p95 |   Mean |    Max | Share of summed total |
| ------------------------- | ----: | ----: | -----: | -----: | -----: | -----: | -----: | --------------------: |
| fixed overhead, no wait   | 1.394 | 8.799 | 13.486 | 19.203 | 33.924 | 16.445 | 76.739 |                 68.7% |
| fixed overhead, with wait | 1.394 | 8.799 | 15.393 | 21.165 | 35.607 | 17.050 | 76.739 |                 71.2% |

## Runner Timing

These values split the `execute` bucket. `child setup` includes successful `execve`; `process/io` starts after close-on-exec confirmation and includes action runtime and stdout/stderr drain.

| Runner Stage   |   Min |   p25 |   p50 |    p75 |    p95 |  Mean |    Max | Share of execute |
| -------------- | ----: | ----: | ----: | -----: | -----: | ----: | -----: | ---------------: |
| parent prepare | 0.039 | 0.129 | 0.154 |  6.001 | 14.192 | 3.974 | 30.510 |            18.3% |
| fork           | 0.143 | 0.346 | 0.463 |  1.037 |  5.559 | 1.483 | 15.454 |             6.8% |
| child setup    | 0.008 | 1.626 | 5.090 | 11.872 | 19.394 | 8.753 | 74.287 |            40.3% |
| process/io     | 0.474 | 2.012 | 3.644 |  5.844 | 14.223 | 6.837 | 83.844 |            31.5% |
| wait           | 0.000 | 0.000 | 0.000 |  0.000 |  4.609 | 0.605 |  4.742 |             2.8% |
| stdio digest   | 0.000 | 0.000 | 0.000 |  0.001 |  0.001 | 0.000 |  0.003 |             0.0% |

| Stress Case                | Digest         | Parent Prep |   Fork | Child Setup | Process/IO |  Wait | Stdio Digest | Setup Signaled |
| -------------------------- | -------------- | ----------: | -----: | ----------: | ---------: | ----: | -----------: | -------------- |
| aggregate                  | `b685ab4a0d00` |       0.110 |  0.276 |       9.863 |      2.348 | 0.000 |        0.001 | True           |
| bare_individual_files      | `24c5cd3f112a` |      13.991 |  0.348 |       4.009 |      5.844 | 0.000 |        0.000 | True           |
| bare_individual_files      | `2623700af2b1` |       0.146 |  0.463 |      14.002 |     12.122 | 0.000 |        0.001 | True           |
| bare_individual_files      | `43f037c27458` |      14.996 |  0.722 |       3.040 |      1.851 | 1.962 |        0.000 | True           |
| bare_individual_files      | `feeb2d55641f` |       0.122 |  0.283 |       7.266 |     10.812 | 0.000 |        0.001 | True           |
| filesystem_regression      | `d132925a0328` |       0.123 |  3.175 |      15.351 |     83.844 | 0.000 |        0.000 | True           |
| generated_file_producer    | `e84ec75ce42e` |       0.154 |  8.245 |       5.814 |      8.351 | 2.104 |        0.000 | True           |
| generated_individual_files | `118b63159b38` |       4.064 |  1.021 |       0.886 |      2.487 | 0.000 |        0.000 | True           |
| generated_individual_files | `242c99eb2c28` |       2.561 |  1.778 |       3.018 |      2.371 | 0.000 |        0.000 | True           |
| generated_individual_files | `78230e4a6f6d` |       3.444 |  1.892 |       3.274 |      7.660 | 0.000 |        0.000 | True           |
| generated_individual_files | `ec087db43ffd` |       3.041 |  2.295 |       0.877 |      1.571 | 0.000 |        0.001 | True           |
| generated_tree_producer    | `d33821cebf3e` |       0.133 |  0.346 |      18.122 |     16.559 | 0.000 |        0.001 | True           |
| generated_tree_reuse       | `0bbda7aff823` |      10.205 |  0.554 |       2.021 |      2.012 | 0.000 |        0.000 | True           |
| generated_tree_reuse       | `28f302b72b2d` |       9.988 |  0.622 |       0.918 |      2.879 | 0.000 |        0.000 | True           |
| generated_tree_reuse       | `3fa11b1bc05f` |       9.799 |  0.394 |       1.626 |      4.833 | 4.586 |        0.000 | True           |
| generated_tree_reuse       | `63a12c93411c` |       0.122 |  0.447 |       1.838 |      4.593 | 0.000 |        0.000 | True           |
| generated_tree_reuse       | `654f662800a0` |      10.530 |  1.287 |       0.008 |      4.334 | 0.000 |        0.000 | True           |
| generated_tree_reuse       | `740cb972a7d0` |       0.143 |  0.528 |      13.035 |      4.378 | 0.000 |        0.000 | True           |
| generated_tree_reuse       | `9de4f80099e4` |      10.471 |  0.987 |       0.460 |      2.529 | 4.699 |        0.000 | True           |
| generated_tree_reuse       | `ce4b28b15b03` |       0.135 |  0.581 |      11.689 |      5.576 | 0.000 |        0.000 | True           |
| mixed_all                  | `05385b608139` |       0.131 |  0.318 |       1.045 |      8.530 | 0.000 |        0.001 | True           |
| nested_individual_files    | `0576f836a969` |       0.129 |  2.737 |      13.501 |      8.299 | 4.307 |        0.000 | True           |
| nested_individual_files    | `0ba5a66718e5` |      10.286 |  0.503 |       3.945 |      1.783 | 0.000 |        0.000 | True           |
| nested_individual_files    | `1dddb1244c87` |       0.100 |  0.288 |      11.872 |      1.837 | 0.000 |        0.003 | True           |
| nested_individual_files    | `5043fa575aa6` |       0.140 |  0.233 |       2.211 |      1.442 | 4.742 |        0.000 | True           |
| nested_individual_files    | `79f9b55d3fb8` |       0.181 |  0.410 |      10.182 |      5.684 | 0.000 |        0.001 | True           |
| nested_individual_files    | `c10c168c3ea7` |       3.846 |  0.414 |       1.603 |      4.816 | 0.000 |        0.000 | True           |
| nested_individual_files    | `df42d8f5a591` |       6.001 |  0.455 |      20.712 |      1.628 | 0.000 |        0.000 | True           |
| nested_individual_files    | `f1239aa39480` |      30.510 |  0.444 |       9.207 |      2.468 | 0.000 |        0.000 | True           |
| pids_one_regression        | `f4c69ffb2998` |       0.294 |  0.354 |      13.795 |      1.119 | 0.000 |        0.001 | True           |
| source_dir_tree            | `280e6ad6e0fe` |       0.120 |  4.888 |       9.557 |      2.830 | 0.000 |        0.000 | True           |
| source_dir_tree            | `35fb441c98d9` |       0.442 |  1.037 |       5.090 |      4.158 | 0.000 |        0.000 | True           |
| source_dir_tree            | `685a1ba5f47a` |       0.117 |  0.262 |      74.287 |     13.639 | 0.000 |        0.001 | True           |
| source_dir_tree            | `6a2a37eadcc5` |       0.120 | 15.454 |       8.903 |      1.408 | 0.000 |        0.001 | True           |
| symlink_input_consumer     | `2698574104c6` |       0.144 |  0.345 |       0.904 |      3.644 | 0.000 |        0.000 | True           |
| timeout_recovery           | `dc6f23f617c1` |       0.148 |  0.336 |      19.064 |      2.254 | 0.000 |        0.001 | True           |
| unknown                    | `9d7a2c7012de` |       0.039 |  0.143 |       0.863 |      0.474 | 0.000 |        0.000 | True           |

## VM Bridge Timing

These are raw TCP-to-vsock pump connection measurements logged by `darwin-actiond serve-vm`.

- Bridge connections logged: `14`
- Total client to guest bytes: `1.51 MiB`
- Total guest to client bytes: `0.30 MiB`
- Pump errors: read=`0`, write=`0`

| Bridge Metric          |     Min |      p25 |      p50 |      p75 |      p95 |     Mean |      Max |
| ---------------------- | ------: | -------: | -------: | -------: | -------: | -------: | -------: |
| connection elapsed     | 242.059 | 1063.933 | 1132.733 | 2243.634 | 5052.708 | 1803.113 | 5109.920 |
| client to guest KiB    |     0.0 |     30.9 |     79.8 |    122.4 |    317.5 |    110.6 |    587.5 |
| guest to client KiB    |     0.0 |      2.2 |     18.1 |     20.3 |     74.8 |     22.1 |    114.3 |
| client to guest reads  |       1 |       13 |      112 |      161 |      202 |    100.6 |      212 |
| client to guest writes |       1 |       13 |      112 |      161 |      202 |    100.6 |      212 |
| guest to client reads  |       0 |       14 |       62 |       78 |      116 |     57.0 |      147 |
| guest to client writes |       0 |       14 |       62 |       78 |      116 |     57.0 |      147 |

## Per Action

| Stress Case                | Digest         |   Total | Input | Execute | Output | Bind Mounts |        Outputs |
| -------------------------- | -------------- | ------: | ----: | ------: | -----: | ----------: | -------------: |
| aggregate                  | `b685ab4a0d00` |  12.985 | 0.300 |  12.625 |  0.060 |           4 |  1 file, 0 dir |
| bare_individual_files      | `24c5cd3f112a` |  27.332 | 2.971 |  24.216 |  0.144 |           4 |  1 file, 1 dir |
| bare_individual_files      | `2623700af2b1` |  28.285 | 0.413 |  26.756 |  1.117 |           4 |  1 file, 1 dir |
| bare_individual_files      | `43f037c27458` |  23.081 | 0.283 |  22.636 |  0.161 |           4 |  1 file, 1 dir |
| bare_individual_files      | `feeb2d55641f` |  19.477 | 0.399 |  18.503 |  0.575 |           4 |  1 file, 1 dir |
| filesystem_regression      | `d132925a0328` | 105.540 | 0.947 | 102.521 |  2.071 |           4 |  1 file, 1 dir |
| generated_file_producer    | `e84ec75ce42e` |  42.392 | 9.242 |  24.742 |  8.408 |           4 | 97 file, 0 dir |
| generated_individual_files | `118b63159b38` |   9.516 | 0.276 |   8.485 |  0.755 |           4 |  1 file, 1 dir |
| generated_individual_files | `242c99eb2c28` |  10.178 | 0.303 |   9.743 |  0.131 |           4 |  1 file, 1 dir |
| generated_individual_files | `78230e4a6f6d` |  16.768 | 0.343 |  16.294 |  0.131 |           4 |  1 file, 1 dir |
| generated_individual_files | `ec087db43ffd` |  10.412 | 0.536 |   7.827 |  2.049 |           4 |  1 file, 1 dir |
| generated_tree_producer    | `d33821cebf3e` |  45.624 | 0.377 |  35.180 | 10.068 |           4 |  1 file, 1 dir |
| generated_tree_reuse       | `0bbda7aff823` |  15.830 | 0.596 |  15.124 |  0.110 |           4 |  1 file, 1 dir |
| generated_tree_reuse       | `28f302b72b2d` |  15.136 | 0.289 |  14.735 |  0.113 |           4 |  1 file, 1 dir |
| generated_tree_reuse       | `3fa11b1bc05f` |  22.070 | 0.697 |  21.263 |  0.110 |           4 |  1 file, 1 dir |
| generated_tree_reuse       | `63a12c93411c` |   7.636 | 0.313 |   7.021 |  0.302 |           4 |  1 file, 1 dir |
| generated_tree_reuse       | `654f662800a0` |  17.689 | 0.564 |  16.192 |  0.933 |           4 |  1 file, 1 dir |
| generated_tree_reuse       | `740cb972a7d0` |  22.083 | 3.158 |  18.115 |  0.810 |           4 |  1 file, 1 dir |
| generated_tree_reuse       | `9de4f80099e4` |  19.634 | 0.324 |  19.186 |  0.124 |           4 |  1 file, 1 dir |
| generated_tree_reuse       | `ce4b28b15b03` |  21.001 | 2.270 |  18.013 |  0.718 |           4 |  1 file, 1 dir |
| mixed_all                  | `05385b608139` |  12.815 | 0.321 |  10.046 |  2.448 |           4 |  1 file, 1 dir |
| nested_individual_files    | `0576f836a969` |  29.748 | 0.345 |  28.995 |  0.408 |           4 |  1 file, 1 dir |
| nested_individual_files    | `0ba5a66718e5` |  17.951 | 0.542 |  16.541 |  0.869 |           4 |  1 file, 1 dir |
| nested_individual_files    | `1dddb1244c87` |  14.939 | 0.321 |  14.131 |  0.486 |           4 |  1 file, 1 dir |
| nested_individual_files    | `5043fa575aa6` |  17.580 | 7.401 |   8.830 |  1.349 |           4 |  1 file, 1 dir |
| nested_individual_files    | `79f9b55d3fb8` |  20.173 | 0.519 |  16.507 |  3.147 |           4 |  1 file, 1 dir |
| nested_individual_files    | `c10c168c3ea7` |  11.994 | 0.608 |  10.722 |  0.663 |           4 |  1 file, 1 dir |
| nested_individual_files    | `df42d8f5a591` |  29.843 | 0.310 |  28.834 |  0.698 |           4 |  1 file, 1 dir |
| nested_individual_files    | `f1239aa39480` |  44.671 | 0.391 |  42.671 |  1.609 |           4 |  1 file, 1 dir |
| pids_one_regression        | `f4c69ffb2998` |  16.760 | 1.012 |  15.606 |  0.142 |           4 |  1 file, 1 dir |
| source_dir_tree            | `280e6ad6e0fe` |  17.967 | 0.394 |  17.426 |  0.147 |           4 |  1 file, 1 dir |
| source_dir_tree            | `35fb441c98d9` |  11.597 | 0.712 |  10.747 |  0.139 |           4 |  1 file, 1 dir |
| source_dir_tree            | `685a1ba5f47a` |  90.436 | 0.897 |  88.363 |  1.175 |           4 |  1 file, 1 dir |
| source_dir_tree            | `6a2a37eadcc5` |  26.434 | 0.316 |  25.931 |  0.186 |           4 |  1 file, 1 dir |
| symlink_input_consumer     | `2698574104c6` |   5.609 | 0.331 |   5.061 |  0.217 |           4 |  1 file, 1 dir |
| timeout_recovery           | `dc6f23f617c1` |  22.593 | 0.643 |  21.843 |  0.107 |           4 |  1 file, 1 dir |
| unknown                    | `9d7a2c7012de` |   1.886 | 0.232 |   1.538 |  0.117 |           2 |  1 file, 0 dir |

## Notes

- Every action uses actiondfs, so input trees are represented by mounted REAPI root digests rather than flattened input counters.
- Some CAS metadata and file read cost appears in the action `process/io` bucket because actiondfs loads inputs lazily.
