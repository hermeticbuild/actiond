# Stress Timing Summary

- Generated: `2026-05-17 09:05:27 EDT`
- Mode: `vm`
- Execute records parsed: `31`
- Unique action digests: `31`
- Source log: `/var/folders/p4/xn8y5q_j24l5xwgwd_jx5c340000gn/T/actiond-vm-e2e.1lbzf2/darwin-actiond-vm.log`
- Command: `ACTIOND_E2E_KEEP_TMP=1 ACTIOND_E2E_PORT=8997 ACTIOND_KERNEL_DOCKER_CONTEXT=colima tools/e2e.sh vm`
- Bazel elapsed: `10.188s`
- Workload: expanded stress workspace: 4 bare-file actions over 160 flat source files forced to file mode, 8 nested-file actions over 96 nested source files each forced to file mode, 1 generated-file producer plus 4 generated-file consumers over 96 generated nested files forced to file mode, 4 source-directory actions over 8 source dirs x 32 files, 8 generated-tree reuse actions sharing one 256-file output directory, and 1 mixed action

## Stage Timing

All timing values are milliseconds unless noted.

| Stage | Min | Median | Mean | Max | Share of summed total |
| --- | ---: | ---: | ---: | ---: | ---: |
| total | 67.528 | 186.184 | 192.713 | 430.595 | 100.0% |
| input fetch/materialize | 2.240 | 17.109 | 53.841 | 151.159 | 27.9% |
| execute | 25.755 | 90.537 | 121.149 | 415.347 | 62.9% |
| output upload/collect | 1.956 | 8.052 | 17.724 | 176.686 | 9.2% |

## Input And Mount Counts

| Metric | Min | Median | Mean | Max |
| --- | ---: | ---: | ---: | ---: |
| file inputs | 1 | 98 | 59.3 | 162 |
| directory inputs | 0 | 0 | 1.1 | 5 |
| bind mounts | 4 | 98 | 60.9 | 162 |
| output files | 1 | 1 | 4.1 | 97 |
| output directories | 0 | 1 | 1.0 | 1 |

## Stage Timing By Stress Case

| Stress Case | Actions | Total Median | Total Mean | Input Mean | Execute Mean | Output Mean | File Inputs Median | Dir Inputs Median | Bind Mounts Median |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| bare_individual_files | 4 | 201.991 | 197.320 | 98.961 | 82.863 | 15.495 | 162 | 0 | 162 |
| generated_file_producer | 1 | 212.916 | 212.916 | 6.274 | 94.837 | 111.805 | 1 | 2 | 4 |
| generated_individual_files | 4 | 68.117 | 86.397 | 38.861 | 40.864 | 6.672 | 98 | 0 | 98 |
| generated_tree_producer | 1 | 297.519 | 297.519 | 5.722 | 115.111 | 176.686 | 1 | 2 | 4 |
| generated_tree_reuse | 8 | 184.265 | 184.733 | 12.492 | 167.101 | 5.140 | 1 | 2 | 4 |
| mixed_all | 1 | 430.595 | 430.595 | 2.240 | 415.347 | 13.007 | 1 | 5 | 7 |
| nested_individual_files | 8 | 199.007 | 191.186 | 122.090 | 58.930 | 10.165 | 98 | 0 | 98 |
| source_dir_tree | 4 | 167.039 | 222.717 | 6.722 | 206.788 | 9.207 | 1 | 2 | 4 |

## Per Action

