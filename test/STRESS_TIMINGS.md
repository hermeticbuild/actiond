# Stress Timing Summary

- Generated: `2026-05-18 10:20:45 EDT`
- Mode: `vm`
- Execute records parsed: `31`
- Unique action digests: `31`
- Source log: `/var/folders/p4/xn8y5q_j24l5xwgwd_jx5c340000gn/T/actiond-vm-e2e.yY4EBe/darwin-actiond-vm.log`
- Command: `ACTIOND_E2E_KEEP_TMP=1 tools/e2e.sh vm`
- Bazel elapsed: `9.304s`
- Workload: //:stress_all

## Stage Timing

All timing values are milliseconds unless noted.

| Stage                   |    Min |     p25 |     p50 |     p75 |     p95 |    Mean |     Max | Share of summed total |
| ----------------------- | -----: | ------: | ------: | ------: | ------: | ------: | ------: | --------------------: |
| total                   | 47.687 | 199.881 | 243.898 | 358.753 | 442.431 | 258.675 | 521.839 |                100.0% |
| input fetch/materialize |  2.063 |   6.013 |   6.534 |   8.270 |  18.642 |   7.980 |  21.353 |                  3.1% |
| execute                 | 41.205 | 150.896 | 191.107 | 299.946 | 367.100 | 218.546 | 453.543 |                 84.5% |
| output upload/collect   |  2.538 |   5.552 |  16.323 |  36.964 | 103.510 |  32.149 | 190.201 |                 12.4% |

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
| bare_individual_files      |       4 |   321.636 |   344.690 |   357.205 |   360.919 |    10.924 |     299.946 |     23.502 |          2 |
| generated_file_producer    |       1 |   412.051 |   412.051 |   412.051 |   412.051 |     8.952 |     266.963 |    136.135 |          2 |
| generated_individual_files |       4 |    49.706 |    51.535 |    52.908 |    53.426 |     2.466 |      43.568 |      5.372 |          2 |
| generated_tree_producer    |       1 |   521.839 |   521.839 |   521.839 |   521.839 |     7.976 |     323.661 |    190.201 |          2 |
| generated_tree_reuse       |       8 |   215.445 |   222.320 |   247.908 |   260.749 |     6.187 |     191.765 |      5.913 |          2 |
| mixed_all                  |       1 |   472.811 |   472.811 |   472.811 |   472.811 |     3.895 |     453.543 |     15.372 |          2 |
| nested_individual_files    |       8 |   195.961 |   218.260 |   232.989 |   247.073 |     8.790 |     150.896 |     58.394 |          2 |
| source_dir_tree            |       4 |   383.534 |   385.262 |   387.168 |   387.747 |     6.264 |     366.098 |     13.300 |          2 |

## Visible Overhead Estimate

`process/io` is excluded here because it is mostly the action process runtime plus stdout/stderr drain.

| Metric                    |    Min |    p25 |    p50 |     p75 |     p95 |   Mean |     Max | Share of summed total |
| ------------------------- | -----: | -----: | -----: | ------: | ------: | -----: | ------: | --------------------: |
| fixed overhead, no wait   |  6.867 | 11.989 | 23.925 |  54.895 | 119.771 | 41.010 | 199.250 |                 15.9% |
| fixed overhead, with wait | 11.935 | 40.273 | 66.853 | 101.544 | 216.897 | 81.623 | 310.036 |                 31.6% |

## Runner Timing

These values split the `execute` bucket. `process/io` starts after child setup signals right before `execve`; it includes the action process runtime and stdout/stderr drain.

| Runner Stage   |    Min |     p25 |     p50 |     p75 |     p95 |    Mean |     Max | Share of execute |
| -------------- | -----: | ------: | ------: | ------: | ------: | ------: | ------: | ---------------: |
| parent prepare |  0.051 |   0.058 |   0.065 |   0.103 |   0.253 |   0.111 |   0.574 |             0.1% |
| fork           |  0.060 |   0.100 |   0.137 |   0.279 |   0.436 |   0.206 |   0.877 |             0.1% |
| child setup    |  0.003 |   0.226 |   0.404 |   0.797 |   1.256 |   0.559 |   2.666 |             0.3% |
| process/io     | 35.743 | 132.035 | 167.282 | 189.160 | 343.700 | 177.036 | 403.442 |            81.0% |
| wait           |  5.067 |  18.767 |  20.031 |  58.962 | 113.590 |  40.613 | 114.074 |            18.6% |
| stdio digest   |  0.001 |   0.002 |   0.003 |   0.006 |   0.010 |   0.004 |   0.015 |             0.0% |

