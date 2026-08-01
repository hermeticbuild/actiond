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

- Generated: `2026-07-31 21:55:41 EDT`
- Command: `ACTIOND_BAZEL_BUILD_FLAGS="--jobs=32 --distdir=/private/tmp/actiond-audit-distdir --override_repository=llvm++osx+macos_sdk=/private/tmp/actiond-audit-macos-sdk" ACTIOND_LLVM_SMOKE_MAC_HOST=0 e2e/run_llvm_vm_smoke.sh`
- Output root: `/var/folders/p4/xn8y5q_j24l5xwgwd_jx5c340000gn/T/actiond-llvm-vm-smoke.7m9AaQ`
- Workload: `@llvm-project//llvm:llvm-tblgen`, jobs=8
- VM warmup target: `//e2e:llvm_exec_warmup`
- Target and VM host platform: `@llvm//platforms:linux_arm64_musl`
- Build mode: `-c opt --strip=always --stripopt=--strip-all`
- VM warmup: `97.329s`; `2207 processes: 190 internal, 2017 remote`
- Measured VM build: `147.209s`; `2310 processes: 4 action cache hit, 204 internal, 2106 remote`
- Measured executions and timing records: `2106`
- Mac-host baseline: not run (`ACTIOND_LLVM_SMOKE_MAC_HOST=0`)

The previous checked-in run used the same jobs=8 and completed the warmup in
`112.244s` and measured build in `86.371s`. The current warmup is 13.3% faster
with the same 2,017 warmup actions. A concurrent local Drake C++ compilation
started during the measured build, so its `147.209s` elapsed time is not a
matched comparison with the previous `86.371s` run. Both measured builds
executed the same 2,106 actions. Compare matched CI actiond/native timings when
host CPU or memory contention affects local VM measurements.

Earlier checked-in runs completed the warmup and measured build in
`102.136s`/`108.831s` and `106.289s`/`138.481s`. A run before action isolation
completed the warmup in `88.364s` and the measured build in `91.490s`. An
intermediate action-isolation run took `256.834s` for warmup and `140.328s`
for the measured build.

## Filesystem Comparison With Prior Checked-In Run

Counters include both warmup and measured builds.

| Counter                              | Prior       | Current     |
| ------------------------------------ | ----------: | ----------: |
| actiondfs mounts                     |       4,123 |       4,122 |
| root directory parses                |       1,407 |       1,406 |
| cached directory hits                |     163,036 |     163,007 |
| cached directory misses              |       6,629 |       6,610 |
| directory blob reads                 |       6,628 |       6,609 |
| staged ensure-directory calls        |      16,001 |      15,994 |
| staged ensure-directory components   |          16 |          16 |
| staged ensure-directory existing     |           0 |           0 |
| staged ensure-directory created      |          16 |          16 |
| staged parent dentry hits            |      15,985 |      15,978 |
| blob-path cache hits                 |     460,969 |     460,692 |
| blob-path cache misses               |       6,971 |       6,883 |
| blob-path cache evictions            |           0 |           0 |
| blob-path cache insertion races      |           1 |           0 |
| staged backing open attempts         |      15,828 |      15,824 |
| staged backing open lookup           | 0.560 ms    | 0.648 ms    |
| staged `copy_file_range` successes   |       3,828 |       3,828 |
| staged `copy_file_range` fallbacks   |           0 |           0 |

The workload retained the same 2,017 warmup actions and 2,106 measured actions.
Root-directory parsing, directory blob reads, staged parent-directory reuse, and
blob-path cache behavior remain close to the previous checked-in result.

## VM Stage Timing

All timing values are milliseconds.

| Stage                 |   Min |    p25 |    p50 |     p75 |      p95 |    Mean |       Max |
| --------------------- | ----: | -----: | -----: | ------: | -------: | ------: | --------: |
| total                 | 5.837 | 27.696 | 40.060 | 122.525 | 2616.169 | 477.553 | 17611.456 |
| input fetch/setup     | 0.418 |  0.592 |  0.683 |   1.104 |    3.948 |   1.700 |   112.102 |
| execute               | 5.098 | 25.931 | 37.629 | 118.874 | 2613.769 | 474.539 | 17608.027 |
| output upload/collect | 0.023 |  0.132 |  0.213 |   1.259 |    4.853 |   1.315 |   133.861 |

## Runner Timing

`child setup` includes successful `execve`. `process/io` starts after
close-on-exec confirmation and includes action execution, stdout/stderr drain,
and lazy actiondfs input reads. All timing values are milliseconds.

