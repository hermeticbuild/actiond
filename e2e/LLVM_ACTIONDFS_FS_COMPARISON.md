# LLVM actiondfs Filesystem Comparison

Generated from an `@llvm-project//llvm:llvm-tblgen` VM smoke on 2026-05-17.
Each row used a fresh `darwin-actiond serve-vm` root, `bazel clean --expunge`,
8 Bazel jobs, 8 VM CPUs, and a 4096 MiB VM.

Raw summaries for this run were written under:
`/var/folders/p4/xn8y5q_j24l5xwgwd_jx5c340000gn/T/actiond-llvm-fs-compare.Lj0F6l`.

## Summary

`actiondfs` was fastest on this LLVM smoke. The synthetic stress workspace still
favored `actiondfs_vec`, so this should be treated as workload-dependent. On
LLVM, lookup strategy is not the dominant cost: input materialization p50 stays
around 2 ms for all three variants, and process/runtime work dominates the
execute bucket.

| FS                 | Bazel elapsed | Actions | Total p50 | Total mean | Input p50 | Fixed/no-wait p50 | Process/IO p50 | Output p50 |
| ------------------ | ------------: | ------: | --------: | ---------: | --------: | ----------------: | -------------: | ---------: |
| `actiondfs_vec`    |          654s |    4469 |   844.647 |   1048.301 |     2.138 |             5.745 |        835.586 |      2.764 |
| `actiondfs`        |          605s |    4469 |   790.350 |    975.741 |     2.036 |             5.473 |        781.330 |      2.644 |
| `actiondfs_bucket` |          636s |    4469 |   836.556 |   1026.178 |     2.103 |             5.670 |        827.560 |      2.738 |

## Stage Timings

All timing values are milliseconds.

### actiondfs_vec

| Stage                   |    Min |     p25 |     p50 |     p75 |      p95 |     Mean |       Max | Share |
| ----------------------- | -----: | ------: | ------: | ------: | -------: | -------: | --------: | ----: |
| total                   | 43.448 | 742.099 | 844.647 | 998.343 | 2530.351 | 1048.301 | 27775.838 | 100.0% |
| input fetch/materialize |  1.014 |   1.899 |   2.138 |   2.522 |    4.008 |    2.464 |    66.774 |   0.2% |
| execute                 | 14.491 | 736.302 | 839.506 | 992.341 | 2515.286 | 1040.718 | 27661.922 |  99.3% |
| output upload/collect   |  0.552 |   2.307 |   2.764 |   4.300 |   12.324 |    5.119 |  1450.950 |   0.5% |

### actiondfs

| Stage                   |    Min |     p25 |     p50 |     p75 |      p95 |    Mean |       Max | Share |
| ----------------------- | -----: | ------: | ------: | ------: | -------: | ------: | --------: | ----: |
| total                   | 33.661 | 698.113 | 790.350 | 921.930 | 2378.795 | 975.741 | 26616.693 | 100.0% |
| input fetch/materialize |  0.966 |   1.824 |   2.036 |   2.372 |    3.622 |   2.271 |    70.852 |   0.2% |
| execute                 | 27.186 | 692.565 | 785.205 | 917.028 | 2365.925 | 968.446 | 26507.656 |  99.3% |
| output upload/collect   |  0.555 |   2.213 |   2.644 |   4.437 |   12.121 |   5.024 |  1324.548 |   0.5% |

### actiondfs_bucket

| Stage                   |    Min |     p25 |     p50 |     p75 |      p95 |     Mean |       Max | Share |
| ----------------------- | -----: | ------: | ------: | ------: | -------: | -------: | --------: | ----: |
| total                   | 52.874 | 734.013 | 836.556 | 979.571 | 2444.495 | 1026.178 | 27495.595 | 100.0% |
| input fetch/materialize |  1.122 |   1.893 |   2.103 |   2.420 |    3.735 |    2.382 |    60.301 |   0.2% |
| execute                 | 22.596 | 728.485 | 831.395 | 974.412 | 2430.999 | 1018.651 | 27383.623 |  99.3% |
| output upload/collect   |  1.054 |   2.290 |   2.738 |   4.348 |   12.232 |    5.144 |  1659.955 |   0.5% |