| Stress Case                | Digest         | Parent Prep |  Fork | Child Setup | Process/IO |    Wait | Stdio Digest | Setup Signaled |
| -------------------------- | -------------- | ----------: | ----: | ----------: | ---------: | ------: | -----------: | -------------- |
| bare_individual_files      | `249502cd8713` |       0.125 | 0.156 |       0.340 |    183.577 | 114.074 |        0.002 | True           |
| bare_individual_files      | `ad55f25cb61f` |       0.065 | 0.072 |       0.761 |    186.889 | 113.803 |        0.001 | True           |
| bare_individual_files      | `c5541e308a49` |       0.574 | 0.341 |       0.404 |    149.969 | 111.457 |        0.007 | True           |
| bare_individual_files      | `d56cf6590fef` |       0.244 | 0.073 |       2.666 |    205.870 | 113.377 |        0.002 | True           |
| generated_file_producer    | `bc2e603f3e0b` |       0.261 | 0.124 |       1.230 |    153.183 | 112.142 |        0.003 | True           |
| generated_individual_files | `0e2aba08daac` |       0.053 | 0.118 |       0.220 |     39.508 |   5.423 |        0.002 | True           |
| generated_individual_files | `93f6d1fb4bbc` |       0.056 | 0.141 |       0.187 |     35.743 |   5.067 |        0.002 | True           |
| generated_individual_files | `b2f28122427f` |       0.059 | 0.165 |       0.476 |     36.779 |   5.070 |        0.002 | True           |
| generated_individual_files | `ef2aa47738bc` |       0.055 | 0.092 |       0.281 |     38.875 |   5.251 |        0.002 | True           |
| generated_tree_producer    | `2dd6c1952601` |       0.060 | 0.106 |       0.904 |    211.797 | 110.786 |        0.001 | True           |
| generated_tree_reuse       | `04ba19135981` |       0.057 | 0.094 |       0.869 |    189.432 |  58.663 |        0.011 | True           |
| generated_tree_reuse       | `127fae4ead86` |       0.058 | 0.083 |       0.195 |    167.282 |  19.608 |        0.002 | True           |
| generated_tree_reuse       | `762b1b9f7d16` |       0.071 | 0.391 |       0.346 |    155.458 |  18.239 |        0.003 | True           |
| generated_tree_reuse       | `7b6fae59491f` |       0.063 | 0.877 |       0.004 |    174.462 |  59.261 |        0.004 | True           |
| generated_tree_reuse       | `7cf4273ba27b` |       0.061 | 0.136 |       0.741 |    168.095 |  19.631 |        0.002 | True           |
| generated_tree_reuse       | `8c4f3e7cd4e7` |       0.053 | 0.212 |       0.004 |    168.868 |  21.952 |        0.006 | True           |
| generated_tree_reuse       | `cef27a1e7fc8` |       0.051 | 0.398 |       0.003 |    188.889 |  61.420 |        0.004 | True           |
| generated_tree_reuse       | `e21d712e10ce` |       0.062 | 0.371 |       0.005 |    170.244 |  21.733 |        0.001 | True           |
| mixed_all                  | `8bf959095e33` |       0.060 | 0.122 |       0.426 |    403.442 |  49.442 |        0.005 | True           |
| nested_individual_files    | `463d1d3b7519` |       0.168 | 0.130 |       1.267 |    115.350 |  19.605 |        0.015 | True           |
| nested_individual_files    | `750c16854c4f` |       0.055 | 0.060 |       0.335 |    153.836 |  11.498 |        0.005 | True           |
| nested_individual_files    | `921deac3abf2` |       0.227 | 0.110 |       0.232 |    135.249 |  18.205 |        0.005 | True           |
| nested_individual_files    | `c0c6c0286d7a` |       0.242 | 0.145 |       0.270 |    114.540 |  19.562 |        0.008 | True           |
| nested_individual_files    | `c3eeebf452a8` |       0.075 | 0.206 |       0.643 |    120.361 |  19.540 |        0.001 | True           |
| nested_individual_files    | `c46382f1c163` |       0.071 | 0.304 |       1.245 |    157.138 |  19.939 |        0.007 | True           |
| nested_individual_files    | `c82d276ce20b` |       0.060 | 0.064 |       0.601 |    128.820 |  18.192 |        0.005 | True           |
| nested_individual_files    | `cbd9737de7fa` |       0.069 | 0.091 |       0.533 |    160.707 |  20.031 |        0.006 | True           |
| source_dir_tree            | `13ad68143150` |       0.075 | 0.137 |       0.857 |    343.441 |  19.296 |        0.003 | True           |
| source_dir_tree            | `7457f233803f` |       0.160 | 0.340 |       0.307 |    343.953 |  22.829 |        0.006 | True           |
| source_dir_tree            | `835056696b6a` |       0.082 | 0.473 |       0.153 |    342.927 |  21.959 |        0.009 | True           |
| source_dir_tree            | `ba00a2e83069` |       0.072 | 0.255 |       0.833 |    343.447 |  21.962 |        0.002 | True           |

## Per Action

