# Executor Timing Summary

- Generated: `2026-08-01 18:19:48 EDT`
- Mode: `vm`
- Execute records parsed: `37`
- Unique action digests: `37`
- Source log: `/var/folders/p4/xn8y5q_j24l5xwgwd_jx5c340000gn/T/actiond-vm-e2e.z0b6EM/darwin-actiond-vm.log`
- Command: `ACTIOND_E2E_KEEP_TMP=1 ACTIOND_E2E_ACTIONDFS_STATS_PATH=/private/tmp/actiondfs-round-seven-final.stats ACTIOND_REPO_BAZEL_FLAGS="--config=remote --config=executor_timing_logs --jobs=32 --distdir=/private/tmp/actiond-audit-distdir --override_repository=llvm++osx+macos_sdk=/private/tmp/actiond-audit-macos-sdk" tools/e2e.sh vm`

## Stage Timing

All timing values are milliseconds unless noted.

| Stage                 |   Min |    p25 |    p50 |     p75 |     p95 |   Mean |     Max | Share of summed total |
| --------------------- | ----: | -----: | -----: | ------: | ------: | -----: | ------: | --------------------: |
| total                 | 1.448 | 19.294 | 46.697 | 110.509 | 179.615 | 66.307 | 211.392 |                100.0% |
| input fetch/setup     | 0.237 |  0.302 |  0.321 |   0.535 |   2.819 |  0.753 |   7.749 |                  1.1% |
| execute               | 1.106 | 18.792 | 45.921 | 109.871 | 157.196 | 62.818 | 210.164 |                 94.7% |
| output upload/collect | 0.069 |  0.166 |  0.341 |   0.609 |   6.771 |  2.735 |  62.242 |                  4.1% |

## Mount And Output Counts

| Metric             | Min | p25 | p50 | p75 | p95 | Mean | Max |
| ------------------ | --: | --: | --: | --: | --: | ---: | --: |
| bind mounts        |   2 |   4 |   4 |   4 |   4 |  3.9 |   4 |
| output files       |   1 |   1 |   1 |   1 |   1 |  3.6 |  97 |
| output directories |   0 |   1 |   1 |   1 |   1 |  0.9 |   1 |

## Stage Timing By Stress Case

| Stress Case                | Actions | Total p25 | Total p50 | Total p75 | Total p95 | Input p50 | Execute p50 | Output p50 | Mounts p50 |
| -------------------------- | ------: | --------: | --------: | --------: | --------: | --------: | ----------: | ---------: | ---------: |
| aggregate                  |       1 |    20.198 |    20.198 |    20.198 |    20.198 |     0.297 |      19.833 |      0.069 |          4 |
| bare_individual_files      |       4 |    33.319 |    54.248 |    86.023 |   122.113 |     0.311 |      41.220 |      0.627 |          4 |
| filesystem_regression      |       1 |   186.060 |   186.060 |   186.060 |   186.060 |     2.613 |     182.837 |      0.609 |          4 |
| generated_file_producer    |       1 |    72.237 |    72.237 |    72.237 |    72.237 |     1.088 |      66.935 |      4.214 |          4 |
| generated_individual_files |       4 |    15.871 |    17.821 |    34.459 |    69.757 |     0.310 |      17.252 |      0.324 |          4 |
| generated_tree_producer    |       1 |   178.003 |   178.003 |   178.003 |   178.003 |     0.302 |     115.459 |     62.242 |          4 |
| generated_tree_reuse       |       8 |    36.673 |    62.610 |   110.657 |   113.499 |     0.495 |      62.052 |      0.177 |          4 |
| mixed_all                  |       1 |   114.812 |   114.812 |   114.812 |   114.812 |     0.353 |     111.190 |      3.268 |          4 |
| nested_individual_files    |       8 |    46.193 |    69.945 |    91.947 |   185.322 |     0.319 |      67.985 |      0.491 |          4 |
| pids_one_regression        |       1 |    18.152 |    18.152 |    18.152 |    18.152 |     0.312 |      17.704 |      0.135 |          4 |
| source_dir_tree            |       4 |    14.190 |    17.024 |    52.322 |   131.588 |     0.286 |      16.558 |      0.253 |          4 |
| symlink_input_consumer     |       1 |     7.427 |     7.427 |     7.427 |     7.427 |     0.308 |       6.867 |      0.251 |          4 |
| timeout_recovery           |       1 |    14.744 |    14.744 |    14.744 |    14.744 |     0.569 |      14.049 |      0.126 |          4 |
| unknown                    |       1 |     1.448 |     1.448 |     1.448 |     1.448 |     0.237 |       1.106 |      0.105 |          2 |

