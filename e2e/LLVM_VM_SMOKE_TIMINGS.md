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

- Generated: `2026-07-30 18:13:49 EDT`
- Command: `ACTIOND_BAZEL_BUILD_FLAGS="--jobs=64 --distdir=/private/tmp/actiond-audit-distdir --override_repository=llvm++osx+macos_sdk=/private/tmp/actiond-audit-macos-sdk" ACTIOND_LLVM_SMOKE_MAC_HOST=0 e2e/run_llvm_vm_smoke.sh`
- Output root: `/var/folders/p4/xn8y5q_j24l5xwgwd_jx5c340000gn/T/actiond-llvm-vm-smoke.Y3w9vq`
- Workload: `@llvm-project//llvm:llvm-tblgen`, jobs=8
- VM warmup target: `//e2e:llvm_exec_warmup`
- Target and VM host platform: `@llvm//platforms:linux_arm64_musl`
- Build mode: `-c opt --strip=always --stripopt=--strip-all`
- VM warmup: `88.364s`; `2207 processes: 190 internal, 2017 remote`
- Measured VM build: `91.490s`; `2310 processes: 4 action cache hit, 204 internal, 2106 remote`
- Measured executions and timing records: `2106`
- Mac-host baseline: not run (`ACTIOND_LLVM_SMOKE_MAC_HOST=0`)

The prior checked-in run used jobs=10 rather than jobs=8. Wall-clock times are
therefore not directly comparable; compare filesystem counters and identical
action counts instead.

## Filesystem Comparison With Prior Checked-In Run

Counters include both warmup and measured builds.

| Counter                              | Prior       | Current     |
| ------------------------------------ | ----------: | ----------: |
| actiondfs mounts                     |       4,123 |       4,122 |
| root directory parses                |       4,123 |       1,405 |
| cached directory hits                |     155,482 |     163,011 |
| cached directory misses              |       5,212 |       6,606 |
| directory blob reads                 |       9,335 |       6,605 |
| staged ensure-directory calls        |      12,182 |      16,012 |
| staged ensure-directory components   |     103,548 |          16 |
| staged ensure-directory existing     |     103,532 |           0 |
| staged ensure-directory created      |          16 |          16 |
| staged parent dentry hits            |           — |      15,996 |
| blob-path cache hits                 |     437,047 |     460,692 |
| blob-path cache misses               |       6,969 |       6,883 |
| blob-path cache evictions            |           — |           0 |
| staged backing open attempts         |      19,656 |      15,825 |
| staged backing open lookup           | 10.351 ms   | 0.595 ms    |
| staged `copy_file_range` successes   |       3,828 |       3,828 |
| staged `copy_file_range` fallbacks   |           0 |           0 |

Root directory parsing fell by 65.9%, directory blob reads fell by 29.2%, and
staged directory component traversal fell from 103,548 to 16. Caching by CAS
directory dentry preserves isolation between different CAS directories while
sharing entries across action mount namespaces. Cached staged parent dentries
avoid re-walking already prepared output directory components.

## VM Stage Timing

All timing values are milliseconds.

| Stage                 |   Min |    p25 |    p50 |    p75 |      p95 |    Mean |       Max |
| --------------------- | ----: | -----: | -----: | -----: | -------: | ------: | --------: |
| total                 | 5.984 | 20.000 | 27.632 | 66.830 | 1635.430 | 292.980 | 10780.159 |
| input fetch/setup     | 0.424 |  0.580 |  0.660 |  1.038 |    2.112 |   1.150 |    68.304 |
| execute               | 4.815 | 18.214 | 25.415 | 62.811 | 1632.914 | 290.375 | 10772.926 |
| output upload/collect | 0.014 |  0.126 |  0.240 |  1.532 |    5.279 |   1.455 |   242.628 |

## Runner Timing

`process/io` includes action execution, stdout/stderr drain, and lazy actiondfs
input reads. All timing values are milliseconds.

| Runner Stage   |   Min |    p25 |    p50 |    p75 |      p95 |    Mean |       Max |
| -------------- | ----: | -----: | -----: | -----: | -------: | ------: | --------: |
| parent prepare | 0.059 |  0.103 |  0.130 |  0.194 |    0.374 |   0.222 |    55.865 |
| fork           | 0.229 |  0.429 |  0.497 |  1.044 |    4.453 |   1.104 |    45.505 |
| child setup    | 0.002 |  0.838 |  1.567 |  2.901 |   11.162 |   3.534 |   142.123 |
| process/io     | 0.004 | 15.105 | 21.658 | 54.810 | 1630.145 | 285.361 | 10770.416 |
| wait           | 0.000 |  0.000 |  0.000 |  0.000 |    0.014 |   0.002 |     0.213 |
| stdio digest   | 0.000 |  0.000 |  0.001 |  0.001 |    0.001 |   0.001 |     0.096 |

## actiondfs Counters

These `/proc/actiondfs_stats` counters cover the VM lifetime.

| Counter                       |           Value |
| ----------------------------- | --------------: |
| mounts                        |           4,122 |
| root directory parses         |           1,405 |
| cached directory requests     |         169,617 |
| cached directory hits         |         163,011 |
| cached directory misses       |           6,606 |
| lookups                       |       1,406,668 |
| lookup hits                   |         841,778 |
| lookup negative               |         564,890 |
| blob open attempts            |         474,180 |
| blob-path cache hits          |         460,692 |
| blob-path cache misses        |           6,883 |
| blob-path cache evictions     |               0 |
| node blob cache hits          |         472,190 |
| node blob cache misses        |         467,575 |
| backing reads                 |         415,332 |
| backing read bytes            |   1,303,012,282 |
| mmap calls                    |          53,030 |
| mmap bytes                    | 1,900,832,624,640 |
| mmap failures                 |               0 |
| directory blob reads          |           6,605 |
| directory blob bytes          |       2,720,060 |

## Staged Filesystem Counters

| Counter                              |       Value |
| ------------------------------------ | ----------: |
| staged ensure-directory calls        |      16,012 |
| staged ensure-directory components   |          16 |
| staged ensure-directory existing     |           0 |
| staged ensure-directory created      |          16 |
| staged parent dentry hits            |      15,996 |
| staged inode lookups                 |   1,406,668 |
| staged inode unstaged-parent skips   |   1,331,309 |
| staged inode lookup hits             |      35,518 |
| staged inode lookup negative         |      39,841 |
| staged inode input-directory merges  |      18,382 |
| staged backing open attempts         |      15,825 |
| staged backing open failures         |           0 |
| staged backing open total            |   14.527 ms |
| staged backing open lookup           |    0.595 ms |
| staged backing open file             |   11.980 ms |
| staged create calls/successes        |      11,981 |
| staged mkdir calls/successes         |         198 |
| staged rename calls/successes        |       3,817 |
| staged size updates/successes        |       3,874 |
| staged write calls                   |      37,065 |
| staged write bytes                   | 105,766,927 |
| staged `copy_file_range` successes   |       3,828 |
| staged `copy_file_range` bytes       |  31,630,764 |
| staged `copy_file_range` fallbacks   |           0 |

The staged-negative filter skipped 1,331,309 lookups with known-unstaged
parents. All 3,828 `copy_file_range` attempts succeeded without buffered
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
| CAS promotion digest                 | 710.983 ms |
| CAS promotion rename                 | 138.289 ms |
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

The measured TCP-to-vsock bridge logged two connections, 28.33 MiB from client
to guest, 37.36 MiB from guest to client, and zero read/write pump errors.
ByteStream reads remained file-backed and all 6,902 gRPC `sendfile` attempts
succeeded.
