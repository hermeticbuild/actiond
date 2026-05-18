# Stress Timing Summary

- Generated: `2026-05-17 22:44:41 EDT`
- Mode: `vm`
- Execute records parsed: `31`
- Unique action digests: `31`
- Source log: `/var/folders/p4/xn8y5q_j24l5xwgwd_jx5c340000gn/T/actiond-vm-e2e.YanhL7/darwin-actiond-vm.log`
- Command: `ACTIOND_E2E_KEEP_TMP=1 tools/e2e.sh vm`

## Stage Timing

All timing values are milliseconds unless noted.

| Stage                   |    Min |     p25 |     p50 |     p75 |     p95 |    Mean |     Max | Share of summed total |
| ----------------------- | -----: | ------: | ------: | ------: | ------: | ------: | ------: | --------------------: |
| total                   | 59.333 | 176.505 | 224.708 | 314.374 | 393.940 | 246.248 | 536.611 |                100.0% |
| input fetch/materialize |  2.244 |   3.993 |   4.501 |  25.042 |  26.008 |  11.435 |  26.240 |                  4.6% |
| execute                 | 51.819 | 146.590 | 202.742 | 262.597 | 342.499 | 207.599 | 517.962 |                 84.3% |
| output upload/collect   |  3.388 |   7.724 |  16.470 |  38.081 |  72.175 |  27.214 | 158.662 |                 11.1% |

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
| bare_individual_files      |       4 |   280.708 |   281.711 |   284.171 |   288.098 |    13.878 |     250.579 |     18.065 |          2 |
| generated_file_producer    |       1 |   360.662 |   360.662 |   360.662 |   360.662 |    25.744 |     242.004 |     92.914 |          2 |
| generated_individual_files |       4 |    62.279 |    63.333 |    63.455 |    63.571 |     2.672 |      54.249 |      5.956 |          2 |
| generated_tree_producer    |       1 |   427.218 |   427.218 |   427.218 |   427.218 |     4.118 |     264.439 |    158.662 |          2 |
| generated_tree_reuse       |       8 |   166.801 |   231.193 |   288.189 |   315.830 |     4.246 |     218.813 |      8.144 |          2 |
| mixed_all                  |       1 |   536.611 |   536.611 |   536.611 |   536.611 |     3.693 |     517.962 |     14.957 |          2 |
| nested_individual_files    |       8 |   194.241 |   213.342 |   223.219 |   224.395 |    24.985 |     147.543 |     41.724 |          2 |
| source_dir_tree            |       4 |   356.516 |   358.056 |   359.315 |   359.591 |    14.735 |     331.580 |     12.441 |          2 |

## Visible Overhead Estimate

`process/io` is excluded here because it is mostly the action process runtime plus stdout/stderr drain.

| Metric                    |    Min |    p25 |    p50 |     p75 |     p95 |   Mean |     Max | Share of summed total |
| ------------------------- | -----: | -----: | -----: | ------: | ------: | -----: | ------: | --------------------: |
| fixed overhead, no wait   |  8.053 | 13.284 | 40.185 |  50.857 |  98.567 | 43.986 | 183.295 |                 17.9% |
| fixed overhead, with wait | 12.926 | 44.677 | 75.617 | 114.755 | 176.007 | 82.320 | 257.609 |                 33.4% |

## Runner Timing

These values split the `execute` bucket. `process/io` starts after child setup signals right before `execve`; it includes the action process runtime and stdout/stderr drain.

| Runner Stage   |    Min |     p25 |     p50 |     p75 |     p95 |    Mean |     Max | Share of execute |
| -------------- | -----: | ------: | ------: | ------: | ------: | ------: | ------: | ---------------: |
| parent prepare |  0.050 |   0.060 |   0.068 |   0.657 |  19.923 |   4.482 |  20.155 |             2.2% |
| fork           |  0.079 |   0.225 |   0.518 |   0.766 |   1.044 |   0.525 |   1.135 |             0.3% |
| child setup    |  0.003 |   0.121 |   0.200 |   0.500 |   1.005 |   0.328 |   1.332 |             0.2% |
| process/io     | 46.362 | 131.124 | 137.026 | 166.758 | 304.113 | 163.892 | 491.166 |            78.9% |
| wait           |  4.873 |  14.076 |  17.715 |  74.006 |  95.954 |  38.334 | 110.595 |            18.5% |
| stdio digest   |  0.001 |   0.002 |   0.003 |   0.004 |   0.006 |   0.003 |   0.010 |             0.0% |