| Stress Case                | Digest         |   Total |  Input | Execute |  Output | File Inputs | Dir Inputs | Bind Mounts | Outputs        |
| -------------------------- | -------------- | ------: | -----: | ------: | ------: | ----------: | ---------: | ----------: | -------------- |
| bare_individual_files      | `249502cd8713` | 333.724 | 13.796 | 298.286 |  21.642 |           0 |          0 |           2 | 1 file, 1 dir  |
| bare_individual_files      | `ad55f25cb61f` | 361.848 | 19.675 | 301.605 |  40.567 |           0 |          0 |           2 | 1 file, 1 dir  |
| bare_individual_files      | `c5541e308a49` | 285.371 |  6.277 | 262.770 |  16.323 |           0 |          0 |           2 | 1 file, 1 dir  |
| bare_individual_files      | `d56cf6590fef` | 355.657 |  8.053 | 322.243 |  25.361 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_file_producer    | `bc2e603f3e0b` | 412.051 |  8.952 | 266.963 | 136.135 |           0 |          0 |           2 | 97 file, 0 dir |
| generated_individual_files | `0e2aba08daac` |  53.556 |  2.623 |  45.330 |   5.602 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_individual_files | `93f6d1fb4bbc` |  47.687 |  2.063 |  41.205 |   4.419 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_individual_files | `b2f28122427f` |  50.378 |  2.308 |  42.569 |   5.501 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_individual_files | `ef2aa47738bc` |  52.692 |  2.884 |  44.566 |   5.242 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_tree_producer    | `2dd6c1952601` | 521.839 |  7.976 | 323.661 | 190.201 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_tree_reuse       | `04ba19135981` | 259.936 |  5.615 | 249.137 |   5.184 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_tree_reuse       | `127fae4ead86` | 197.652 |  5.891 | 187.235 |   4.526 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_tree_reuse       | `762b1b9f7d16` | 188.306 |  7.136 | 174.528 |   6.642 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_tree_reuse       | `7b6fae59491f` | 243.898 |  6.677 | 234.683 |   2.538 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_tree_reuse       | `7cf4273ba27b` | 221.712 |  6.524 | 188.678 |  26.510 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_tree_reuse       | `8c4f3e7cd4e7` | 222.928 |  6.239 | 191.107 |  25.581 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_tree_reuse       | `cef27a1e7fc8` | 261.186 |  6.135 | 250.780 |   4.272 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_tree_reuse       | `e21d712e10ce` | 221.376 |  5.267 | 192.422 |  23.687 |           0 |          0 |           2 | 1 file, 1 dir  |
| mixed_all                  | `8bf959095e33` | 472.811 |  3.895 | 453.543 |  15.372 |           0 |          0 |           2 | 1 file, 1 dir  |
| nested_individual_files    | `463d1d3b7519` | 227.824 | 21.353 | 136.565 |  69.905 |           0 |          0 |           2 | 1 file, 1 dir  |
| nested_individual_files    | `750c16854c4f` | 177.515 |  7.512 | 165.821 |   4.181 |           0 |          0 |           2 | 1 file, 1 dir  |
| nested_individual_files    | `921deac3abf2` | 202.110 | 14.713 | 154.036 |  33.361 |           0 |          0 |           2 | 1 file, 1 dir  |
| nested_individual_files    | `c0c6c0286d7a` | 208.695 |  8.082 | 134.793 |  65.820 |           0 |          0 |           2 | 1 file, 1 dir  |
| nested_individual_files    | `c3eeebf452a8` | 229.334 | 17.608 | 140.842 |  70.885 |           0 |          0 |           2 | 1 file, 1 dir  |
| nested_individual_files    | `c46382f1c163` | 248.752 |  8.459 | 178.715 |  61.578 |           0 |          0 |           2 | 1 file, 1 dir  |
| nested_individual_files    | `c82d276ce20b` | 174.371 |  9.122 | 147.756 |  17.492 |           0 |          0 |           2 | 1 file, 1 dir  |
| nested_individual_files    | `cbd9737de7fa` | 243.956 |  7.298 | 181.448 |  55.210 |           0 |          0 |           2 | 1 file, 1 dir  |
| source_dir_tree            | `13ad68143150` | 383.597 |  6.186 | 363.826 |  13.585 |           0 |          0 |           2 | 1 file, 1 dir  |
| source_dir_tree            | `7457f233803f` | 386.926 |  6.292 | 367.618 |  13.016 |           0 |          0 |           2 | 1 file, 1 dir  |
| source_dir_tree            | `835056696b6a` | 383.344 |  6.534 | 365.614 |  11.195 |           0 |          0 |           2 | 1 file, 1 dir  |
| source_dir_tree            | `ba00a2e83069` | 387.892 |  6.236 | 366.582 |  15.073 |           0 |          0 |           2 | 1 file, 1 dir  |

## Notes

- This run observed `directory_inputs=0` for every action. Actions with `actiondfs_mounts>0` are using the lazy actiondfs input-root path, so their input tree is represented by the mounted REAPI root digest rather than by flattened file or directory counters.
- For actiondfs actions, some CAS directory/file read cost moves from input fetch/materialization into the action `process/io` bucket because metadata and pages are loaded lazily.
