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

- Generated: `2026-08-01 15:44:38 EDT`
- Command: `ACTIOND_BAZEL_BUILD_FLAGS="--jobs=32 --distdir=/private/tmp/actiond-audit-distdir --override_repository=llvm++osx+macos_sdk=/private/tmp/actiond-audit-macos-sdk" ACTIOND_LLVM_SMOKE_MAC_HOST=0 e2e/run_llvm_vm_smoke.sh`
- Output root: `/var/folders/p4/xn8y5q_j24l5xwgwd_jx5c340000gn/T/actiond-llvm-vm-smoke.yu77B2`
- Workload: `@llvm-project//llvm:llvm-tblgen`, jobs=8
- VM warmup target: `//e2e:llvm_exec_warmup`
- Target and VM host platform: `@llvm//platforms:linux_arm64_musl`
- Build mode: `-c opt --strip=always --stripopt=--strip-all`
- VM warmup: `82.129s`; `2207 processes: 190 internal, 2017 remote`
- Measured VM build: `92.336s`; `2310 processes: 4 action cache hit, 204 internal, 2106 remote`
- Measured executions and timing records: `2106`
- Mac-host baseline: not run (`ACTIOND_LLVM_SMOKE_MAC_HOST=0`)

The previous checked-in run used the same jobs=8 and completed the warmup in
`83.160s` and measured build in `88.494s`. The current measured build is 4.3%
slower with the same 2,106 actions, while its warmup is 1.2% faster with the
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
| cached directory hits                |     163,011 |     162,998 |
| cached directory misses              |       6,606 |       6,619 |
| directory blob reads                 |       6,605 |       6,618 |
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
| staged backing open lookup           | 0.705 ms    | 0.297 ms    |
| staged `copy_file_range` successes   |       3,828 |       3,828 |
| staged `copy_file_range` fallbacks   |           0 |           0 |

The workload retained the same 2,017 warmup actions and 2,106 measured actions.
All 162,998 cached-directory hits used RCU instead of the global directory-cache
mutex, and all 18,382 staged input-directory merges searched only cached input
directories. Root inode ownership reduced each of the 4,122 superblock
allocations from 128 bytes to 96 bytes, and unhashed root inodes avoided global
inode-hash insertion on each mount. CAS blob lookups and staged parent lookups
borrowed existing mount or path references. Root-directory parsing, staged
parent-directory reuse, and blob-path cache behavior remain close to the previous
checked-in result.

## VM Stage Timing

All timing values are milliseconds.

| Stage                 |   Min |    p25 |    p50 |     p75 |      p95 |    Mean |       Max |
| --------------------- | ----: | -----: | -----: | ------: | -------: | ------: | --------: |
| total                 | 7.303 | 22.280 | 31.502 |  72.387 | 1654.434 | 304.721 |  9170.784 |
| input fetch/setup     | 0.405 |  0.586 |  0.642 |   0.996 |    1.994 |   1.034 |    60.478 |
| execute               | 5.979 | 20.755 | 29.458 |  71.567 | 1651.500 | 302.320 |  9161.111 |
| output upload/collect | 0.022 |  0.138 |  0.262 |   1.601 |    5.233 |   1.367 |   157.599 |

## Runner Timing

`child setup` includes successful `execve`. `process/io` starts after
close-on-exec confirmation and includes action execution, stdout/stderr drain,
and lazy actiondfs input reads. All timing values are milliseconds.

| Runner Stage   |   Min |    p25 |    p50 |    p75 |      p95 |    Mean |       Max |
| -------------- | ----: | -----: | -----: | -----: | -------: | ------: | --------: |
| parent prepare | 0.049 |  0.100 |  0.124 |  0.154 |    0.395 |   0.193 |    12.384 |
| fork           | 0.252 |  0.505 |  0.576 |  1.042 |    5.887 |   1.766 |   201.901 |
| child setup    | 0.004 |  1.761 |  3.161 |  6.020 |   21.088 |   6.044 |   107.745 |
| process/io     | 0.588 | 15.747 | 22.252 | 52.498 | 1646.214 | 293.593 |  9134.104 |
| wait           | 0.000 |  0.000 |  0.000 |  0.000 |    4.334 |   0.575 |    14.531 |
| stdio digest   | 0.000 |  0.001 |  0.001 |  0.001 |    0.001 |   0.001 |     0.142 |

## actiondfs Counters

These `/proc/actiondfs_stats` counters cover the VM lifetime.

| Counter                       |           Value |
| ----------------------------- | --------------: |
| mounts                        |           4,122 |
| root directory parses         |           1,405 |
| cached directory requests     |         169,617 |
| cached directory hits         |         162,998 |
| cached directory misses       |           6,619 |
| lookups                       |       1,406,668 |
| lookup hits                   |         841,778 |
| lookup negative               |         564,890 |
| blob open attempts            |         474,193 |
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
| directory blob reads          |           6,618 |
| directory blob bytes          |       2,732,839 |

## Staged Filesystem Counters

| Counter                              |       Value |
| ------------------------------------ | ----------: |
| staged ensure-directory calls        |      15,996 |
| staged ensure-directory components   |          16 |
| staged ensure-directory existing     |           0 |
| staged ensure-directory created      |          16 |
| staged parent dentry hits            |      15,980 |
| staged inode lookups                 |   1,406,668 |
| staged inode unstaged-parent skips   |   1,331,308 |
| staged inode lookup hits             |      35,518 |
| staged inode lookup negative         |      39,842 |
| staged inode input-directory merges  |      18,382 |
| staged backing open attempts         |      15,825 |
| staged backing open failures         |           0 |
| staged backing open total            |   12.784 ms |
| staged backing open lookup           |    0.297 ms |
| staged backing open file             |   10.582 ms |
| staged create calls/successes        |      11,981 |
| staged mkdir calls/successes         |         198 |
| staged rename calls/successes        |       3,817 |
| staged size updates/successes        |       3,874 |
| staged write calls                   |      37,140 |
| staged write bytes                   | 106,132,435 |
| staged `copy_file_range` successes   |       3,828 |
| staged `copy_file_range` bytes       |  31,630,764 |
| staged `copy_file_range` fallbacks   |           0 |

The staged-negative filter skipped 1,331,308 lookups with known-unstaged
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
| CAS promotion digest                 | 642.254 ms |
| CAS promotion rename                 | 127.801 ms |
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
| gRPC data frames                     |     37,011 |
| gRPC file payload frames             |      6,902 |
| gRPC `sendfile` attempts/successes   |      6,902 |
| gRPC `sendfile` bytes                | 57,616,538 |
| gRPC `sendfile` fallbacks            |          0 |

The measured TCP-to-vsock bridge logged two connections, 28.25 MiB from client
to guest, 37.36 MiB from guest to client, and zero read/write pump errors.
ByteStream reads remained file-backed and all 6,902 gRPC `sendfile` attempts
succeeded.