## Visible Overhead Estimate

`process/io` is excluded here because it is mostly the action process runtime plus stdout/stderr drain.

| Metric                    |   Min |    p25 |    p50 |    p75 |    p95 |   Mean |     Max | Share of summed total |
| ------------------------- | ----: | -----: | -----: | -----: | -----: | -----: | ------: | --------------------: |
| fixed overhead, no wait   | 1.122 | 13.555 | 31.299 | 38.040 | 84.384 | 35.131 | 186.093 |                 53.0% |
| fixed overhead, with wait | 1.122 | 13.555 | 31.815 | 38.040 | 96.734 | 35.901 | 186.093 |                 54.1% |

## Runner Timing

These values split the `execute` bucket. `child setup` includes successful `execve`; `process/io` starts after close-on-exec confirmation and includes action runtime and stdout/stderr drain.

| Runner Stage   |   Min |   p25 |    p50 |    p75 |     p95 |   Mean |     Max | Share of execute |
| -------------- | ----: | ----: | -----: | -----: | ------: | -----: | ------: | ---------------: |
| parent prepare | 0.030 | 0.113 |  3.474 | 15.014 |  23.418 |  7.602 |  33.307 |            12.1% |
| fork           | 0.121 | 0.303 |  0.653 |  2.076 |  10.871 |  2.123 |  12.015 |             3.4% |
| child setup    | 0.197 | 5.594 | 12.433 | 28.355 |  57.755 | 21.917 | 184.087 |            34.9% |
| process/io     | 0.318 | 2.938 |  6.884 | 45.981 | 124.798 | 30.363 | 154.147 |            48.3% |
| wait           | 0.000 | 0.000 |  0.000 |  0.000 |   2.697 |  0.770 |  15.438 |             1.2% |
| stdio digest   | 0.000 | 0.000 |  0.000 |  0.001 |   0.002 |  0.001 |   0.009 |             0.0% |

