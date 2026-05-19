# LLVM VM Smoke Timings

This file records the most recent checked-in LLVM VM smoke run. Re-run it with:

```bash
e2e/run_llvm_vm_smoke.sh
```

The script starts a fresh `darwin-actiond serve-vm` worker, runs `bazel clean
--expunge`, builds `@llvm-project//llvm:llvm-tblgen` from this repo's `@llvm`
module dependency, and writes parsed timing summaries under the printed output
directory. The VM build uses `@llvm//platforms:linux_arm64_musl` for both target
and host platform so generated exec tools run inside the Linux VM without glibc.
The runner also records a mac-host baseline with the same target platform and
the default macOS host platform. The latest output root is written to
`/tmp/actiond-last-llvm-vm-smoke-path`.

Both builds target `@llvm//platforms:linux_arm64_musl`. The VM build also uses
that as the host platform because exec tools run in Linux. The mac-host baseline
keeps the host platform as macOS so local exec tools are runnable on Darwin;
some output paths therefore still contain `darwin_arm64-opt` even though the
compile target triple is Linux musl.

`ACTIOND_LLVM_SMOKE_WARMUP_TARGET=<label>` can run a pre-measure build and parse
only the VM log slice after that warmup. The default is
`//e2e:llvm_exec_warmup`, a `cfg = "exec"` wrapper around
`@llvm-project//llvm:llvm-min-tblgen`. Aquery showed that
`@llvm//runtimes:resource_directory` is not the full VM/mac action-count delta:
the VM `llvm-tblgen` graph has 5,341 configured actions, the mac-host graph has
3,637, and `@llvm//runtimes:resource_directory` has 597. The exec warmup has
2,713 configured actions and the same 2,403 action keys as the Linux exec-config
subset of the VM `llvm-tblgen` graph.

## Latest Checked-In Result

- Generated: `2026-05-18 23:26:53 EDT`
- Command: `ACTIOND_LLVM_SMOKE_MAC_HOST=0 e2e/run_llvm_vm_smoke.sh`
- Output root: `/var/folders/p4/xn8y5q_j24l5xwgwd_jx5c340000gn/T/actiond-llvm-vm-smoke.E0Oh0n`
- Workload: `@llvm-project//llvm:llvm-tblgen`, jobs=8
- VM warmup target: `//e2e:llvm_exec_warmup`
- Target platform: `@llvm//platforms:linux_arm64_musl`
- VM host platform: `@llvm//platforms:linux_arm64_musl`
- Build mode: `-c opt --strip=always --stripopt=--strip-all`
- VM warmup elapsed: `72.421s`
- VM warmup processes: `2207 processes: 190 internal, 2017 remote`
- VM Bazel elapsed: `82.018s`
- VM executions: `2106`
- VM timing records parsed: `2106`
- VM Bazel processes: `2310 processes: 4 action cache hit, 204 internal, 2106 remote`
- Mac-host baseline: not run for this actiondfs CAS path cache check

## Run Comparison

| Metric            | Previous |     New |    Delta |
| ----------------- | -------: | ------: | -------: |
| VM measured build |  88.784s | 82.018s |  -6.766s |
| VM warmup         |  93.737s | 72.421s | -21.316s |

| VM Stage                | Previous Mean |  New Mean |     Delta |
| ----------------------- | ------------: | --------: | --------: |
| total                   |     277.425ms | 250.411ms | -27.014ms |
| input fetch/materialize |       0.376ms |   0.353ms |  -0.023ms |
| execute                 |     274.071ms | 247.156ms | -26.915ms |
| output upload/collect   |       2.978ms |   2.901ms |  -0.077ms |

## VM Stage Timing

All values are milliseconds.

| Stage                   |   Min |    p25 |    p50 |    p75 |      p95 |    Mean |      Max |
| ----------------------- | ----: | -----: | -----: | -----: | -------: | ------: | -------: |
| total                   | 4.643 | 19.381 | 25.705 | 42.167 | 1503.564 | 250.411 | 7605.353 |
| input fetch/materialize | 0.134 |  0.199 |  0.239 |  0.421 |    0.755 |   0.353 |    6.213 |
| execute                 | 4.148 | 18.282 | 24.268 | 40.547 | 1490.656 | 247.156 | 7586.624 |
| output upload/collect   | 0.218 |  0.468 |  0.646 |  1.378 |   12.112 |   2.901 |  796.015 |

## Runner Timing

`process/io` includes the action process runtime, stdout/stderr drain, and lazy
filesystem reads issued by the action through the mounted actiondfs tree.

