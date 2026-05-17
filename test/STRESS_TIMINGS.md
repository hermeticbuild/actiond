# Stress Timing Summary

- Generated: `2026-05-17 08:43:17 EDT`
- Mode: `vm`
- Actions parsed: `27`
- Source log: `/var/folders/p4/xn8y5q_j24l5xwgwd_jx5c340000gn/T/actiond-vm-e2e.vKn38e/darwin-actiond-vm.log`
- Command: `ACTIOND_E2E_KEEP_TMP=1 ACTIOND_E2E_PORT=8997 ACTIOND_KERNEL_DOCKER_CONTEXT=colima tools/e2e.sh vm`
- Bazel elapsed: `9.407s`
- Workload: expanded stress workspace: 4 bare-file actions over 160 flat file inputs forced to file mode, 8 nested-file actions over 96 nested file inputs each forced to file mode, 4 source-directory actions over 8 source dirs x 32 files, 8 generated-tree reuse actions sharing one 256-file output directory, and 1 mixed action

## Stage Timing

All timing values are milliseconds unless noted.

| Stage | Min | Median | Mean | Max | Share of summed total |
| --- | ---: | ---: | ---: | ---: | ---: |
| total | 92.665 | 167.175 | 178.020 | 499.674 | 100.0% |
| input fetch/materialize | 4.206 | 8.121 | 59.123 | 165.684 | 33.2% |
| execute | 6.606 | 122.266 | 103.835 | 478.655 | 58.3% |
| output upload/collect | 1.910 | 10.022 | 15.062 | 173.862 | 8.5% |

## Input And Mount Counts

| Metric | Min | Median | Mean | Max |
| --- | ---: | ---: | ---: | ---: |
| file inputs | 1 | 1 | 53.6 | 162 |
| directory inputs | 0 | 2 | 1.2 | 5 |
| bind mounts | 1 | 3 | 2.2 | 6 |
| output files | 1 | 1 | 1.0 | 1 |
| output directories | 1 | 1 | 1.0 | 1 |

## Stage Timing By Stress Case

| Stress Case | Actions | Total Median | Total Mean | Input Mean | Execute Mean | Output Mean | File Inputs Median | Dir Inputs Median | Bind Mounts Median |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| bare_individual_files | 4 | 188.168 | 190.859 | 164.778 | 13.899 | 12.181 | 162 | 0 | 1 |
| generated_tree_producer | 1 | 308.279 | 308.279 | 5.402 | 129.015 | 173.862 | 1 | 2 | 3 |
| generated_tree_reuse | 9 | 157.695 | 164.262 | 6.355 | 151.926 | 5.981 | 1 | 2 | 3 |
| mixed_all | 1 | 499.674 | 499.674 | 8.121 | 478.655 | 12.898 | 1 | 5 | 6 |
| nested_individual_files | 8 | 134.973 | 131.754 | 105.555 | 14.737 | 11.461 | 98 | 0 | 1 |
| source_dir_tree | 4 | 167.446 | 175.690 | 5.510 | 163.760 | 6.419 | 1 | 2 | 3 |

## Per Action

