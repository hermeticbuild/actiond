# Stress Timing Summary

- Generated: `2026-05-17 08:49:21 EDT`
- Mode: `vm`
- Execute records parsed: `31`
- Unique action digests: `31`
- Source log: `/var/folders/p4/xn8y5q_j24l5xwgwd_jx5c340000gn/T/actiond-vm-e2e.TCbnEB/darwin-actiond-vm.log`
- Command: `ACTIOND_E2E_KEEP_TMP=1 ACTIOND_E2E_PORT=8997 ACTIOND_KERNEL_DOCKER_CONTEXT=colima tools/e2e.sh vm`
- Bazel elapsed: `10.191s`
- Workload: expanded stress workspace: 4 bare-file actions over 160 flat source files forced to file mode, 8 nested-file actions over 96 nested source files each forced to file mode, 1 generated-file producer plus 4 generated-file consumers over 96 generated nested files forced to file mode, 4 source-directory actions over 8 source dirs x 32 files, 8 generated-tree reuse actions sharing one 256-file output directory, and 1 mixed action

## Stage Timing

All timing values are milliseconds unless noted.

| Stage | Min | Median | Mean | Max | Share of summed total |
| --- | ---: | ---: | ---: | ---: | ---: |
| total | 75.687 | 175.405 | 215.055 | 523.439 | 100.0% |
| input fetch/materialize | 1.964 | 17.421 | 79.700 | 250.311 | 37.1% |
| execute | 7.913 | 48.376 | 102.080 | 403.891 | 47.5% |
| output upload/collect | 1.873 | 11.414 | 33.274 | 380.595 | 15.5% |

## Input And Mount Counts

| Metric | Min | Median | Mean | Max |
| --- | ---: | ---: | ---: | ---: |
| file inputs | 1 | 98 | 59.3 | 162 |
| directory inputs | 0 | 0 | 1.1 | 5 |
| bind mounts | 1 | 1 | 2.1 | 6 |
| output files | 1 | 1 | 4.1 | 97 |
| output directories | 0 | 1 | 1.0 | 1 |

## Stage Timing By Stress Case

| Stress Case | Actions | Total Median | Total Mean | Input Mean | Execute Mean | Output Mean | File Inputs Median | Dir Inputs Median | Bind Mounts Median |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| bare_individual_files | 4 | 276.006 | 238.428 | 207.663 | 16.846 | 13.919 | 162 | 0 | 1 |
| generated_file_producer | 1 | 328.966 | 328.966 | 5.996 | 115.115 | 207.855 | 1 | 2 | 3 |
| generated_individual_files | 4 | 92.246 | 101.202 | 17.933 | 37.700 | 45.569 | 98 | 0 | 1 |
| generated_tree_producer | 1 | 523.439 | 523.439 | 8.091 | 134.753 | 380.595 | 1 | 2 | 3 |
| generated_tree_reuse | 8 | 151.763 | 171.251 | 8.682 | 152.070 | 10.499 | 1 | 2 | 3 |
| mixed_all | 1 | 440.284 | 440.284 | 26.469 | 403.891 | 9.925 | 1 | 5 | 6 |
| nested_individual_files | 8 | 252.512 | 218.083 | 179.796 | 27.561 | 10.725 | 98 | 0 | 1 |
| source_dir_tree | 4 | 226.492 | 225.204 | 4.987 | 213.874 | 6.343 | 1 | 2 | 3 |

## Per Action

