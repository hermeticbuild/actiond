# Executor Timing Summary

- Generated: `2026-08-01 15:38:43 EDT`
- Mode: `vm`
- Execute records parsed: `36`
- Unique action digests: `36`
- Source log: `/var/folders/p4/xn8y5q_j24l5xwgwd_jx5c340000gn/T/actiond-vm-e2e.0mQ13T/darwin-actiond-vm.log`
- Command: `ACTIOND_E2E_KEEP_TMP=1 ACTIOND_E2E_ACTIONDFS_STATS_PATH=/private/tmp/actiondfs-round-six-final.stats ACTIOND_REPO_BAZEL_FLAGS="--config=remote --config=executor_timing_logs --jobs=32 --distdir=/private/tmp/actiond-audit-distdir --override_repository=llvm++osx+macos_sdk=/private/tmp/actiond-audit-macos-sdk" tools/e2e.sh vm`

## Stage Timing

All timing values are milliseconds unless noted.

| Stage                 |   Min |   p25 |    p50 |    p75 |    p95 |   Mean |    Max | Share of summed total |
| --------------------- | ----: | ----: | -----: | -----: | -----: | -----: | -----: | --------------------: |
| total                 | 2.800 | 7.638 | 15.403 | 21.545 | 44.323 | 17.931 | 96.064 |                100.0% |
| input fetch/setup     | 0.265 | 0.304 |  0.320 |  0.369 |  0.718 |  0.385 |  0.774 |                  2.1% |
| execute               | 2.239 | 6.911 | 14.545 | 19.252 | 36.624 | 16.418 | 94.466 |                 91.6% |
| output upload/collect | 0.073 | 0.185 |  0.417 |  0.947 |  5.558 |  1.128 | 10.451 |                  6.3% |

## Mount And Output Counts

| Metric             | Min | p25 | p50 | p75 | p95 | Mean | Max |
| ------------------ | --: | --: | --: | --: | --: | ---: | --: |
| bind mounts        |   4 |   4 |   4 |   4 |   4 |  4.0 |   4 |
| output files       |   1 |   1 |   1 |   1 |   1 |  3.7 |  97 |
| output directories |   0 |   1 |   1 |   1 |   1 |  0.9 |   1 |

## Stage Timing By Stress Case

| Stress Case                | Actions | Total p25 | Total p50 | Total p75 | Total p95 | Input p50 | Execute p50 | Output p50 | Mounts p50 |
| -------------------------- | ------: | --------: | --------: | --------: | --------: | --------: | ----------: | ---------: | ---------: |
| aggregate                  |       1 |    21.765 |    21.765 |    21.765 |    21.765 |     0.334 |      21.358 |      0.073 |          4 |
| bare_individual_files      |       4 |    14.152 |    15.531 |    19.003 |    25.750 |     0.310 |      14.864 |      0.350 |          4 |
| filesystem_regression      |       1 |    96.064 |    96.064 |    96.064 |    96.064 |     0.403 |      94.466 |      1.194 |          4 |
| generated_file_producer    |       1 |    40.791 |    40.791 |    40.791 |    40.791 |     0.729 |      34.097 |      5.964 |          4 |
| generated_individual_files |       4 |     4.759 |     5.354 |     8.250 |    14.238 |     0.508 |       4.325 |      0.336 |          4 |
| generated_tree_producer    |       1 |    54.918 |    54.918 |    54.918 |    54.918 |     0.265 |      44.202 |     10.451 |          4 |
| generated_tree_reuse       |       8 |     6.399 |     9.482 |    15.911 |    21.792 |     0.323 |       8.946 |      0.179 |          4 |
| mixed_all                  |       1 |    21.317 |    21.317 |    21.317 |    21.317 |     0.309 |      18.169 |      2.839 |          4 |
| nested_individual_files    |       8 |     7.202 |    14.776 |    19.407 |    23.647 |     0.315 |      13.525 |      0.691 |          4 |
| pids_one_regression        |       1 |     8.981 |     8.981 |     8.981 |     8.981 |     0.328 |       8.493 |      0.160 |          4 |
| source_dir_tree            |       4 |    15.268 |    17.018 |    19.448 |    24.224 |     0.325 |      16.561 |      0.339 |          4 |
| symlink_input_consumer     |       1 |     2.800 |     2.800 |     2.800 |     2.800 |     0.287 |       2.239 |      0.274 |          4 |
| timeout_recovery           |       1 |    22.876 |    22.876 |    22.876 |    22.876 |     0.683 |      21.918 |      0.275 |          4 |

