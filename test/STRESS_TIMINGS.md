# Executor Timing Summary

- Generated: `2026-08-02 17:31:16 EDT`
- Mode: `vm`
- Execute records parsed: `37`
- Unique action digests: `37`
- Source log: `/var/folders/p4/xn8y5q_j24l5xwgwd_jx5c340000gn/T/actiond-vm-e2e.ZrWA2N/darwin-actiond-vm.log`
- Command: `ACTIOND_E2E_KEEP_TMP=1 ACTIOND_REPO_BAZEL_FLAGS="--config=remote --config=executor_timing_logs" tools/e2e.sh vm`

## Stage Timing

All timing values are milliseconds unless noted.

| Stage                 |   Min |    p25 |    p50 |    p75 |    p95 |   Mean |     Max | Share of summed total |
| --------------------- | ----: | -----: | -----: | -----: | -----: | -----: | ------: | --------------------: |
| total                 | 1.952 | 12.928 | 22.751 | 32.288 | 65.471 | 29.264 | 213.224 |                100.0% |
| input fetch/setup     | 0.198 |  0.291 |  0.319 |  0.530 |  1.456 |  0.897 |  16.614 |                  3.1% |
| execute               | 1.644 | 12.424 | 19.441 | 31.322 | 62.674 | 26.891 | 212.333 |                 91.9% |
| output upload/collect | 0.056 |  0.156 |  0.388 |  0.603 |  3.684 |  1.476 |  28.829 |                  5.0% |

## Mount And Output Counts

| Metric             | Min | p25 | p50 | p75 | p95 | Mean | Max |
| ------------------ | --: | --: | --: | --: | --: | ---: | --: |
| bind mounts        |   2 |   4 |   4 |   4 |   4 |  3.9 |   4 |
| output files       |   1 |   1 |   1 |   1 |   1 |  3.6 |  97 |
| output directories |   0 |   1 |   1 |   1 |   1 |  0.9 |   1 |

## Stage Timing By Stress Case

| Stress Case                | Actions | Total p25 | Total p50 | Total p75 | Total p95 | Input p50 | Execute p50 | Output p50 | Mounts p50 |
| -------------------------- | ------: | --------: | --------: | --------: | --------: | --------: | ----------: | ---------: | ---------: |
| aggregate                  |       1 |    31.942 |    31.942 |    31.942 |    31.942 |     0.281 |      31.606 |      0.056 |          4 |
| bare_individual_files      |       4 |    11.904 |    16.790 |    30.748 |    56.390 |     0.377 |      16.248 |      0.274 |          4 |
| filesystem_regression      |       1 |   213.224 |   213.224 |   213.224 |   213.224 |     0.287 |     212.333 |      0.603 |          4 |
| generated_file_producer    |       1 |    24.952 |    24.952 |    24.952 |    24.952 |     0.692 |      16.875 |      7.385 |          4 |
| generated_individual_files |       4 |     5.633 |     6.113 |     7.625 |    10.553 |     0.313 |       5.662 |      0.257 |          4 |
| generated_tree_producer    |       1 |    47.602 |    47.602 |    47.602 |    47.602 |     0.317 |      18.456 |     28.829 |          4 |
| generated_tree_reuse       |       8 |    21.052 |    22.670 |    29.163 |    30.309 |     0.323 |      22.179 |      0.201 |          4 |
| mixed_all                  |       1 |    34.436 |    34.436 |    34.436 |    34.436 |     0.303 |      31.471 |      2.662 |          4 |
| nested_individual_files    |       8 |    32.254 |    34.462 |    35.784 |    62.467 |     0.319 |      32.381 |      0.535 |          4 |
| pids_one_regression        |       1 |    16.626 |    16.626 |    16.626 |    16.626 |     0.584 |      15.768 |      0.274 |          4 |
| source_dir_tree            |       4 |    10.899 |    13.767 |    18.627 |    26.835 |     0.421 |      12.867 |      0.370 |          4 |
| symlink_input_consumer     |       1 |     6.269 |     6.269 |     6.269 |     6.269 |     1.013 |       5.039 |      0.217 |          4 |
| timeout_recovery           |       1 |    16.611 |    16.611 |    16.611 |    16.611 |     0.364 |      16.141 |      0.105 |          4 |
| unknown                    |       1 |     1.952 |     1.952 |     1.952 |     1.952 |     0.198 |       1.644 |      0.110 |          2 |

