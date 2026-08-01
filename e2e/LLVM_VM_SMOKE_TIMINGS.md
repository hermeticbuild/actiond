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

- Generated: `2026-08-01 08:31:36 EDT`
- Command: `ACTIOND_BAZEL_BUILD_FLAGS="--jobs=32 --distdir=/private/tmp/actiond-audit-distdir --override_repository=llvm++osx+macos_sdk=/private/tmp/actiond-audit-macos-sdk" ACTIOND_LLVM_SMOKE_MAC_HOST=0 e2e/run_llvm_vm_smoke.sh`
- Output root: `/var/folders/p4/xn8y5q_j24l5xwgwd_jx5c340000gn/T/actiond-llvm-vm-smoke.rAvy7K`
- Workload: `@llvm-project//llvm:llvm-tblgen`, jobs=8
- VM warmup target: `//e2e:llvm_exec_warmup`
- Target and VM host platform: `@llvm//platforms:linux_arm64_musl`
- Build mode: `-c opt --strip=always --stripopt=--strip-all`
- VM warmup: `87.517s`; `2207 processes: 190 internal, 2017 remote`
- Measured VM build: `103.064s`; `2310 processes: 4 action cache hit, 204 internal, 2106 remote`
- Measured executions and timing records: `2106`
- Mac-host baseline: not run (`ACTIOND_LLVM_SMOKE_MAC_HOST=0`)

The previous checked-in run used the same jobs=8 and completed the warmup in
`90.683s` and measured build in `135.518s`. The current measured build is 23.9%
faster with the same 2,106 actions, while its warmup is 3.5% faster with the
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
| actiondfs mounts                     |       4,122 |       4,122 |
| root directory parses                |       1,405 |       1,406 |
| cached directory hits                |     163,011 |     163,007 |
| cached directory misses              |       6,606 |       6,610 |
| directory blob reads                 |       6,605 |       6,609 |
| staged ensure-directory calls        |      15,996 |      15,994 |
| staged ensure-directory components   |          16 |          16 |
| staged ensure-directory existing     |           0 |           0 |
| staged ensure-directory created      |          16 |          16 |
| staged parent dentry hits            |      15,980 |      15,978 |
| blob-path cache hits                 |     460,692 |     460,691 |
| blob-path cache misses               |       6,883 |       6,884 |
| blob-path cache evictions            |           0 |           0 |
| blob-path cache insertion races      |           0 |           1 |
| staged backing open attempts         |      15,825 |      15,824 |
| staged backing open lookup           | 0.767 ms    | 0.680 ms    |
| staged `copy_file_range` successes   |       3,828 |       3,828 |
| staged `copy_file_range` fallbacks   |           0 |           0 |

The workload retained the same 2,017 warmup actions and 2,106 measured actions.
All 163,007 cached-directory hits used RCU instead of the global directory-cache
mutex, and all 18,382 staged input-directory merges searched only cached input
directories. Root inode ownership reduced each of the 4,122 superblock
allocations from 128 bytes to 96 bytes. Root-directory parsing, staged
parent-directory reuse, and blob-path cache behavior remain close to the previous
checked-in result.

## VM Stage Timing

All timing values are milliseconds.

| Stage                 |   Min |    p25 |    p50 |     p75 |      p95 |    Mean |       Max |
| --------------------- | ----: | -----: | -----: | ------: | -------: | ------: | --------: |
| total                 | 6.745 | 25.027 | 34.577 |  74.160 | 2024.802 | 337.545 | 10086.407 |
| input fetch/setup     | 0.453 |  0.599 |  0.672 |   1.042 |    2.328 |   1.119 |    46.547 |
| execute               | 6.143 | 23.013 | 32.741 |  70.832 | 2021.932 | 334.886 | 10079.382 |
| output upload/collect | 0.020 |  0.145 |  0.287 |   1.790 |    5.823 |   1.539 |   126.589 |

## Runner Timing

`child setup` includes successful `execve`. `process/io` starts after
close-on-exec confirmation and includes action execution, stdout/stderr drain,
and lazy actiondfs input reads. All timing values are milliseconds.

| Runner Stage   |   Min |    p25 |    p50 |    p75 |      p95 |    Mean |       Max |
| -------------- | ----: | -----: | -----: | -----: | -------: | ------: | --------: |
| parent prepare | 0.058 |  0.099 |  0.123 |  0.158 |    0.465 |   0.203 |    12.161 |
| fork           | 0.261 |  0.528 |  0.605 |  1.183 |    7.101 |   2.064 |   210.760 |
| child setup    | 0.005 |  2.301 |  4.082 |  7.709 |   21.879 |   6.897 |   235.094 |
| process/io     | 0.654 | 17.273 | 24.376 | 54.316 | 2012.426 | 325.008 | 10064.808 |
| wait           | 0.000 |  0.000 |  0.000 |  0.000 |    4.635 |   0.567 |    18.201 |
| stdio digest   | 0.000 |  0.001 |  0.001 |  0.001 |    0.001 |   0.001 |     0.344 |

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
| blob-path cache hits          |         460,691 |
| blob-path cache misses        |           6,884 |
| blob-path cache evictions     |               0 |
| blob-path cache insertion races |             1 |
| node blob cache hits          |         472,190 |
| node blob cache misses        |         467,575 |
| backing reads                 |         415,332 |
| backing read bytes            |   1,303,012,282 |
| mmap calls                    |          53,030 |
| mmap bytes                    | 1,900,832,624,640 |
| mmap failures                 |               0 |
| directory blob reads          |           6,609 |
| directory blob bytes          |       2,720,441 |

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
| staged backing open total            |   16.355 ms |
| staged backing open lookup           |    0.680 ms |
| staged backing open file             |   10.791 ms |
| staged create calls/successes        |      11,980 |
| staged mkdir calls/successes         |         198 |
| staged rename calls/successes        |       3,816 |
| staged size updates/successes        |       3,874 |
| staged write calls                   |      36,955 |
| staged write bytes                   | 105,298,314 |
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
| CAS promoted bytes                   | 31,349,823 |
| CAS digest bytes                     | 83,683,775 |
| CAS promotion digest                 | 708.922 ms |
| CAS promotion rename                 | 131.988 ms |
| CAS cross-device fallbacks           |          0 |
| CAS permission fallbacks             |          0 |
| CAS put-file copy calls              |          0 |

## ByteStream, gRPC, And VM Bridge Counters

| Counter                              |      Value |
| ------------------------------------ | ---------: |
| ByteStream file reads                |      4,037 |
| ByteStream file bytes                | 57,515,051 |
| ByteStream buffered reads            |          0 |
| gRPC response tasks started          |     36,228 |
| gRPC response tasks failed           |          0 |
| gRPC response concurrency waits      |          0 |
| gRPC data frames                     |     37,004 |
| gRPC file payload frames             |      6,896 |
| gRPC `sendfile` attempts/successes   |      6,896 |
| gRPC `sendfile` bytes                | 57,515,051 |
| gRPC `sendfile` fallbacks            |          0 |

The measured TCP-to-vsock bridge logged two connections, 28.34 MiB from client
to guest, 37.37 MiB from guest to client, and zero read/write pump errors.
ByteStream reads remained file-backed and all 6,896 gRPC `sendfile` attempts
succeeded.