| Stress Case | Digest | Total | Input | Execute | Output | File Inputs | Dir Inputs | Bind Mounts | Outputs |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| bare_individual_files | `0f3d2125a32f` | 201.744 | 165.341 | 23.821 | 12.581 | 162 | 0 | 1 | 1 file, 1 dir |
| bare_individual_files | `2cd8a2c7a547` | 186.789 | 164.241 | 10.503 | 12.046 | 162 | 0 | 1 | 1 file, 1 dir |
| bare_individual_files | `79c3dad090fe` | 185.355 | 163.848 | 10.261 | 11.244 | 162 | 0 | 1 | 1 file, 1 dir |
| bare_individual_files | `bb3c9bc13d5c` | 189.548 | 165.684 | 11.009 | 12.854 | 162 | 0 | 1 | 1 file, 1 dir |
| generated_tree_producer | `93127bed9297` | 308.279 | 5.402 | 129.015 | 173.862 | 1 | 2 | 3 | 1 file, 1 dir |
| generated_tree_reuse | `1214cb58fbcb` | 157.695 | 7.019 | 147.843 | 2.832 | 1 | 2 | 3 | 1 file, 1 dir |
| generated_tree_reuse | `20f81daf918b` | 215.046 | 8.939 | 200.963 | 5.143 | 1 | 2 | 3 | 1 file, 1 dir |
| generated_tree_reuse | `2bcd2bbb4876` | 157.596 | 5.958 | 146.173 | 5.465 | 1 | 2 | 3 | 1 file, 1 dir |
| generated_tree_reuse | `2bcd2bbb4876` | 92.665 | 6.936 | 83.818 | 1.910 | 1 | 2 | 3 | 1 file, 1 dir |
| generated_tree_reuse | `495d6e6f3304` | 191.813 | 6.124 | 183.379 | 2.310 | 1 | 2 | 3 | 1 file, 1 dir |
| generated_tree_reuse | `4d9695341c01` | 169.006 | 5.314 | 146.581 | 17.111 | 1 | 2 | 3 | 1 file, 1 dir |
| generated_tree_reuse | `858310c1c96b` | 153.102 | 4.206 | 143.303 | 5.592 | 1 | 2 | 3 | 1 file, 1 dir |
| generated_tree_reuse | `988a59714c27` | 210.006 | 6.980 | 193.004 | 10.022 | 1 | 2 | 3 | 1 file, 1 dir |
| generated_tree_reuse | `cd8244ebe0a7` | 131.433 | 5.718 | 122.266 | 3.448 | 1 | 2 | 3 | 1 file, 1 dir |
| mixed_all | `d4921428d93a` | 499.674 | 8.121 | 478.655 | 12.898 | 1 | 5 | 6 | 1 file, 1 dir |
| nested_individual_files | `1f8f880081f2` | 102.488 | 86.210 | 8.846 | 7.432 | 98 | 0 | 1 | 1 file, 1 dir |
| nested_individual_files | `2bb586b94410` | 143.577 | 121.064 | 8.772 | 13.741 | 98 | 0 | 1 | 1 file, 1 dir |
| nested_individual_files | `2c498bcedfd4` | 146.504 | 114.438 | 20.387 | 11.679 | 98 | 0 | 1 | 1 file, 1 dir |
| nested_individual_files | `3ec6afe65ff0` | 144.642 | 121.395 | 8.881 | 14.366 | 98 | 0 | 1 | 1 file, 1 dir |
| nested_individual_files | `6eb8ce303c4c` | 101.543 | 84.921 | 6.606 | 10.015 | 98 | 0 | 1 | 1 file, 1 dir |
| nested_individual_files | `7d527d5baa91` | 126.370 | 96.434 | 18.800 | 11.136 | 98 | 0 | 1 | 1 file, 1 dir |
| nested_individual_files | `f331ac84f85e` | 120.406 | 88.886 | 21.131 | 10.388 | 98 | 0 | 1 | 1 file, 1 dir |
| nested_individual_files | `fb068379cad3` | 168.498 | 131.091 | 24.474 | 12.933 | 98 | 0 | 1 | 1 file, 1 dir |
| source_dir_tree | `869d292263fe` | 160.583 | 4.925 | 152.120 | 3.539 | 1 | 2 | 3 | 1 file, 1 dir |
| source_dir_tree | `a95182e73cb7` | 167.175 | 4.950 | 155.013 | 7.212 | 1 | 2 | 3 | 1 file, 1 dir |
| source_dir_tree | `bd26dbafb6ea` | 167.718 | 6.835 | 152.035 | 8.848 | 1 | 2 | 3 | 1 file, 1 dir |
| source_dir_tree | `cdeec201f617` | 207.283 | 5.331 | 195.875 | 6.077 | 1 | 2 | 3 | 1 file, 1 dir |

## Runner Timing

These values split the `execute` bucket. `process/io` starts after child setup signals right before `execve`; it includes the action process runtime and stdout/stderr drain.

| Runner Stage | Min | Median | Mean | Max | Share of execute |
| --- | ---: | ---: | ---: | ---: | ---: |
| parent prepare | 0.067 | 0.169 | 2.175 | 14.348 | 2.1% |
| fork | 0.049 | 0.079 | 0.109 | 0.406 | 0.1% |
| child setup | 0.001 | 0.568 | 5.465 | 21.127 | 5.3% |
| process/io | 3.691 | 64.799 | 93.648 | 462.319 | 90.2% |
| wait | 0.002 | 0.005 | 0.016 | 0.298 | 0.0% |
| stdio digest | 0.000 | 0.001 | 0.001 | 0.001 | 0.0% |

