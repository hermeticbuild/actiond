# Stress Timing Summary

- Generated: `2026-05-17 20:02:06 EDT`
- Mode: `vm-actiondfs`
- Execute records parsed: `31`
- Unique action digests: `31`
- Source log: `/var/folders/p4/xn8y5q_j24l5xwgwd_jx5c340000gn/T/actiond-vm-e2e.UunfoE/darwin-actiond-vm.log`
- Command: `ACTIOND_E2E_KEEP_TMP=1 tools/e2e.sh vm`

## Stage Timing

All timing values are milliseconds unless noted.

| Stage                   |    Min |     p25 |     p50 |     p75 |     p95 |    Mean |     Max | Share of summed total |
| ----------------------- | -----: | ------: | ------: | ------: | ------: | ------: | ------: | --------------------: |
| total                   | 56.521 | 160.536 | 216.540 | 386.531 | 514.358 | 273.055 | 558.720 |                100.0% |
| input fetch/materialize |  1.369 |   4.857 |   6.574 |  10.684 |  18.387 |   8.161 |  18.958 |                  3.0% |
| execute                 | 49.202 | 140.193 | 178.418 | 353.575 | 443.928 | 228.060 | 539.744 |                 83.5% |
| output upload/collect   |  4.998 |   6.683 |  12.776 |  20.956 | 136.295 |  36.834 | 188.768 |                 13.5% |

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
| bare_individual_files      |       4 |   378.049 |   384.578 |   386.188 |   387.010 |     5.425 |     353.575 |     20.956 |          2 |
| generated_file_producer    |       1 |   473.414 |   473.414 |   473.414 |   473.414 |    18.390 |     318.829 |    136.196 |          2 |
| generated_individual_files |       4 |    57.638 |    59.118 |    60.602 |    61.508 |     1.752 |      51.696 |      5.660 |          2 |
| generated_tree_producer    |       1 |   555.302 |   555.302 |   555.302 |   555.302 |     6.674 |     359.859 |    188.768 |          2 |
| generated_tree_reuse       |       8 |   166.602 |   189.440 |   204.028 |   216.125 |     6.963 |     167.498 |      8.677 |          2 |
| mixed_all                  |       1 |   558.720 |   558.720 |   558.720 |   558.720 |     2.499 |     539.744 |     16.476 |          2 |
| nested_individual_files    |       8 |   138.617 |   223.500 |   296.596 |   302.874 |     5.450 |     140.193 |     56.423 |          2 |
| source_dir_tree            |       4 |   463.410 |   467.216 |   469.377 |   471.205 |    14.079 |     440.073 |     12.493 |          2 |

## Visible Overhead Estimate

`process/io` is excluded here because it is mostly the action process runtime plus stdout/stderr drain.

| Metric                    |    Min |    p25 |    p50 |     p75 |     p95 |   Mean |     Max | Share of summed total |
| ------------------------- | -----: | -----: | -----: | ------: | ------: | -----: | ------: | --------------------: |
| fixed overhead, no wait   |  7.570 | 14.394 | 25.940 |  39.978 | 156.191 | 47.229 | 206.536 |                 17.3% |
| fixed overhead, with wait | 12.922 | 35.509 | 50.038 | 106.784 | 185.225 | 76.709 | 271.500 |                 28.1% |

## Runner Timing

These values split the `execute` bucket. `process/io` starts after child setup signals right before `execve`; it includes the action process runtime and stdout/stderr drain.

| Runner Stage   |    Min |     p25 |     p50 |     p75 |     p95 |    Mean |     Max | Share of execute |
| -------------- | -----: | ------: | ------: | ------: | ------: | ------: | ------: | ---------------: |
| parent prepare |  0.052 |   0.065 |   0.081 |   0.230 |  10.650 |   1.554 |  12.915 |             0.7% |
| fork           |  0.082 |   0.130 |   0.242 |   0.464 |   0.854 |   0.333 |   1.240 |             0.1% |
| child setup    |  0.003 |   0.144 |   0.253 |   0.463 |   0.924 |   0.331 |   1.247 |             0.1% |
| process/io     | 43.318 | 122.262 | 132.765 | 277.221 | 427.101 | 196.312 | 489.904 |            86.1% |
| wait           |  5.166 |  13.497 |  21.566 |  42.014 |  69.060 |  29.479 |  71.287 |            12.9% |
| stdio digest   |  0.001 |   0.002 |   0.004 |   0.006 |   0.018 |   0.016 |   0.355 |             0.0% |

