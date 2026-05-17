# Stress Timing Summary

- Generated: `2026-05-17 18:23:13 EDT`
- Mode: `vm-actiondfs-canonical-lookup`
- Execute records parsed: `31`
- Unique action digests: `31`
- Source log: `/var/folders/p4/xn8y5q_j24l5xwgwd_jx5c340000gn/T/actiond-vm-e2e.y0INze/darwin-actiond-vm.log`
- Command: `ACTIOND_E2E_KEEP_TMP=1 ACTIOND_KERNEL_DOCKER_CONTEXT=colima tools/e2e.sh vm`

## Stage Timing

All timing values are milliseconds unless noted.

| Stage                   |    Min |     p25 |     p50 |     p75 |     p95 |    Mean |     Max | Share of summed total |
| ----------------------- | -----: | ------: | ------: | ------: | ------: | ------: | ------: | --------------------: |
| total                   | 68.270 | 222.134 | 324.803 | 430.817 | 512.898 | 313.126 | 571.914 |                100.0% |
| input fetch/materialize |  2.697 |   3.766 |   4.658 |   6.177 |  19.337 |   7.263 |  19.945 |                  2.3% |
| execute                 | 57.459 | 171.629 | 226.621 | 384.696 | 472.508 | 270.569 | 494.670 |                 86.4% |
| output upload/collect   |  7.375 |  14.191 |  21.217 |  46.301 | 101.265 |  35.293 | 169.851 |                 11.3% |

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
| bare_individual_files      |       4 |   423.555 |   426.520 |   430.063 |   431.874 |    11.944 |     390.308 |     24.665 |          2 |
| generated_file_producer    |       1 |   510.246 |   510.246 |   510.246 |   510.246 |    18.916 |     383.273 |    108.057 |          2 |
| generated_individual_files |       4 |    68.858 |    69.155 |    69.597 |    70.418 |     2.949 |      58.487 |      7.774 |          2 |
| generated_tree_producer    |       1 |   571.914 |   571.914 |   571.914 |   571.914 |    16.109 |     385.954 |    169.851 |          2 |
| generated_tree_reuse       |       8 |   182.577 |   223.447 |   235.417 |   242.120 |     4.541 |     171.629 |     46.301 |          2 |
| mixed_all                  |       1 |   515.551 |   515.551 |   515.551 |   515.551 |     3.226 |     494.670 |     17.654 |          2 |
| nested_individual_files    |       8 |   298.412 |   326.541 |   338.766 |   344.448 |     4.849 |     261.701 |     21.973 |          2 |
| source_dir_tree            |       4 |   485.889 |   487.882 |   490.600 |   494.832 |     5.216 |     466.568 |     14.603 |          2 |

## Visible Overhead Estimate

`process/io` is excluded here because it is mostly the action process runtime plus stdout/stderr drain.

| Metric                    |    Min |    p25 |    p50 |    p75 |     p95 |   Mean |     Max | Share of summed total |
| ------------------------- | -----: | -----: | -----: | -----: | ------: | -----: | ------: | --------------------: |
| fixed overhead, no wait   | 10.795 | 20.014 | 36.500 | 53.100 | 113.057 | 44.577 | 186.816 |                 14.2% |
| fixed overhead, with wait | 16.520 | 40.608 | 64.760 | 83.175 | 174.937 | 70.756 | 206.111 |                 22.6% |

## Runner Timing

These values split the `execute` bucket. `process/io` starts after child setup signals right before `execve`; it includes the action process runtime and stdout/stderr drain.

| Runner Stage   |    Min |     p25 |     p50 |     p75 |     p95 |    Mean |     Max | Share of execute |
| -------------- | -----: | ------: | ------: | ------: | ------: | ------: | ------: | ---------------: |
| parent prepare |  0.053 |   0.061 |   0.065 |   0.121 |   9.387 |   1.317 |  11.111 |             0.5% |
| fork           |  0.071 |   0.121 |   0.181 |   0.609 |   1.208 |   0.390 |   1.521 |             0.1% |
| child setup    |  0.004 |   0.142 |   0.273 |   0.351 |   0.685 |   0.309 |   1.313 |             0.1% |
| process/io     | 51.732 | 145.808 | 155.569 | 364.530 | 449.661 | 242.351 | 464.552 |            89.6% |
| wait           |  5.436 |  18.569 |  20.998 |  26.607 |  75.301 |  26.179 |  78.857 |             9.7% |
| stdio digest   |  0.001 |   0.002 |   0.003 |   0.005 |   0.011 |   0.005 |   0.032 |             0.0% |