| Runner Stage   |   Min |    p25 |    p50 |    p75 |      p95 |    Mean |       Max |
| -------------- | ----: | -----: | -----: | -----: | -------: | ------: | --------: |
| parent prepare | 0.059 |  0.096 |  0.126 |  0.167 |    0.546 |   0.365 |   110.160 |
| fork           | 0.289 |  0.539 |  0.630 |  1.229 |   11.535 |   3.255 |   264.441 |
| child setup    | 0.009 |  2.864 |  5.137 |  9.901 |   39.427 |  11.185 |   409.289 |
| process/io     | 0.812 | 19.219 | 28.286 | 75.714 | 2591.701 | 459.093 | 17592.442 |
| wait           | 0.000 |  0.000 |  0.000 |  0.000 |    3.337 |   0.350 |    31.314 |
| stdio digest   | 0.000 |  0.001 |  0.001 |  0.001 |    0.001 |   0.001 |     0.153 |

## actiondfs Counters

These `/proc/actiondfs_stats` counters cover the VM lifetime.

| Counter                       |           Value |
| ----------------------------- | --------------: |
| mounts                        |           4,122 |
| root directory parses         |           1,406 |
| cached directory requests     |         169,617 |
| cached directory hits         |         163,007 |
| cached directory misses       |           6,610 |
| lookups                       |       1,406,667 |
| lookup hits                   |         841,778 |
| lookup negative               |         564,889 |
| blob open attempts            |         474,184 |
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
| directory blob reads          |           6,609 |
| directory blob bytes          |       2,720,612 |

## Staged Filesystem Counters

| Counter                              |       Value |
| ------------------------------------ | ----------: |
| staged ensure-directory calls        |      15,994 |
| staged ensure-directory components   |          16 |
| staged ensure-directory existing     |           0 |
| staged ensure-directory created      |          16 |
| staged parent dentry hits            |      15,978 |
| staged inode lookups                 |   1,406,667 |
| staged inode unstaged-parent skips   |   1,331,308 |
| staged inode lookup hits             |      35,518 |
| staged inode lookup negative         |      39,841 |
| staged inode input-directory merges  |      18,382 |
| staged backing open attempts         |      15,824 |
| staged backing open failures         |           0 |
| staged backing open total            |   12.551 ms |
| staged backing open lookup           |    0.648 ms |
| staged backing open file             |    9.859 ms |
| staged create calls/successes        |      11,980 |
| staged mkdir calls/successes         |         198 |
| staged rename calls/successes        |       3,816 |
| staged size updates/successes        |       3,874 |
| staged write calls                   |      36,943 |
| staged write bytes                   | 105,212,804 |
| staged `copy_file_range` successes   |       3,828 |
| staged `copy_file_range` bytes       |  31,630,764 |
| staged `copy_file_range` fallbacks   |           0 |

The staged-negative filter skipped 1,331,308 lookups with known-unstaged
parents. All 3,828 `copy_file_range` attempts succeeded without a buffered
fallback.

## CAS Put-File Promotion Counters

| Counter                              |      Value |
| ------------------------------------ | ---------: |
| CAS put-file calls                   |      7,946 |
| CAS promotion attempts               |      7,946 |
| CAS promotion success                |      2,086 |
| CAS existing-blob hits               |      5,860 |
| CAS promoted bytes                   | 31,268,199 |
| CAS digest bytes                     | 83,602,151 |
| CAS promotion digest                 | 792.857 ms |
| CAS promotion rename                 | 147.752 ms |
| CAS cross-device fallbacks           |          0 |
| CAS permission fallbacks             |          0 |
| CAS put-file copy calls              |          0 |

## ByteStream, gRPC, And VM Bridge Counters

| Counter                              |      Value |
| ------------------------------------ | ---------: |
| ByteStream file reads                |      4,037 |
| ByteStream file bytes                | 57,511,165 |
| ByteStream buffered reads            |          0 |
| gRPC response tasks started          |     36,228 |
| gRPC response tasks failed           |          0 |
| gRPC response concurrency waits      |          0 |
| gRPC data frames                     |     37,003 |
| gRPC file payload frames             |      6,895 |
| gRPC `sendfile` attempts/successes   |      6,895 |
| gRPC `sendfile` bytes                | 57,511,165 |
| gRPC `sendfile` fallbacks            |          0 |

The measured TCP-to-vsock bridge logged two connections, 28.23 MiB from client
to guest, 37.37 MiB from guest to client, and zero read/write pump errors.
ByteStream reads remained file-backed and all 6,895 gRPC `sendfile` attempts
succeeded.
