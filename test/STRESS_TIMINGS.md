# Stress Timing Summary

- Generated: `2026-05-17 19:03:30 EDT`
- Mode: `vm-actiondfs`
- Execute records parsed: `31`
- Unique action digests: `31`
- Source log: `/var/folders/p4/xn8y5q_j24l5xwgwd_jx5c340000gn/T/actiond-vm-e2e.thTjah/darwin-actiond-vm.log`
- Command: `ACTIOND_ACTIONDFS_FSTYPE=actiondfs ACTIOND_E2E_KEEP_TMP=1 tools/e2e.sh vm`

## Stage Timing

All timing values are milliseconds unless noted.

| Stage                   |    Min |     p25 |     p50 |     p75 |     p95 |    Mean |     Max | Share of summed total |
| ----------------------- | -----: | ------: | ------: | ------: | ------: | ------: | ------: | --------------------: |
| total                   | 57.542 | 202.322 | 288.933 | 324.852 | 404.365 | 260.779 | 579.484 |                100.0% |
| input fetch/materialize |  1.822 |   3.586 |   4.767 |  22.457 |  23.719 |  10.620 |  25.532 |                  4.1% |
| execute                 | 48.182 | 159.525 | 244.680 | 276.183 | 323.731 | 224.879 | 563.268 |                 86.2% |
| output upload/collect   |  3.835 |  11.106 |  16.935 |  27.794 |  68.715 |  25.279 | 177.801 |                  9.7% |

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
| bare_individual_files      |       4 |   289.506 |   289.872 |   291.288 |   294.265 |    23.069 |     244.289 |     22.132 |          2 |
| generated_file_producer    |       1 |   362.532 |   362.532 |   362.532 |   362.532 |    23.183 |     243.466 |     95.883 |          2 |
| generated_individual_files |       4 |    57.554 |    60.475 |    63.635 |    64.219 |     2.782 |      53.709 |      4.919 |          2 |
| generated_tree_producer    |       1 |   446.198 |   446.198 |   446.198 |   446.198 |     3.909 |     264.488 |    177.801 |          2 |
| generated_tree_reuse       |       8 |   279.623 |   301.317 |   311.345 |   329.783 |     4.534 |     274.378 |     22.279 |          2 |
| mixed_all                  |       1 |   579.484 |   579.484 |   579.484 |   579.484 |     2.168 |     563.268 |     14.048 |          2 |
| nested_individual_files    |       8 |   155.070 |   202.322 |   219.641 |   219.837 |    13.642 |     159.525 |     17.408 |          2 |
| source_dir_tree            |       4 |   353.153 |   359.126 |   359.364 |   359.461 |    21.747 |     322.642 |     13.362 |          2 |

## Visible Overhead Estimate

`process/io` is excluded here because it is mostly the action process runtime plus stdout/stderr drain.

| Metric                    |    Min |    p25 |    p50 |    p75 |     p95 |   Mean |     Max | Share of summed total |
| ------------------------- | -----: | -----: | -----: | -----: | ------: | -----: | ------: | --------------------: |
| fixed overhead, no wait   |  6.551 | 15.583 | 35.967 | 46.654 |  88.129 | 38.268 | 199.736 |                 14.7% |
| fixed overhead, with wait | 12.151 | 45.299 | 56.334 | 81.559 | 128.137 | 65.853 | 242.866 |                 25.3% |

## Runner Timing

These values split the `execute` bucket. `process/io` starts after child setup signals right before `execve`; it includes the action process runtime and stdout/stderr drain.

| Runner Stage   |    Min |     p25 |     p50 |     p75 |     p95 |    Mean |     Max | Share of execute |
| -------------- | -----: | ------: | ------: | ------: | ------: | ------: | ------: | ---------------: |
| parent prepare |  0.049 |   0.063 |   0.069 |   0.136 |  16.843 |   1.771 |  18.031 |             0.8% |
| fork           |  0.063 |   0.109 |   0.168 |   0.255 |   0.666 |   0.240 |   0.891 |             0.1% |
| child setup    |  0.003 |   0.218 |   0.321 |   0.468 |   0.770 |   0.354 |   1.153 |             0.2% |
| process/io     | 42.832 | 135.018 | 199.138 | 247.346 | 306.405 | 194.913 | 532.666 |            86.7% |
| wait           |  3.848 |  18.335 |  27.653 |  39.795 |  45.403 |  27.585 |  57.141 |            12.3% |
| stdio digest   |  0.001 |   0.002 |   0.003 |   0.004 |   0.006 |   0.003 |   0.007 |             0.0% |