| Stress Case                | Digest         | Parent Prep |  Fork | Child Setup | Process/IO |   Wait | Stdio Digest | Setup Signaled |
| -------------------------- | -------------- | ----------: | ----: | ----------: | ---------: | -----: | -----------: | -------------- |
| bare_individual_files      | `249502cd8713` |      12.915 | 0.144 |       0.154 |    275.162 | 71.287 |        0.003 | True           |
| bare_individual_files      | `ad55f25cb61f` |      10.517 | 0.134 |       0.513 |    280.041 | 68.379 |        0.005 | True           |
| bare_individual_files      | `c5541e308a49` |       0.058 | 0.104 |       0.163 |    275.470 | 40.398 |        0.007 | True           |
| bare_individual_files      | `d56cf6590fef` |       0.243 | 0.136 |       0.521 |    276.895 | 69.740 |        0.005 | True           |
| generated_file_producer    | `bc2e603f3e0b` |       0.101 | 0.718 |       0.009 |    277.548 | 40.438 |        0.002 | True           |
| generated_individual_files | `0e2aba08daac` |       0.166 | 0.127 |       0.135 |     43.318 |  5.166 |        0.010 | True           |
| generated_individual_files | `93f6d1fb4bbc` |       0.060 | 0.199 |       0.322 |     46.827 |  5.681 |        0.002 | True           |
| generated_individual_files | `b2f28122427f` |       0.065 | 0.438 |       0.005 |     47.462 |  6.690 |        0.007 | True           |
| generated_individual_files | `ef2aa47738bc` |       0.218 | 0.270 |       0.135 |     43.995 |  5.659 |        0.005 | True           |
| generated_tree_producer    | `2dd6c1952601` |      10.569 | 0.107 |       0.413 |    283.788 | 64.964 |        0.004 | True           |
| generated_tree_reuse       | `04ba19135981` |       0.081 | 0.324 |       0.175 |    149.127 | 41.922 |        0.002 | True           |
| generated_tree_reuse       | `127fae4ead86` |       0.073 | 0.121 |       0.331 |    130.364 | 22.673 |        0.002 | True           |
| generated_tree_reuse       | `762b1b9f7d16` |       0.183 | 0.109 |       0.180 |    126.564 | 18.751 |        0.002 | True           |
| generated_tree_reuse       | `7b6fae59491f` |       0.052 | 0.646 |       0.115 |    141.490 | 36.079 |        0.024 | True           |
| generated_tree_reuse       | `7cf4273ba27b` |       0.069 | 0.554 |       0.343 |    143.429 | 42.761 |        0.004 | True           |
| generated_tree_reuse       | `8c4f3e7cd4e7` |       0.077 | 0.490 |       0.040 |    147.217 | 42.107 |        0.002 | True           |
| generated_tree_reuse       | `cef27a1e7fc8` |       0.057 | 0.507 |       0.247 |    132.765 | 22.990 |        0.002 | True           |
| generated_tree_reuse       | `e21d712e10ce` |       0.063 | 0.174 |       1.247 |    119.896 | 30.204 |        0.001 | True           |
| mixed_all                  | `8bf959095e33` |       0.059 | 0.242 |       0.003 |    489.904 | 49.517 |        0.009 | True           |
| nested_individual_files    | `463d1d3b7519` |      10.731 | 0.439 |       0.281 |    131.492 | 13.457 |        0.004 | True           |
| nested_individual_files    | `750c16854c4f` |       0.090 | 0.191 |       0.801 |    104.902 | 18.730 |        0.005 | True           |
| nested_individual_files    | `921deac3abf2` |       0.468 | 0.102 |       0.253 |    130.410 | 54.418 |        0.007 | True           |
| nested_individual_files    | `c0c6c0286d7a` |       0.125 | 0.286 |       0.541 |    100.597 | 21.527 |        0.004 | True           |
| nested_individual_files    | `c3eeebf452a8` |       0.065 | 1.240 |       0.530 |    128.430 | 13.126 |        0.355 | True           |
| nested_individual_files    | `c46382f1c163` |       0.055 | 0.082 |       0.551 |    128.482 | 13.219 |        0.003 | True           |
| nested_individual_files    | `c82d276ce20b` |       0.394 | 0.135 |       0.401 |    103.746 | 21.566 |        0.003 | True           |
| nested_individual_files    | `cbd9737de7fa` |       0.065 | 0.627 |       1.048 |    124.629 | 11.561 |        0.012 | True           |
| source_dir_tree            | `13ad68143150` |       0.071 | 0.991 |       0.004 |    428.420 | 17.296 |        0.004 | True           |
| source_dir_tree            | `7457f233803f` |       0.112 | 0.290 |       0.402 |    422.808 | 15.097 |        0.002 | True           |
| source_dir_tree            | `835056696b6a` |       0.312 | 0.304 |       0.190 |    424.725 | 13.536 |        0.003 | True           |
| source_dir_tree            | `ba00a2e83069` |       0.065 | 0.091 |       0.198 |    425.782 | 14.920 |        0.003 | True           |

## Per Action