| Stress Case                | Digest         | Parent Prep |  Fork | Child Setup | Process/IO |    Wait | Stdio Digest | Setup Signaled |
| -------------------------- | -------------- | ----------: | ----: | ----------: | ---------: | ------: | -----------: | -------------- |
| bare_individual_files      | `249502cd8713` |       0.057 | 0.600 |       0.564 |    163.219 |  75.622 |        0.002 | True           |
| bare_individual_files      | `ad55f25cb61f` |      18.380 | 0.412 |       1.074 |    167.081 |  74.136 |        0.002 | True           |
| bare_individual_files      | `c5541e308a49` |       0.071 | 0.758 |       0.432 |    163.203 |  73.247 |        0.005 | True           |
| bare_individual_files      | `d56cf6590fef` |      20.076 | 0.212 |       0.489 |    166.435 |  73.877 |        0.002 | True           |
| generated_file_producer    | `bc2e603f3e0b` |       0.096 | 0.103 |       0.180 |    167.252 |  74.354 |        0.002 | True           |
| generated_individual_files | `0e2aba08daac` |       0.064 | 0.291 |       0.177 |     46.362 |   4.873 |        0.006 | True           |
| generated_individual_files | `93f6d1fb4bbc` |       0.062 | 0.135 |       0.204 |     47.443 |   6.901 |        0.003 | True           |
| generated_individual_files | `b2f28122427f` |       0.060 | 0.079 |       0.125 |     47.179 |   6.986 |        0.003 | True           |
| generated_individual_files | `ef2aa47738bc` |       0.057 | 0.237 |       0.261 |     46.707 |   6.765 |        0.003 | True           |
| generated_tree_producer    | `2dd6c1952601` |      18.856 | 0.326 |       1.332 |    169.599 |  74.314 |        0.001 | True           |
| generated_tree_reuse       | `04ba19135981` |       0.060 | 1.135 |       0.010 |    118.445 |  18.157 |        0.002 | True           |
| generated_tree_reuse       | `127fae4ead86` |       0.061 | 0.822 |       0.705 |    158.580 |  89.371 |        0.003 | True           |
| generated_tree_reuse       | `762b1b9f7d16` |       0.055 | 0.256 |       0.003 |    150.166 |  84.383 |        0.010 | True           |
| generated_tree_reuse       | `7b6fae59491f` |       0.194 | 0.518 |       0.134 |    131.092 |  21.106 |        0.004 | True           |
| generated_tree_reuse       | `7cf4273ba27b` |       0.060 | 1.019 |       0.003 |    160.077 | 102.537 |        0.005 | True           |
| generated_tree_reuse       | `8c4f3e7cd4e7` |       0.066 | 0.597 |       0.003 |    131.559 |  23.157 |        0.004 | True           |
| generated_tree_reuse       | `cef27a1e7fc8` |       0.059 | 0.132 |       0.285 |    160.595 | 110.595 |        0.004 | True           |
| generated_tree_reuse       | `e21d712e10ce` |       0.072 | 1.070 |       0.182 |    137.026 |  64.088 |        0.005 | True           |
| mixed_all                  | `8bf959095e33` |       0.050 | 0.507 |       0.118 |    491.166 |  26.104 |        0.005 | True           |
| nested_individual_files    | `463d1d3b7519` |       1.120 | 0.169 |       0.529 |    131.972 |  12.362 |        0.002 | True           |
| nested_individual_files    | `750c16854c4f` |       0.069 | 0.720 |       0.511 |    131.157 |  14.554 |        0.001 | True           |
| nested_individual_files    | `921deac3abf2` |       0.062 | 0.921 |       0.294 |    132.738 |  14.762 |        0.003 | True           |
| nested_individual_files    | `c0c6c0286d7a` |       0.068 | 0.128 |       0.656 |    133.085 |  14.029 |        0.001 | True           |
| nested_individual_files    | `c3eeebf452a8` |       0.112 | 0.824 |       0.018 |    131.930 |  11.268 |        0.003 | True           |
| nested_individual_files    | `c46382f1c163` |       0.073 | 0.709 |       0.004 |    119.646 |  14.124 |        0.002 | True           |
| nested_individual_files    | `c82d276ce20b` |      19.771 | 0.775 |       0.936 |    130.491 |  15.080 |        0.003 | True           |
| nested_individual_files    | `cbd9737de7fa` |      19.178 | 0.662 |       0.197 |    135.717 |  13.883 |        0.001 | True           |
| source_dir_tree            | `13ad68143150` |      20.155 | 0.710 |       0.270 |    303.836 |  17.303 |        0.002 | True           |
| source_dir_tree            | `7457f233803f` |      19.752 | 0.891 |       0.200 |    304.391 |  17.468 |        0.002 | True           |
| source_dir_tree            | `835056696b6a` |       0.058 | 0.457 |       0.114 |    302.526 |  17.715 |        0.001 | True           |
| source_dir_tree            | `ba00a2e83069` |       0.060 | 0.092 |       0.153 |    299.967 |  15.224 |        0.003 | True           |

## Per Action

