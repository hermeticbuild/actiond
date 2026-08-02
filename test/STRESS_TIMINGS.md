# Executor Timing Summary

- Generated: `2026-08-01 22:16:50 EDT`
- Mode: `vm`
- Execute records parsed: `37`
- Unique action digests: `37`
- Source log: `/private/var/folders/p4/xn8y5q_j24l5xwgwd_jx5c340000gn/T/actiond-vm-e2e.zslx0e/darwin-actiond-vm.log`
- Command: `ACTIOND_E2E_KEEP_TMP=1 ACTIOND_REPO_BAZEL_FLAGS="--config=remote --config=executor_timing_logs" tools/e2e.sh vm`

## Stage Timing

All timing values are milliseconds unless noted.

| Stage                 |   Min |   p25 |    p50 |    p75 |    p95 |   Mean |     Max | Share of summed total |
| --------------------- | ----: | ----: | -----: | -----: | -----: | -----: | ------: | --------------------: |
| total                 | 1.646 | 6.868 | 14.809 | 21.798 | 34.470 | 17.880 | 122.846 |                100.0% |
| input fetch/setup     | 0.238 | 0.315 |  0.362 |  0.489 |  0.952 |  0.448 |   1.085 |                  2.5% |
| execute               | 1.309 | 5.307 | 13.675 | 18.963 | 29.634 | 15.933 | 121.629 |                 89.1% |
| output upload/collect | 0.078 | 0.132 |  0.443 |  1.140 |  7.894 |  1.498 |  11.683 |                  8.4% |

## Mount And Output Counts

| Metric             | Min | p25 | p50 | p75 | p95 | Mean | Max |
| ------------------ | --: | --: | --: | --: | --: | ---: | --: |
| bind mounts        |   2 |   4 |   4 |   4 |   4 |  3.9 |   4 |
| output files       |   1 |   1 |   1 |   1 |   1 |  3.6 |  97 |
| output directories |   0 |   1 |   1 |   1 |   1 |  0.9 |   1 |

## Stage Timing By Stress Case

| Stress Case                | Actions | Total p25 | Total p50 | Total p75 | Total p95 | Input p50 | Execute p50 | Output p50 | Mounts p50 |
| -------------------------- | ------: | --------: | --------: | --------: | --------: | --------: | ----------: | ---------: | ---------: |
| aggregate                  |       1 |    34.937 |    34.937 |    34.937 |    34.937 |     0.317 |      34.543 |      0.078 |          4 |
| bare_individual_files      |       4 |    14.849 |    17.165 |    21.967 |    27.966 |     0.322 |      16.707 |      0.147 |          4 |
| filesystem_regression      |       1 |   122.846 |   122.846 |   122.846 |   122.846 |     0.441 |     121.629 |      0.776 |          4 |
| generated_file_producer    |       1 |    11.894 |    11.894 |    11.894 |    11.894 |     0.909 |       6.804 |      4.180 |          4 |
| generated_individual_files |       4 |    14.274 |    14.677 |    15.992 |    18.316 |     0.369 |      13.937 |      0.215 |          4 |
| generated_tree_producer    |       1 |    34.353 |    34.353 |    34.353 |    34.353 |     0.299 |      22.370 |     11.683 |          4 |
| generated_tree_reuse       |       8 |     6.020 |     6.884 |     8.846 |    10.322 |     0.423 |       5.778 |      0.137 |          4 |
| mixed_all                  |       1 |    16.179 |    16.179 |    16.179 |    16.179 |     0.308 |      12.302 |      3.569 |          4 |
| nested_individual_files    |       8 |    20.553 |    22.405 |    24.292 |    28.021 |     0.568 |      19.189 |      1.342 |          4 |
| pids_one_regression        |       1 |    19.502 |    19.502 |    19.502 |    19.502 |     0.400 |      18.939 |      0.163 |          4 |
| source_dir_tree            |       4 |     4.776 |     5.163 |     5.496 |     5.850 |     0.313 |       4.590 |      0.293 |          4 |
| symlink_input_consumer     |       1 |     5.342 |     5.342 |     5.342 |     5.342 |     0.338 |       3.864 |      1.140 |          4 |
| timeout_recovery           |       1 |    22.541 |    22.541 |    22.541 |    22.541 |     1.085 |      21.220 |      0.236 |          4 |
| unknown                    |       1 |     1.646 |     1.646 |     1.646 |     1.646 |     0.238 |       1.309 |      0.099 |          2 |

