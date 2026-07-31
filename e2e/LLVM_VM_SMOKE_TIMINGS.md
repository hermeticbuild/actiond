# LLVM VM Smoke Timings

This file records the most recent checked-in LLVM VM smoke run. Re-run it with:

```bash
e2e/run_llvm_vm_smoke.sh
```

The script starts a fresh `darwin-actiond serve-vm` worker, runs `bazel clean
--expunge` in the LLVM smoke output base, builds
`@llvm-project//llvm:llvm-tblgen` from this repo's `@llvm` module dependency,
and writes parsed timing summaries under the printed output directory. The VM
build uses `@llvm//platforms:linux_arm64_musl` for both target and host platform
so generated exec tools run inside the Linux VM without glibc. The mac-host
baseline keeps the host platform as default macOS so local exec tools are
runnable on Darwin.

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

- Generated: `2026-07-31 15:21:16 EDT`
- Command: `ACTIOND_BAZEL_BUILD_FLAGS="--jobs=32 --distdir=/private/tmp/actiond-audit-distdir --override_repository=llvm++osx+macos_sdk=/private/tmp/actiond-audit-macos-sdk" ACTIOND_LLVM_SMOKE_MAC_HOST=0 e2e/run_llvm_vm_smoke.sh`
- Output root: `/var/folders/p4/xn8y5q_j24l5xwgwd_jx5c340000gn/T/actiond-llvm-vm-smoke.r89W0G`
- Workload: `@llvm-project//llvm:llvm-tblgen`, jobs=8
- VM warmup target: `//e2e:llvm_exec_warmup`
- Target and VM host platform: `@llvm//platforms:linux_arm64_musl`
- Build mode: `-c opt --strip=always --stripopt=--strip-all`
- VM warmup: `137.064s`; `2207 processes: 190 internal, 2017 remote`
- Measured VM build: `151.585s`; `2310 processes: 4 action cache hit, 204 internal, 2106 remote`
- Measured executions and timing records: `2106`
- Mac-host baseline: not run (`ACTIOND_LLVM_SMOKE_MAC_HOST=0`)

The previous checked-in run used the same jobs=8 and completed the warmup in
`102.136s` and measured build in `108.831s`. The current warmup is 34.2% slower
and the measured build is 39.3% slower with the same 2,106 measured actions.
An immediate unchanged-code repeat took `166.200s` for warmup and `196.180s`
for the measured build while unrelated local C++ compilers and other processes
were active. Compared with the previous run, 91.9% of the summed action-time
increase was action `process/io`, while actiondfs reads, opens, lookups, and
errors were unchanged. Compare matched CI actiond/native timings when host CPU
and memory contention affect local VM measurements.

An earlier checked-in run completed the warmup in `106.289s` and the measured
build in `138.481s`. A run before action isolation completed the warmup in
`88.364s` and the measured build in `91.490s`. An intermediate action-isolation
run took `256.834s` for warmup and `140.328s` for the measured build.

## Filesystem Comparison With Prior Checked-In Run

Counters include both warmup and measured builds.

| Counter                              | Prior       | Current     |
| ------------------------------------ | ----------: | ----------: |
| actiondfs mounts                     |       4,123 |       4,122 |
| root directory parses                |       1,407 |       1,406 |
| cached directory hits                |     163,045 |     163,001 |
| cached directory misses              |       6,620 |       6,616 |
| directory blob reads                 |       6,619 |       6,615 |
| staged ensure-directory calls        |      16,001 |      15,996 |
| staged ensure-directory components   |          16 |          16 |
| staged ensure-directory existing     |           0 |           0 |
| staged ensure-directory created      |          16 |          16 |
| staged parent dentry hits            |      15,985 |      15,980 |
| blob-path cache hits                 |     460,970 |     460,692 |
| blob-path cache misses               |       6,970 |       6,883 |
| blob-path cache evictions            |           0 |           0 |
| blob-path cache insertion races      |           0 |           0 |
| staged backing open attempts         |      15,828 |      15,825 |
| staged backing open lookup           | 0.961 ms    | 0.600 ms    |
| staged `copy_file_range` successes   |       3,828 |       3,828 |
| staged `copy_file_range` fallbacks   |           0 |           0 |

The workload retained the same 2,017 warmup actions and 2,106 measured actions.
Root-directory parsing, directory blob reads, staged parent-directory reuse, and
blob-path cache behavior remain close to the previous checked-in result.

## VM Stage Timing

All timing values are milliseconds.

| Stage                 |   Min |    p25 |    p50 |    p75 |      p95 |    Mean |       Max |
| --------------------- | ----: | -----: | -----: | -----: | -------: | ------: | --------: |
| total                 | 10.467 | 30.075 | 47.931 | 177.485 | 2691.978 | 503.038 | 17790.613 |
| input fetch/setup     |  0.428 |  0.599 |  0.706 |   1.178 |    5.151 |   2.216 |   148.489 |
| execute               |  8.838 | 28.178 | 45.168 | 166.368 | 2688.531 | 499.166 | 17782.837 |
| output upload/collect |  0.022 |  0.145 |  0.287 |   1.664 |    5.737 |   1.655 |   175.722 |

## Runner Timing