| Stress Case                | Digest         |   Total |  Input | Execute |  Output | File Inputs | Dir Inputs | Bind Mounts | Outputs        |
| -------------------------- | -------------- | ------: | -----: | ------: | ------: | ----------: | ---------: | ----------: | -------------- |
| bare_individual_files      | `249502cd8713` | 289.079 | 26.129 | 240.069 |  22.882 |           0 |          0 |           2 | 1 file, 1 dir  |
| bare_individual_files      | `ad55f25cb61f` | 282.535 |  2.627 | 261.090 |  18.817 |           0 |          0 |           2 | 1 file, 1 dir  |
| bare_individual_files      | `c5541e308a49` | 280.170 | 25.129 | 237.728 |  17.313 |           0 |          0 |           2 | 1 file, 1 dir  |
| bare_individual_files      | `d56cf6590fef` | 280.887 |  2.244 | 261.482 |  17.161 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_file_producer    | `bc2e603f3e0b` | 360.662 | 25.744 | 242.004 |  92.914 |           0 |          0 |           2 | 97 file, 0 dir |
| generated_individual_files | `0e2aba08daac` |  59.333 |  2.338 |  51.819 |   5.176 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_individual_files | `93f6d1fb4bbc` |  63.600 |  2.650 |  54.763 |   6.187 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_individual_files | `b2f28122427f` |  63.261 |  3.086 |  54.449 |   5.726 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_individual_files | `ef2aa47738bc` |  63.406 |  2.694 |  54.049 |   6.663 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_tree_producer    | `2dd6c1952601` | 427.218 |  4.118 | 264.439 | 158.662 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_tree_reuse       | `04ba19135981` | 146.269 |  4.001 | 137.826 |   4.442 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_tree_reuse       | `127fae4ead86` | 281.077 |  4.032 | 249.551 |  27.495 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_tree_reuse       | `762b1b9f7d16` | 247.659 |  5.198 | 234.884 |   7.576 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_tree_reuse       | `7b6fae59491f` | 165.463 |  3.985 | 153.061 |   8.416 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_tree_reuse       | `7cf4273ba27b` | 309.523 |  4.377 | 263.713 |  41.432 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_tree_reuse       | `8c4f3e7cd4e7` | 167.248 |  4.522 | 155.396 |   7.329 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_tree_reuse       | `cef27a1e7fc8` | 319.226 |  4.501 | 271.680 |  43.045 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_tree_reuse       | `e21d712e10ce` | 214.728 |  4.115 | 202.742 |   7.872 |           0 |          0 |           2 | 1 file, 1 dir  |
| mixed_all                  | `8bf959095e33` | 536.611 |  3.693 | 517.962 |  14.957 |           0 |          0 |           2 | 1 file, 1 dir  |
| nested_individual_files    | `463d1d3b7519` | 218.323 | 23.444 | 146.162 |  48.717 |           0 |          0 |           2 | 1 file, 1 dir  |
| nested_individual_files    | `750c16854c4f` | 223.813 | 25.887 | 147.018 |  50.908 |           0 |          0 |           2 | 1 file, 1 dir  |
| nested_individual_files    | `921deac3abf2` | 208.361 | 24.844 | 148.786 |  34.731 |           0 |          0 |           2 | 1 file, 1 dir  |
| nested_individual_files    | `c0c6c0286d7a` | 224.708 | 25.204 | 148.068 |  51.437 |           0 |          0 |           2 | 1 file, 1 dir  |
| nested_individual_files    | `c3eeebf452a8` | 185.762 | 25.127 | 144.165 |  16.470 |           0 |          0 |           2 | 1 file, 1 dir  |
| nested_individual_files    | `c46382f1c163` | 163.588 | 25.621 | 134.579 |   3.388 |           0 |          0 |           2 | 1 file, 1 dir  |
| nested_individual_files    | `c82d276ce20b` | 197.068 |  4.448 | 167.070 |  25.549 |           0 |          0 |           2 | 1 file, 1 dir  |
| nested_individual_files    | `cbd9737de7fa` | 223.021 |  4.543 | 169.647 |  48.831 |           0 |          0 |           2 | 1 file, 1 dir  |
| source_dir_tree            | `13ad68143150` | 359.660 |  4.468 | 342.283 |  12.909 |           0 |          0 |           2 | 1 file, 1 dir  |
| source_dir_tree            | `7457f233803f` | 359.200 |  4.513 | 342.715 |  11.972 |           0 |          0 |           2 | 1 file, 1 dir  |
| source_dir_tree            | `835056696b6a` | 355.327 | 24.957 | 320.877 |   9.493 |           0 |          0 |           2 | 1 file, 1 dir  |
| source_dir_tree            | `ba00a2e83069` | 356.912 | 26.240 | 315.507 |  15.165 |           0 |          0 |           2 | 1 file, 1 dir  |

## Notes

- This run observed `directory_inputs=0` for every action. Actions with `actiondfs_mounts>0` are using the lazy actiondfs input-root path, so their input tree is represented by the mounted REAPI root digest rather than by flattened file or directory counters.
- For actiondfs actions, some CAS directory/file read cost moves from input fetch/materialization into the action `process/io` bucket because metadata and pages are loaded lazily.
