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

- Generated: `2026-08-01 18:24:59 EDT`
- Command: `ACTIOND_BAZEL_BUILD_FLAGS="--jobs=32 --distdir=/private/tmp/actiond-audit-distdir --override_repository=llvm++osx+macos_sdk=/private/tmp/actiond-audit-macos-sdk" ACTIOND_LLVM_SMOKE_MAC_HOST=0 e2e/run_llvm_vm_smoke.sh`
- Output root: `/var/folders/p4/xn8y5q_j24l5xwgwd_jx5c340000gn/T/actiond-llvm-vm-smoke.G6vg1w`
- Workload: `@llvm-project//llvm:llvm-tblgen`, jobs=8
- VM warmup target: `//e2e:llvm_exec_warmup`
- Target and VM host platform: `@llvm//platforms:linux_arm64_musl`
- Build mode: `-c opt --strip=always --stripopt=--strip-all`
- VM warmup: `90.262s`; `2207 processes: 190 internal, 2017 remote`
- Measured VM build: `98.569s`; `2310 processes: 4 action cache hit, 204 internal, 2106 remote`
- Measured executions and timing records: `2106`
- Mac-host baseline: not run (`ACTIOND_LLVM_SMOKE_MAC_HOST=0`)

The previous checked-in run used the same jobs=8 and completed the warmup in
`82.129s` and measured build in `92.336s`. The current measured build is 6.8%
slower with the same 2,106 actions, while its warmup is 9.9% slower with the
same 2,017 actions. A repeat with the previous code completed the warmup in
`63.992s` and the measured build in `86.002s`. Intermediate runs on the same
machine completed the warmup/measured builds in `96.032s`/`104.393s` and
`94.614s`/`180.238s`. The large changes between identical action sets coincide
with host CPU and memory contention; compare matched CI actiond/native timings
for performance changes.

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
| root directory parses                |       1,405 |       1,405 |
| directory loads                      |     151,235 |     169,617 |
| cached directory requests            |     169,617 |     169,617 |
| cached directory hits                |     162,998 |     163,010 |
| cached directory misses              |       6,619 |       6,607 |
| cached directory races               |          13 |           1 |
| directory blob reads                 |       6,618 |       6,606 |
| staged ensure-directory calls        |      15,996 |      15,996 |
| staged ensure-directory components   |          16 |          16 |
| staged ensure-directory existing     |           0 |           0 |
| staged ensure-directory created      |          16 |          16 |
| staged parent dentry hits            |      15,980 |      15,980 |
| blob-path cache hits                 |     460,692 |     460,692 |
| blob-path cache misses               |       6,883 |       6,883 |
| blob-path cache evictions            |           0 |           0 |
| blob-path cache insertion races      |           0 |           0 |
| staged backing open attempts         |      15,825 |      15,825 |
| staged backing open lookup           | 0.297 ms    | 0.324 ms    |
| staged `copy_file_range` successes   |       3,828 |       3,828 |
| staged `copy_file_range` fallbacks   |           0 |           0 |

The workload retained the same 2,017 warmup actions and 2,106 measured actions.
All 163,010 cached-directory hits used RCU instead of the global directory-cache
mutex, and all 18,382 staged input-directory merges searched only cached input
directories. The 169,617 cached-directory requests were unchanged: merged input
directories deferred metadata loading until first access instead of removing
directory-cache requests. The 472,190 input backing-file acquisitions used RCU,
and 75,358 staged positive or negative inode lookups avoided exclusive backing
directory locks. Resolving 6,883 CAS cache misses and 6,606 directory blobs
directly avoided 13,489 temporary `PATH_MAX` pathname allocations, or about
52.7 MiB of cumulative allocation. Root inode ownership reduced each of the
4,122 superblock allocations from 128 bytes to 96 bytes, and unhashed root
inodes avoided global inode-hash insertion on each mount.

Staged inode ownership followed the backing inode through the staged mount
idmap, preserving sandbox uid and gid checks. Unsupported extended attributes
were skipped without bypassing normal inode permission checks, and backing
filesystem security flags were inherited only when the backing filesystem
advertised the same guarantees. Staged create, mkdir, unlink, rename, size
updates, mmap, and child lookups reported zero failures.

## VM Stage Timing

All timing values are milliseconds.

| Stage                 |   Min |    p25 |    p50 |     p75 |      p95 |    Mean |       Max |
| --------------------- | ----: | -----: | -----: | ------: | -------: | ------: | --------: |
| total                 | 7.179 | 24.020 | 34.068 |  93.793 | 1725.016 | 315.365 | 11505.363 |
| input fetch/setup     | 0.400 |  0.582 |  0.668 |   1.053 |    2.103 |   1.269 |    84.561 |
| execute               | 6.238 | 22.263 | 31.895 |  91.312 | 1722.654 | 312.755 | 11499.724 |
| output upload/collect | 0.026 |  0.136 |  0.258 |   1.312 |    5.180 |   1.341 |   121.919 |

## Runner Timing

`child setup` includes successful `execve`. `process/io` starts after
close-on-exec confirmation and includes action execution, stdout/stderr drain,
and lazy actiondfs input reads. All timing values are milliseconds.