| Stress Case                | Digest         | Parent Prep |   Fork | Child Setup | Process/IO |   Wait | Stdio Digest | Setup Signaled |
| -------------------------- | -------------- | ----------: | -----: | ----------: | ---------: | -----: | -----------: | -------------- |
| aggregate                  | `097d7589806b` |       0.109 |  0.303 |      16.791 |      2.607 |  0.000 |        0.001 | True           |
| bare_individual_files      | `90cce354641e` |      16.998 |  2.076 |      52.792 |     58.782 |  0.000 |        0.002 | True           |
| bare_individual_files      | `cfea754f9880` |      11.678 |  8.589 |       7.016 |     34.918 |  0.000 |        0.000 | True           |
| bare_individual_files      | `d227993ae34f` |       0.125 |  0.460 |      12.805 |      4.277 |  2.439 |        0.000 | True           |
| bare_individual_files      | `faa36aaa12ef` |       7.630 |  0.300 |       6.573 |      5.617 |  0.000 |        0.009 | True           |
| filesystem_regression      | `d6e431f72b37` |      15.310 | 12.015 |       0.197 |    154.147 |  1.115 |        0.000 | True           |
| generated_file_producer    | `0ab29dfeee67` |       0.105 |  2.194 |      24.369 |     40.254 |  0.000 |        0.000 | True           |
| generated_individual_files | `8949618893dd` |      13.240 |  2.434 |       5.594 |     54.267 |  2.233 |        0.001 | True           |
| generated_individual_files | `8e7053a36faf` |       8.184 |  0.449 |       3.598 |      6.884 |  0.000 |        0.001 | True           |
| generated_individual_files | `ac62596d2eae` |       0.091 |  0.219 |      11.867 |      2.938 |  0.000 |        0.000 | True           |
| generated_individual_files | `d7beec3fc619` |       0.104 |  0.332 |      11.629 |      3.266 |  0.000 |        0.000 | True           |
| generated_tree_producer    | `f8cb8cf8722c` |       7.494 |  0.445 |       7.026 |     84.991 | 15.438 |        0.001 | True           |
| generated_tree_reuse       | `4f9d33590a97` |       0.123 |  0.323 |      17.583 |     45.981 |  0.000 |        0.000 | True           |
| generated_tree_reuse       | `ad080d1d4b46` |      16.020 |  0.850 |      17.171 |      0.677 |  0.000 |        0.000 | True           |
| generated_tree_reuse       | `b82ea83117e0` |      24.852 |  2.076 |       7.014 |     73.544 |  2.800 |        0.000 | True           |
| generated_tree_reuse       | `bdbccf204e0e` |       0.228 |  0.602 |      15.987 |      1.602 |  0.000 |        0.000 | True           |
| generated_tree_reuse       | `c222b682e1e5` |      15.568 | 11.700 |      28.903 |     51.000 |  2.671 |        0.000 | True           |
| generated_tree_reuse       | `cc2d17d56174` |      15.014 | 10.664 |       6.815 |     27.547 |  0.000 |        0.001 | True           |
| generated_tree_reuse       | `ec3c5569c6cf` |      33.307 |  0.409 |      77.610 |      2.884 |  0.000 |        0.000 | True           |
| generated_tree_reuse       | `f58a3550a687` |       0.093 |  0.665 |      33.534 |      0.873 |  0.000 |        0.002 | True           |
| mixed_all                  | `ff909e41f5d7` |      22.656 |  0.242 |       8.827 |     77.636 |  1.788 |        0.000 | True           |
| nested_individual_files    | `515cc9e83e3d` |       1.190 |  1.479 |      32.946 |     33.272 |  0.000 |        0.000 | True           |
| nested_individual_files    | `6b51fb6999bc` |      23.059 |  7.960 |      37.940 |      6.362 |  0.000 |        0.000 | True           |
| nested_individual_files    | `816552fd7392` |       0.124 |  0.653 |     184.087 |     25.280 |  0.000 |        0.001 | True           |
| nested_individual_files    | `97febd68ffa3` |      12.919 |  0.294 |      28.355 |      4.331 |  0.000 |        0.001 | True           |
| nested_individual_files    | `a85c70689335` |       0.075 |  0.291 |      36.883 |     29.797 |  0.000 |        0.000 | True           |
| nested_individual_files    | `c595420ad290` |       0.105 |  3.134 |      39.664 |      0.859 |  0.000 |        0.000 | True           |
| nested_individual_files    | `f697e529f79f` |       0.137 |  0.941 |       4.858 |    130.155 |  0.000 |        0.001 | True           |
| nested_individual_files    | `f96dbd47704b` |      20.254 |  2.316 |       4.668 |     10.081 |  0.000 |        0.001 | True           |
| pids_one_regression        | `9270a8412a96` |       0.127 |  0.281 |      16.083 |      1.188 |  0.000 |        0.000 | True           |
| source_dir_tree            | `64c12911a3b8` |       3.576 |  0.916 |       2.688 |      4.486 |  0.000 |        0.000 | True           |
| source_dir_tree            | `67e7d6014831` |       3.474 |  0.509 |       4.735 |      5.519 |  0.000 |        0.001 | True           |
| source_dir_tree            | `eaf41c0a7f6e` |       6.942 |  0.903 |       3.083 |      7.851 |  0.000 |        0.000 | True           |
| source_dir_tree            | `fc7ef573df10` |       0.113 |  0.296 |      26.877 |    123.459 |  0.000 |        0.001 | True           |
| symlink_input_consumer     | `f22dfeb3cc2a` |       0.108 |  0.811 |       1.295 |      4.627 |  0.000 |        0.001 | True           |
| timeout_recovery           | `bc69c98c3696` |       0.129 |  0.298 |      12.433 |      1.158 |  0.000 |        0.000 | True           |
| unknown                    | `e6380fd0c4ff` |       0.030 |  0.121 |       0.628 |      0.318 |  0.000 |        0.000 | True           |

