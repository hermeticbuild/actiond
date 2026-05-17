# Stress Timing Summary

- Generated: `2026-05-16 22:48:42 EDT`
- Mode: `vm`
- Actions parsed: `3`
- Source log: `/var/folders/p4/xn8y5q_j24l5xwgwd_jx5c340000gn/T/actiond-vm-e2e.s3WFus/darwin-actiond-vm.log`
- Command: `ACTIOND_E2E_KEEP_TMP=1 ACTIOND_E2E_PORT=8992 ACTIOND_KERNEL_DOCKER_CONTEXT=colima tools/e2e.sh vm`
- Bazel elapsed: `7.919s`
- Workload: default stress workspace: 160 bare files, 8 source dirs x 32 files, 2 tree-artifact producer actions, 1 final consumer action

## Stage Timing

All timing values are milliseconds unless noted.

| Stage | Min | Median | Mean | Max | Share of summed total |
| --- | ---: | ---: | ---: | ---: | ---: |
| total | 76.182 | 102.763 | 104.751 | 135.309 | 100.0% |
| input fetch/materialize | 1.579 | 1.610 | 1.813 | 2.250 | 1.7% |
| execute | 68.679 | 93.835 | 94.187 | 120.046 | 89.9% |
| output upload/collect | 5.893 | 7.349 | 8.752 | 13.013 | 8.4% |

## Input And Mount Counts

| Metric | Min | Median | Mean | Max |
| --- | ---: | ---: | ---: | ---: |
| file inputs | 1 | 2 | 2.0 | 3 |
| directory inputs | 2 | 3 | 3.3 | 5 |
| bind mounts | 3 | 4 | 4.3 | 6 |
| output files | 1 | 1 | 1.0 | 1 |
| output directories | 1 | 1 | 1.0 | 1 |

## Per Action

| Digest | Total | Input | Execute | Output | File Inputs | Dir Inputs | Bind Mounts | Outputs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `c4139458b2a6` | 76.182 | 1.610 | 68.679 | 5.893 | 1 | 2 | 3 | 1 file, 1 dir |
| `237887859f8e` | 102.763 | 1.579 | 93.835 | 7.349 | 2 | 3 | 4 | 1 file, 1 dir |
| `48742c47e955` | 135.309 | 2.250 | 120.046 | 13.013 | 3 | 5 | 6 | 1 file, 1 dir |

## Notes

- Directory bind inputs are active in this run: file inputs dropped from 317.7 mean in the previous VM baseline to 2.0 mean, while directory inputs rose from 0.0 to 3.3 mean.
- Mean input fetch/materialization fell from 109.259 ms to 1.813 ms. Mean total action time fell from 151.463 ms to 104.751 ms, and the stress build elapsed time fell from 8.446s to 7.919s.
- The measured execute phase now includes the action process plus chroot/mount setup and is the dominant remaining stage.
