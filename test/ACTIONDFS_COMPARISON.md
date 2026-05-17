# Actiondfs VM Stress Comparison

Generated: 2026-05-17 12:15 EDT.

These runs used the same VM stress harness on the same Mac/Colima setup:

- Main baseline: `/Users/dzbarsky/actiond-benchmark`, `ACTIOND_E2E_PORT=8996`
- Actiondfs branch: `/Users/dzbarsky/actiond`, `ACTIOND_E2E_PORT=8997`
- Command shape: `ACTIOND_E2E_KEEP_TMP=1 ACTIOND_KERNEL_DOCKER_CONTEXT=colima tools/e2e.sh vm`
- Main log: `/var/folders/p4/xn8y5q_j24l5xwgwd_jx5c340000gn/T/actiond-vm-e2e.7slcul/darwin-actiond-vm.log`
- Actiondfs log: `/var/folders/p4/xn8y5q_j24l5xwgwd_jx5c340000gn/T/actiond-vm-e2e.iAflsf/darwin-actiond-vm.log`

Both runs completed successfully with 31 parsed Execute records. The first target in each build is Bazel-internal and is not logged as an Execute record by actiond.

## Overall

| Metric | Main | Actiondfs | Change |
| --- | ---: | ---: | ---: |
| Total median | 203.241 ms | 166.285 ms | -18.2% |
| Total mean | 219.087 ms | 182.364 ms | -16.8% |
| Input fetch mean | 56.342 ms | 60.766 ms | +7.9% |
| Execute mean | 135.195 ms | 99.026 ms | -26.8% |
| Output upload mean | 27.549 ms | 22.572 ms | -18.1% |
| Runner process/io mean | 120.231 ms | 84.582 ms | -29.7% |

## Tree-Oriented Cases

These are the cases actiondfs is meant to improve: source directories, generated tree reuse, and mixed inputs. Actiondfs replaces tree directory bind mounts with one manifest filesystem mount plus the runtime mounts.

| Stress case | Main total mean | Actiondfs total mean | Change | Main execute mean | Actiondfs execute mean | Mounts median |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `generated_tree_reuse` | 212.604 ms | 109.508 ms | -48.5% | 191.823 ms | 91.645 ms | 4 -> 2 |
| `source_dir_tree` | 260.597 ms | 224.173 ms | -14.0% | 245.682 ms | 187.041 ms | 4 -> 2 |
| `mixed_all` | 485.424 ms | 434.839 ms | -10.4% | 412.926 ms | 368.346 ms | 7 -> 2 |

The largest win is generated tree reuse. The likely reason is that actiondfs keeps directory metadata in the kernel manifest tree instead of walking tree directories through virtiofs. File contents still come from CAS blobs.

## Other Cases

| Stress case | Main total mean | Actiondfs total mean | Change | Notes |
| --- | ---: | ---: | ---: | --- |
| `generated_tree_producer` | 469.228 ms | 427.633 ms | -8.9% | One sample; output collection dominates. |
| `generated_file_producer` | 201.076 ms | 226.087 ms | +12.4% | One sample; actiondfs is not clearly better here. |
| `bare_individual_files` | 253.832 ms | 212.538 ms | -16.3% | Forced file-input mode, so actiondfs is not used. Treat as run noise. |
| `nested_individual_files` | 193.052 ms | 205.596 ms | +6.5% | Forced file-input mode, so actiondfs is not used. Treat as run noise. |
| `generated_individual_files` | 83.247 ms | 74.264 ms | -10.8% | Forced file-input mode, so actiondfs is not used. Treat as run noise. |

## Notes

- Actiondfs initially failed tree-output actions with `AccessDenied` because actiondfs directories were mounted as `0555`, and overlayfs permission checks blocked output directory creation through the merged tree. Commit `60f18d7` changed actiondfs directories to writable sandbox directories while keeping files read-only.
- This is a single-run comparison. Repeat runs are needed before treating small changes as signal.
- The current actiondfs branch reports tree contents as file inputs in the manifest path, so `file_inputs` counts are not directly comparable with main's `directory_inputs` counts.