## Visible Overhead Estimate

`process/io` is excluded here because it is mostly the action process runtime plus stdout/stderr drain.

| Metric                    |   Min |   p25 |    p50 |    p75 |    p95 |   Mean |    Max | Share of summed total |
| ------------------------- | ----: | ----: | -----: | -----: | -----: | -----: | -----: | --------------------: |
| fixed overhead, no wait   | 1.601 | 9.403 | 19.053 | 26.967 | 33.695 | 18.168 | 40.780 |                 62.1% |
| fixed overhead, with wait | 1.601 | 9.403 | 19.053 | 26.967 | 33.695 | 18.327 | 40.780 |                 62.6% |

## Runner Timing

These values split the `execute` bucket. `child setup` includes successful `execve`; `process/io` starts after close-on-exec confirmation and includes action runtime and stdout/stderr drain.

| Runner Stage   |   Min |   p25 |   p50 |    p75 |    p95 |   Mean |     Max | Share of execute |
| -------------- | ----: | ----: | ----: | -----: | -----: | -----: | ------: | ---------------: |
| parent prepare | 0.029 | 0.126 | 0.348 |  8.996 | 24.580 |  5.820 |  25.331 |            21.6% |
| fork           | 0.102 | 0.252 | 0.317 |  0.564 |  3.637 |  0.803 |   5.233 |             3.0% |
| child setup    | 0.692 | 2.342 | 4.242 | 14.884 | 27.495 |  9.172 |  31.297 |            34.1% |
| process/io     | 0.341 | 1.577 | 3.476 |  5.434 | 35.588 | 10.905 | 191.373 |            40.6% |
| wait           | 0.000 | 0.000 | 0.000 |  0.000 |  0.489 |  0.159 |   3.426 |             0.6% |
| stdio digest   | 0.000 | 0.000 | 0.000 |  0.000 |  0.001 |  0.000 |   0.001 |             0.0% |

