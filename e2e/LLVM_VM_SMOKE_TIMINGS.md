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

- Generated: `2026-08-01 00:33:32 EDT`
- Command: `ACTIOND_BAZEL_BUILD_FLAGS="--jobs=32 --distdir=/private/tmp/actiond-audit-distdir --override_repository=llvm++osx+macos_sdk=/private/tmp/actiond-audit-macos-sdk" ACTIOND_LLVM_SMOKE_MAC_HOST=0 e2e/run_llvm_vm_smoke.sh`
- Output root: `/var/folders/p4/xn8y5q_j24l5xwgwd_jx5c340000gn/T/actiond-llvm-vm-smoke.4zlbWj`
- Workload: `@llvm-project//llvm:llvm-tblgen`, jobs=8
- VM warmup target: `//e2e:llvm_exec_warmup`
- Target and VM host platform: `@llvm//platforms:linux_arm64_musl`
- Build mode: `-c opt --strip=always --stripopt=--strip-all`
- VM warmup: `154.225s`; `2207 processes: 190 internal, 2017 remote`
- Measured VM build: `136.185s`; `2310 processes: 4 action cache hit, 204 internal, 2106 remote`
- Measured executions and timing records: `2106`
- Mac-host baseline: not run (`ACTIOND_LLVM_SMOKE_MAC_HOST=0`)

The previous checked-in run used the same jobs=8 and completed the warmup in
`97.329s` and measured build in `147.209s`. The current measured build is 7.5%
faster with the same 2,106 actions, while its warmup is 58.5% slower with the
same 2,017 actions. Intermediate runs on the same machine completed the
warmup/measured builds in `96.032s`/`104.393s` and `94.614s`/`180.238s`. The
large changes between identical action sets coincide with host CPU and memory
contention; compare matched CI actiond/native timings for performance changes.

Earlier checked-in runs completed the warmup and measured build in
`102.136s`/`108.831s` and `106.289s`/`138.481s`. A run before action isolation
completed the warmup in `88.364s` and the measured build in `91.490s`. An
intermediate action-isolation run took `256.834s` for warmup and `140.328s`
for the measured build.

## Filesystem Comparison With Prior Checked-In Run

Counters include both warmup and measured builds.

| Counter                              | Prior       | Current     |
| ------------------------------------ | ----------: | ----------: |
| actiondfs mounts                     |       4,122 |       4,123 |
| root directory parses                |       1,406 |       1,406 |
| cached directory hits                |     163,007 |     163,041 |
| cached directory misses              |       6,610 |       6,624 |
| directory blob reads                 |       6,609 |       6,623 |
| staged ensure-directory calls        |      15,994 |      16,001 |
| staged ensure-directory components   |          16 |          16 |
| staged ensure-directory existing     |           0 |           0 |
| staged ensure-directory created      |          16 |          16 |
| staged parent dentry hits            |      15,978 |      15,985 |
| blob-path cache hits                 |     460,692 |     460,969 |
| blob-path cache misses               |       6,883 |       6,971 |
| blob-path cache evictions            |           0 |           0 |
| blob-path cache insertion races      |           0 |           1 |
| staged backing open attempts         |      15,824 |      15,828 |
| staged backing open lookup           | 0.648 ms    | 0.692 ms    |
| staged `copy_file_range` successes   |       3,828 |       3,828 |
| staged `copy_file_range` fallbacks   |           0 |           0 |

The workload retained the same 2,017 warmup actions and 2,106 measured actions.
Root-directory parsing, directory blob reads, staged parent-directory reuse, and
blob-path cache behavior remain close to the previous checked-in result.

## VM Stage Timing

All timing values are milliseconds.

| Stage                 |   Min |    p25 |    p50 |     p75 |      p95 |    Mean |       Max |
| --------------------- | ----: | -----: | -----: | ------: | -------: | ------: | --------: |
| total                 | 7.856 | 30.071 | 51.388 | 190.619 | 2488.708 | 437.578 | 11479.179 |
| input fetch/setup     | 0.415 |  0.594 |  0.845 |   1.234 |    4.437 |   1.740 |   188.989 |
| execute               | 7.088 | 28.012 | 48.725 | 183.730 | 2478.244 | 433.987 | 11469.574 |
| output upload/collect | 0.020 |  0.145 |  0.294 |   1.587 |    6.432 |   1.851 |   161.902 |

## Runner Timing

`child setup` includes successful `execve`. `process/io` starts after
close-on-exec confirmation and includes action execution, stdout/stderr drain,
and lazy actiondfs input reads. All timing values are milliseconds.

