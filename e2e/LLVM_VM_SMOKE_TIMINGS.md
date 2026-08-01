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

- Generated: `2026-08-01 08:56:53 EDT`
- Command: `ACTIOND_BAZEL_BUILD_FLAGS="--jobs=32 --distdir=/private/tmp/actiond-audit-distdir --override_repository=llvm++osx+macos_sdk=/private/tmp/actiond-audit-macos-sdk" ACTIOND_LLVM_SMOKE_MAC_HOST=0 e2e/run_llvm_vm_smoke.sh`
- Output root: `/var/folders/p4/xn8y5q_j24l5xwgwd_jx5c340000gn/T/actiond-llvm-vm-smoke.3d4ru5`
- Workload: `@llvm-project//llvm:llvm-tblgen`, jobs=8
- VM warmup target: `//e2e:llvm_exec_warmup`
- Target and VM host platform: `@llvm//platforms:linux_arm64_musl`
- Build mode: `-c opt --strip=always --stripopt=--strip-all`
- VM warmup: `71.325s`; `2207 processes: 190 internal, 2017 remote`
- Measured VM build: `74.995s`; `2310 processes: 4 action cache hit, 204 internal, 2106 remote`
- Measured executions and timing records: `2106`
- Mac-host baseline: not run (`ACTIOND_LLVM_SMOKE_MAC_HOST=0`)

The previous checked-in run used the same jobs=8 and completed the warmup in
`87.517s` and measured build in `103.064s`. The current measured build is 27.2%
faster with the same 2,106 actions, while its warmup is 18.5% faster with the
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
| root directory parses                |       1,406 |       1,406 |
| cached directory hits                |     163,007 |     163,007 |
| cached directory misses              |       6,610 |       6,610 |
| directory blob reads                 |       6,609 |       6,609 |
| staged ensure-directory calls        |      15,994 |      15,994 |
| staged ensure-directory components   |          16 |          16 |
| staged ensure-directory existing     |           0 |           0 |
| staged ensure-directory created      |          16 |          16 |
| staged parent dentry hits            |      15,978 |      15,978 |
| blob-path cache hits                 |     460,691 |     460,691 |
| blob-path cache misses               |       6,884 |       6,884 |
| blob-path cache evictions            |           0 |           0 |
| blob-path cache insertion races      |           1 |           1 |
| staged backing open attempts         |      15,824 |      15,824 |
| staged backing open lookup           | 0.680 ms    | 0.632 ms    |
| staged `copy_file_range` successes   |       3,828 |       3,828 |
| staged `copy_file_range` fallbacks   |           0 |           0 |

The workload retained the same 2,017 warmup actions and 2,106 measured actions.
All 163,007 cached-directory hits used RCU instead of the global directory-cache
mutex, and all 18,382 staged input-directory merges searched only cached input
directories. Root inode ownership reduced each of the 4,122 superblock
allocations from 128 bytes to 96 bytes, and unhashed root inodes avoided global
inode-hash insertion on each mount. Root-directory parsing, staged
parent-directory reuse, and blob-path cache behavior remain close to the previous
checked-in result.

## VM Stage Timing

All timing values are milliseconds.

| Stage                 |   Min |    p25 |    p50 |     p75 |      p95 |    Mean |       Max |
| --------------------- | ----: | -----: | -----: | ------: | -------: | ------: | --------: |
| total                 | 7.607 | 21.335 | 28.953 |  53.019 | 1380.981 | 241.158 |  6666.777 |
| input fetch/setup     | 0.418 |  0.572 |  0.628 |   0.983 |    1.829 |   0.952 |    39.829 |
| execute               | 5.237 | 19.657 | 27.051 |  50.836 | 1374.352 | 238.914 |  6642.901 |
| output upload/collect | 0.020 |  0.129 |  0.256 |   1.469 |    4.519 |   1.292 |   201.862 |

## Runner Timing

`child setup` includes successful `execve`. `process/io` starts after
close-on-exec confirmation and includes action execution, stdout/stderr drain,
and lazy actiondfs input reads. All timing values are milliseconds.

| Runner Stage   |   Min |    p25 |    p50 |    p75 |      p95 |    Mean |       Max |
| -------------- | ----: | -----: | -----: | -----: | -------: | ------: | --------: |
| parent prepare | 0.058 |  0.092 |  0.116 |  0.155 |    0.292 |   0.196 |    33.258 |
| fork           | 0.280 |  0.457 |  0.517 |  0.932 |    4.461 |   1.290 |    87.484 |
| child setup    | 0.004 |  1.945 |  3.304 |  5.900 |   16.392 |   5.291 |   110.128 |
| process/io     | 0.026 | 14.685 | 20.379 | 39.355 | 1367.614 | 231.656 |  6628.871 |
| wait           | 0.000 |  0.000 |  0.000 |  0.000 |    3.629 |   0.387 |    10.698 |
| stdio digest   | 0.000 |  0.000 |  0.001 |  0.001 |    0.001 |   0.001 |     1.187 |

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
| staged inode unstaged-parent skips   |   1,331,309 |
| staged inode lookup hits             |      35,518 |
| staged inode lookup negative         |      39,840 |
| staged inode input-directory merges  |      18,382 |
| staged backing open attempts         |      15,824 |
| staged backing open failures         |           0 |
| staged backing open total            |   11.208 ms |
| staged backing open lookup           |    0.632 ms |
| staged backing open file             |    8.477 ms |
| staged create calls/successes        |      11,980 |
| staged mkdir calls/successes         |         198 |
| staged rename calls/successes        |       3,816 |
| staged size updates/successes        |       3,874 |
| staged write calls                   |      36,940 |
| staged write bytes                   | 105,205,576 |
| staged `copy_file_range` successes   |       3,828 |
| staged `copy_file_range` bytes       |  31,630,764 |
| staged `copy_file_range` fallbacks   |           0 |

The staged-negative filter skipped 1,331,309 lookups with known-unstaged
parents. All 3,828 `copy_file_range` attempts succeeded without a buffered
fallback.

## CAS Put-File Promotion Counters

| Counter                              |      Value |
| ------------------------------------ | ---------: |
| CAS put-file calls                   |      7,946 |
| CAS promotion attempts               |      7,946 |
| CAS promotion success                |      2,086 |
| CAS existing-blob hits               |      5,860 |
| CAS promoted bytes                   | 31,257,287 |
| CAS digest bytes                     | 83,591,239 |
| CAS promotion digest                 | 672.445 ms |
| CAS promotion rename                 | 105.677 ms |
| CAS cross-device fallbacks           |          0 |
| CAS permission fallbacks             |          0 |
| CAS put-file copy calls              |          0 |

## ByteStream, gRPC, And VM Bridge Counters

| Counter                              |      Value |
| ------------------------------------ | ---------: |
| ByteStream file reads                |      4,037 |
| ByteStream file bytes                | 57,514,849 |
| ByteStream buffered reads            |          0 |
| gRPC response tasks started          |     36,228 |
| gRPC response tasks failed           |          0 |
| gRPC response concurrency waits      |          0 |
| gRPC data frames                     |     37,003 |
| gRPC file payload frames             |      6,895 |
| gRPC `sendfile` attempts/successes   |      6,895 |
| gRPC `sendfile` bytes                | 57,514,849 |
| gRPC `sendfile` fallbacks            |          0 |

The measured TCP-to-vsock bridge logged two connections, 27.82 MiB from client
to guest, 37.36 MiB from guest to client, and zero read/write pump errors.
ByteStream reads remained file-backed and all 6,895 gRPC `sendfile` attempts
succeeded.