## Visible Overhead Estimate

`process/io` is excluded here because it is mostly the action process runtime plus stdout/stderr drain.

| Metric                    |   Min |   p25 |    p50 |    p75 |    p95 |   Mean |    Max | Share of summed total |
| ------------------------- | ----: | ----: | -----: | -----: | -----: | -----: | -----: | --------------------: |
| fixed overhead, no wait   | 1.291 | 3.257 | 10.253 | 18.409 | 23.429 | 11.424 | 30.980 |                 63.9% |
| fixed overhead, with wait | 1.291 | 3.257 | 10.253 | 18.418 | 24.086 | 11.585 | 30.980 |                 64.8% |

## Runner Timing

These values split the `execute` bucket. `child setup` includes successful `execve`; `process/io` starts after close-on-exec confirmation and includes action runtime and stdout/stderr drain.

| Runner Stage   |   Min |   p25 |   p50 |    p75 |    p95 |  Mean |     Max | Share of execute |
| -------------- | ----: | ----: | ----: | -----: | -----: | ----: | ------: | ---------------: |
| parent prepare | 0.040 | 0.116 | 0.136 |  1.299 | 13.565 | 2.532 |  15.579 |            15.9% |
| fork           | 0.115 | 0.178 | 0.204 |  0.256 |  2.397 | 0.515 |   3.814 |             3.2% |
| child setup    | 0.198 | 1.623 | 2.030 | 12.723 | 18.367 | 6.431 |  30.306 |            40.4% |
| process/io     | 0.343 | 1.410 | 2.391 |  3.832 | 12.872 | 6.265 | 109.238 |            39.3% |
| wait           | 0.000 | 0.000 | 0.000 |  0.000 |  0.535 | 0.161 |   3.282 |             1.0% |
| stdio digest   | 0.000 | 0.000 | 0.000 |  0.001 |  0.001 | 0.000 |   0.002 |             0.0% |