## Visible Overhead Estimate

`process/io` is excluded here because it is mostly the action process runtime plus stdout/stderr drain.

| Metric                    |   Min |   p25 |   p50 |    p75 |    p95 |   Mean |    Max | Share of summed total |
| ------------------------- | ----: | ----: | ----: | -----: | -----: | -----: | -----: | --------------------: |
| fixed overhead, no wait   | 1.922 | 4.703 | 9.708 | 15.758 | 27.705 | 11.656 | 37.169 |                 65.0% |
| fixed overhead, with wait | 1.922 | 4.703 | 9.708 | 16.919 | 27.705 | 11.856 | 37.169 |                 66.1% |

## Runner Timing

These values split the `execute` bucket. `child setup` includes successful `execve`; `process/io` starts after close-on-exec confirmation and includes action runtime and stdout/stderr drain.

| Runner Stage   |   Min |   p25 |   p50 |   p75 |    p95 |  Mean |    Max | Share of execute |
| -------------- | ----: | ----: | ----: | ----: | -----: | ----: | -----: | ---------------: |
| parent prepare | 0.099 | 0.117 | 0.270 | 6.675 | 22.877 | 4.427 | 24.358 |            27.0% |
| fork           | 0.134 | 0.218 | 0.264 | 0.529 |  1.192 | 0.441 |  1.442 |             2.7% |
| child setup    | 0.819 | 1.635 | 2.306 | 5.647 | 18.052 | 5.275 | 18.704 |            32.1% |
| process/io     | 0.600 | 1.487 | 2.439 | 4.551 | 13.859 | 6.046 | 88.532 |            36.8% |
| wait           | 0.000 | 0.000 | 0.000 | 0.000 |  0.384 | 0.200 |  5.675 |             1.2% |
| stdio digest   | 0.000 | 0.000 | 0.000 | 0.001 |  0.001 | 0.000 |  0.001 |             0.0% |