`child setup` includes successful `execve`. `process/io` starts after
close-on-exec confirmation and includes action execution, stdout/stderr drain,
and lazy actiondfs input reads. All timing values are milliseconds.

| Runner Stage   |   Min |    p25 |    p50 |    p75 |      p95 |    Mean |       Max |
| -------------- | ----: | -----: | -----: | -----: | -------: | ------: | --------: |
| parent prepare | 0.058 |  0.105 |  0.130 |   0.183 |    0.760 |   0.713 |   125.178 |
| fork           | 0.560 |  0.904 |  1.086 |   2.362 |   16.226 |   4.886 |   305.062 |
| child setup    | 0.009 |  3.571 |  5.878 |  11.076 |   49.143 |  13.804 |   463.233 |
| process/io     | 2.352 | 19.521 | 31.235 | 103.996 | 2680.702 | 478.850 | 17776.924 |
| wait           | 0.000 |  0.000 |  0.000 |   0.000 |    4.251 |   0.582 |   123.580 |
| stdio digest   | 0.000 |  0.001 |  0.001 |   0.001 |    0.001 |   0.001 |     0.245 |

## actiondfs Counters

These `/proc/actiondfs_stats` counters cover the VM lifetime.

| Counter                       |           Value |
| ----------------------------- | --------------: |
| mounts                        |           4,122 |
| root directory parses         |           1,406 |
| cached directory requests     |         169,617 |
| cached directory hits         |         163,001 |
| cached directory misses       |           6,616 |
| lookups                       |       1,406,668 |
| lookup hits                   |         841,778 |
| lookup negative               |         564,890 |
| blob open attempts            |         474,190 |
| blob-path cache hits          |         460,692 |
| blob-path cache misses        |           6,883 |
| blob-path cache evictions     |               0 |
| blob-path cache insertion races |             0 |
| node blob cache hits          |         472,190 |
| node blob cache misses        |         467,575 |
| backing reads                 |         415,332 |
| backing read bytes            |   1,303,012,282 |
| mmap calls                    |          53,030 |
| mmap bytes                    | 1,900,832,624,640 |
| mmap failures                 |               0 |
| directory blob reads          |           6,615 |
| directory blob bytes          |       2,729,935 |

## Staged Filesystem Counters

| Counter                              |       Value |
| ------------------------------------ | ----------: |
| staged ensure-directory calls        |      15,996 |
| staged ensure-directory components   |          16 |
| staged ensure-directory existing     |           0 |
| staged ensure-directory created      |          16 |
| staged parent dentry hits            |      15,980 |
| staged inode lookups                 |   1,406,668 |
| staged inode unstaged-parent skips   |   1,331,309 |
| staged inode lookup hits             |      35,518 |
| staged inode lookup negative         |      39,841 |
| staged inode input-directory merges  |      18,382 |
| staged backing open attempts         |      15,825 |
| staged backing open failures         |           0 |
| staged backing open total            |   15.511 ms |
| staged backing open lookup           |    0.600 ms |
| staged backing open file             |   12.684 ms |
| staged create calls/successes        |      11,981 |
| staged mkdir calls/successes         |         198 |
| staged rename calls/successes        |       3,817 |
| staged size updates/successes        |       3,874 |
| staged write calls                   |      37,140 |
| staged write bytes                   | 106,132,435 |
| staged `copy_file_range` successes   |       3,828 |
| staged `copy_file_range` bytes       |  31,630,764 |
| staged `copy_file_range` fallbacks   |           0 |

The staged-negative filter skipped 1,331,309 lookups with known-unstaged
parents. All 3,828 `copy_file_range` attempts succeeded without a buffered
fallback.

## CAS Put-File Promotion Counters

| Counter                              |      Value |
| ------------------------------------ | ---------: |
| CAS put-file calls                   |      7,947 |
| CAS promotion attempts               |      7,947 |
| CAS promotion success                |      2,087 |
| CAS existing-blob hits               |      5,860 |
| CAS promoted bytes                   | 32,082,447 |
| CAS digest bytes                     | 84,416,399 |
| CAS promotion digest                 | 863.028 ms |
| CAS promotion rename                 | 211.363 ms |
| CAS cross-device fallbacks           |          0 |
| CAS permission fallbacks             |          0 |
| CAS put-file copy calls              |          0 |

## ByteStream, gRPC, And VM Bridge Counters

| Counter                              |      Value |
| ------------------------------------ | ---------: |
| ByteStream file reads                |      4,038 |
| ByteStream file bytes                | 57,616,538 |
| ByteStream buffered reads            |          0 |
| gRPC response tasks started          |     36,229 |
| gRPC response tasks failed           |          0 |
| gRPC response concurrency waits      |          0 |
| gRPC data frames                     |     37,010 |
| gRPC file payload frames             |      6,902 |
| gRPC `sendfile` attempts/successes   |      6,902 |
| gRPC `sendfile` bytes                | 57,616,538 |
| gRPC `sendfile` fallbacks            |          0 |

The measured TCP-to-vsock bridge logged two connections, 28.30 MiB from client
to guest, 37.38 MiB from guest to client, and zero read/write pump errors.
ByteStream reads remained file-backed and all 6,902 gRPC `sendfile` attempts
succeeded.
