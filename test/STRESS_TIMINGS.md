# Executor Timing Summary

- Generated: `2026-07-30 21:27:31 EDT`
- Mode: `vm`
- Execute records parsed: `36`
- Unique action digests: `36`
- Source log: `/var/folders/p4/xn8y5q_j24l5xwgwd_jx5c340000gn/T/actiond-vm-e2e.0KEOIs/darwin-actiond-vm.log`
- Command: `ACTIOND_E2E_KEEP_TMP=1 ACTIOND_REPO_BAZEL_FLAGS="--config=remote --config=executor_timing_logs" tools/e2e.sh vm`

## Stage Timing

All timing values are milliseconds unless noted.

| Stage                 |   Min |    p25 |    p50 |    p75 |    p95 |   Mean |     Max | Share of summed total |
| --------------------- | ----: | -----: | -----: | -----: | -----: | -----: | ------: | --------------------: |
| total                 | 4.168 | 20.570 | 31.554 | 39.426 | 57.708 | 37.878 | 284.074 |                100.0% |
| input fetch/setup     | 0.271 |  0.302 |  0.354 |  0.737 |  3.949 |  0.999 |   7.604 |                  2.6% |
| execute               | 3.484 | 18.485 | 27.423 | 35.506 | 51.711 | 34.130 | 281.650 |                 90.1% |
| output upload/collect | 0.083 |  0.153 |  0.791 |  2.121 | 15.584 |  2.748 |  20.587 |                  7.3% |

## Mount And Output Counts

| Metric             | Min | p25 | p50 | p75 | p95 | Mean | Max |
| ------------------ | --: | --: | --: | --: | --: | ---: | --: |
| bind mounts        |   4 |   4 |   4 |   4 |   4 |  4.0 |   4 |
| output files       |   1 |   1 |   1 |   1 |   1 |  3.7 |  97 |
| output directories |   0 |   1 |   1 |   1 |   1 |  0.9 |   1 |

## Stage Timing By Stress Case

| Stress Case                | Actions | Total p25 | Total p50 | Total p75 | Total p95 | Input p50 | Execute p50 | Output p50 | Mounts p50 |
| -------------------------- | ------: | --------: | --------: | --------: | --------: | --------: | ----------: | ---------: | ---------: |
| aggregate                  |       1 |    26.055 |    26.055 |    26.055 |    26.055 |     0.285 |      25.686 |      0.083 |          4 |
| bare_individual_files      |       4 |    27.443 |    32.164 |    33.786 |    34.289 |     0.317 |      29.378 |      0.468 |          4 |
| filesystem_regression      |       1 |   284.074 |   284.074 |   284.074 |   284.074 |     0.308 |     281.650 |      2.116 |          4 |
| generated_file_producer    |       1 |    34.346 |    34.346 |    34.346 |    34.346 |     0.645 |      26.347 |      7.354 |          4 |
| generated_individual_files |       4 |    32.756 |    39.116 |    45.676 |    56.690 |     0.559 |      36.750 |      1.019 |          4 |
| generated_tree_producer    |       1 |    44.460 |    44.460 |    44.460 |    44.460 |     1.335 |      32.007 |     11.117 |          4 |
| generated_tree_reuse       |       8 |    13.997 |    26.427 |    41.653 |    55.203 |     0.655 |      24.178 |      0.603 |          4 |
| mixed_all                  |       1 |    20.897 |    20.897 |    20.897 |    20.897 |     0.271 |      17.814 |      2.812 |          4 |
| nested_individual_files    |       8 |    26.163 |    32.731 |    43.742 |    57.088 |     0.318 |      30.859 |      1.144 |          4 |
| pids_one_regression        |       1 |    13.369 |    13.369 |    13.369 |    13.369 |     0.305 |      12.916 |      0.148 |          4 |
| source_dir_tree            |       4 |    23.606 |    23.986 |    27.969 |    37.392 |     0.543 |      22.857 |      0.377 |          4 |
| symlink_input_consumer     |       1 |     4.168 |     4.168 |     4.168 |     4.168 |     0.272 |       3.484 |      0.412 |          4 |
| timeout_recovery           |       1 |    27.716 |    27.716 |    27.716 |    27.716 |     3.338 |      23.844 |      0.533 |          4 |

## Visible Overhead Estimate

`process/io` is excluded here because it is mostly the action process runtime plus stdout/stderr drain.

| Metric                    |   Min |    p25 |    p50 |    p75 |    p95 |   Mean |    Max | Share of summed total |
| ------------------------- | ----: | -----: | -----: | -----: | -----: | -----: | -----: | --------------------: |
| fixed overhead, no wait   | 2.646 | 11.225 | 21.477 | 32.465 | 48.440 | 23.086 | 53.829 |                 60.9% |
| fixed overhead, with wait | 2.646 | 12.156 | 21.477 | 32.465 | 49.602 | 23.380 | 53.829 |                 61.7% |