| Stress Case | Digest | Total | Input | Execute | Output | File Inputs | Dir Inputs | Bind Mounts | Outputs |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| bare_individual_files | `44dcc5c3b269` | 276.715 | 248.024 | 10.245 | 18.446 | 162 | 0 | 1 | 1 file, 1 dir |
| bare_individual_files | `5f8f7c691db8` | 276.367 | 249.480 | 12.213 | 14.674 | 162 | 0 | 1 | 1 file, 1 dir |
| bare_individual_files | `b98f47c49d7c` | 124.986 | 84.644 | 34.298 | 6.043 | 162 | 0 | 1 | 1 file, 1 dir |
| bare_individual_files | `e9f8ff023480` | 275.645 | 248.503 | 10.629 | 16.513 | 162 | 0 | 1 | 1 file, 1 dir |
| generated_file_producer | `bc2e603f3e0b` | 328.966 | 5.996 | 115.115 | 207.855 | 1 | 2 | 3 | 97 file, 0 dir |
| generated_individual_files | `25fb09284361` | 144.629 | 20.897 | 7.913 | 115.817 | 98 | 0 | 1 | 1 file, 1 dir |
| generated_individual_files | `46084f9680b6` | 75.687 | 17.421 | 48.376 | 9.889 | 98 | 0 | 1 | 1 file, 1 dir |
| generated_individual_files | `afeea77762dd` | 104.266 | 16.603 | 47.443 | 40.220 | 98 | 0 | 1 | 1 file, 1 dir |
| generated_individual_files | `c07084d6d06f` | 80.226 | 16.812 | 47.065 | 16.348 | 98 | 0 | 1 | 1 file, 1 dir |
| generated_tree_producer | `2dd6c1952601` | 523.439 | 8.091 | 134.753 | 380.595 | 1 | 2 | 3 | 1 file, 1 dir |
| generated_tree_reuse | `04ba19135981` | 150.351 | 7.295 | 130.363 | 12.693 | 1 | 2 | 3 | 1 file, 1 dir |
| generated_tree_reuse | `127fae4ead86` | 214.514 | 6.822 | 205.818 | 1.873 | 1 | 2 | 3 | 1 file, 1 dir |
| generated_tree_reuse | `762b1b9f7d16` | 240.382 | 17.839 | 211.222 | 11.320 | 1 | 2 | 3 | 1 file, 1 dir |
| generated_tree_reuse | `7b6fae59491f` | 171.634 | 7.585 | 148.465 | 15.584 | 1 | 2 | 3 | 1 file, 1 dir |
| generated_tree_reuse | `7cf4273ba27b` | 147.176 | 6.759 | 128.901 | 11.516 | 1 | 2 | 3 | 1 file, 1 dir |
| generated_tree_reuse | `8c4f3e7cd4e7` | 153.175 | 9.250 | 132.511 | 11.414 | 1 | 2 | 3 | 1 file, 1 dir |
| generated_tree_reuse | `cef27a1e7fc8` | 147.064 | 6.466 | 129.190 | 11.407 | 1 | 2 | 3 | 1 file, 1 dir |
| generated_tree_reuse | `e21d712e10ce` | 145.711 | 7.441 | 130.087 | 8.182 | 1 | 2 | 3 | 1 file, 1 dir |
| mixed_all | `8bf959095e33` | 440.284 | 26.469 | 403.891 | 9.925 | 1 | 5 | 6 | 1 file, 1 dir |
| nested_individual_files | `01e6174c9630` | 131.879 | 94.585 | 30.354 | 6.939 | 98 | 0 | 1 | 1 file, 1 dir |
| nested_individual_files | `0f7a086bdb54` | 296.493 | 250.311 | 31.201 | 14.981 | 98 | 0 | 1 | 1 file, 1 dir |
| nested_individual_files | `330f4a331c1b` | 105.995 | 79.371 | 19.591 | 7.032 | 98 | 0 | 1 | 1 file, 1 dir |
| nested_individual_files | `706c441ffb0a` | 286.391 | 247.646 | 26.031 | 12.713 | 98 | 0 | 1 | 1 file, 1 dir |
| nested_individual_files | `af2be6555144` | 298.784 | 248.070 | 36.546 | 14.168 | 98 | 0 | 1 | 1 file, 1 dir |
| nested_individual_files | `bc0f0e1811b4` | 120.100 | 89.734 | 23.826 | 6.540 | 98 | 0 | 1 | 1 file, 1 dir |
| nested_individual_files | `c7ed90992fa6` | 249.460 | 212.019 | 27.995 | 9.446 | 98 | 0 | 1 | 1 file, 1 dir |
| nested_individual_files | `e1a4ee868ebc` | 255.565 | 216.634 | 24.948 | 13.983 | 98 | 0 | 1 | 1 file, 1 dir |
| source_dir_tree | `13ad68143150` | 277.579 | 3.547 | 269.252 | 4.779 | 1 | 2 | 3 | 1 file, 1 dir |
| source_dir_tree | `7457f233803f` | 145.430 | 4.953 | 134.395 | 6.082 | 1 | 2 | 3 | 1 file, 1 dir |
| source_dir_tree | `835056696b6a` | 302.402 | 1.964 | 293.171 | 7.267 | 1 | 2 | 3 | 1 file, 1 dir |
| source_dir_tree | `ba00a2e83069` | 175.405 | 9.482 | 158.677 | 7.246 | 1 | 2 | 3 | 1 file, 1 dir |

## Runner Timing

These values split the `execute` bucket. `process/io` starts after child setup signals right before `execve`; it includes the action process runtime and stdout/stderr drain.

| Runner Stage | Min | Median | Mean | Max | Share of execute |
| --- | ---: | ---: | ---: | ---: | ---: |
| parent prepare | 0.070 | 0.302 | 9.014 | 34.709 | 8.8% |
| fork | 0.036 | 0.078 | 0.235 | 3.609 | 0.2% |
| child setup | 0.003 | 0.260 | 5.107 | 36.066 | 5.0% |
| process/io | 2.733 | 15.048 | 86.919 | 379.723 | 85.1% |
| wait | 0.002 | 0.005 | 0.007 | 0.051 | 0.0% |
| stdio digest | 0.000 | 0.000 | 0.000 | 0.001 | 0.0% |

