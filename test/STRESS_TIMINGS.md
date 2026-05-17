# Stress Timing Summary

- Generated: `2026-05-16 23:03:53 EDT`
- Mode: `vm`
- Actions parsed: `3`
- Source log: `/var/folders/p4/xn8y5q_j24l5xwgwd_jx5c340000gn/T/actiond-vm-e2e.MX8KDG/darwin-actiond-vm.log`
- Command: `ACTIOND_E2E_KEEP_TMP=1 ACTIOND_E2E_PORT=8997 ACTIOND_KERNEL_DOCKER_CONTEXT=colima tools/e2e.sh vm`
- Bazel elapsed: `7.862s`
- Workload: default stress workspace: 160 bare files, 8 source dirs x 32 files, 2 tree-artifact producer actions, 1 final consumer action

## Stage Timing

All timing values are milliseconds unless noted.

| Stage | Min | Median | Mean | Max | Share of summed total |
| --- | ---: | ---: | ---: | ---: | ---: |
| total | 77.565 | 116.337 | 111.855 | 141.662 | 100.0% |
| input fetch/materialize | 1.944 | 2.180 | 2.130 | 2.267 | 1.9% |
| execute | 68.267 | 104.824 | 99.719 | 126.066 | 89.2% |
| output upload/collect | 7.117 | 9.569 | 10.005 | 13.329 | 8.9% |

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
| `c4139458b2a6` | 77.565 | 2.180 | 68.267 | 7.117 | 1 | 2 | 3 | 1 file, 1 dir |
| `237887859f8e` | 116.337 | 1.944 | 104.824 | 9.569 | 2 | 3 | 4 | 1 file, 1 dir |
| `48742c47e955` | 141.662 | 2.267 | 126.066 | 13.329 | 3 | 5 | 6 | 1 file, 1 dir |

## Runner Timing

These values split the `execute` bucket. `process/io` starts after child setup signals right before `execve`; it includes the action process runtime and stdout/stderr drain.

| Runner Stage | Min | Median | Mean | Max | Share of execute |
| --- | ---: | ---: | ---: | ---: | ---: |
| parent prepare | 0.081 | 0.089 | 0.100 | 0.131 | 0.1% |
| fork | 0.057 | 0.082 | 0.075 | 0.088 | 0.1% |
| child setup | 19.164 | 19.373 | 21.566 | 26.161 | 21.6% |
| process/io | 48.589 | 85.419 | 77.882 | 99.639 | 78.1% |
| wait | 0.004 | 0.005 | 0.008 | 0.015 | 0.0% |
| stdio digest | 0.001 | 0.001 | 0.001 | 0.001 | 0.0% |

| Digest | Parent Prep | Fork | Child Setup | Process/IO | Wait | Stdio Digest | Setup Signaled |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `c4139458b2a6` | 0.131 | 0.082 | 19.373 | 48.589 | 0.004 | 0.001 | True |
| `237887859f8e` | 0.081 | 0.088 | 19.164 | 85.419 | 0.005 | 0.001 | True |
| `48742c47e955` | 0.089 | 0.057 | 26.161 | 99.639 | 0.015 | 0.001 | True |

## Notes

- Directory bind inputs are active: file inputs remain at 2.0 mean and directory inputs at 3.3 mean.
- The remaining `execute` time is not parent allocation, fork, wait, or stdout/stderr digesting. `process/io` is 78.1% of summed execute time, so the action process is spending the time after `execve`.
- Child sandbox setup is roughly 19-26 ms/action in this VM run. That includes namespace setup, loopback setup, recursive-private mount setup, read-only bind mounts, chroot, and privilege drop.
- The investigated guest-local tree-cache variant moved mean execute time back down to roughly 32 ms, but raised mean input fetch/materialization to roughly 80 ms. For this stress shape, host-side tree pre-materialization remains faster overall.