## VM Bridge Timing

These are raw TCP-to-vsock pump connection measurements logged by `darwin-actiond serve-vm`.

- Bridge connections logged: `10`
- Total client to guest bytes: `1.47 MiB`
- Total guest to client bytes: `0.30 MiB`
- Pump errors: read=`0`, write=`0`

| Bridge Metric          |     Min |      p25 |      p50 |      p75 |      p95 |     Mean |      Max |
| ---------------------- | ------: | -------: | -------: | -------: | -------: | -------: | -------: |
| connection elapsed     | 186.088 | 1190.171 | 1324.212 | 2915.719 | 5545.221 | 2203.577 | 5575.022 |
| client to guest KiB    |     0.0 |     19.6 |    141.4 |    184.7 |    431.1 |    150.8 |    581.9 |
| guest to client KiB    |     0.0 |      1.3 |     21.6 |     46.7 |     86.5 |     31.0 |    103.5 |
| client to guest reads  |       1 |       12 |       92 |      260 |      314 |    132.1 |      339 |
| client to guest writes |       1 |       12 |       92 |      260 |      314 |    132.1 |      339 |
| guest to client reads  |       0 |       10 |       91 |      198 |      246 |    108.7 |      270 |
| guest to client writes |       0 |       10 |       91 |      198 |      246 |    108.7 |      270 |

## Per Action