| Stress Case | Digest | Parent Prep | Fork | Child Setup | Process/IO | Wait | Stdio Digest | Setup Signaled |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| bare_individual_files | `44dcc5c3b269` | 0.140 | 0.350 | 0.003 | 9.663 | 0.007 | 0.000 | True |
| bare_individual_files | `5f8f7c691db8` | 0.162 | 0.097 | 0.268 | 11.606 | 0.002 | 0.000 | True |
| bare_individual_files | `b98f47c49d7c` | 0.120 | 0.066 | 27.607 | 6.439 | 0.004 | 0.000 | True |
| bare_individual_files | `e9f8ff023480` | 0.209 | 0.060 | 0.309 | 9.780 | 0.004 | 0.001 | True |
| generated_file_producer | `bc2e603f3e0b` | 0.145 | 0.036 | 0.206 | 114.641 | 0.007 | 0.001 | True |
| generated_individual_files | `25fb09284361` | 0.132 | 0.119 | 0.364 | 7.226 | 0.006 | 0.000 | True |
| generated_individual_files | `46084f9680b6` | 34.198 | 0.069 | 5.268 | 8.794 | 0.002 | 0.000 | True |
| generated_individual_files | `afeea77762dd` | 0.115 | 0.078 | 36.066 | 11.023 | 0.006 | 0.001 | True |
| generated_individual_files | `c07084d6d06f` | 34.709 | 3.609 | 0.164 | 8.500 | 0.008 | 0.001 | True |
| generated_tree_producer | `2dd6c1952601` | 0.087 | 0.151 | 0.182 | 134.272 | 0.002 | 0.000 | True |
| generated_tree_reuse | `04ba19135981` | 14.438 | 0.083 | 0.236 | 115.558 | 0.002 | 0.000 | True |
| generated_tree_reuse | `127fae4ead86` | 14.443 | 0.062 | 0.088 | 168.946 | 0.005 | 0.001 | True |
| generated_tree_reuse | `762b1b9f7d16` | 0.224 | 0.077 | 19.424 | 191.431 | 0.002 | 0.000 | True |
| generated_tree_reuse | `7b6fae59491f` | 15.070 | 0.041 | 0.420 | 132.873 | 0.007 | 0.001 | True |
| generated_tree_reuse | `7cf4273ba27b` | 14.588 | 0.066 | 0.375 | 113.786 | 0.006 | 0.001 | True |
| generated_tree_reuse | `8c4f3e7cd4e7` | 0.273 | 0.090 | 16.532 | 115.566 | 0.002 | 0.000 | True |
| generated_tree_reuse | `cef27a1e7fc8` | 14.062 | 0.121 | 0.174 | 114.779 | 0.004 | 0.000 | True |
| generated_tree_reuse | `e21d712e10ce` | 14.420 | 0.062 | 0.441 | 115.010 | 0.005 | 0.001 | True |
| mixed_all | `8bf959095e33` | 0.214 | 0.099 | 23.786 | 379.723 | 0.006 | 0.001 | True |
| nested_individual_files | `01e6174c9630` | 22.395 | 0.066 | 0.168 | 7.660 | 0.004 | 0.000 | True |
| nested_individual_files | `0f7a086bdb54` | 16.274 | 0.074 | 0.523 | 14.278 | 0.002 | 0.000 | True |
| nested_individual_files | `330f4a331c1b` | 13.292 | 0.044 | 3.447 | 2.733 | 0.017 | 0.000 | True |
| nested_individual_files | `706c441ffb0a` | 19.098 | 0.305 | 0.004 | 6.465 | 0.004 | 0.001 | True |
| nested_individual_files | `af2be6555144` | 0.172 | 0.113 | 21.158 | 15.048 | 0.003 | 0.000 | True |
| nested_individual_files | `bc0f0e1811b4` | 17.430 | 0.116 | 0.130 | 6.013 | 0.004 | 0.001 | True |
| nested_individual_files | `c7ed90992fa6` | 18.327 | 0.091 | 0.260 | 9.257 | 0.004 | 0.000 | True |
| nested_individual_files | `e1a4ee868ebc` | 14.119 | 0.816 | 0.073 | 9.887 | 0.006 | 0.000 | True |
| source_dir_tree | `13ad68143150` | 0.144 | 0.077 | 0.127 | 268.822 | 0.007 | 0.001 | True |
| source_dir_tree | `7457f233803f` | 0.302 | 0.118 | 0.145 | 133.638 | 0.051 | 0.001 | True |
| source_dir_tree | `835056696b6a` | 0.070 | 0.066 | 0.167 | 292.792 | 0.007 | 0.001 | True |
| source_dir_tree | `ba00a2e83069` | 0.075 | 0.054 | 0.187 | 158.294 | 0.005 | 0.000 | True |