| Stress Case                | Digest         | Parent Prep |  Fork | Child Setup | Process/IO |   Wait | Stdio Digest | Setup Signaled |
| -------------------------- | -------------- | ----------: | ----: | ----------: | ---------: | -----: | -----------: | -------------- |
| bare_individual_files      | `249502cd8713` |       9.355 | 0.550 |       0.009 |    367.289 | 19.931 |        0.032 | True           |
| bare_individual_files      | `ad55f25cb61f` |       0.062 | 0.827 |       0.345 |    360.555 | 21.617 |        0.002 | True           |
| bare_individual_files      | `c5541e308a49` |       0.062 | 0.121 |       0.576 |    361.671 | 18.805 |        0.003 | True           |
| bare_individual_files      | `d56cf6590fef` |       9.419 | 1.279 |       0.334 |    366.335 | 19.941 |        0.005 | True           |
| generated_file_producer    | `bc2e603f3e0b` |       0.082 | 0.107 |       0.287 |    363.266 | 19.517 |        0.004 | True           |
| generated_individual_files | `0e2aba08daac` |       0.059 | 0.080 |       0.130 |     51.732 |  5.436 |        0.004 | True           |
| generated_individual_files | `93f6d1fb4bbc` |       0.057 | 0.243 |       0.105 |     52.270 |  5.460 |        0.002 | True           |
| generated_individual_files | `b2f28122427f` |       0.058 | 0.242 |       0.446 |     52.976 |  6.156 |        0.001 | True           |
| generated_individual_files | `ef2aa47738bc` |       0.060 | 0.093 |       0.214 |     52.682 |  5.768 |        0.004 | True           |
| generated_tree_producer    | `2dd6c1952601` |       0.061 | 0.570 |       0.224 |    365.795 | 19.296 |        0.002 | True           |
| generated_tree_reuse       | `04ba19135981` |       0.053 | 0.181 |       0.093 |    149.917 | 21.550 |        0.001 | True           |
| generated_tree_reuse       | `127fae4ead86` |       0.062 | 0.647 |       0.133 |    151.252 | 20.998 |        0.002 | True           |
| generated_tree_reuse       | `762b1b9f7d16` |       0.217 | 0.901 |       0.004 |    155.030 | 21.775 |        0.003 | True           |
| generated_tree_reuse       | `7b6fae59491f` |       0.063 | 0.127 |       0.201 |    149.821 | 21.210 |        0.002 | True           |
| generated_tree_reuse       | `7cf4273ba27b` |       0.053 | 0.775 |       0.004 |    146.045 | 19.309 |        0.002 | True           |
| generated_tree_reuse       | `8c4f3e7cd4e7` |       0.069 | 0.698 |       0.302 |    146.835 | 15.719 |        0.003 | True           |
| generated_tree_reuse       | `cef27a1e7fc8` |       0.064 | 0.186 |       0.300 |    155.569 | 21.867 |        0.002 | True           |
| generated_tree_reuse       | `e21d712e10ce` |       0.064 | 0.148 |       0.203 |    141.582 | 22.319 |        0.001 | True           |
| mixed_all                  | `8bf959095e33` |       0.058 | 0.138 |       0.306 |    464.552 | 29.599 |        0.005 | True           |
| nested_individual_files    | `463d1d3b7519` |       0.086 | 0.350 |       0.273 |    145.226 | 74.495 |        0.005 | True           |
| nested_individual_files    | `750c16854c4f` |       0.073 | 0.079 |       0.325 |    147.278 | 78.857 |        0.002 | True           |
| nested_individual_files    | `921deac3abf2` |       0.065 | 0.102 |       0.773 |    269.359 | 26.457 |        0.009 | True           |
| nested_individual_files    | `c0c6c0286d7a` |       0.534 | 0.071 |       0.597 |    145.571 | 76.107 |        0.004 | True           |
| nested_individual_files    | `c3eeebf452a8` |       0.067 | 0.249 |       0.252 |    140.092 | 67.350 |        0.005 | True           |
| nested_individual_files    | `c46382f1c163` |       0.077 | 0.148 |       0.357 |    273.771 | 26.756 |        0.007 | True           |
| nested_individual_files    | `c82d276ce20b` |      11.111 | 1.138 |       1.313 |    271.549 | 27.138 |        0.004 | True           |
| nested_individual_files    | `cbd9737de7fa` |       0.157 | 0.160 |       0.150 |    272.668 | 27.287 |        0.006 | True           |
| source_dir_tree            | `13ad68143150` |       0.063 | 0.121 |       0.523 |    445.798 | 17.006 |        0.002 | True           |
| source_dir_tree            | `7457f233803f` |       8.362 | 1.521 |       0.023 |    451.992 | 16.497 |        0.013 | True           |
| source_dir_tree            | `835056696b6a` |       0.070 | 0.143 |       0.260 |    447.067 | 18.987 |        0.007 | True           |
| source_dir_tree            | `ba00a2e83069` |       0.184 | 0.098 |       0.504 |    447.330 | 18.333 |        0.003 | True           |

## Per Action

