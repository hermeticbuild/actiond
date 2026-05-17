# Stress Timing Summary

- Generated: `2026-05-16 22:39:11 EDT`
- Mode: `vm`
- Actions parsed: `3`
- Source log: `/var/folders/p4/xn8y5q_j24l5xwgwd_jx5c340000gn/T/actiond-vm-e2e.8SlvLe/darwin-actiond-vm.log`
- Command: `ACTIOND_E2E_KEEP_TMP=1 ACTIOND_E2E_PORT=8991 ACTIOND_KERNEL_DOCKER_CONTEXT=colima tools/e2e.sh vm`
- Bazel elapsed: `8.446s`
- Workload: default stress workspace: 160 bare files, 8 source dirs x 32 files, 2 tree-artifact producer actions, 1 final consumer action

## Stage Timing

All timing values are milliseconds unless noted.

| Stage | Min | Median | Mean | Max | Share of summed total |
| --- | ---: | ---: | ---: | ---: | ---: |
| total | 81.713 | 142.143 | 151.463 | 230.533 | 100.0% |
| input fetch/materialize | 52.117 | 92.741 | 109.259 | 182.918 | 72.1% |
| execute | 22.321 | 36.374 | 31.837 | 36.816 | 21.0% |
| output upload/collect | 7.275 | 11.241 | 10.367 | 12.586 | 6.8% |

## Input And Mount Counts

| Metric | Min | Median | Mean | Max |
| --- | ---: | ---: | ---: | ---: |
| file inputs | 162 | 291 | 317.7 | 500 |
| directory inputs | 0 | 0 | 0.0 | 0 |
| bind mounts | 1 | 1 | 1.0 | 1 |
| output files | 1 | 1 | 1.0 | 1 |
| output directories | 1 | 1 | 1.0 | 1 |

## Per Action

| Digest | Total | Input | Execute | Output | File Inputs | Dir Inputs | Bind Mounts | Outputs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `c4139458b2a6` | 81.713 | 52.117 | 22.321 | 7.275 | 162 | 0 | 1 | 1 file, 1 dir |
| `237887859f8e` | 230.533 | 182.918 | 36.374 | 11.241 | 291 | 0 | 1 | 1 file, 1 dir |
| `48742c47e955` | 142.143 | 92.741 | 36.816 | 12.586 | 500 | 0 | 1 | 1 file, 1 dir |

## Notes

- This run observed `directory_inputs=0` for every action. The stress graph declares tree artifacts, but this execution path expanded them into file inputs rather than using directory bind mounts.
- Input fetch/materialization dominates this run, so execroot construction remains the next performance target.