| Stress Case | Digest | Parent Prep | Fork | Child Setup | Process/IO | Wait | Stdio Digest | Setup Signaled |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| bare_individual_files | `0f3d2125a32f` | 0.120 | 0.061 | 0.793 | 22.321 | 0.298 | 0.000 | True |
| bare_individual_files | `2cd8a2c7a547` | 0.115 | 0.066 | 0.288 | 9.976 | 0.002 | 0.000 | True |
| bare_individual_files | `79c3dad090fe` | 0.117 | 0.095 | 0.682 | 9.200 | 0.006 | 0.001 | True |
| bare_individual_files | `bb3c9bc13d5c` | 0.316 | 0.105 | 0.568 | 9.966 | 0.003 | 0.000 | True |
| generated_tree_producer | `93127bed9297` | 0.067 | 0.195 | 0.078 | 128.563 | 0.004 | 0.000 | True |
| generated_tree_reuse | `1214cb58fbcb` | 0.088 | 0.161 | 12.664 | 134.788 | 0.009 | 0.001 | True |
| generated_tree_reuse | `20f81daf918b` | 0.124 | 0.065 | 21.127 | 179.463 | 0.005 | 0.001 | True |
| generated_tree_reuse | `2bcd2bbb4876` | 0.158 | 0.121 | 18.661 | 64.799 | 0.005 | 0.001 | True |
| generated_tree_reuse | `2bcd2bbb4876` | 0.158 | 0.121 | 18.661 | 64.799 | 0.005 | 0.001 | True |
| generated_tree_reuse | `495d6e6f3304` | 7.895 | 0.065 | 0.454 | 174.872 | 0.006 | 0.001 | True |
| generated_tree_reuse | `4d9695341c01` | 5.516 | 0.055 | 0.224 | 140.708 | 0.005 | 0.001 | True |
| generated_tree_reuse | `858310c1c96b` | 14.348 | 0.058 | 0.120 | 128.583 | 0.006 | 0.001 | True |
| generated_tree_reuse | `988a59714c27` | 0.169 | 0.136 | 12.617 | 179.995 | 0.005 | 0.001 | True |
| generated_tree_reuse | `cd8244ebe0a7` | 5.868 | 0.049 | 0.307 | 115.700 | 0.018 | 0.001 | True |
| mixed_all | `d4921428d93a` | 0.104 | 0.069 | 16.078 | 462.319 | 0.005 | 0.001 | True |
| nested_individual_files | `1f8f880081f2` | 0.258 | 0.066 | 0.188 | 8.263 | 0.006 | 0.000 | True |
| nested_individual_files | `2bb586b94410` | 1.476 | 0.079 | 3.446 | 3.691 | 0.006 | 0.000 | True |
| nested_individual_files | `2c498bcedfd4` | 9.751 | 0.105 | 3.733 | 6.739 | 0.005 | 0.000 | True |
| nested_individual_files | `3ec6afe65ff0` | 1.230 | 0.406 | 3.410 | 3.780 | 0.007 | 0.000 | True |
| nested_individual_files | `6eb8ce303c4c` | 0.449 | 0.079 | 0.168 | 5.863 | 0.002 | 0.000 | True |
| nested_individual_files | `7d527d5baa91` | 9.720 | 0.054 | 0.200 | 8.731 | 0.004 | 0.000 | True |
| nested_individual_files | `f331ac84f85e` | 0.172 | 0.085 | 14.925 | 5.866 | 0.005 | 0.001 | True |
| nested_individual_files | `fb068379cad3` | 0.205 | 0.109 | 17.550 | 6.545 | 0.004 | 0.001 | True |
| source_dir_tree | `869d292263fe` | 0.071 | 0.050 | 0.187 | 151.693 | 0.008 | 0.001 | True |
| source_dir_tree | `a95182e73cb7` | 0.081 | 0.062 | 0.196 | 154.360 | 0.005 | 0.001 | True |
| source_dir_tree | `bd26dbafb6ea` | 0.075 | 0.054 | 0.233 | 151.594 | 0.005 | 0.000 | True |
| source_dir_tree | `cdeec201f617` | 0.074 | 0.388 | 0.001 | 195.313 | 0.002 | 0.000 | True |
