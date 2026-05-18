# LLVM actiondfs Filesystem Comparison

This file records the most recent checked-in LLVM VM smoke comparison. Re-run
it with:

```bash
e2e/llvm_fs_compare.sh
```

The current script compares `actiondfs` and `actiondfs_hybrid32`. Each run
starts a fresh `darwin-actiond serve-vm` worker, runs `bazel clean --expunge`,
builds `@llvm-project//llvm:llvm-tblgen`, and writes parsed timing summaries
under the printed comparison directory. The latest comparison output root is
also written to `/tmp/actiond-last-llvm-fs-compare-path`.

## Latest Checked-In Result

The latest full LLVM comparison in this file is from the pre-hybrid lookup
experiment on 2026-05-17. It compared pure binary search, the former linear
vector implementation, and the now-deleted first-byte bucket implementation.
That run showed `actiondfs` was fastest on LLVM:

| FS              | Bazel elapsed | Actions | Total p50 | Total mean | Input p50 | Fixed/no-wait p50 | Process/IO p50 | Output p50 |
| --------------- | ------------: | ------: | --------: | ---------: | --------: | ----------------: | -------------: | ---------: |
| `actiondfs`     |          605s |   4,469 |   790.350 |    975.741 |     2.036 |             5.473 |        781.330 |      2.644 |
| old linear vec  |          654s |   4,469 |   844.647 |  1,048.301 |     2.138 |             5.745 |        835.586 |      2.764 |
| deleted bucket  |          636s |   4,469 |   836.556 |  1,026.178 |     2.103 |             5.670 |        827.560 |      2.738 |

The bucket filesystem was removed after that result. The stress comparison in
`test/ACTIONDFS_FS_COMPARISON.md` has been updated for the active hybrid
variants; update this file after the next LLVM run.