| Stress Case                | Digest         |   Total | Input | Execute | Output | Bind Mounts |        Outputs |
| -------------------------- | -------------- | ------: | ----: | ------: | -----: | ----------: | -------------: |
| aggregate                  | `097d7589806b` |  20.198 | 0.297 |  19.833 |  0.069 |           4 |  1 file, 0 dir |
| bare_individual_files      | `90cce354641e` | 131.135 | 0.288 | 130.680 |  0.166 |           4 |  1 file, 1 dir |
| bare_individual_files      | `cfea754f9880` |  70.986 | 7.749 |  62.231 |  1.005 |           4 |  1 file, 1 dir |
| bare_individual_files      | `d227993ae34f` |  20.741 | 0.319 |  20.171 |  0.250 |           4 |  1 file, 1 dir |
| bare_individual_files      | `faa36aaa12ef` |  37.511 | 0.303 |  20.208 | 17.000 |           4 |  1 file, 1 dir |
| filesystem_regression      | `d6e431f72b37` | 186.060 | 2.613 | 182.837 |  0.609 |           4 |  1 file, 1 dir |
| generated_file_producer    | `0ab29dfeee67` |  72.237 | 1.088 |  66.935 |  4.214 |           4 | 97 file, 0 dir |
| generated_individual_files | `8949618893dd` |  78.581 | 0.375 |  77.865 |  0.341 |           4 |  1 file, 1 dir |
| generated_individual_files | `8e7053a36faf` |  19.752 | 0.300 |  19.146 |  0.306 |           4 |  1 file, 1 dir |
| generated_individual_files | `ac62596d2eae` |  15.891 | 0.291 |  15.140 |  0.460 |           4 |  1 file, 1 dir |
| generated_individual_files | `d7beec3fc619` |  15.812 | 0.321 |  15.358 |  0.133 |           4 |  1 file, 1 dir |
| generated_tree_producer    | `f8cb8cf8722c` | 178.003 | 0.302 | 115.459 | 62.242 |           4 |  1 file, 1 dir |
| generated_tree_reuse       | `4f9d33590a97` |  64.459 | 0.303 |  64.028 |  0.128 |           4 |  1 file, 1 dir |
| generated_tree_reuse       | `ad080d1d4b46` |  36.264 | 0.651 |  34.749 |  0.864 |           4 |  1 file, 1 dir |
| generated_tree_reuse       | `b82ea83117e0` | 111.101 | 0.637 | 110.325 |  0.139 |           4 |  1 file, 1 dir |
| generated_tree_reuse       | `bdbccf204e0e` |  19.132 | 0.455 |  18.506 |  0.171 |           4 |  1 file, 1 dir |
| generated_tree_reuse       | `c222b682e1e5` | 110.509 | 0.535 | 109.871 |  0.103 |           4 |  1 file, 1 dir |
| generated_tree_reuse       | `cc2d17d56174` |  60.761 | 0.387 |  60.077 |  0.297 |           4 |  1 file, 1 dir |
| generated_tree_reuse       | `ec3c5569c6cf` | 114.790 | 0.375 | 114.232 |  0.183 |           4 |  1 file, 1 dir |
| generated_tree_reuse       | `f58a3550a687` |  36.810 | 0.723 |  35.231 |  0.856 |           4 |  1 file, 1 dir |
| mixed_all                  | `ff909e41f5d7` | 114.812 | 0.353 | 111.190 |  3.268 |           4 |  1 file, 1 dir |
| nested_individual_files    | `515cc9e83e3d` |  72.038 | 0.302 |  68.909 |  2.826 |           4 |  1 file, 1 dir |
| nested_individual_files    | `6b51fb6999bc` |  76.960 | 1.043 |  75.415 |  0.502 |           4 |  1 file, 1 dir |
| nested_individual_files    | `816552fd7392` | 211.392 | 0.308 | 210.164 |  0.919 |           4 |  1 file, 1 dir |
| nested_individual_files    | `97febd68ffa3` |  46.697 | 0.297 |  45.921 |  0.479 |           4 |  1 file, 1 dir |
| nested_individual_files    | `a85c70689335` |  67.853 | 0.330 |  67.062 |  0.460 |           4 |  1 file, 1 dir |
| nested_individual_files    | `c595420ad290` |  44.681 | 0.355 |  43.797 |  0.528 |           4 |  1 file, 1 dir |
| nested_individual_files    | `f697e529f79f` | 136.907 | 0.308 | 136.126 |  0.472 |           4 |  1 file, 1 dir |
| nested_individual_files    | `f96dbd47704b` |  41.547 | 3.642 |  37.486 |  0.419 |           4 |  1 file, 1 dir |
| pids_one_regression        | `9270a8412a96` |  18.152 | 0.312 |  17.704 |  0.135 |           4 |  1 file, 1 dir |
| source_dir_tree            | `64c12911a3b8` |  12.502 | 0.288 |  11.698 |  0.516 |           4 |  1 file, 1 dir |
| source_dir_tree            | `67e7d6014831` |  14.753 | 0.283 |  14.325 |  0.145 |           4 |  1 file, 1 dir |
| source_dir_tree            | `eaf41c0a7f6e` |  19.294 | 0.330 |  18.792 |  0.172 |           4 |  1 file, 1 dir |
| source_dir_tree            | `fc7ef573df10` | 151.404 | 0.284 | 150.786 |  0.334 |           4 |  1 file, 1 dir |
| symlink_input_consumer     | `f22dfeb3cc2a` |   7.427 | 0.308 |   6.867 |  0.251 |           4 |  1 file, 1 dir |
| timeout_recovery           | `bc69c98c3696` |  14.744 | 0.569 |  14.049 |  0.126 |           4 |  1 file, 1 dir |
| unknown                    | `e6380fd0c4ff` |   1.448 | 0.237 |   1.106 |  0.105 |           2 |  1 file, 0 dir |

## Notes

- Every action uses actiondfs, so input trees are represented by mounted REAPI root digests rather than flattened input counters.
- Some CAS metadata and file read cost appears in the action `process/io` bucket because actiondfs loads inputs lazily.