| Stress Case                | Digest         | Parent Prep |  Fork | Child Setup | Process/IO |  Wait | Stdio Digest | Setup Signaled |
| -------------------------- | -------------- | ----------: | ----: | ----------: | ---------: | ----: | -----------: | -------------- |
| aggregate                  | `b685ab4a0d00` |       0.103 | 0.264 |      29.013 |      2.204 | 0.000 |        0.001 | True           |
| bare_individual_files      | `24c5cd3f112a` |       0.143 | 0.317 |      12.070 |      6.888 | 0.000 |        0.000 | True           |
| bare_individual_files      | `2623700af2b1` |      21.587 | 0.442 |       3.262 |     34.173 | 0.000 |        0.000 | True           |
| bare_individual_files      | `43f037c27458` |       0.162 | 0.476 |       2.342 |      3.333 | 0.000 |        0.000 | True           |
| bare_individual_files      | `feeb2d55641f` |       8.996 | 0.564 |       2.096 |      1.379 | 0.000 |        0.000 | True           |
| filesystem_regression      | `d132925a0328` |      16.896 | 0.203 |       3.831 |    191.373 | 0.000 |        0.000 | True           |
| generated_file_producer    | `e84ec75ce42e` |       8.042 | 0.944 |       2.454 |      5.417 | 0.000 |        0.000 | True           |
| generated_individual_files | `118b63159b38` |       0.105 | 0.292 |       3.474 |      3.257 | 3.426 |        0.000 | True           |
| generated_individual_files | `242c99eb2c28` |       0.126 | 0.369 |       1.564 |      1.365 | 0.000 |        0.000 | True           |
| generated_individual_files | `78230e4a6f6d` |       0.142 | 0.496 |       2.165 |      3.092 | 0.000 |        0.000 | True           |
| generated_individual_files | `ec087db43ffd` |       0.094 | 0.234 |       4.570 |      0.485 | 0.000 |        0.000 | True           |
| generated_tree_producer    | `d33821cebf3e` |       8.290 | 0.320 |       3.024 |      6.809 | 0.000 |        0.000 | True           |
| generated_tree_reuse       | `0bbda7aff823` |      15.067 | 0.185 |       0.692 |      6.349 | 0.000 |        0.000 | True           |
| generated_tree_reuse       | `28f302b72b2d` |       0.208 | 3.427 |      17.194 |      5.434 | 0.000 |        0.000 | True           |
| generated_tree_reuse       | `3fa11b1bc05f` |      14.356 | 0.313 |       3.245 |      3.499 | 0.000 |        0.000 | True           |
| generated_tree_reuse       | `63a12c93411c` |       0.120 | 0.277 |      27.116 |      1.424 | 0.000 |        0.001 | True           |
| generated_tree_reuse       | `654f662800a0` |       2.987 | 2.462 |       3.306 |      3.652 | 0.000 |        0.000 | True           |
| generated_tree_reuse       | `740cb972a7d0` |      11.111 | 0.432 |       1.176 |      3.440 | 0.000 |        0.000 | True           |
| generated_tree_reuse       | `9de4f80099e4` |       0.108 | 5.233 |      19.376 |      5.056 | 0.000 |        0.000 | True           |
| generated_tree_reuse       | `ce4b28b15b03` |      15.120 | 2.556 |       2.024 |      2.332 | 0.000 |        0.000 | True           |
| mixed_all                  | `05385b608139` |       3.163 | 0.603 |       5.548 |     22.133 | 0.000 |        0.001 | True           |
| nested_individual_files    | `0576f836a969` |      24.816 | 0.217 |       6.841 |      1.466 | 0.000 |        0.000 | True           |
| nested_individual_files    | `0ba5a66718e5` |      25.331 | 0.224 |       8.487 |     41.246 | 0.000 |        0.000 | True           |
| nested_individual_files    | `1dddb1244c87` |       0.111 | 0.246 |      25.783 |      5.157 | 0.000 |        0.001 | True           |
| nested_individual_files    | `5043fa575aa6` |       0.627 | 0.241 |      12.449 |      3.724 | 0.000 |        0.001 | True           |
| nested_individual_files    | `79f9b55d3fb8` |       3.979 | 0.261 |      19.055 |     11.193 | 0.000 |        0.000 | True           |
| nested_individual_files    | `c10c168c3ea7` |       0.133 | 0.257 |      31.297 |      3.615 | 0.000 |        0.000 | True           |
| nested_individual_files    | `df42d8f5a591` |       0.127 | 4.476 |      18.086 |      1.432 | 0.000 |        0.000 | True           |
| nested_individual_files    | `f1239aa39480` |      24.521 | 0.356 |       3.015 |      3.476 | 0.000 |        0.001 | True           |
| pids_one_regression        | `f4c69ffb2998` |       0.225 | 0.306 |      13.631 |      1.577 | 0.000 |        0.001 | True           |
| source_dir_tree            | `280e6ad6e0fe` |       7.308 | 0.876 |       4.242 |      2.107 | 0.000 |        0.000 | True           |
| source_dir_tree            | `35fb441c98d9` |       0.191 | 0.252 |       1.103 |      4.111 | 0.000 |        0.000 | True           |
| source_dir_tree            | `685a1ba5f47a` |       0.348 | 0.601 |       7.307 |      2.873 | 0.000 |        0.000 | True           |
| source_dir_tree            | `6a2a37eadcc5` |       0.108 | 0.349 |      21.562 |      6.323 | 0.000 |        0.000 | True           |
| symlink_input_consumer     | `2698574104c6` |       0.443 | 0.280 |       0.934 |      0.900 | 2.446 |        0.000 | True           |
| timeout_recovery           | `dc6f23f617c1` |       0.120 | 0.252 |      14.884 |      0.858 | 0.000 |        0.000 | True           |
| unknown                    | `9d7a2c7012de` |       0.029 | 0.102 |       1.162 |      0.341 | 0.000 |        0.000 | True           |