| Runner Stage   |   Min |    p25 |    p50 |    p75 |      p95 |    Mean |      Max |
| -------------- | ----: | -----: | -----: | -----: | -------: | ------: | -------: |
| parent prepare | 0.068 |  0.106 |  0.133 |  0.202 |    0.435 |   0.192 |    4.053 |
| fork           | 0.178 |  0.427 |  0.514 |  1.177 |    4.619 |   1.176 |    9.647 |
| child setup    | 0.002 |  0.246 |  0.783 |  2.383 |    5.289 |   1.628 |   39.924 |
| process/io     | 0.027 | 15.193 | 21.257 | 36.826 | 1488.136 | 243.999 | 7583.171 |
| wait           | 0.000 |  0.000 |  0.000 |  0.008 |    0.018 |   0.009 |    2.069 |
| stdio digest   | 0.001 |  0.003 |  0.004 |  0.006 |    0.008 |   0.007 |    1.300 |

## VM Bridge Timing

These counters measure the raw TCP-to-vsock pump in `darwin-actiond serve-vm`.
The elapsed column is connection lifetime, not CPU time.

- Bridge connections logged: `2`
- Total client to guest bytes: `28.21 MiB`
- Total guest to client bytes: `37.76 MiB`
- Pump errors: read=`0`, write=`0`

| Bridge Metric          |       Min |       p25 |       p50 |       p75 |       p95 |      Mean |       Max |
| ---------------------- | --------: | --------: | --------: | --------: | --------: | --------: | --------: |
| connection elapsed     | 80133.066 | 80754.928 | 81376.790 | 81998.651 | 82496.141 | 81376.790 | 82620.513 |
| client to guest KiB    |   12102.1 |   13271.7 |   14441.3 |   15610.9 |   16546.6 |   14441.3 |   16780.5 |
| guest to client KiB    |   16172.2 |   17753.6 |   19335.1 |   20916.5 |   22181.7 |   19335.1 |   22498.0 |
| client to guest reads  |      8275 |      8413 |      8551 |      8689 |      8799 |    8551.0 |      8827 |
| client to guest writes |      8274 |      8412 |      8550 |      8688 |      8798 |    8550.0 |      8826 |
| guest to client reads  |     19105 |     19890 |     20674 |     21458 |     22086 |   20674.0 |     22243 |
| guest to client writes |     19104 |     19888 |     20673 |     21458 |     22085 |   20673.0 |     22242 |

## actiondfs Counters

These counters are from `/proc/actiondfs_stats` at the end of the VM run.

| Counter                   |        Value |
| ------------------------- | -----------: |
| mounts                    |         8246 |
| root directory parses     |         8246 |
| cached directory hits     |       173844 |
| cached directory misses   |         5217 |
| lookups                   |      1396390 |
| lookup hits               |       843455 |
| lookup negative           |       552935 |
| blob open attempts        |       457479 |
| blob path cache hits      |       437046 |
| blob path cache misses    |         6970 |
| blob path cache inserts   |         6969 |
| blob path cache evictions |            0 |
| blob path cache races     |            1 |
| node blob cache hits      |        28917 |
| node blob cache misses    |       444016 |
| backing reads             |       419542 |
| backing read bytes        |   1329451317 |
| splice reads              |          148 |
| splice read bytes         |      6084014 |
| mmap calls                |        53243 |
| mmap bytes                | 1901688147968 |
| mmap failures             |            0 |
| directory blob reads      |        13460 |
| directory blob bytes      |      3862752 |

## Notes

The `execute` bucket dominates this workload. With lazy actiondfs inputs, most
filesystem metadata and mapped-file access happen while the child process is
running, so that time appears in `execute`, primarily in `process/io`, rather
than in `input fetch/materialize`.

This run adds a bounded digest-to-CAS-path cache in actiondfs. The cache avoids
repeating the same CAS pathname resolution across per-action mounts while still
opening a per-action backing file, preserving the correct visible actiondfs path
for `mmap`, `read_iter`, and `/proc`.

The raw VM bridge moved about 66 MiB across two long-lived measured
connections, so the dumb TCP-to-vsock pump is not the visible bottleneck in
this run. Most time remains in `process/io`, which includes compiler runtime
plus lazy actiondfs filesystem work issued by the compiler itself.

The mac-host baseline was skipped for this specific actiondfs cache check.
The previous checked-in full comparison had matching measured action counts:
`2310` total processes and `2106` action executions for both VM and mac-host.