| Stress Case                | Digest         | Parent Prep |  Fork | Child Setup | Process/IO |   Wait | Stdio Digest | Setup Signaled |
| -------------------------- | -------------- | ----------: | ----: | ----------: | ---------: | -----: | -----------: | -------------- |
| bare_individual_files      | `249502cd8713` |       0.085 | 0.254 |       0.326 |    198.478 | 45.526 |        0.002 | True           |
| bare_individual_files      | `ad55f25cb61f` |       0.185 | 0.123 |       0.233 |    198.068 | 45.280 |        0.002 | True           |
| bare_individual_files      | `c5541e308a49` |       0.072 | 0.375 |       0.003 |    199.233 | 43.838 |        0.005 | True           |
| bare_individual_files      | `d56cf6590fef` |      18.031 | 0.250 |       0.444 |    202.099 | 43.202 |        0.002 | True           |
| generated_file_producer    | `bc2e603f3e0b` |       0.502 | 0.466 |       0.544 |    199.138 | 42.801 |        0.003 | True           |
| generated_individual_files | `0e2aba08daac` |       0.069 | 0.139 |       1.153 |     51.044 |  4.077 |        0.001 | True           |
| generated_individual_files | `93f6d1fb4bbc` |       0.058 | 0.131 |       0.351 |     45.382 |  5.600 |        0.007 | True           |
| generated_individual_files | `b2f28122427f` |       0.068 | 0.215 |       0.554 |     51.171 |  3.848 |        0.002 | True           |
| generated_individual_files | `ef2aa47738bc` |       0.099 | 0.171 |       0.253 |     42.832 |  4.813 |        0.003 | True           |
| generated_tree_producer    | `2dd6c1952601` |      17.279 | 0.257 |       0.488 |    203.325 | 43.130 |        0.002 | True           |
| generated_tree_reuse       | `04ba19135981` |       0.075 | 0.284 |       0.004 |    225.771 | 37.202 |        0.002 | True           |
| generated_tree_reuse       | `127fae4ead86` |       0.131 | 0.891 |       0.003 |    248.909 | 42.387 |        0.004 | True           |
| generated_tree_reuse       | `762b1b9f7d16` |       0.075 | 0.100 |       0.669 |    246.837 | 28.447 |        0.001 | True           |
| generated_tree_reuse       | `7b6fae59491f` |       0.065 | 0.170 |       0.233 |    248.570 | 27.715 |        0.002 | True           |
| generated_tree_reuse       | `7cf4273ba27b` |       0.060 | 0.156 |       0.158 |    189.170 | 57.141 |        0.003 | True           |
| generated_tree_reuse       | `8c4f3e7cd4e7` |       0.066 | 0.191 |       0.871 |    247.855 | 27.206 |        0.001 | True           |
| generated_tree_reuse       | `cef27a1e7fc8` |       0.069 | 0.565 |       0.006 |    235.833 | 27.653 |        0.002 | True           |
| generated_tree_reuse       | `e21d712e10ce` |       0.194 | 0.764 |       0.448 |    243.222 | 27.960 |        0.004 | True           |
| mixed_all                  | `8bf959095e33` |       0.049 | 0.078 |       0.124 |    532.666 | 30.337 |        0.005 | True           |
| nested_individual_files    | `463d1d3b7519` |      16.408 | 0.189 |       0.490 |    141.878 | 25.789 |        0.004 | True           |
| nested_individual_files    | `750c16854c4f` |       0.060 | 0.093 |       0.167 |    140.053 | 28.708 |        0.003 | True           |
| nested_individual_files    | `921deac3abf2` |       0.072 | 0.104 |       0.271 |    101.787 | 19.286 |        0.004 | True           |
| nested_individual_files    | `c0c6c0286d7a` |       0.066 | 0.083 |       0.420 |    112.911 | 29.468 |        0.004 | True           |
| nested_individual_files    | `c3eeebf452a8` |       0.060 | 0.063 |       0.268 |    105.481 | 22.973 |        0.002 | True           |
| nested_individual_files    | `c46382f1c163` |       0.066 | 0.168 |       0.602 |    138.165 | 27.072 |        0.004 | True           |
| nested_individual_files    | `c82d276ce20b` |       0.057 | 0.126 |       0.383 |    137.971 | 25.970 |        0.005 | True           |
| nested_individual_files    | `cbd9737de7fa` |       0.551 | 0.106 |       0.261 |    132.066 | 21.514 |        0.006 | True           |
| source_dir_tree            | `13ad68143150` |       0.053 | 0.111 |       0.305 |    304.216 | 16.571 |        0.002 | True           |
| source_dir_tree            | `7457f233803f` |       0.066 | 0.568 |       0.423 |    306.126 | 17.383 |        0.001 | True           |
| source_dir_tree            | `835056696b6a` |       0.142 | 0.152 |       0.203 |    306.684 | 15.695 |        0.003 | True           |
| source_dir_tree            | `ba00a2e83069` |       0.057 | 0.105 |       0.321 |    305.364 | 16.543 |        0.002 | True           |

## Per Action