## VM Bridge Timing

These are raw TCP-to-vsock pump connection measurements logged by `darwin-actiond serve-vm`.

- Bridge connections logged: `10`
- Total client to guest bytes: `1.48 MiB`
- Total guest to client bytes: `0.30 MiB`
- Pump errors: read=`0`, write=`0`

| Bridge Metric          |     Min |     p25 |     p50 |      p75 |      p95 |     Mean |      Max |
| ---------------------- | ------: | ------: | ------: | -------: | -------: | -------: | -------: |
| connection elapsed     | 168.522 | 743.358 | 871.378 | 2786.821 | 5127.514 | 1885.829 | 5297.803 |
| client to guest KiB    |     0.0 |    19.6 |   154.6 |    178.9 |    421.0 |    151.0 |    587.5 |
| guest to client KiB    |     0.0 |     1.3 |    20.2 |     55.5 |     82.8 |     30.9 |    101.9 |
| client to guest reads  |       1 |      12 |      58 |      224 |      316 |    118.1 |      339 |
| client to guest writes |       1 |      12 |      58 |      224 |      316 |    118.1 |      339 |
| guest to client reads  |       0 |      10 |      84 |      197 |      207 |     99.0 |      212 |
| guest to client writes |       0 |      10 |      84 |      197 |      207 |     99.0 |      212 |

## Per Action