| Stress Case                | Digest         | Parent Prep |  Fork | Child Setup | Process/IO |  Wait | Stdio Digest | Setup Signaled |
| -------------------------- | -------------- | ----------: | ----: | ----------: | ---------: | ----: | -----------: | -------------- |
| aggregate                  | `b685ab4a0d00` |       0.109 | 0.171 |      30.306 |      3.918 | 0.000 |        0.001 | True           |
| bare_individual_files      | `24c5cd3f112a` |       0.118 | 0.183 |       6.060 |      7.923 | 0.000 |        0.001 | True           |
| bare_individual_files      | `2623700af2b1` |       0.110 | 0.204 |      12.723 |      1.391 | 0.000 |        0.000 | True           |
| bare_individual_files      | `43f037c27458` |       0.125 | 0.186 |      15.100 |      0.821 | 2.674 |        0.001 | True           |
| bare_individual_files      | `feeb2d55641f` |      13.253 | 0.185 |       2.837 |     12.110 | 0.000 |        0.000 | True           |
| filesystem_regression      | `d132925a0328` |      10.528 | 0.188 |       1.660 |    109.238 | 0.000 |        0.001 | True           |
| generated_file_producer    | `e84ec75ce42e` |       0.148 | 0.162 |       1.660 |      4.813 | 0.000 |        0.000 | True           |
| generated_individual_files | `118b63159b38` |       7.910 | 0.229 |       1.615 |      3.832 | 0.000 |        0.000 | True           |
| generated_individual_files | `242c99eb2c28` |       0.116 | 0.186 |      12.101 |      1.753 | 0.000 |        0.000 | True           |
| generated_individual_files | `78230e4a6f6d` |       0.136 | 0.220 |      16.864 |      1.145 | 0.000 |        0.000 | True           |
| generated_individual_files | `ec087db43ffd` |       7.948 | 0.230 |       1.669 |      3.762 | 0.000 |        0.001 | True           |
| generated_tree_producer    | `d33821cebf3e` |       0.117 | 3.814 |       2.495 |     15.920 | 0.000 |        0.000 | True           |
| generated_tree_reuse       | `0bbda7aff823` |       0.555 | 0.660 |       1.281 |      3.725 | 0.000 |        0.000 | True           |
| generated_tree_reuse       | `28f302b72b2d` |       1.299 | 2.139 |       2.959 |      3.326 | 0.000 |        0.000 | True           |
| generated_tree_reuse       | `3fa11b1bc05f` |       0.118 | 0.145 |       1.190 |      4.877 | 0.000 |        0.000 | True           |
| generated_tree_reuse       | `63a12c93411c` |       0.097 | 0.162 |       1.717 |      2.337 | 0.000 |        0.000 | True           |
| generated_tree_reuse       | `654f662800a0` |       0.360 | 0.256 |       1.884 |      5.119 | 0.000 |        0.001 | True           |
| generated_tree_reuse       | `740cb972a7d0` |       0.108 | 0.172 |       2.046 |      2.764 | 0.000 |        0.001 | True           |
| generated_tree_reuse       | `9de4f80099e4` |       0.111 | 1.186 |       0.198 |      3.470 | 0.000 |        0.000 | True           |
| generated_tree_reuse       | `ce4b28b15b03` |       0.109 | 0.237 |       1.134 |      3.800 | 0.000 |        0.000 | True           |
| mixed_all                  | `05385b608139` |       0.128 | 0.219 |       1.782 |     10.154 | 0.000 |        0.000 | True           |
| nested_individual_files    | `0576f836a969` |       0.102 | 3.429 |      13.742 |      0.768 | 0.000 |        0.000 | True           |
| nested_individual_files    | `0ba5a66718e5` |       0.524 | 0.892 |      17.232 |      1.638 | 0.000 |        0.000 | True           |
| nested_individual_files    | `1dddb1244c87` |      12.102 | 0.168 |       0.622 |      1.762 | 0.000 |        0.000 | True           |
| nested_individual_files    | `5043fa575aa6` |       2.640 | 0.256 |      18.220 |      1.095 | 0.000 |        0.000 | True           |
| nested_individual_files    | `79f9b55d3fb8` |       0.089 | 0.115 |       3.428 |      3.112 | 0.000 |        0.000 | True           |
| nested_individual_files    | `c10c168c3ea7` |      15.579 | 0.376 |       0.775 |      1.280 | 3.282 |        0.000 | True           |
| nested_individual_files    | `df42d8f5a591` |       3.055 | 0.712 |      16.444 |      1.559 | 0.000 |        0.000 | True           |
| nested_individual_files    | `f1239aa39480` |      14.810 | 0.223 |       1.595 |      1.410 | 0.000 |        0.001 | True           |
| pids_one_regression        | `f4c69ffb2998` |       0.134 | 0.187 |      17.451 |      1.127 | 0.000 |        0.001 | True           |
| source_dir_tree            | `280e6ad6e0fe` |       0.134 | 0.232 |       1.623 |      2.391 | 0.000 |        0.000 | True           |
| source_dir_tree            | `35fb441c98d9` |       0.213 | 0.158 |       2.332 |      2.201 | 0.000 |        0.000 | True           |
| source_dir_tree            | `685a1ba5f47a` |       0.206 | 0.178 |       1.746 |      2.611 | 0.000 |        0.002 | True           |
| source_dir_tree            | `6a2a37eadcc5` |       0.120 | 0.168 |       1.762 |      1.350 | 0.000 |        0.001 | True           |
| symlink_input_consumer     | `2698574104c6` |       0.138 | 0.198 |       2.030 |      1.476 | 0.000 |        0.000 | True           |
| timeout_recovery           | `dc6f23f617c1` |       0.286 | 0.421 |      18.956 |      1.501 | 0.000 |        0.001 | True           |
| unknown                    | `9d7a2c7012de` |       0.040 | 0.196 |       0.719 |      0.343 | 0.000 |        0.000 | True           |