## Runner Timing

These values split the `execute` bucket. `child setup` includes successful `execve`; `process/io` starts after close-on-exec confirmation and includes action runtime and stdout/stderr drain.

| Runner Stage   |   Min |   p25 |   p50 |    p75 |    p95 |   Mean |     Max | Share of execute |
| -------------- | ----: | ----: | ----: | -----: | -----: | -----: | ------: | ---------------: |
| parent prepare | 0.088 | 0.121 | 0.502 | 10.362 | 27.204 |  6.767 |  27.793 |            19.8% |
| fork           | 0.313 | 0.521 | 0.928 |  1.645 |  3.923 |  1.339 |   5.006 |             3.9% |
| child setup    | 0.946 | 4.264 | 7.329 | 19.516 | 28.501 | 11.233 |  31.908 |            32.9% |
| process/io     | 0.034 | 2.374 | 5.509 |  9.156 | 22.220 | 14.455 | 272.967 |            42.4% |
| wait           | 0.000 | 0.000 | 0.000 |  0.000 |  3.067 |  0.294 |   4.203 |             0.9% |
| stdio digest   | 0.000 | 0.000 | 0.000 |  0.001 |  0.001 |  0.000 |   0.001 |             0.0% |

| Stress Case                | Digest         | Parent Prep |  Fork | Child Setup | Process/IO |  Wait | Stdio Digest | Setup Signaled |
| -------------------------- | -------------- | ----------: | ----: | ----------: | ---------: | ----: | -----------: | -------------- |
| aggregate                  | `2fa3a4511718` |       0.109 | 0.404 |      22.475 |      2.673 | 0.000 |        0.001 | True           |
| bare_individual_files      | `1a9a1d7d45e4` |      26.561 | 0.862 |       4.883 |      0.125 | 0.000 |        0.001 | True           |
| bare_individual_files      | `293475ee06bb` |      14.018 | 5.006 |       1.000 |     10.215 | 0.000 |        0.001 | True           |
| bare_individual_files      | `96c424f1edad` |       4.347 | 0.547 |       8.585 |      1.354 | 0.000 |        0.001 | True           |
| bare_individual_files      | `ccdb7626dedd` |       0.119 | 1.077 |      24.906 |      2.374 | 0.000 |        0.000 | True           |
| filesystem_regression      | `9a580d312f78` |       4.558 | 1.515 |       2.578 |    272.967 | 0.000 |        0.001 | True           |
| generated_file_producer    | `174bffc360c9` |       9.937 | 0.459 |       2.482 |     13.451 | 0.000 |        0.000 | True           |
| generated_individual_files | `2d4ce7a45898` |       0.180 | 1.661 |      28.695 |      7.672 | 0.000 |        0.001 | True           |
| generated_individual_files | `58d933f8a1cc` |       0.234 | 0.522 |      28.436 |     22.490 | 0.000 |        0.001 | True           |
| generated_individual_files | `ebe0486999bc` |      11.639 | 1.753 |       2.042 |      3.249 | 0.000 |        0.000 | True           |
| generated_individual_files | `ef34017f746a` |      27.624 | 1.523 |       4.050 |      2.008 | 0.000 |        0.001 | True           |
| generated_tree_producer    | `db960becfd36` |       7.452 | 0.519 |       8.340 |     15.662 | 0.000 |        0.001 | True           |
| generated_tree_reuse       | `056bce18df22` |      19.927 | 1.252 |       4.336 |      8.929 | 0.000 |        0.000 | True           |
| generated_tree_reuse       | `1c8778f3cc78` |       0.101 | 0.447 |       7.538 |      0.034 | 0.000 |        0.000 | True           |
| generated_tree_reuse       | `21983588efc6` |       1.900 | 0.559 |      27.173 |     22.093 | 0.000 |        0.000 | True           |
| generated_tree_reuse       | `46d362087f03` |       0.099 | 0.333 |       6.882 |     22.130 | 4.203 |        0.000 | True           |
| generated_tree_reuse       | `5eba25364668` |       0.088 | 3.770 |       6.620 |      3.326 | 0.000 |        0.000 | True           |
| generated_tree_reuse       | `94a4a5794423` |       0.223 | 1.235 |       6.501 |      6.261 | 0.000 |        0.001 | True           |
| generated_tree_reuse       | `e89401eb9021` |      26.148 | 2.621 |       3.050 |      6.616 | 0.000 |        0.000 | True           |
| generated_tree_reuse       | `f433d0b3a994` |       0.111 | 2.246 |       5.474 |      4.559 | 0.000 |        0.000 | True           |
| mixed_all                  | `c91e0b696fc8` |       0.100 | 0.735 |       7.120 |      9.836 | 0.000 |        0.001 | True           |
| nested_individual_files    | `3dff464548c3` |       0.116 | 0.638 |      31.908 |      5.219 | 0.000 |        0.000 | True           |
| nested_individual_files    | `624772a8ae88` |       0.925 | 1.559 |       4.860 |      3.957 | 3.424 |        0.001 | True           |
| nested_individual_files    | `6875f2d910c8` |      27.793 | 2.406 |       2.728 |      3.273 | 0.000 |        0.000 | True           |
| nested_individual_files    | `7c722534d2c8` |       1.890 | 1.640 |      18.237 |      2.374 | 0.000 |        0.001 | True           |
| nested_individual_files    | `b77221109b6c` |       0.181 | 0.512 |       7.987 |     21.800 | 0.000 |        0.001 | True           |
| nested_individual_files    | `c66b33449ee8` |       1.744 | 0.641 |      15.435 |      6.701 | 0.000 |        0.000 | True           |
| nested_individual_files    | `e9b5b4f432a6` |      27.063 | 4.382 |       1.346 |      5.800 | 2.948 |        0.000 | True           |
| nested_individual_files    | `f904af8dd963` |       0.091 | 2.044 |      20.130 |      8.925 | 0.000 |        0.000 | True           |
| pids_one_regression        | `cd3cb4b17ba0` |       0.142 | 0.519 |      11.147 |      1.071 | 0.000 |        0.000 | True           |
| source_dir_tree            | `0744164ec172` |       0.121 | 0.354 |      19.792 |      2.694 | 0.000 |        0.001 | True           |
| source_dir_tree            | `25d07a1a15b9` |       0.676 | 0.313 |      19.439 |      2.239 | 0.000 |        0.000 | True           |
| source_dir_tree            | `5d07305214c6` |       0.128 | 0.824 |      12.161 |      8.702 | 0.000 |        0.000 | True           |
| source_dir_tree            | `c7d0b3212bf8` |      26.715 | 0.993 |       5.355 |      5.927 | 0.000 |        0.000 | True           |
| symlink_input_consumer     | `5c31db5029b1` |       0.234 | 0.781 |       0.946 |      1.482 | 0.000 |        0.001 | True           |
| timeout_recovery           | `01ac7dd6dd9b` |       0.328 | 1.536 |      19.747 |      2.189 | 0.000 |        0.001 | True           |