| Stress Case                | Digest         |   Total |  Input | Execute |  Output | File Inputs | Dir Inputs | Bind Mounts | Outputs        |
| -------------------------- | -------------- | ------: | -----: | ------: | ------: | ----------: | ---------: | ----------: | -------------- |
| bare_individual_files      | `249502cd8713` | 423.732 |  5.337 | 397.178 |  21.217 |           0 |          0 |           2 | 1 file, 1 dir  |
| bare_individual_files      | `ad55f25cb61f` | 429.308 | 18.372 | 383.437 |  27.499 |           0 |          0 |           2 | 1 file, 1 dir  |
| bare_individual_files      | `c5541e308a49` | 423.026 | 19.945 | 381.249 |  21.831 |           0 |          0 |           2 | 1 file, 1 dir  |
| bare_individual_files      | `d56cf6590fef` | 432.327 |  5.517 | 397.324 |  29.486 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_file_producer    | `bc2e603f3e0b` | 510.246 | 18.916 | 383.273 | 108.057 |           0 |          0 |           2 | 97 file, 0 dir |
| generated_individual_files | `0e2aba08daac` |  68.270 |  3.300 |  57.459 |   7.511 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_individual_files | `93f6d1fb4bbc` |  69.054 |  2.849 |  58.144 |   8.062 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_individual_files | `b2f28122427f` |  70.623 |  2.697 |  59.888 |   8.037 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_individual_files | `ef2aa47738bc` |  69.255 |  3.050 |  58.830 |   7.375 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_tree_producer    | `2dd6c1952601` | 571.914 | 16.109 | 385.954 | 169.851 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_tree_reuse       | `04ba19135981` | 235.253 |  5.564 | 171.828 |  57.862 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_tree_reuse       | `127fae4ead86` | 216.018 |  4.077 | 173.100 |  38.841 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_tree_reuse       | `762b1b9f7d16` | 235.908 |  4.208 | 177.939 |  53.761 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_tree_reuse       | `7b6fae59491f` | 230.875 |  4.551 | 171.431 |  54.893 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_tree_reuse       | `7cf4273ba27b` | 179.887 |  3.886 | 166.195 |   9.805 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_tree_reuse       | `8c4f3e7cd4e7` | 177.452 |  4.531 | 163.644 |   9.277 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_tree_reuse       | `cef27a1e7fc8` | 245.464 |  4.658 | 177.994 |  62.812 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_tree_reuse       | `e21d712e10ce` | 183.473 |  5.055 | 164.365 |  14.053 |           0 |          0 |           2 | 1 file, 1 dir  |
| mixed_all                  | `8bf959095e33` | 515.551 |  3.226 | 494.670 |  17.654 |           0 |          0 |           2 | 1 file, 1 dir  |
| nested_individual_files    | `463d1d3b7519` | 239.815 |  3.660 | 220.456 |  15.700 |           0 |          0 |           2 | 1 file, 1 dir  |
| nested_individual_files    | `750c16854c4f` | 324.803 |  3.707 | 226.621 |  94.474 |           0 |          0 |           2 | 1 file, 1 dir  |
| nested_individual_files    | `921deac3abf2` | 336.917 | 19.758 | 296.780 |  20.378 |           0 |          0 |           2 | 1 file, 1 dir  |
| nested_individual_files    | `c0c6c0286d7a` | 317.944 |  3.688 | 222.901 |  91.354 |           0 |          0 |           2 | 1 file, 1 dir  |
| nested_individual_files    | `c3eeebf452a8` | 228.249 |  3.825 | 208.053 |  16.370 |           0 |          0 |           2 | 1 file, 1 dir  |
| nested_individual_files    | `c46382f1c163` | 344.315 | 17.153 | 301.133 |  26.029 |           0 |          0 |           2 | 1 file, 1 dir  |
| nested_individual_files    | `c82d276ce20b` | 344.519 | 10.254 | 312.276 |  21.989 |           0 |          0 |           2 | 1 file, 1 dir  |
| nested_individual_files    | `cbd9737de7fa` | 328.280 |  5.872 | 300.450 |  21.957 |           0 |          0 |           2 | 1 file, 1 dir  |
| source_dir_tree            | `13ad68143150` | 482.771 |  4.917 | 463.525 |  14.329 |           0 |          0 |           2 | 1 file, 1 dir  |
| source_dir_tree            | `7457f233803f` | 495.891 |  4.488 | 478.415 |  12.988 |           0 |          0 |           2 | 1 file, 1 dir  |
| source_dir_tree            | `835056696b6a` | 488.836 |  6.482 | 466.601 |  15.752 |           0 |          0 |           2 | 1 file, 1 dir  |
| source_dir_tree            | `ba00a2e83069` | 486.928 |  5.515 | 466.535 |  14.878 |           0 |          0 |           2 | 1 file, 1 dir  |

## Notes

- This run observed `directory_inputs=0` for every action. Actions with `actiondfs_mounts>0` are using the lazy actiondfs input-root path, so their input tree is represented by the mounted REAPI root digest rather than by flattened file or directory counters.
- For actiondfs actions, some CAS directory/file read cost moves from input fetch/materialization into the action `process/io` bucket because metadata and pages are loaded lazily.