## Runner Timings

`process/io` starts after child setup signals right before `execve`; it includes
the action process runtime and stdout/stderr drain.

### actiondfs_vec

| Runner Stage   |    Min |     p25 |     p50 |     p75 |      p95 |     Mean |       Max | Share |
| -------------- | -----: | ------: | ------: | ------: | -------: | -------: | --------: | ----: |
| parent prepare |  0.065 |   0.097 |   0.114 |   0.141 |    0.295 |    0.175 |    26.193 |  0.0% |
| fork           |  0.079 |   0.232 |   0.278 |   0.332 |    0.462 |    0.296 |     3.004 |  0.0% |
| child setup    |  0.003 |   0.193 |   0.215 |   0.259 |    0.549 |    0.285 |     5.773 |  0.0% |
| process/io     | 13.622 | 732.585 | 835.586 | 987.820 | 2447.518 | 1029.138 | 27652.703 | 98.9% |
| wait           |  0.004 |   2.504 |   3.235 |   4.722 |   63.573 |   10.764 |   230.536 |  1.0% |
| stdio digest   |  0.001 |   0.002 |   0.002 |   0.003 |    0.005 |    0.003 |     0.444 |  0.0% |

### actiondfs

| Runner Stage   |    Min |     p25 |     p50 |     p75 |      p95 |    Mean |       Max | Share |
| -------------- | -----: | ------: | ------: | ------: | -------: | ------: | --------: | ----: |
| parent prepare |  0.065 |   0.098 |   0.112 |   0.143 |    0.356 |   0.161 |    14.119 |  0.0% |
| fork           |  0.067 |   0.212 |   0.242 |   0.271 |    0.428 |   0.261 |     3.518 |  0.0% |
| child setup    |  0.003 |   0.183 |   0.203 |   0.237 |    0.462 |   0.253 |     6.182 |  0.0% |
| process/io     | 26.460 | 688.848 | 781.330 | 911.485 | 2304.036 | 957.388 | 26498.149 | 98.9% |
| wait           |  0.005 |   2.411 |   3.148 |   4.607 |   62.586 |  10.323 |   211.292 |  1.1% |
| stdio digest   |  0.001 |   0.002 |   0.002 |   0.003 |    0.004 |   0.003 |     0.679 |  0.0% |

### actiondfs_bucket

| Runner Stage   |    Min |     p25 |     p50 |     p75 |      p95 |     Mean |       Max | Share |
| -------------- | -----: | ------: | ------: | ------: | -------: | -------: | --------: | ----: |
| parent prepare |  0.058 |   0.097 |   0.113 |   0.140 |    0.304 |    0.151 |    24.192 |  0.0% |
| fork           |  0.076 |   0.178 |   0.215 |   0.260 |    0.371 |    0.235 |     4.300 |  0.0% |
| child setup    |  0.003 |   0.190 |   0.212 |   0.252 |    0.531 |    0.273 |     4.543 |  0.0% |
| process/io     | 21.205 | 725.227 | 827.560 | 970.039 | 2367.631 | 1007.472 | 27374.532 | 98.9% |
| wait           |  0.234 |   2.443 |   3.190 |   4.622 |   63.117 |   10.459 |   188.039 |  1.0% |
| stdio digest   |  0.001 |   0.002 |   0.002 |   0.003 |    0.004 |    0.003 |     0.661 |  0.0% |

## Filesystem Notes

The first-byte bucket experiment did not win here. Its expected benefit is
smaller local scans after jumping into a sorted child range, but common source
tree naming patterns concentrate many entries under the same first byte and add
bucket construction work when loading each REAPI directory.

The useful filesystem-design takeaway from ext4/XFS/btrfs-style directory
indexes is to make indexing adaptive. For actiondfs, immutable in-memory child
lists plus VFS dcache already cover common repeated lookups, so the next likely
candidate is a hash index only for large or hot directories, not a fixed
per-directory bucket table.