## VM Bridge Timing

These are raw TCP-to-vsock pump connection measurements logged by `darwin-actiond serve-vm`.

- Bridge connections logged: `9`
- Total client to guest bytes: `1.47 MiB`
- Total guest to client bytes: `0.30 MiB`
- Pump errors: read=`0`, write=`0`

| Bridge Metric          |     Min |     p25 |     p50 |     p75 |      p95 |     Mean |      Max |
| ---------------------- | ------: | ------: | ------: | ------: | -------: | -------: | -------: |
| connection elapsed     | 142.430 | 728.515 | 773.341 | 810.956 | 3337.637 | 1197.899 | 3512.199 |
| client to guest KiB    |     2.5 |    19.7 |   126.2 |   172.2 |    503.7 |    167.1 |    705.4 |
| guest to client KiB    |     0.9 |     2.3 |    37.6 |    43.9 |     81.1 |     34.3 |     96.5 |
| client to guest reads  |      11 |      18 |     184 |     241 |      252 |    148.3 |      253 |
| client to guest writes |      11 |      18 |     184 |     241 |      252 |    148.3 |      253 |
| guest to client reads  |       9 |      21 |     106 |     128 |      136 |     85.4 |      138 |
| guest to client writes |       9 |      21 |     106 |     128 |      136 |     85.4 |      138 |

## Per Action