| Stress Case                | Digest         |   Total |  Input | Execute | Output | Bind Mounts |        Outputs |
| -------------------------- | -------------- | ------: | -----: | ------: | -----: | ----------: | -------------: |
| aggregate                  | `b685ab4a0d00` |  31.942 |  0.281 |  31.606 |  0.056 |           4 |  1 file, 0 dir |
| bare_individual_files      | `24c5cd3f112a` |  20.064 |  0.304 |  19.441 |  0.319 |           4 |  1 file, 1 dir |
| bare_individual_files      | `2623700af2b1` |  62.800 |  0.530 |  59.512 |  2.758 |           4 |  1 file, 1 dir |
| bare_individual_files      | `43f037c27458` |   7.068 |  0.417 |   6.422 |  0.228 |           4 |  1 file, 1 dir |
| bare_individual_files      | `feeb2d55641f` |  13.516 |  0.337 |  13.054 |  0.125 |           4 |  1 file, 1 dir |
| filesystem_regression      | `d132925a0328` | 213.224 |  0.287 | 212.333 |  0.603 |           4 |  1 file, 1 dir |
| generated_file_producer    | `e84ec75ce42e` |  24.952 |  0.692 |  16.875 |  7.385 |           4 | 97 file, 0 dir |
| generated_individual_files | `118b63159b38` |  11.285 |  0.319 |  10.582 |  0.384 |           4 |  1 file, 1 dir |
| generated_individual_files | `242c99eb2c28` |   5.068 |  0.307 |   3.507 |  1.254 |           4 |  1 file, 1 dir |
| generated_individual_files | `78230e4a6f6d` |   6.406 |  0.354 |   5.920 |  0.131 |           4 |  1 file, 1 dir |
| generated_individual_files | `ec087db43ffd` |   5.821 |  0.291 |   5.404 |  0.125 |           4 |  1 file, 1 dir |
| generated_tree_producer    | `d33821cebf3e` |  47.602 |  0.317 |  18.456 | 28.829 |           4 |  1 file, 1 dir |
| generated_tree_reuse       | `0bbda7aff823` |  22.751 |  0.347 |  22.309 |  0.096 |           4 |  1 file, 1 dir |
| generated_tree_reuse       | `28f302b72b2d` |  29.034 |  1.997 |  26.309 |  0.728 |           4 |  1 file, 1 dir |
| generated_tree_reuse       | `3fa11b1bc05f` |  22.588 |  0.299 |  21.449 |  0.839 |           4 |  1 file, 1 dir |
| generated_tree_reuse       | `63a12c93411c` |  29.550 |  0.430 |  28.964 |  0.156 |           4 |  1 file, 1 dir |
| generated_tree_reuse       | `654f662800a0` |  12.928 |  0.257 |  12.424 |  0.247 |           4 |  1 file, 1 dir |
| generated_tree_reuse       | `740cb972a7d0` |  16.970 |  0.285 |  16.251 |  0.433 |           4 |  1 file, 1 dir |
| generated_tree_reuse       | `9de4f80099e4` |  30.717 |  0.808 |  29.798 |  0.112 |           4 |  1 file, 1 dir |
| generated_tree_reuse       | `ce4b28b15b03` |  22.412 |  0.260 |  22.050 |  0.102 |           4 |  1 file, 1 dir |
| mixed_all                  | `05385b608139` |  34.436 |  0.303 |  31.471 |  2.662 |           4 |  1 file, 1 dir |
| nested_individual_files    | `0576f836a969` |  34.112 |  0.322 |  33.364 |  0.426 |           4 |  1 file, 1 dir |
| nested_individual_files    | `0ba5a66718e5` |  76.157 |  0.370 |  75.323 |  0.463 |           4 |  1 file, 1 dir |
| nested_individual_files    | `1dddb1244c87` |  32.149 |  0.295 |  31.322 |  0.532 |           4 |  1 file, 1 dir |
| nested_individual_files    | `5043fa575aa6` |  34.813 | 16.614 |  17.074 |  1.125 |           4 |  1 file, 1 dir |
| nested_individual_files    | `79f9b55d3fb8` |  35.365 |  0.317 |  34.510 |  0.538 |           4 |  1 file, 1 dir |
| nested_individual_files    | `c10c168c3ea7` |  37.042 |  1.321 |  35.330 |  0.392 |           4 |  1 file, 1 dir |
| nested_individual_files    | `df42d8f5a591` |  25.220 |  0.288 |  24.142 |  0.790 |           4 |  1 file, 1 dir |
| nested_individual_files    | `f1239aa39480` |  32.288 |  0.290 |  31.398 |  0.600 |           4 |  1 file, 1 dir |
| pids_one_regression        | `f4c69ffb2998` |  16.626 |  0.584 |  15.768 |  0.274 |           4 |  1 file, 1 dir |
| source_dir_tree            | `280e6ad6e0fe` |  15.207 |  0.299 |  14.557 |  0.351 |           4 |  1 file, 1 dir |
| source_dir_tree            | `35fb441c98d9` |   6.617 |  0.543 |   5.685 |  0.388 |           4 |  1 file, 1 dir |
| source_dir_tree            | `685a1ba5f47a` |  12.326 |  0.660 |  11.178 |  0.487 |           4 |  1 file, 1 dir |
| source_dir_tree            | `6a2a37eadcc5` |  28.887 |  0.291 |  28.367 |  0.228 |           4 |  1 file, 1 dir |
| symlink_input_consumer     | `2698574104c6` |   6.269 |  1.013 |   5.039 |  0.217 |           4 |  1 file, 1 dir |
| timeout_recovery           | `dc6f23f617c1` |  16.611 |  0.364 |  16.141 |  0.105 |           4 |  1 file, 1 dir |
| unknown                    | `9d7a2c7012de` |   1.952 |  0.198 |   1.644 |  0.110 |           2 |  1 file, 0 dir |

## Notes

- Every action uses actiondfs, so input trees are represented by mounted REAPI root digests rather than flattened input counters.
- Some CAS metadata and file read cost appears in the action `process/io` bucket because actiondfs loads inputs lazily.