| Runner Stage   |   Min |    p25 |    p50 |    p75 |      p95 |    Mean |       Max |
| -------------- | ----: | -----: | -----: | -----: | -------: | ------: | --------: |
| parent prepare | 0.056 |  0.102 |  0.132 |  0.214 |    0.632 |   0.423 |    96.043 |
| fork           | 0.331 |  0.561 |  0.752 |  1.843 |   19.644 |   5.298 |   408.534 |
| child setup    | 0.006 |  3.421 |  6.095 | 14.244 |   56.363 |  14.388 |   287.535 |
| process/io     | 2.457 | 19.980 | 32.946 | 121.092 | 2467.317 | 413.121 | 11440.529 |
| wait           | 0.000 |  0.000 |  0.000 |  0.000 |    4.235 |   0.538 |    43.349 |
| stdio digest   | 0.000 |  0.001 |  0.001 |  0.001 |    0.001 |   0.006 |     8.539 |

## actiondfs Counters

These `/proc/actiondfs_stats` counters cover the VM lifetime.

| Counter                       |           Value |
| ----------------------------- | --------------: |
| mounts                        |           4,123 |
| root directory parses         |           1,406 |
| cached directory requests     |         169,665 |
| cached directory hits         |         163,041 |
| cached directory misses       |           6,624 |
| lookups                       |       1,407,099 |
| lookup hits                   |         842,187 |
| lookup negative               |         564,912 |
| blob open attempts            |         474,563 |
| blob-path cache hits          |         460,969 |
| blob-path cache misses        |           6,971 |
| blob-path cache evictions     |               0 |
| blob-path cache insertion races |             1 |
| node blob cache hits          |         472,567 |
| node blob cache misses        |         467,940 |
| backing reads                 |         415,500 |
| backing read bytes            |   1,303,975,362 |
| mmap calls                    |          53,239 |
| mmap bytes                    | 1,901,676,589,056 |
| mmap failures                 |               0 |
| directory blob reads          |           6,623 |
| directory blob bytes          |       2,736,211 |

## Staged Filesystem Counters

| Counter                              |       Value |
| ------------------------------------ | ----------: |
| staged ensure-directory calls        |      16,001 |
| staged ensure-directory components   |          16 |
| staged ensure-directory existing     |           0 |
| staged ensure-directory created      |          16 |
| staged parent dentry hits            |      15,985 |
| staged inode lookups                 |   1,407,099 |
| staged inode unstaged-parent skips   |   1,331,722 |
| staged inode lookup hits             |      35,524 |
| staged inode lookup negative         |      39,853 |
| staged inode input-directory merges  |      18,388 |
| staged backing open attempts         |      15,828 |
| staged backing open failures         |           0 |
| staged backing open total            |   13.080 ms |
| staged backing open lookup           |    0.692 ms |
| staged backing open file             |    9.727 ms |
| staged create calls/successes        |      11,984 |
| staged mkdir calls/successes         |         198 |
| staged rename calls/successes        |       3,819 |
| staged size updates/successes        |       3,876 |
| staged write calls                   |      37,194 |
| staged write bytes                   | 106,356,427 |
| staged `copy_file_range` successes   |       3,828 |
| staged `copy_file_range` bytes       |  31,630,764 |
| staged `copy_file_range` fallbacks   |           0 |

The staged-negative filter skipped 1,331,722 lookups with known-unstaged
parents. All 3,828 `copy_file_range` attempts succeeded without a buffered
fallback.

## CAS Put-File Promotion Counters

| Counter                              |      Value |
| ------------------------------------ | ---------: |
| CAS put-file calls                   |      7,949 |
| CAS promotion attempts               |      7,949 |
| CAS promotion success                |      2,089 |
| CAS existing-blob hits               |      5,860 |
| CAS promoted bytes                   | 37,922,351 |
| CAS digest bytes                     | 90,256,303 |
| CAS promotion digest                 | 1,069.739 ms |
| CAS promotion rename                 | 229.018 ms |
| CAS cross-device fallbacks           |          0 |
| CAS permission fallbacks             |          0 |
| CAS put-file copy calls              |          0 |

## ByteStream, gRPC, And VM Bridge Counters

| Counter                              |      Value |
| ------------------------------------ | ---------: |
| ByteStream file reads                |      4,045 |
| ByteStream file bytes                | 63,436,296 |
| ByteStream buffered reads            |          0 |
| gRPC response tasks started          |     36,255 |
| gRPC response tasks failed           |          0 |
| gRPC response concurrency waits      |          0 |
| gRPC data frames                     |     37,395 |
| gRPC file payload frames             |      7,263 |
| gRPC `sendfile` attempts/successes   |      7,263 |
| gRPC `sendfile` bytes                | 63,436,296 |
| gRPC `sendfile` fallbacks            |          0 |

The measured TCP-to-vsock bridge logged two connections, 28.21 MiB from client
to guest, 37.38 MiB from guest to client, and zero read/write pump errors.
ByteStream reads remained file-backed and all 7,263 gRPC `sendfile` attempts
succeeded.