| Stress Case | Digest | Total | Input | Execute | Output | File Inputs | Dir Inputs | Bind Mounts | Outputs |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| bare_individual_files | `44dcc5c3b269` | 240.099 | 150.886 | 80.252 | 8.960 | 162 | 0 | 162 | 1 file, 1 dir |
| bare_individual_files | `5f8f7c691db8` | 163.884 | 46.240 | 82.552 | 35.092 | 162 | 0 | 162 | 1 file, 1 dir |
| bare_individual_files | `b98f47c49d7c` | 135.549 | 47.560 | 78.113 | 9.875 | 162 | 0 | 162 | 1 file, 1 dir |
| bare_individual_files | `e9f8ff023480` | 249.748 | 151.159 | 90.537 | 8.052 | 162 | 0 | 162 | 1 file, 1 dir |
| generated_file_producer | `bc2e603f3e0b` | 212.916 | 6.274 | 94.837 | 111.805 | 1 | 2 | 4 | 97 file, 0 dir |
| generated_individual_files | `25fb09284361` | 68.441 | 16.453 | 48.601 | 3.386 | 98 | 0 | 98 | 1 file, 1 dir |
| generated_individual_files | `46084f9680b6` | 67.793 | 17.109 | 44.953 | 5.730 | 98 | 0 | 98 | 1 file, 1 dir |
| generated_individual_files | `afeea77762dd` | 141.826 | 105.158 | 25.755 | 10.913 | 98 | 0 | 98 | 1 file, 1 dir |
| generated_individual_files | `c07084d6d06f` | 67.528 | 16.724 | 44.145 | 6.658 | 98 | 0 | 98 | 1 file, 1 dir |
| generated_tree_producer | `2dd6c1952601` | 297.519 | 5.722 | 115.111 | 176.686 | 1 | 2 | 4 | 1 file, 1 dir |
| generated_tree_reuse | `04ba19135981` | 199.525 | 18.134 | 174.178 | 7.214 | 1 | 2 | 4 | 1 file, 1 dir |
| generated_tree_reuse | `127fae4ead86` | 197.363 | 15.278 | 175.416 | 6.668 | 1 | 2 | 4 | 1 file, 1 dir |
| generated_tree_reuse | `762b1b9f7d16` | 182.346 | 7.896 | 166.775 | 7.674 | 1 | 2 | 4 | 1 file, 1 dir |
| generated_tree_reuse | `7b6fae59491f` | 172.342 | 5.106 | 164.142 | 3.094 | 1 | 2 | 4 | 1 file, 1 dir |
| generated_tree_reuse | `7cf4273ba27b` | 235.987 | 22.586 | 209.655 | 3.746 | 1 | 2 | 4 | 1 file, 1 dir |
| generated_tree_reuse | `8c4f3e7cd4e7` | 148.113 | 8.884 | 134.986 | 4.243 | 1 | 2 | 4 | 1 file, 1 dir |
| generated_tree_reuse | `cef27a1e7fc8` | 156.003 | 10.470 | 143.577 | 1.956 | 1 | 2 | 4 | 1 file, 1 dir |
| generated_tree_reuse | `e21d712e10ce` | 186.184 | 11.579 | 168.082 | 6.522 | 1 | 2 | 4 | 1 file, 1 dir |
| mixed_all | `8bf959095e33` | 430.595 | 2.240 | 415.347 | 13.007 | 1 | 5 | 7 | 1 file, 1 dir |
| nested_individual_files | `01e6174c9630` | 218.367 | 137.975 | 70.347 | 10.045 | 98 | 0 | 98 | 1 file, 1 dir |
| nested_individual_files | `0f7a086bdb54` | 127.934 | 76.038 | 37.984 | 13.912 | 98 | 0 | 98 | 1 file, 1 dir |
| nested_individual_files | `330f4a331c1b` | 223.917 | 137.779 | 73.620 | 12.518 | 98 | 0 | 98 | 1 file, 1 dir |
| nested_individual_files | `706c441ffb0a` | 195.246 | 135.956 | 51.840 | 7.450 | 98 | 0 | 98 | 1 file, 1 dir |
| nested_individual_files | `af2be6555144` | 225.186 | 136.178 | 77.147 | 11.860 | 98 | 0 | 98 | 1 file, 1 dir |
| nested_individual_files | `bc0f0e1811b4` | 140.820 | 77.866 | 53.153 | 9.801 | 98 | 0 | 98 | 1 file, 1 dir |
| nested_individual_files | `c7ed90992fa6` | 195.483 | 137.693 | 51.032 | 6.758 | 98 | 0 | 98 | 1 file, 1 dir |
| nested_individual_files | `e1a4ee868ebc` | 202.532 | 137.235 | 56.319 | 8.978 | 98 | 0 | 98 | 1 file, 1 dir |
| source_dir_tree | `13ad68143150` | 146.869 | 4.425 | 136.331 | 6.112 | 1 | 2 | 4 | 1 file, 1 dir |
| source_dir_tree | `7457f233803f` | 180.975 | 4.670 | 165.004 | 11.301 | 1 | 2 | 4 | 1 file, 1 dir |
| source_dir_tree | `835056696b6a` | 153.102 | 5.145 | 134.696 | 13.260 | 1 | 2 | 4 | 1 file, 1 dir |
| source_dir_tree | `ba00a2e83069` | 409.923 | 12.646 | 391.122 | 6.155 | 1 | 2 | 4 | 1 file, 1 dir |

## Runner Timing

These values split the `execute` bucket. `process/io` starts after child setup signals right before `execve`; it includes the action process runtime and stdout/stderr drain.

| Runner Stage | Min | Median | Mean | Max | Share of execute |
| --- | ---: | ---: | ---: | ---: | ---: |
| parent prepare | 0.079 | 0.289 | 6.473 | 29.294 | 5.3% |
| fork | 0.047 | 0.079 | 0.128 | 0.705 | 0.1% |
| child setup | 0.007 | 1.115 | 7.050 | 33.292 | 5.8% |
| process/io | 8.620 | 79.996 | 103.225 | 389.945 | 85.2% |
| wait | 0.002 | 0.005 | 0.007 | 0.033 | 0.0% |
| stdio digest | 0.001 | 0.001 | 0.002 | 0.009 | 0.0% |