## VM Bridge Timing

These are raw TCP-to-vsock pump connection measurements logged by `darwin-actiond serve-vm`.

- Bridge connections logged: `7`
- Total client to guest bytes: `1.44 MiB`
- Total guest to client bytes: `0.30 MiB`
- Pump errors: read=`0`, write=`0`

| Bridge Metric          |     Min |     p25 |      p50 |      p75 |      p95 |     Mean |      Max |
| ---------------------- | ------: | ------: | -------: | -------: | -------: | -------: | -------: |
| connection elapsed     | 156.541 | 460.205 | 1717.141 | 3984.197 | 4957.493 | 2249.734 | 4985.655 |
| client to guest KiB    |     0.0 |    11.1 |     19.7 |    421.3 |    560.7 |    210.3 |    587.5 |
| guest to client KiB    |     0.0 |     0.8 |      2.2 |     53.2 |    170.6 |     44.2 |    199.1 |
| client to guest reads  |       1 |      11 |       13 |      276 |      588 |    171.1 |      610 |
| client to guest writes |       1 |      11 |       13 |      276 |      588 |    171.1 |      610 |
| guest to client reads  |       0 |       6 |       10 |      210 |      442 |    128.6 |      457 |
| guest to client writes |       0 |       6 |       10 |      210 |      442 |    128.6 |      457 |

## Per Action

