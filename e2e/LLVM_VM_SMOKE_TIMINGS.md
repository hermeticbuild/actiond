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

- Generated: `2026-05-19 08:12:12 EDT`
- Command: `ACTIOND_LLVM_SMOKE_MAC_HOST=0 ACTIOND_VM_CAS_IMAGE_SIZE_MIB=8192 e2e/run_llvm_vm_smoke.sh`
- Output root: `/var/folders/p4/xn8y5q_j24l5xwgwd_jx5c340000gn/T/actiond-llvm-vm-smoke.OePPyw`
- Workload: `@llvm-project//llvm:llvm-tblgen`, jobs=8
- VM warmup target: `//e2e:llvm_exec_warmup`
- Target platform: `@llvm//platforms:linux_arm64_musl`
- VM host platform: `@llvm//platforms:linux_arm64_musl`
- Build mode: `-c opt --strip=always --stripopt=--strip-all`
- VM warmup elapsed: `84.970s`
- VM warmup processes: `2207 processes: 190 internal, 2017 remote`
- VM Bazel elapsed: `79.282s`
- VM executions: `2106`
- VM timing records parsed: `2106`
- VM Bazel processes: `2310 processes: 4 action cache hit, 204 internal, 2106 remote`
- Mac-host baseline: not run for this actiondfs CAS path cache check

## Run Comparison

| Metric            | Previous |     New |    Delta |
| ----------------- | -------: | ------: | -------: |
| VM measured build |  82.018s | 79.282s |  -2.736s |
| VM warmup         |  72.421s | 84.970s | +12.549s |

| VM Stage                | Previous Mean |  New Mean |     Delta |
| ----------------------- | ------------: | --------: | --------: |
| total                   |     250.411ms | 243.955ms |  -6.456ms |
| input fetch/materialize |       0.353ms |   0.321ms |  -0.032ms |
| execute                 |     247.156ms | 240.745ms |  -6.411ms |
| output upload/collect   |       2.901ms |   2.888ms |  -0.013ms |

## VM Stage Timing

All values are milliseconds.

| Stage                   |   Min |    p25 |    p50 |    p75 |      p95 |    Mean |      Max |
| ----------------------- | ----: | -----: | -----: | -----: | -------: | ------: | -------: |
| total                   | 5.671 | 16.957 | 22.115 | 36.263 | 1476.474 | 243.955 | 8123.355 |
| input fetch/materialize | 0.113 |  0.189 |  0.211 |  0.371 |    0.665 |   0.321 |   13.442 |
| execute                 | 3.194 | 15.957 | 21.063 | 35.019 | 1465.645 | 240.745 | 8085.824 |
| output upload/collect   | 0.211 |  0.431 |  0.538 |  1.215 |   12.711 |   2.888 |  625.043 |

## Runner Timing

`process/io` includes the action process runtime, stdout/stderr drain, and lazy
filesystem reads issued by the action through the mounted actiondfs tree.

| Runner Stage   |   Min |    p25 |    p50 |    p75 |      p95 |    Mean |      Max |
| -------------- | ----: | -----: | -----: | -----: | -------: | ------: | -------: |
| parent prepare | 0.070 |  0.102 |  0.119 |  0.166 |    0.369 |   0.167 |    3.285 |
| fork           | 0.172 |  0.399 |  0.469 |  1.018 |    4.515 |   1.105 |   19.531 |
| child setup    | 0.002 |  0.219 |  0.604 |  2.207 |    5.120 |   1.531 |   63.136 |
| process/io     | 1.397 | 13.476 | 18.397 | 31.592 | 1463.508 | 237.829 | 8084.272 |
| wait           | 0.000 |  0.000 |  0.000 |  0.007 |    0.017 |   0.008 |    3.389 |
| stdio digest   | 0.001 |  0.003 |  0.003 |  0.004 |    0.007 |   0.005 |    0.465 |

## VM Bridge Timing

These counters measure the raw TCP-to-vsock pump in `darwin-actiond serve-vm`.
The elapsed column is connection lifetime, not CPU time.

- Bridge connections logged: `2`
- Total client to guest bytes: `28.20 MiB`
- Total guest to client bytes: `37.76 MiB`
- Pump errors: read=`0`, write=`0`

| Bridge Metric          |       Min |       p25 |       p50 |       p75 |       p95 |      Mean |       Max |
| ---------------------- | --------: | --------: | --------: | --------: | --------: | --------: | --------: |
| connection elapsed     | 77897.888 | 78399.125 | 78900.361 | 79401.598 | 79802.587 | 78900.361 | 79902.834 |
| client to guest KiB    |   10713.5 |   12574.7 |   14436.0 |   16297.2 |   17786.2 |   14436.0 |   18158.4 |
| guest to client KiB    |   16692.2 |   18013.8 |   19335.5 |   20657.1 |   21714.5 |   19335.5 |   21978.8 |
| client to guest reads  |      8297 |      8448 |      8598 |      8749 |      8870 |    8598.5 |      8900 |
| client to guest writes |      8296 |      8447 |      8598 |      8748 |      8869 |    8597.5 |      8899 |
| guest to client reads  |     19728 |     20500 |     21272 |     22043 |     22661 |   21271.5 |     22815 |
| guest to client writes |     19727 |     20499 |     21270 |     22042 |     22660 |   21270.5 |     22814 |

## actiondfs Counters

These counters are from `/proc/actiondfs_stats` at the end of the VM run.

| Counter                   |        Value |
| ------------------------- | -----------: |
| mounts                    |         8246 |
| root directory parses     |         8246 |
| cached directory hits     |       173842 |
| cached directory misses   |         5219 |
| lookups                   |      1396390 |
| lookup hits               |       843455 |
| lookup negative           |       552935 |
| blob open attempts        |       457481 |
| blob path cache hits      |       437047 |
| blob path cache misses    |         6969 |
| blob path cache inserts   |         6969 |
| blob path cache evictions |            0 |
| blob path cache races     |            0 |
| node blob cache hits      |        28917 |
| node blob cache misses    |       444016 |
| backing reads             |       419542 |
| backing read bytes        |   1329451317 |
| splice reads              |          148 |
| splice read bytes         |      6084014 |
| mmap calls                |        53243 |
| mmap bytes                | 1901688147968 |
| mmap failures             |            0 |
| directory blob reads      |        13462 |
| directory blob bytes      |      3861312 |

## Notes

The `execute` bucket dominates this workload. With lazy actiondfs inputs, most
filesystem metadata and mapped-file access happen while the child process is
running, so that time appears in `execute`, primarily in `process/io`, rather
than in `input fetch/materialize`.

This run makes the bounded digest-to-CAS-path cache use an RCU hit path. The
cache still avoids repeating CAS pathname resolution across per-action mounts,
and it still opens a per-action backing file to preserve the correct visible
actiondfs path for `mmap`, `read_iter`, and `/proc`. The measured build used an
8 GiB temporary ext4 CAS image because this machine was low on free disk during
the run; action counts stayed the same as the previous checked-in smoke.

The raw VM bridge moved about 66 MiB across two long-lived measured
connections, so the dumb TCP-to-vsock pump is not the visible bottleneck in
this run. Most time remains in `process/io`, which includes compiler runtime
plus lazy actiondfs filesystem work issued by the compiler itself.

The mac-host baseline was skipped for this specific actiondfs cache check.
The previous checked-in full comparison had matching measured action counts:
`2310` total processes and `2106` action executions for both VM and mac-host.
