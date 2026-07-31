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

- Generated: `2026-07-30 21:35:18 EDT`
- Command: `ACTIOND_BAZEL_BUILD_FLAGS="--jobs=64 --distdir=/private/tmp/actiond-audit-distdir --override_repository=llvm++osx+macos_sdk=/private/tmp/actiond-audit-macos-sdk" ACTIOND_LLVM_SMOKE_MAC_HOST=0 e2e/run_llvm_vm_smoke.sh`
- Output root: `/var/folders/p4/xn8y5q_j24l5xwgwd_jx5c340000gn/T/actiond-llvm-vm-smoke.04G6ke`
- Workload: `@llvm-project//llvm:llvm-tblgen`, jobs=8
- VM warmup target: `//e2e:llvm_exec_warmup`
- Target and VM host platform: `@llvm//platforms:linux_arm64_musl`
- Build mode: `-c opt --strip=always --stripopt=--strip-all`
- VM warmup: `106.289s`; `2207 processes: 190 internal, 2017 remote`
- Measured VM build: `138.481s`; `2310 processes: 4 action cache hit, 204 internal, 2106 remote`
- Measured executions and timing records: `2106`
- Mac-host baseline: not run (`ACTIOND_LLVM_SMOKE_MAC_HOST=0`)

The prior checked-in run used the same jobs=8 and completed the warmup in
`88.364s` and measured build in `91.490s`. An intermediate run with the new
action isolation took `256.834s` for warmup and `140.328s` for the measured
build. Direct namespace cloning and the default-enabled seccomp BPF JIT reduced
the warmup to `106.289s`. The measured build remains slower than the prior
checked-in result; runner samples show scheduler and memory-contention outliers
of `389.600 ms` for process creation and `1,478.677 ms` for child setup.

## Filesystem Comparison With Prior Checked-In Run

Counters include both warmup and measured builds.

| Counter                              | Prior       | Current     |
| ------------------------------------ | ----------: | ----------: |
| actiondfs mounts                     |       4,122 |       4,108 |
| root directory parses                |       1,405 |       1,403 |
| cached directory hits                |     163,011 |     162,614 |
| cached directory misses              |       6,606 |       6,603 |
| directory blob reads                 |       6,605 |       6,602 |
| staged ensure-directory calls        |      16,012 |      15,949 |
| staged ensure-directory components   |          16 |          15 |
| staged ensure-directory existing     |           0 |           0 |
| staged ensure-directory created      |          16 |          15 |
| staged parent dentry hits            |      15,996 |      15,934 |
| blob-path cache hits                 |     460,692 |     459,163 |
| blob-path cache misses               |       6,883 |       6,881 |
| blob-path cache evictions            |           0 |           0 |
| staged backing open attempts         |      15,825 |      15,782 |
| staged backing open lookup           | 0.595 ms    | 0.866 ms    |
| staged `copy_file_range` successes   |       3,828 |       3,819 |
| staged `copy_file_range` fallbacks   |           0 |           1 |

The workload retained the same 2,017 warmup actions and 2,106 measured actions.
Root-directory parsing, directory blob reads, staged parent-directory reuse, and
blob-path cache behavior remain close to the previous checked-in result.

## VM Stage Timing

All timing values are milliseconds.

| Stage                 |   Min |    p25 |    p50 |    p75 |      p95 |    Mean |       Max |
| --------------------- | ----: | -----: | -----: | -----: | -------: | ------: | --------: |
| total                 | 6.799 | 27.671 | 58.352 | 279.327 | 2134.781 | 444.223 | 15195.751 |
| input fetch/setup     | 0.421 |  0.583 |  0.656 |   1.138 |    8.916 |   3.328 |   302.326 |
| execute               | 6.003 | 25.217 | 54.401 | 267.455 | 2132.625 | 438.685 | 15191.620 |
| output upload/collect | 0.021 |  0.131 |  0.264 |   1.846 |    6.818 |   2.209 |   246.605 |

## Runner Timing

`child setup` includes successful `execve`. `process/io` starts after
close-on-exec confirmation and includes action execution, stdout/stderr drain,
and lazy actiondfs input reads. All timing values are milliseconds.