| Stress Case                | Digest         |   Total | Input | Execute | Output | Bind Mounts |        Outputs |
| -------------------------- | -------------- | ------: | ----: | ------: | -----: | ----------: | -------------: |
| aggregate                  | `b685ab4a0d00` |  34.937 | 0.317 |  34.543 |  0.078 |           4 |  1 file, 0 dir |
| bare_individual_files      | `24c5cd3f112a` |  14.809 | 0.362 |  14.316 |  0.131 |           4 |  1 file, 1 dir |
| bare_individual_files      | `2623700af2b1` |  14.863 | 0.286 |  14.452 |  0.125 |           4 |  1 file, 1 dir |
| bare_individual_files      | `43f037c27458` |  19.468 | 0.341 |  18.963 |  0.164 |           4 |  1 file, 1 dir |
| bare_individual_files      | `feeb2d55641f` |  29.465 | 0.303 |  28.407 |  0.756 |           4 |  1 file, 1 dir |
| filesystem_regression      | `d132925a0328` | 122.846 | 0.441 | 121.629 |  0.776 |           4 |  1 file, 1 dir |
| generated_file_producer    | `e84ec75ce42e` |  11.894 | 0.909 |   6.804 |  4.180 |           4 | 97 file, 0 dir |
| generated_individual_files | `118b63159b38` |  14.104 | 0.392 |  13.607 |  0.105 |           4 |  1 file, 1 dir |
| generated_individual_files | `242c99eb2c28` |  15.024 | 0.315 |  14.199 |  0.510 |           4 |  1 file, 1 dir |
| generated_individual_files | `78230e4a6f6d` |  18.897 | 0.391 |  18.385 |  0.121 |           4 |  1 file, 1 dir |
| generated_individual_files | `ec087db43ffd` |  14.331 | 0.347 |  13.675 |  0.308 |           4 |  1 file, 1 dir |
| generated_tree_producer    | `d33821cebf3e` |  34.353 | 0.299 |  22.370 | 11.683 |           4 |  1 file, 1 dir |
| generated_tree_reuse       | `0bbda7aff823` |   6.868 | 0.489 |   6.249 |  0.130 |           4 |  1 file, 1 dir |
| generated_tree_reuse       | `28f302b72b2d` |  10.401 | 0.529 |   9.740 |  0.132 |           4 |  1 file, 1 dir |
| generated_tree_reuse       | `3fa11b1bc05f` |   6.901 | 0.397 |   6.363 |  0.141 |           4 |  1 file, 1 dir |
| generated_tree_reuse       | `63a12c93411c` |   4.729 | 0.284 |   4.328 |  0.117 |           4 |  1 file, 1 dir |
| generated_tree_reuse       | `654f662800a0` |   8.403 | 0.347 |   7.647 |  0.409 |           4 |  1 file, 1 dir |
| generated_tree_reuse       | `740cb972a7d0` |  10.173 | 0.449 |   5.125 |  4.600 |           4 |  1 file, 1 dir |
| generated_tree_reuse       | `9de4f80099e4` |   5.719 | 0.607 |   4.985 |  0.113 |           4 |  1 file, 1 dir |
| generated_tree_reuse       | `ce4b28b15b03` |   6.121 | 0.304 |   5.307 |  0.509 |           4 |  1 file, 1 dir |
| mixed_all                  | `05385b608139` |  16.179 | 0.308 |  12.302 |  3.569 |           4 |  1 file, 1 dir |
| nested_individual_files    | `0576f836a969` |  19.219 | 0.655 |  18.073 |  0.490 |           4 |  1 file, 1 dir |
| nested_individual_files    | `0ba5a66718e5` |  21.798 | 0.339 |  20.301 |  1.158 |           4 |  1 file, 1 dir |
| nested_individual_files    | `1dddb1244c87` |  24.774 | 0.583 |  14.677 |  9.513 |           4 |  1 file, 1 dir |
| nested_individual_files    | `5043fa575aa6` |  24.131 | 0.350 |  22.255 |  1.527 |           4 |  1 file, 1 dir |
| nested_individual_files    | `79f9b55d3fb8` |   7.897 | 0.552 |   6.766 |  0.580 |           4 |  1 file, 1 dir |
| nested_individual_files    | `c10c168c3ea7` |  29.769 | 0.951 |  21.329 |  7.489 |           4 |  1 file, 1 dir |
| nested_individual_files    | `df42d8f5a591` |  23.013 | 0.365 |  21.790 |  0.857 |           4 |  1 file, 1 dir |
| nested_individual_files    | `f1239aa39480` |  20.998 | 0.954 |  18.077 |  1.967 |           4 |  1 file, 1 dir |
| pids_one_regression        | `f4c69ffb2998` |  19.502 | 0.400 |  18.939 |  0.163 |           4 |  1 file, 1 dir |
| source_dir_tree            | `280e6ad6e0fe` |   4.978 | 0.436 |   4.405 |  0.138 |           4 |  1 file, 1 dir |
| source_dir_tree            | `35fb441c98d9` |   5.348 | 0.279 |   4.926 |  0.144 |           4 |  1 file, 1 dir |
| source_dir_tree            | `685a1ba5f47a` |   5.939 | 0.337 |   4.775 |  0.827 |           4 |  1 file, 1 dir |
| source_dir_tree            | `6a2a37eadcc5` |   4.170 | 0.289 |   3.438 |  0.443 |           4 |  1 file, 1 dir |
| symlink_input_consumer     | `2698574104c6` |   5.342 | 0.338 |   3.864 |  1.140 |           4 |  1 file, 1 dir |
| timeout_recovery           | `dc6f23f617c1` |  22.541 | 1.085 |  21.220 |  0.236 |           4 |  1 file, 1 dir |
| unknown                    | `9d7a2c7012de` |   1.646 | 0.238 |   1.309 |  0.099 |           2 |  1 file, 0 dir |

## Notes

- Every action uses actiondfs, so input trees are represented by mounted REAPI root digests rather than flattened input counters.
- Some CAS metadata and file read cost appears in the action `process/io` bucket because actiondfs loads inputs lazily.