| Stress Case                | Digest         | Parent Prep |  Fork | Child Setup | Process/IO |  Wait | Stdio Digest | Setup Signaled |
| -------------------------- | -------------- | ----------: | ----: | ----------: | ---------: | ----: | -----------: | -------------- |
| aggregate                  | `1aaef86306e4` |       0.129 | 0.241 |      18.301 |      2.642 | 0.000 |        0.001 | True           |
| bare_individual_files      | `066472414ea9` |      10.339 | 0.445 |       2.710 |      0.781 | 0.000 |        0.000 | True           |
| bare_individual_files      | `2bf32e1a816e` |       0.117 | 0.212 |      14.195 |      0.867 | 0.000 |        0.000 | True           |
| bare_individual_files      | `5f0c7908f803` |      23.502 | 0.182 |       2.102 |      1.158 | 0.000 |        0.001 | True           |
| bare_individual_files      | `9ddf9d0661e8` |       4.309 | 0.963 |       2.074 |      3.677 | 0.000 |        0.001 | True           |
| filesystem_regression      | `a889da71fec5` |       3.170 | 0.628 |       2.111 |     88.532 | 0.000 |        0.000 | True           |
| generated_file_producer    | `ce0a87dadeaf` |      22.669 | 0.256 |       2.482 |      8.666 | 0.000 |        0.001 | True           |
| generated_individual_files | `07134f6f78fb` |      10.292 | 0.473 |       2.257 |      1.502 | 0.000 |        0.000 | True           |
| generated_individual_files | `1ada216cf349` |       0.122 | 1.442 |       1.107 |      1.541 | 0.000 |        0.000 | True           |
| generated_individual_files | `2fcd9276e686` |       0.109 | 1.348 |       0.852 |      2.077 | 0.000 |        0.001 | True           |
| generated_individual_files | `963770016a83` |       0.137 | 0.442 |       0.819 |      2.043 | 0.000 |        0.000 | True           |
| generated_tree_producer    | `a0e22e4a2449` |      24.358 | 0.134 |       1.961 |     17.723 | 0.000 |        0.001 | True           |
| generated_tree_reuse       | `234fe92db0c4` |       8.840 | 0.537 |       2.457 |      2.662 | 0.000 |        0.001 | True           |
| generated_tree_reuse       | `307f8dd32223` |       4.255 | 0.179 |       1.653 |      4.424 | 0.000 |        0.001 | True           |
| generated_tree_reuse       | `31ecae29e592` |       0.130 | 0.196 |       4.773 |      2.221 | 0.000 |        0.000 | True           |
| generated_tree_reuse       | `3a94355a7850` |       0.099 | 0.195 |       1.732 |      1.411 | 0.000 |        0.001 | True           |
| generated_tree_reuse       | `3f5910cbd10a` |       0.261 | 0.255 |       1.989 |      1.341 | 0.000 |        0.000 | True           |
| generated_tree_reuse       | `958cf2efa665` |       0.157 | 0.228 |      14.039 |      1.441 | 0.000 |        0.001 | True           |
| generated_tree_reuse       | `b57daa400252` |      12.385 | 1.140 |       1.366 |      6.658 | 1.536 |        0.000 | True           |
| generated_tree_reuse       | `f1aa103ccd7c` |       0.117 | 0.527 |       2.218 |      3.448 | 0.000 |        0.000 | True           |
| mixed_all                  | `400c2bebfdf7` |       0.105 | 0.257 |       5.214 |     12.572 | 0.000 |        0.001 | True           |
| nested_individual_files    | `00a5c8fd5eca` |       0.134 | 0.265 |      12.860 |      5.493 | 0.000 |        0.000 | True           |
| nested_individual_files    | `06648fa82c90` |       5.043 | 0.253 |       1.228 |      3.685 | 0.000 |        0.001 | True           |
| nested_individual_files    | `0e936d2585e1` |       0.114 | 0.220 |      18.704 |      1.623 | 0.000 |        0.000 | True           |
| nested_individual_files    | `38e0080a81a7` |       0.115 | 0.208 |      15.868 |      1.725 | 0.000 |        0.001 | True           |
| nested_individual_files    | `6e61d7c5c043` |       0.114 | 0.213 |       1.572 |      2.024 | 0.000 |        0.001 | True           |
| nested_individual_files    | `7bb6083de2c1` |       0.278 | 0.251 |       3.609 |      2.952 | 0.000 |        0.000 | True           |
| nested_individual_files    | `7ebc5b535734` |       0.667 | 0.341 |      11.347 |      4.417 | 0.000 |        0.000 | True           |
| nested_individual_files    | `a455f1d89ad8` |       0.110 | 0.263 |       1.580 |      2.236 | 0.000 |        0.000 | True           |
| pids_one_regression        | `bbe16c49ab86` |       0.122 | 0.307 |       6.946 |      1.084 | 0.000 |        0.001 | True           |
| source_dir_tree            | `35ad590c3e20` |       6.631 | 0.303 |       2.926 |      0.600 | 0.000 |        0.000 | True           |
| source_dir_tree            | `94ef482d0fd5` |       7.094 | 0.854 |       4.140 |      4.930 | 0.000 |        0.000 | True           |
| source_dir_tree            | `98458d72ec38` |       6.144 | 0.752 |       1.308 |      7.867 | 0.000 |        0.000 | True           |
| source_dir_tree            | `f176f6534568` |       6.808 | 0.417 |       2.355 |      7.892 | 5.675 |        0.000 | True           |
| symlink_input_consumer     | `e7ebd25b87b9` |       0.109 | 0.193 |       1.058 |      0.857 | 0.000 |        0.000 | True           |
| timeout_recovery           | `ed01de57e2a7` |       0.288 | 0.740 |      17.969 |      2.868 | 0.000 |        0.001 | True           |

