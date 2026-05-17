# Actiondfs VM Stress Comparison

Generated: 2026-05-17 12:41 EDT.

These runs used the same VM stress harness on the same Mac/Colima setup:

- Main baseline: `/Users/dzbarsky/actiond-benchmark`, `ACTIOND_E2E_PORT=8996`
- Flattened actiondfs branch: `/Users/dzbarsky/actiond`, `ACTIOND_E2E_PORT=8997`
- Lazy actiondfs branch: `/Users/dzbarsky/actiond`, `ACTIOND_E2E_PORT=8997`
- Command shape: `ACTIOND_E2E_KEEP_TMP=1 ACTIOND_KERNEL_DOCKER_CONTEXT=colima tools/e2e.sh vm`
- Main log: `/var/folders/p4/xn8y5q_j24l5xwgwd_jx5c340000gn/T/actiond-vm-e2e.7slcul/darwin-actiond-vm.log`
- Flattened actiondfs log: `/var/folders/p4/xn8y5q_j24l5xwgwd_jx5c340000gn/T/actiond-vm-e2e.iAflsf/darwin-actiond-vm.log`
- Lazy actiondfs log: `/var/folders/p4/xn8y5q_j24l5xwgwd_jx5c340000gn/T/actiond-vm-e2e.zGr6kI/darwin-actiond-vm.log`

All runs completed successfully with 31 parsed Execute records. The first target in each build is Bazel-internal and is not logged as an Execute record by actiond.

## Overall

| Metric | Main | Flattened Actiondfs | Lazy Actiondfs | Lazy vs Main |
| --- | ---: | ---: | ---: | ---: |
| Total median | 203.241 ms | 166.285 ms | 176.266 ms | -13.3% |
| Total mean | 219.087 ms | 182.364 ms | 197.171 ms | -10.0% |
| Input fetch mean | 56.342 ms | 60.766 ms | 63.725 ms | +13.1% |
| Execute mean | 135.195 ms | 99.026 ms | 119.029 ms | -12.0% |
| Output upload mean | 27.549 ms | 22.572 ms | 14.417 ms | -47.7% |
| Runner process/io mean | 120.231 ms | 84.582 ms | 100.109 ms | -16.7% |

Lazy actiondfs removes the host-side flattened manifest build and mounts the REAPI input-root digest directly. That makes tree-action input setup very small, but CAS metadata and page reads now happen during action process I/O.

## Tree-Oriented Cases

These are the cases actiondfs is meant to improve: source directories, generated tree reuse, and mixed inputs. Lazy actiondfs uses one actiondfs mount plus one overlay mount for the whole execroot.

| Stress case | Main total mean | Flattened total mean | Lazy total mean | Lazy input mean | Lazy process/io mean | Mounts median |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `generated_tree_reuse` | 212.604 ms | 109.508 ms | 119.614 ms | 3.110 ms | 80.021 ms | 4 -> 2 |
| `source_dir_tree` | 260.597 ms | 224.173 ms | 256.815 ms | 1.553 ms | 233.937 ms | 4 -> 2 |
| `mixed_all` | 485.424 ms | 434.839 ms | 344.006 ms | 0.740 ms | 310.616 ms | 7 -> 2 |

The generated-tree reuse case is still the clearest win versus main. The source-dir case no longer shows a meaningful total win in this single run because the lazy file and metadata reads moved into `process/io`. The mixed case improved substantially, mostly by avoiding a larger set of per-input mounts.

## Other Cases

| Stress case | Main total mean | Flattened total mean | Lazy total mean | Notes |
| --- | ---: | ---: | ---: | --- |
| `generated_tree_producer` | 469.228 ms | 427.633 ms | 164.875 ms | One sample; lazy actiondfs sharply reduces output collection noise in this run. |
| `generated_file_producer` | 201.076 ms | 226.087 ms | 234.473 ms | One sample; output upload dominates. |
| `bare_individual_files` | 253.832 ms | 212.538 ms | 305.444 ms | Forced file-input mode, so actiondfs is not used. Treat as run noise. |
| `nested_individual_files` | 193.052 ms | 205.596 ms | 236.103 ms | Forced file-input mode, so actiondfs is not used. Treat as run noise. |
| `generated_individual_files` | 83.247 ms | 74.264 ms | 68.541 ms | Forced file-input mode, so actiondfs is not used. Treat as run noise. |

## Notes

- Commit `60f18d7` changed actiondfs directories to writable sandbox directories while keeping files read-only so overlayfs can create output paths.
- Lazy actiondfs reports `file_inputs=0` and `directory_inputs=0` for actiondfs actions because the visible input tree is represented by the mounted REAPI root digest instead of flattened counters.
- This is a single-run comparison. Repeat runs are needed before treating small differences as signal.