| Stress Case                | Digest         |   Total | Input | Execute | Output | Bind Mounts |        Outputs |
| -------------------------- | -------------- | ------: | ----: | ------: | -----: | ----------: | -------------: |
| aggregate                  | `2fa3a4511718` |  26.055 | 0.285 |  25.686 |  0.083 |           4 |  1 file, 0 dir |
| bare_individual_files      | `1a9a1d7d45e4` |  33.577 | 0.290 |  32.505 |  0.782 |           4 |  1 file, 1 dir |
| bare_individual_files      | `293475ee06bb` |  30.751 | 0.340 |  30.257 |  0.154 |           4 |  1 file, 1 dir |
| bare_individual_files      | `96c424f1edad` |  17.519 | 0.295 |  14.856 |  2.368 |           4 |  1 file, 1 dir |
| bare_individual_files      | `ccdb7626dedd` |  34.415 | 5.781 |  28.500 |  0.134 |           4 |  1 file, 1 dir |
| filesystem_regression      | `9a580d312f78` | 284.074 | 0.308 | 281.650 |  2.116 |           4 |  1 file, 1 dir |
| generated_file_producer    | `174bffc360c9` |  34.346 | 0.645 |  26.347 |  7.354 |           4 | 97 file, 0 dir |
| generated_individual_files | `2d4ce7a45898` |  41.087 | 0.715 |  38.235 |  2.136 |           4 |  1 file, 1 dir |
| generated_individual_files | `58d933f8a1cc` |  59.443 | 7.604 |  51.703 |  0.137 |           4 |  1 file, 1 dir |
| generated_individual_files | `ebe0486999bc` |  19.589 | 0.402 |  18.708 |  0.478 |           4 |  1 file, 1 dir |
| generated_individual_files | `ef34017f746a` |  37.145 | 0.321 |  35.265 |  1.559 |           4 |  1 file, 1 dir |
| generated_tree_producer    | `db960becfd36` |  44.460 | 1.335 |  32.007 | 11.117 |           4 |  1 file, 1 dir |
| generated_tree_reuse       | `056bce18df22` |  37.129 | 0.804 |  34.458 |  1.867 |           4 |  1 file, 1 dir |
| generated_tree_reuse       | `1c8778f3cc78` |   9.727 | 0.506 |   8.142 |  1.078 |           4 |  1 file, 1 dir |
| generated_tree_reuse       | `21983588efc6` |  54.266 | 2.430 |  51.738 |  0.098 |           4 |  1 file, 1 dir |
| generated_tree_reuse       | `46d362087f03` |  37.448 | 0.284 |  34.119 |  3.045 |           4 |  1 file, 1 dir |
| generated_tree_reuse       | `5eba25364668` |  14.213 | 0.277 |  13.823 |  0.113 |           4 |  1 file, 1 dir |
| generated_tree_reuse       | `94a4a5794423` |  15.725 | 1.360 |  14.238 |  0.127 |           4 |  1 file, 1 dir |
| generated_tree_reuse       | `e89401eb9021` |  55.707 | 0.279 |  38.448 | 16.980 |           4 |  1 file, 1 dir |
| generated_tree_reuse       | `f433d0b3a994` |  13.349 | 0.803 |  12.424 |  0.122 |           4 |  1 file, 1 dir |
| mixed_all                  | `c91e0b696fc8` |  20.897 | 0.271 |  17.814 |  2.812 |           4 |  1 file, 1 dir |
| nested_individual_files    | `3dff464548c3` |  39.318 | 0.306 |  37.921 |  1.092 |           4 |  1 file, 1 dir |
| nested_individual_files    | `624772a8ae88` |  15.882 | 0.273 |  14.809 |  0.800 |           4 |  1 file, 1 dir |
| nested_individual_files    | `6875f2d910c8` |  57.129 | 0.315 |  36.228 | 20.587 |           4 |  1 file, 1 dir |
| nested_individual_files    | `7c722534d2c8` |  26.195 | 0.354 |  24.169 |  1.673 |           4 |  1 file, 1 dir |
| nested_individual_files    | `b77221109b6c` |  33.105 | 2.097 |  30.510 |  0.499 |           4 |  1 file, 1 dir |
| nested_individual_files    | `c66b33449ee8` |  26.067 | 0.318 |  24.554 |  1.196 |           4 |  1 file, 1 dir |
| nested_individual_files    | `e9b5b4f432a6` |  57.012 | 0.318 |  41.575 | 15.118 |           4 |  1 file, 1 dir |
| nested_individual_files    | `f904af8dd963` |  32.356 | 0.689 |  31.209 |  0.458 |           4 |  1 file, 1 dir |
| pids_one_regression        | `cd3cb4b17ba0` |  13.369 | 0.305 |  12.916 |  0.148 |           4 |  1 file, 1 dir |
| source_dir_tree            | `0744164ec172` |  23.930 | 0.619 |  23.008 |  0.302 |           4 |  1 file, 1 dir |
| source_dir_tree            | `25d07a1a15b9` |  24.043 | 0.467 |  22.706 |  0.869 |           4 |  1 file, 1 dir |
| source_dir_tree            | `5d07305214c6` |  22.636 | 0.354 |  21.831 |  0.451 |           4 |  1 file, 1 dir |
| source_dir_tree            | `c7d0b3212bf8` |  39.748 | 0.619 |  39.009 |  0.120 |           4 |  1 file, 1 dir |
| symlink_input_consumer     | `5c31db5029b1` |   4.168 | 0.272 |   3.484 |  0.412 |           4 |  1 file, 1 dir |
| timeout_recovery           | `01ac7dd6dd9b` |  27.716 | 3.338 |  23.844 |  0.533 |           4 |  1 file, 1 dir |

## Notes

- Every action uses actiondfs, so input trees are represented by mounted REAPI root digests rather than flattened input counters.
- Some CAS metadata and file read cost appears in the action `process/io` bucket because actiondfs loads inputs lazily.