| Stress Case                | Digest         |   Total |  Input | Execute |  Output | File Inputs | Dir Inputs | Bind Mounts | Outputs        |
| -------------------------- | -------------- | ------: | -----: | ------: | ------: | ----------: | ---------: | ----------: | -------------- |
| bare_individual_files      | `249502cd8713` | 385.846 |  5.631 | 359.678 |  20.536 |           0 |          0 |           2 | 1 file, 1 dir  |
| bare_individual_files      | `ad55f25cb61f` | 383.310 |  5.219 | 359.602 |  18.489 |           0 |          0 |           2 | 1 file, 1 dir  |
| bare_individual_files      | `c5541e308a49` | 362.269 |  4.279 | 316.215 |  41.774 |           0 |          0 |           2 | 1 file, 1 dir  |
| bare_individual_files      | `d56cf6590fef` | 387.216 | 18.291 | 347.548 |  21.376 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_file_producer    | `bc2e603f3e0b` | 473.414 | 18.390 | 318.829 | 136.196 |           0 |          0 |           2 | 97 file, 0 dir |
| generated_individual_files | `0e2aba08daac` |  56.521 |  1.751 |  49.202 |   5.567 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_individual_files | `93f6d1fb4bbc` |  60.225 |  1.369 |  53.102 |   5.753 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_individual_files | `b2f28122427f` |  61.734 |  1.753 |  54.679 |   5.302 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_individual_files | `ef2aa47738bc` |  58.010 |  1.932 |  50.290 |   5.788 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_tree_producer    | `2dd6c1952601` | 555.302 |  6.674 | 359.859 | 188.768 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_tree_reuse       | `04ba19135981` | 216.540 |  6.574 | 191.640 |  18.326 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_tree_reuse       | `127fae4ead86` | 167.818 |  6.805 | 153.609 |   7.404 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_tree_reuse       | `762b1b9f7d16` | 158.116 |  6.720 | 145.805 |   5.591 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_tree_reuse       | `7b6fae59491f` | 196.069 |  7.700 | 178.418 |   9.951 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_tree_reuse       | `7cf4273ba27b` | 200.253 |  7.121 | 187.169 |   5.962 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_tree_reuse       | `8c4f3e7cd4e7` | 215.354 |  7.457 | 189.941 |  17.955 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_tree_reuse       | `cef27a1e7fc8` | 182.812 |  7.734 | 156.578 |  18.500 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_tree_reuse       | `e21d712e10ce` | 162.957 |  6.363 | 151.596 |   4.998 |           0 |          0 |           2 | 1 file, 1 dir  |
| mixed_all                  | `8bf959095e33` | 558.720 |  2.499 | 539.744 |  16.476 |           0 |          0 |           2 | 1 file, 1 dir  |
| nested_individual_files    | `463d1d3b7519` | 295.837 |  5.906 | 156.421 | 133.509 |           0 |          0 |           2 | 1 file, 1 dir  |
| nested_individual_files    | `750c16854c4f` | 138.955 |  4.843 | 124.735 |   9.376 |           0 |          0 |           2 | 1 file, 1 dir  |
| nested_individual_files    | `921deac3abf2` | 305.028 | 18.958 | 185.680 | 100.390 |           0 |          0 |           2 | 1 file, 1 dir  |
| nested_individual_files    | `c0c6c0286d7a` | 137.606 |  4.935 | 123.107 |   9.564 |           0 |          0 |           2 | 1 file, 1 dir  |
| nested_individual_files    | `c3eeebf452a8` | 298.873 | 18.384 | 144.095 | 136.394 |           0 |          0 |           2 | 1 file, 1 dir  |
| nested_individual_files    | `c46382f1c163` | 278.238 |  4.994 | 142.410 | 130.833 |           0 |          0 |           2 | 1 file, 1 dir  |
| nested_individual_files    | `c82d276ce20b` | 136.647 |  4.871 | 126.265 |   5.511 |           0 |          0 |           2 | 1 file, 1 dir  |
| nested_individual_files    | `cbd9737de7fa` | 168.761 | 18.329 | 137.976 |  12.456 |           0 |          0 |           2 | 1 file, 1 dir  |
| source_dir_tree            | `13ad68143150` | 471.662 | 13.634 | 446.792 |  11.236 |           0 |          0 |           2 | 1 file, 1 dir  |
| source_dir_tree            | `7457f233803f` | 456.192 |  4.577 | 438.717 |  12.898 |           0 |          0 |           2 | 1 file, 1 dir  |
| source_dir_tree            | `835056696b6a` | 465.815 | 14.524 | 439.082 |  12.210 |           0 |          0 |           2 | 1 file, 1 dir  |
| source_dir_tree            | `ba00a2e83069` | 468.616 | 14.774 | 441.065 |  12.776 |           0 |          0 |           2 | 1 file, 1 dir  |

## Notes

- This run observed `directory_inputs=0` for every action. Actions with `actiondfs_mounts>0` are using the lazy actiondfs input-root path, so their input tree is represented by the mounted REAPI root digest rather than by flattened file or directory counters.
- For actiondfs actions, some CAS directory/file read cost moves from input fetch/materialization into the action `process/io` bucket because metadata and pages are loaded lazily.