## VM Bridge Timing

These are raw TCP-to-vsock pump connection measurements logged by `darwin-actiond serve-vm`.

- Bridge connections logged: `6`
- Total client to guest bytes: `1.43 MiB`
- Total guest to client bytes: `0.30 MiB`
- Pump errors: read=`0`, write=`0`

| Bridge Metric          |     Min |     p25 |      p50 |      p75 |      p95 |     Mean |      Max |
| ---------------------- | ------: | ------: | -------: | -------: | -------: | -------: | -------: |
| connection elapsed     | 155.124 | 309.787 | 1899.559 | 3321.879 | 4764.864 | 2128.014 | 5237.991 |
| client to guest KiB    |     0.0 |     6.8 |     19.6 |    371.2 |    819.7 |    243.4 |    930.1 |
| guest to client KiB    |     0.0 |     1.3 |      2.2 |     81.9 |    173.4 |     51.5 |    195.0 |
| client to guest reads  |       1 |      10 |       14 |      260 |      399 |    133.0 |      418 |
| client to guest writes |       1 |      10 |       14 |      260 |      399 |    133.0 |      418 |
| guest to client reads  |       0 |      10 |       16 |      338 |      458 |    158.2 |      463 |
| guest to client writes |       0 |      10 |       16 |      338 |      458 |    158.2 |      463 |

## Per Action