| Stress Case                | Digest         |   Total |  Input | Execute |  Output | File Inputs | Dir Inputs | Bind Mounts | Outputs        |
| -------------------------- | -------------- | ------: | -----: | ------: | ------: | ----------: | ---------: | ----------: | -------------- |
| bare_individual_files      | `249502cd8713` | 288.933 | 22.610 | 244.680 |  21.643 |           0 |          0 |           2 | 1 file, 1 dir  |
| bare_individual_files      | `ad55f25cb61f` | 290.048 | 23.529 | 243.898 |  22.621 |           0 |          0 |           2 | 1 file, 1 dir  |
| bare_individual_files      | `c5541e308a49` | 289.697 | 25.532 | 243.538 |  20.627 |           0 |          0 |           2 | 1 file, 1 dir  |
| bare_individual_files      | `d56cf6590fef` | 295.009 |  5.926 | 264.046 |  25.036 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_file_producer    | `bc2e603f3e0b` | 362.532 | 23.183 | 243.466 |  95.883 |           0 |          0 |           2 | 97 file, 0 dir |
| generated_individual_files | `0e2aba08daac` |  64.365 |  2.966 |  56.489 |   4.911 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_individual_files | `93f6d1fb4bbc` |  57.558 |  2.168 |  51.554 |   3.835 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_individual_files | `b2f28122427f` |  63.392 |  2.599 |  55.865 |   4.928 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_individual_files | `ef2aa47738bc` |  57.542 |  3.852 |  48.182 |   5.507 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_tree_producer    | `2dd6c1952601` | 446.198 |  3.909 | 264.488 | 177.801 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_tree_reuse       | `04ba19135981` | 279.586 |  4.923 | 263.349 |  11.314 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_tree_reuse       | `127fae4ead86` | 338.347 |  4.463 | 292.337 |  41.546 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_tree_reuse       | `762b1b9f7d16` | 313.879 |  4.606 | 276.144 |  33.130 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_tree_reuse       | `7b6fae59491f` | 304.912 |  4.767 | 276.763 |  23.382 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_tree_reuse       | `7cf4273ba27b` | 259.961 |  6.275 | 246.712 |   6.973 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_tree_reuse       | `8c4f3e7cd4e7` | 310.501 |  3.512 | 276.221 |  30.767 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_tree_reuse       | `cef27a1e7fc8` | 279.635 |  4.071 | 264.141 |  11.422 |           0 |          0 |           2 | 1 file, 1 dir  |
| generated_tree_reuse       | `e21d712e10ce` | 297.722 |  3.933 | 272.613 |  21.176 |           0 |          0 |           2 | 1 file, 1 dir  |
| mixed_all                  | `8bf959095e33` | 579.484 |  2.168 | 563.268 |  14.048 |           0 |          0 |           2 | 1 file, 1 dir  |
| nested_individual_files    | `463d1d3b7519` | 219.939 |  2.606 | 184.770 |  32.563 |           0 |          0 |           2 | 1 file, 1 dir  |
| nested_individual_files    | `750c16854c4f` | 208.333 | 22.304 | 169.093 |  16.935 |           0 |          0 |           2 | 1 file, 1 dir  |
| nested_individual_files    | `921deac3abf2` | 129.915 |  2.182 | 121.544 |   6.188 |           0 |          0 |           2 | 1 file, 1 dir  |
| nested_individual_files    | `c0c6c0286d7a` | 161.392 |  4.980 | 142.967 |  13.444 |           0 |          0 |           2 | 1 file, 1 dir  |
| nested_individual_files    | `c3eeebf452a8` | 136.106 |  1.822 | 128.856 |   5.428 |           0 |          0 |           2 | 1 file, 1 dir  |
| nested_individual_files    | `c46382f1c163` | 219.648 | 23.008 | 166.089 |  30.551 |           0 |          0 |           2 | 1 file, 1 dir  |
| nested_individual_files    | `c82d276ce20b` | 219.638 | 23.136 | 164.530 |  31.972 |           0 |          0 |           2 | 1 file, 1 dir  |
| nested_individual_files    | `cbd9737de7fa` | 196.312 | 23.910 | 154.521 |  17.880 |           0 |          0 |           2 | 1 file, 1 dir  |
| source_dir_tree            | `13ad68143150` | 335.825 |  3.661 | 321.265 |  10.898 |           0 |          0 |           2 | 1 file, 1 dir  |
| source_dir_tree            | `7457f233803f` | 359.486 | 21.578 | 324.577 |  13.331 |           0 |          0 |           2 | 1 file, 1 dir  |
| source_dir_tree            | `835056696b6a` | 359.324 | 21.917 | 322.886 |  14.521 |           0 |          0 |           2 | 1 file, 1 dir  |
| source_dir_tree            | `ba00a2e83069` | 358.929 | 23.137 | 322.399 |  13.393 |           0 |          0 |           2 | 1 file, 1 dir  |

## Notes

- This run observed `directory_inputs=0` for every action. Actions with `actiondfs_mounts>0` are using the lazy actiondfs input-root path, so their input tree is represented by the mounted REAPI root digest rather than by flattened file or directory counters.
- For actiondfs actions, some CAS directory/file read cost moves from input fetch/materialization into the action `process/io` bucket because metadata and pages are loaded lazily.