| Runner Stage   |   Min |    p25 |    p50 |    p75 |      p95 |    Mean |       Max |
| -------------- | ----: | -----: | -----: | -----: | -------: | ------: | --------: |
| parent prepare | 0.058 |  0.092 |  0.116 |   0.166 |    0.708 |   0.577 |    84.637 |
| fork           | 0.329 |  0.632 |  0.732 |   1.817 |   25.078 |   5.876 |   389.600 |
| child setup    | 0.005 |  2.808 |  5.292 |  18.657 |  135.783 |  26.781 |  1478.677 |
| process/io     | 1.242 | 18.012 | 33.622 | 194.182 | 2097.637 | 404.387 | 15184.102 |
| wait           | 0.000 |  0.000 |  0.000 |   0.000 |    4.524 |   0.567 |    36.906 |
| stdio digest   | 0.000 |  0.000 |  0.001 |   0.001 |    0.001 |   0.004 |     5.998 |

## actiondfs Counters

These `/proc/actiondfs_stats` counters cover the VM lifetime.

| Counter                       |           Value |
| ----------------------------- | --------------: |
| mounts                        |           4,108 |
| root directory parses         |           1,403 |
| cached directory requests     |         169,217 |
| cached directory hits         |         162,614 |
| cached directory misses       |           6,603 |
| lookups                       |       1,403,982 |
| lookup hits                   |         839,807 |
| lookup negative               |         564,175 |
| blob open attempts            |         472,646 |
| blob-path cache hits          |         459,163 |
| blob-path cache misses        |           6,881 |
| blob-path cache evictions     |               0 |
| node blob cache hits          |         470,582 |
| node blob cache misses        |         466,044 |
| backing reads                 |         413,804 |
| backing read bytes            |   1,300,645,948 |
| mmap calls                    |          52,958 |
| mmap bytes                    | 1,895,503,368,192 |
| mmap failures                 |               0 |
| directory blob reads          |           6,602 |
| directory blob bytes          |       2,731,622 |

## Staged Filesystem Counters

| Counter                              |       Value |
| ------------------------------------ | ----------: |
| staged ensure-directory calls        |      15,949 |
| staged ensure-directory components   |          15 |
| staged ensure-directory existing     |           0 |
| staged ensure-directory created      |          15 |
| staged parent dentry hits            |      15,934 |
| staged inode lookups                 |   1,403,982 |
| staged inode unstaged-parent skips   |   1,328,837 |
| staged inode lookup hits             |      35,395 |
| staged inode lookup negative         |      39,750 |
| staged inode input-directory merges  |      18,319 |
| staged backing open attempts         |      15,782 |
| staged backing open failures         |           0 |
| staged backing open total            |   13.436 ms |
| staged backing open lookup           |    0.866 ms |
| staged backing open file             |   10.146 ms |
| staged create calls/successes        |      11,947 |
| staged mkdir calls/successes         |         198 |
| staged rename calls/successes        |       3,804 |
| staged size updates/successes        |       3,865 |
| staged write calls                   |      36,648 |
| staged write bytes                   | 104,099,831 |
| staged `copy_file_range` successes   |       3,819 |
| staged `copy_file_range` bytes       |  29,413,418 |
| staged `copy_file_range` fallbacks   |           1 |

The staged-negative filter skipped 1,328,837 lookups with known-unstaged
parents. Of 3,820 `copy_file_range` attempts, 3,819 succeeded and one used the
buffered fallback.

## CAS Put-File Promotion Counters

| Counter                              |      Value |
| ------------------------------------ | ---------: |
| CAS put-file calls                   |      7,925 |
| CAS promotion attempts               |      7,925 |
| CAS promotion success                |      2,088 |
| CAS existing-blob hits               |      5,837 |
| CAS promoted bytes                   | 32,204,511 |
| CAS digest bytes                     | 80,077,779 |
| CAS promotion digest                 | 762.362 ms |
| CAS promotion rename                 | 219.052 ms |
| CAS cross-device fallbacks           |          0 |
| CAS permission fallbacks             |          0 |
| CAS put-file copy calls              |          0 |

## ByteStream, gRPC, And VM Bridge Counters

| Counter                              |      Value |
| ------------------------------------ | ---------: |
| ByteStream file reads                |      4,025 |
| ByteStream file bytes                | 57,704,579 |
| ByteStream buffered reads            |          0 |
| gRPC response tasks started          |     36,160 |
| gRPC response tasks failed           |          0 |
| gRPC response concurrency waits      |          0 |
| gRPC data frames                     |     36,948 |
| gRPC file payload frames             |      6,895 |
| gRPC `sendfile` attempts/successes   |      6,895 |
| gRPC `sendfile` bytes                | 57,704,579 |
| gRPC `sendfile` fallbacks            |          0 |

The measured TCP-to-vsock bridge logged two connections, 28.36 MiB from client
to guest, 37.37 MiB from guest to client, and zero read/write pump errors.
ByteStream reads remained file-backed and all 6,895 gRPC `sendfile` attempts
succeeded.