| Stress Case                | Digest         |  Total | Input | Execute | Output | Bind Mounts |        Outputs |
| -------------------------- | -------------- | -----: | ----: | ------: | -----: | ----------: | -------------: |
| aggregate                  | `1aaef86306e4` | 21.765 | 0.334 |  21.358 |  0.073 |           4 |  1 file, 0 dir |
| bare_individual_files      | `066472414ea9` | 14.869 | 0.315 |  14.297 |  0.257 |           4 |  1 file, 1 dir |
| bare_individual_files      | `2bf32e1a816e` | 16.192 | 0.318 |  15.431 |  0.443 |           4 |  1 file, 1 dir |
| bare_individual_files      | `5f0c7908f803` | 27.436 | 0.297 |  26.984 |  0.155 |           4 |  1 file, 1 dir |
| bare_individual_files      | `9ddf9d0661e8` | 12.000 | 0.304 |  11.042 |  0.654 |           4 |  1 file, 1 dir |
| filesystem_regression      | `a889da71fec5` | 96.064 | 0.403 |  94.466 |  1.194 |           4 |  1 file, 1 dir |
| generated_file_producer    | `ce0a87dadeaf` | 40.791 | 0.729 |  34.097 |  5.964 |           4 | 97 file, 0 dir |
| generated_individual_files | `07134f6f78fb` | 15.735 | 0.774 |  14.543 |  0.418 |           4 |  1 file, 1 dir |
| generated_individual_files | `1ada216cf349` |  5.755 | 0.441 |   4.240 |  1.074 |           4 |  1 file, 1 dir |
| generated_individual_files | `2fcd9276e686` |  4.954 | 0.290 |   4.410 |  0.254 |           4 |  1 file, 1 dir |
| generated_individual_files | `963770016a83` |  4.176 | 0.574 |   3.459 |  0.142 |           4 |  1 file, 1 dir |
| generated_tree_producer    | `a0e22e4a2449` | 54.918 | 0.265 |  44.202 | 10.451 |           4 |  1 file, 1 dir |
| generated_tree_reuse       | `234fe92db0c4` | 15.071 | 0.334 |  14.546 |  0.190 |           4 |  1 file, 1 dir |
| generated_tree_reuse       | `307f8dd32223` | 11.144 | 0.294 |  10.549 |  0.302 |           4 |  1 file, 1 dir |
| generated_tree_reuse       | `31ecae29e592` |  7.819 | 0.359 |   7.343 |  0.117 |           4 |  1 file, 1 dir |
| generated_tree_reuse       | `3a94355a7850` |  3.893 | 0.305 |   3.454 |  0.134 |           4 |  1 file, 1 dir |
| generated_tree_reuse       | `3f5910cbd10a` |  4.308 | 0.303 |   3.867 |  0.138 |           4 |  1 file, 1 dir |
| generated_tree_reuse       | `958cf2efa665` | 18.433 | 0.366 |  15.942 |  2.125 |           4 |  1 file, 1 dir |
| generated_tree_reuse       | `b57daa400252` | 23.601 | 0.311 |  23.120 |  0.169 |           4 |  1 file, 1 dir |
| generated_tree_reuse       | `f1aa103ccd7c` |  7.096 | 0.358 |   6.325 |  0.413 |           4 |  1 file, 1 dir |
| mixed_all                  | `400c2bebfdf7` | 21.317 | 0.309 |  18.169 |  2.839 |           4 |  1 file, 1 dir |
| nested_individual_files    | `00a5c8fd5eca` | 24.818 | 0.621 |  18.774 |  5.422 |           4 |  1 file, 1 dir |
| nested_individual_files    | `06648fa82c90` | 11.444 | 0.308 |  10.241 |  0.895 |           4 |  1 file, 1 dir |
| nested_individual_files    | `0e936d2585e1` | 21.472 | 0.301 |  20.683 |  0.487 |           4 |  1 file, 1 dir |
| nested_individual_files    | `38e0080a81a7` | 18.718 | 0.305 |  17.978 |  0.435 |           4 |  1 file, 1 dir |
| nested_individual_files    | `6e61d7c5c043` |  5.278 | 0.308 |   3.945 |  1.024 |           4 |  1 file, 1 dir |
| nested_individual_files    | `7bb6083de2c1` |  7.843 | 0.321 |   7.106 |  0.416 |           4 |  1 file, 1 dir |
| nested_individual_files    | `7ebc5b535734` | 18.108 | 0.378 |  16.809 |  0.921 |           4 |  1 file, 1 dir |
| nested_individual_files    | `a455f1d89ad8` |  5.058 | 0.367 |   4.213 |  0.478 |           4 |  1 file, 1 dir |
| pids_one_regression        | `bbe16c49ab86` |  8.981 | 0.328 |   8.493 |  0.160 |           4 |  1 file, 1 dir |
| source_dir_tree            | `35ad590c3e20` | 11.335 | 0.359 |  10.503 |  0.472 |           4 |  1 file, 1 dir |
| source_dir_tree            | `94ef482d0fd5` | 17.458 | 0.291 |  17.037 |  0.129 |           4 |  1 file, 1 dir |
| source_dir_tree            | `98458d72ec38` | 16.579 | 0.287 |  16.085 |  0.207 |           4 |  1 file, 1 dir |
| source_dir_tree            | `f176f6534568` | 25.419 | 0.715 |  23.182 |  1.522 |           4 |  1 file, 1 dir |
| symlink_input_consumer     | `e7ebd25b87b9` |  2.800 | 0.287 |   2.239 |  0.274 |           4 |  1 file, 1 dir |
| timeout_recovery           | `ed01de57e2a7` | 22.876 | 0.683 |  21.918 |  0.275 |           4 |  1 file, 1 dir |

## Notes

- Every action uses actiondfs, so input trees are represented by mounted REAPI root digests rather than flattened input counters.
- Some CAS metadata and file read cost appears in the action `process/io` bucket because actiondfs loads inputs lazily.