| Runner Stage   |   Min |    p25 |    p50 |    p75 |      p95 |    Mean |       Max |
| -------------- | ----: | -----: | -----: | -----: | -------: | ------: | --------: |
| parent prepare | 0.057 |  0.105 |  0.135 |  0.199 |    0.412 |   0.280 |    55.961 |
| fork           | 0.438 |  0.723 |  0.819 |  1.902 |    7.894 |   2.690 |   143.889 |
| child setup    | 0.004 |  2.816 |  4.654 |  8.657 |   30.668 |   9.209 |   220.184 |
| process/io     | 0.002 | 15.844 | 23.161 | 64.357 | 1716.234 | 299.968 | 11479.045 |
| wait           | 0.000 |  0.000 |  0.000 |  0.000 |    3.570 |   0.385 |    23.227 |
| stdio digest   | 0.000 |  0.000 |  0.001 |  0.001 |    0.001 |   0.001 |     0.135 |

## actiondfs Counters

These `/proc/actiondfs_stats` counters cover the VM lifetime.

| Counter                       |           Value |
| ----------------------------- | --------------: |
| mounts                        |           4,122 |
| root directory parses         |           1,405 |
| directory loads               |         169,617 |
| cached directory requests     |         169,617 |
| cached directory hits         |         163,010 |
| cached directory misses       |           6,607 |
| cached directory races        |               1 |
| lookups                       |       1,406,668 |
| lookup hits                   |         841,778 |
| lookup negative               |         564,890 |
| blob open attempts            |         474,181 |
| blob open stale retries       |               0 |
| blob-path cache hits          |         460,692 |
| blob-path cache misses        |           6,883 |
| blob-path cache evictions     |               0 |
| blob-path cache insertion races |             0 |
| node blob cache hits          |         472,190 |
| node blob cache misses        |         467,575 |
| backing reads                 |         415,332 |
| backing read bytes            |   1,303,012,282 |
| backing read stale retries    |               0 |
| mmap calls                    |          53,030 |
| mmap bytes                    | 1,900,832,624,640 |
| mmap failures                 |               0 |
| directory blob reads          |           6,606 |
| directory blob bytes          |       2,720,139 |

## Staged Filesystem Counters

| Counter                              |       Value |
| ------------------------------------ | ----------: |
| staged ensure-directory calls        |      15,996 |
| staged ensure-directory components   |          16 |
| staged ensure-directory existing     |           0 |
| staged ensure-directory created      |          16 |
| staged parent dentry hits            |      15,980 |
| staged child lookups                 |      87,568 |
| staged child lookup hits             |      35,533 |
| staged child lookup negative         |      52,035 |
| staged child lookup failures         |           0 |
| staged inode lookups                 |   1,406,668 |
| staged inode unstaged-parent skips   |   1,331,310 |
| staged inode lookup hits             |      35,518 |
| staged inode lookup negative         |      39,840 |
| staged inode lookup failures         |           0 |
| staged inode input-directory merges  |      18,382 |
| staged backing open attempts         |      15,825 |
| staged backing open failures         |           0 |
| staged backing open total            |   12.790 ms |
| staged backing open lookup           |    0.324 ms |
| staged backing open file             |   10.718 ms |
| staged create calls/successes        |      11,981 |
| staged create failures               |           0 |
| staged mkdir calls/successes         |         198 |
| staged mkdir failures                |           0 |
| staged unlink calls/successes        |          15 |
| staged unlink failures               |           0 |
| staged rename calls/successes        |       3,817 |
| staged rename failures               |           0 |
| staged size updates/successes        |       3,874 |
| staged size update failures          |           0 |
| staged write calls                   |      37,065 |
| staged write bytes                   | 105,766,927 |
| staged mmap calls                    |          30 |
| staged mmap bytes                    |   2,084,864 |
| staged mmap failures                 |           0 |
| staged `copy_file_range` successes   |       3,828 |
| staged `copy_file_range` bytes       |  31,630,764 |
| staged `copy_file_range` fallbacks   |           0 |

The staged-negative filter skipped 1,331,310 lookups with known-unstaged
parents. All 3,828 `copy_file_range` attempts succeeded without a buffered
fallback.

## CAS Put-File Promotion Counters

| Counter                              |      Value |
| ------------------------------------ | ---------: |
| CAS put-file calls                   |      7,947 |
| CAS promotion attempts               |      7,947 |
| CAS promotion success                |      2,087 |
| CAS existing-blob hits               |      5,860 |
| CAS promoted bytes                   | 31,718,871 |
| CAS digest bytes                     | 84,052,823 |
| CAS promotion digest                 | 661.226 ms |
| CAS promotion rename                 | 174.472 ms |
| CAS cross-device fallbacks           |          0 |
| CAS permission fallbacks             |          0 |
| CAS put-file copy calls              |          0 |

## ByteStream, gRPC, And VM Bridge Counters

| Counter                              |      Value |
| ------------------------------------ | ---------: |
| ByteStream file reads                |      4,038 |
| ByteStream file bytes                | 57,614,606 |
| ByteStream buffered reads            |          0 |
| gRPC response tasks started          |     36,229 |
| gRPC response tasks failed           |          0 |
| gRPC response concurrency waits      |          0 |
| gRPC data frames                     |     37,011 |
| gRPC file payload frames             |      6,902 |
| gRPC `sendfile` attempts/successes   |      6,902 |
| gRPC `sendfile` bytes                | 57,614,606 |
| gRPC `sendfile` fallbacks            |          0 |

The measured TCP-to-vsock bridge logged two connections, 28.15 MiB from client
to guest, 37.37 MiB from guest to client, and zero read/write pump errors.
ByteStream reads remained file-backed and all 6,902 gRPC `sendfile` attempts
succeeded.