| Stress Case | Digest | Parent Prep | Fork | Child Setup | Process/IO | Wait | Stdio Digest | Setup Signaled |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| bare_individual_files | `44dcc5c3b269` | 16.934 | 0.080 | 1.068 | 62.094 | 0.006 | 0.001 | True |
| bare_individual_files | `5f8f7c691db8` | 0.118 | 0.056 | 2.236 | 79.996 | 0.033 | 0.003 | True |
| bare_individual_files | `b98f47c49d7c` | 0.145 | 0.120 | 1.468 | 64.453 | 0.018 | 0.003 | True |
| bare_individual_files | `e9f8ff023480` | 17.050 | 0.051 | 1.345 | 72.006 | 0.010 | 0.001 | True |
| generated_file_producer | `bc2e603f3e0b` | 0.094 | 0.053 | 0.184 | 94.445 | 0.003 | 0.001 | True |
| generated_individual_files | `25fb09284361` | 0.375 | 0.363 | 33.292 | 14.506 | 0.004 | 0.001 | True |
| generated_individual_files | `46084f9680b6` | 28.929 | 0.099 | 5.366 | 10.383 | 0.004 | 0.001 | True |
| generated_individual_files | `afeea77762dd` | 0.131 | 0.071 | 16.848 | 8.620 | 0.007 | 0.002 | True |
| generated_individual_files | `c07084d6d06f` | 0.136 | 0.182 | 25.947 | 17.801 | 0.007 | 0.001 | True |
| generated_tree_producer | `2dd6c1952601` | 0.079 | 0.050 | 0.170 | 114.726 | 0.006 | 0.001 | True |
| generated_tree_reuse | `04ba19135981` | 13.564 | 0.062 | 0.544 | 141.882 | 0.005 | 0.002 | True |
| generated_tree_reuse | `127fae4ead86` | 0.136 | 0.076 | 14.532 | 139.469 | 0.002 | 0.001 | True |
| generated_tree_reuse | `762b1b9f7d16` | 6.776 | 0.199 | 0.092 | 138.442 | 0.002 | 0.001 | True |
| generated_tree_reuse | `7b6fae59491f` | 4.196 | 0.047 | 0.506 | 141.906 | 0.002 | 0.001 | True |
| generated_tree_reuse | `7cf4273ba27b` | 0.101 | 0.070 | 20.514 | 188.797 | 0.019 | 0.001 | True |
| generated_tree_reuse | `8c4f3e7cd4e7` | 7.183 | 0.088 | 0.218 | 127.171 | 0.003 | 0.001 | True |
| generated_tree_reuse | `cef27a1e7fc8` | 9.116 | 0.272 | 0.007 | 134.126 | 0.004 | 0.001 | True |
| generated_tree_reuse | `e21d712e10ce` | 7.840 | 0.050 | 0.370 | 137.072 | 0.004 | 0.001 | True |
| mixed_all | `8bf959095e33` | 0.147 | 0.186 | 24.969 | 389.945 | 0.008 | 0.009 | True |
| nested_individual_files | `01e6174c9630` | 14.469 | 0.128 | 0.940 | 54.607 | 0.004 | 0.001 | True |
| nested_individual_files | `0f7a086bdb54` | 0.274 | 0.079 | 0.535 | 37.031 | 0.003 | 0.001 | True |
| nested_individual_files | `330f4a331c1b` | 29.294 | 0.054 | 1.115 | 43.081 | 0.005 | 0.001 | True |
| nested_individual_files | `706c441ffb0a` | 14.222 | 0.129 | 0.663 | 36.746 | 0.003 | 0.001 | True |
| nested_individual_files | `af2be6555144` | 14.375 | 0.705 | 0.502 | 61.513 | 0.003 | 0.001 | True |
| nested_individual_files | `bc0f0e1811b4` | 0.114 | 0.058 | 13.055 | 39.877 | 0.002 | 0.001 | True |
| nested_individual_files | `c7ed90992fa6` | 14.216 | 0.092 | 1.234 | 35.376 | 0.006 | 0.001 | True |
| nested_individual_files | `e1a4ee868ebc` | 0.289 | 0.185 | 14.821 | 40.970 | 0.005 | 0.001 | True |
| source_dir_tree | `13ad68143150` | 0.081 | 0.066 | 14.431 | 121.608 | 0.005 | 0.004 | True |
| source_dir_tree | `7457f233803f` | 0.088 | 0.182 | 0.070 | 156.111 | 0.004 | 0.001 | True |
| source_dir_tree | `835056696b6a` | 0.118 | 0.056 | 0.229 | 125.625 | 0.017 | 0.002 | True |
| source_dir_tree | `ba00a2e83069` | 0.087 | 0.068 | 21.269 | 369.598 | 0.006 | 0.002 | True |
