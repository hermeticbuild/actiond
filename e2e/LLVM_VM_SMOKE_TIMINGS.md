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

- Generated: `2026-08-01 23:15:01 EDT`
- Command: `ACTIOND_BAZEL_BUILD_FLAGS="--jobs=32 --distdir=/private/tmp/actiond-audit-distdir --override_repository=llvm++osx+macos_sdk=/private/tmp/actiond-audit-macos-sdk" ACTIOND_LLVM_SMOKE_MAC_HOST=0 e2e/run_llvm_vm_smoke.sh`
- Output root: `/var/folders/p4/xn8y5q_j24l5xwgwd_jx5c340000gn/T/actiond-llvm-vm-smoke.J4l9IY`
- Workload: `@llvm-project//llvm:llvm-tblgen`, jobs=8
- VM warmup target: `//e2e:llvm_exec_warmup`
- Target and VM host platform: `@llvm//platforms:linux_arm64_musl`
- Build mode: `-c opt --strip=always --stripopt=--strip-all`
- VM warmup: `92.411s`; `2207 processes: 190 internal, 2017 remote`
- Measured VM build: `109.140s`; `2310 processes: 4 action cache hit, 204 internal, 2106 remote`
- Measured executions and timing records: `2106`
- Mac-host baseline: not run (`ACTIOND_LLVM_SMOKE_MAC_HOST=0`)

The prior checked-in run completed the warmup in `97.375s` and the measured
build in `144.161s` with the same 2,017 warmup actions and 2,106 measured
actions; the current measured build is 24.3% faster. An intermediate run after
the first ten changes completed the warmup in `151.588s` and the measured
build in `155.934s`. Earlier runs of the same action sets completed in
`90.262s`/`98.569s`, `82.129s`/`92.336s`, `63.992s`/`86.002s`,
`96.032s`/`104.393s`, and `94.614s`/`180.238s`. Host CPU and memory contention
produce substantial variation, so these local elapsed times do not isolate an
`actiondfs` improvement or regression; compare matched CI actiond/native
timings instead.

Earlier checked-in runs completed the warmup and measured build in
`102.136s`/`108.831s` and `106.289s`/`138.481s`. A run before action isolation
completed the warmup in `88.364s` and the measured build in `91.490s`. An
intermediate action-isolation run took `256.834s` for warmup and `140.328s`
for the measured build.

## Filesystem Comparison With Prior Checked-In Run

Counters include both warmup and measured builds.

| Counter                              | Prior       | Current     |
| ------------------------------------ | ----------: | ----------: |
| actiondfs mounts                     |       4,123 |       4,123 |
| root directory parses                |       1,407 |       1,406 |
| directory loads                      |     169,665 |     169,665 |
| cached directory requests            |     169,665 |     169,665 |
| cached directory hits                |     163,042 |     163,046 |
| cached directory misses              |       6,623 |       6,619 |
| cached directory races               |           4 |           0 |
| cached file records                  |      16,723 |      16,722 |
| cached directory records             |      12,937 |      12,934 |
| directory blob reads                 |       6,622 |       6,618 |
| staged ensure-directory calls        |      16,000 |      15,999 |
| staged ensure-directory components   |          16 |          16 |
| staged ensure-directory existing     |           0 |           0 |
| staged ensure-directory created      |          16 |          16 |
| staged parent dentry hits            |      15,984 |      15,983 |
| blob-path cache hits                 |     460,968 |     460,970 |
| blob-path cache misses               |       6,972 |       6,970 |
| blob-path cache evictions            |           0 |           0 |
| blob-path cache insertion races      |           2 |           0 |
| backing reads                        |     415,500 |     415,500 |
| input backing-file acquisitions      |     472,567 |     472,567 |
| mmap calls                           |      53,239 |      53,239 |
| staged write calls                   |      37,194 |      37,194 |
| staged backing open attempts         |      15,828 |      15,827 |
| staged backing open lookup           | 2.606 ms    | 0.296 ms    |
| staged `copy_file_range` successes   |       3,828 |       3,828 |
| staged `copy_file_range` fallbacks   |           0 |           0 |

The workload retained the same 2,017 warmup actions and 2,106 measured actions.
The 163,046 cached-directory hits used RCU without a per-node mutex. The
1,407,098 lookups retained the staged-negative filter, while cached input inode
lookups used `iget5_locked_rcu` without the global inode-hash lookup lock;
hashed inode identity and filesystem watches were preserved. Cached-directory
checks were inlined without constructing the directory-parser stack frame, and
input inode numbers used cached-child indexes instead of hashing filenames.
Immutable input inodes reused their mount root's timestamps.

The 16,722 cached file records and 12,934 cached directory records stored
32-byte binary SHA-256 digests instead of 64-byte hexadecimal digests, saving
948,992 bytes across those 29,656 records. Each cached directory used one
sorted child vector instead of separate file, directory, and symlink vectors;
packed filenames reused unused child-vector capacity when possible and needed
a separate allocation only when that capacity was insufficient.
Cached-directory records borrowed persistent child digests, compared matching
digest pointers before bytes, rejected full cache-key mismatches before digest
comparisons, and skipped sorting already ordered children.
Each filesystem node omitted its former directory-loading mutex, and each of
the 4,123 mounts borrowed its mount-option buffer.

The 472,567 input backing-file acquisitions borrowed open backing files without
per-operation references. The 415,500 synchronous backing reads, 53,239 mmap
calls, and 37,194 synchronous staged writes avoided redundant credential swaps.
Staged creates reused VFS negative lookup results, initialized staged ownership
directly, and retained backing-inode ownership through the staged mount idmap.
Directory-blob closes and blob-cache entry releases omitted deferred close and
release workqueues. Staged create, mkdir, unlink, rename, size updates, mmap,
and child lookups reported zero failures.

Input inode owners used `current_fsuid_fsgid`, while identity-mapped staged
inodes copied backing UID/GID directly instead of performing idmap
conversions. Synchronous backing reads and staged writes constructed backing
credential contexts only for asynchronous or direct-I/O requests, and immutable
input reads let `iov_iter_truncate` clamp the requested byte count directly.
Directory attributes used `generic_fillattr` directly, while regular files and
symlinks used the VFS generic attribute fallback. Staged writes and
`copy_file_range` skipped `file_remove_privs` only when `IS_NOSEC` confirmed no
security attributes required processing.

All 18,388 staged input-directory merges searched cached input directories, and
75,376 staged positive or negative inode lookups avoided exclusive backing
directory locks. Resolving 6,970 blob-path cache misses and 6,618 directory
blobs directly avoided 13,588 temporary `PATH_MAX` pathname allocations, or
about 53.1 MiB of cumulative allocation. Unsupported extended attributes were
skipped without bypassing inode permission checks, and backing filesystem
security flags were inherited only when the backing filesystem advertised the
same guarantees.

## VM Stage Timing

All timing values are milliseconds.

| Stage                 |   Min |    p25 |    p50 |    p75 |      p95 |    Mean |       Max |
| --------------------- | ----: | -----: | -----: | -----: | -------: | ------: | --------: |
| total                 | 4.379 | 23.305 | 31.561 | 84.933 | 1998.589 | 358.241 | 11136.456 |
| input fetch/setup     | 0.423 |  0.589 |  0.643 |  1.031 |    2.596 |   1.749 |   480.404 |
| execute               | 3.626 | 21.362 | 29.330 | 80.134 | 1993.589 | 354.955 | 11131.297 |
| output upload/collect | 0.022 |  0.138 |  0.280 |  1.604 |    5.317 |   1.537 |   106.624 |

## Runner Timing

`child setup` includes successful `execve`. `process/io` starts after
close-on-exec confirmation and includes action execution, stdout/stderr drain,
and lazy actiondfs input reads. All timing values are milliseconds.

| Runner Stage   |   Min |    p25 |    p50 |    p75 |      p95 |    Mean |       Max |
| -------------- | ----: | -----: | -----: | -----: | -------: | ------: | --------: |
| parent prepare | 0.061 |  0.101 |  0.121 |  0.156 |    0.452 |   0.225 |    33.856 |
| fork           | 0.283 |  0.515 |  0.589 |  0.977 |    6.401 |   2.939 |   217.086 |
| child setup    | 0.008 |  2.190 |  3.563 |  6.238 |   22.170 |   7.461 |   322.330 |
| process/io     | 1.689 | 15.803 | 21.989 | 54.066 | 1987.070 | 343.441 | 11127.559 |
| wait           | 0.000 |  0.000 |  0.000 |  0.000 |    4.653 |   0.681 |    32.240 |
| stdio digest   | 0.000 |  0.000 |  0.001 |  0.001 |    0.001 |   0.001 |     0.106 |

## actiondfs Counters

These `/proc/actiondfs_stats` counters cover the VM lifetime.

| Counter                       |           Value |
| ----------------------------- | --------------: |
| mounts                        |           4,123 |
| root directory parses         |           1,406 |
| directory loads               |         169,665 |
| cached directory requests     |         169,665 |
| cached directory hits         |         163,046 |
| cached directory misses       |           6,619 |
| cached directory races        |               0 |
| lookups                       |       1,407,098 |
| lookup hits                   |         842,187 |
| lookup negative               |         564,911 |
| blob open attempts            |         474,558 |
| blob open stale retries       |               0 |
| blob-path cache hits          |         460,970 |
| blob-path cache misses        |           6,970 |
| blob-path cache evictions     |               0 |
| blob-path cache insertion races |             0 |
| node blob cache hits          |         472,567 |
| node blob cache misses        |         467,940 |
| backing reads                 |         415,500 |
| backing read bytes            |   1,303,975,362 |
| backing read stale retries    |               0 |
| mmap calls                    |          53,239 |
| mmap bytes                    | 1,901,676,589,056 |
| mmap failures                 |               0 |
| directory blob reads          |           6,618 |
| directory blob bytes          |       2,731,662 |

## Staged Filesystem Counters

| Counter                              |       Value |
| ------------------------------------ | ----------: |
| staged ensure-directory calls        |      15,999 |
| staged ensure-directory components   |          16 |
| staged ensure-directory existing     |           0 |
| staged ensure-directory created      |          16 |
| staged parent dentry hits            |      15,983 |
| staged child lookups                 |      87,589 |
| staged child lookup hits             |      35,540 |
| staged child lookup negative         |      52,049 |
| staged child lookup failures         |           0 |
| staged inode lookups                 |   1,407,098 |
| staged inode unstaged-parent skips   |   1,331,722 |
| staged inode lookup hits             |      35,524 |
| staged inode lookup negative         |      39,852 |
| staged inode lookup failures         |           0 |
| staged inode input-directory merges  |      18,388 |
| staged backing open attempts         |      15,827 |
| staged backing open failures         |           0 |
| staged backing open total            |   19.004 ms |
| staged backing open lookup           |    0.296 ms |
| staged backing open file             |   16.781 ms |
| staged create calls/successes        |      11,983 |
| staged create failures               |           0 |
| staged mkdir calls/successes         |         198 |
| staged mkdir failures                |           0 |
| staged unlink calls/successes        |          16 |
| staged unlink failures               |           0 |
| staged rename calls/successes        |       3,818 |
| staged rename failures               |           0 |
| staged size updates/successes        |       3,875 |
| staged size update failures          |           0 |
| staged write calls                   |      37,194 |
| staged write bytes                   | 106,356,427 |
| staged mmap calls                    |          31 |
| staged mmap bytes                    |   2,088,960 |
| staged mmap failures                 |           0 |
| staged `copy_file_range` successes   |       3,828 |
| staged `copy_file_range` bytes       |  31,630,764 |
| staged `copy_file_range` fallbacks   |           0 |

The staged-negative filter skipped 1,331,722 lookups with known-unstaged
parents. All 3,828 `copy_file_range` attempts succeeded without a buffered
fallback.

## CAS Put-File Promotion Counters

| Counter                              |      Value |
| ------------------------------------ | ---------: |
| CAS put-file calls                   |      7,948 |
| CAS promotion attempts               |      7,948 |
| CAS promotion success                |      2,088 |
| CAS existing-blob hits               |      5,860 |
| CAS promoted bytes                   | 32,204,511 |
| CAS digest bytes                     | 84,538,463 |
| CAS promotion digest                 | 686.880 ms |
| CAS promotion rename                 | 142.628 ms |
| CAS cross-device fallbacks           |          0 |
| CAS permission fallbacks             |          0 |
| CAS put-file copy calls              |          0 |

## ByteStream, gRPC, And VM Bridge Counters

| Counter                              |      Value |
| ------------------------------------ | ---------: |
| ByteStream file reads                |      4,039 |
| ByteStream file bytes                | 57,718,456 |
| ByteStream buffered reads            |          0 |
| gRPC response tasks started          |     36,254 |
| gRPC response tasks failed           |          0 |
| gRPC response concurrency waits      |          0 |
| gRPC data frames                     |     37,041 |
| gRPC file payload frames             |      6,909 |
| gRPC `sendfile` attempts/successes   |      6,909 |
| gRPC `sendfile` bytes                | 57,718,456 |
| gRPC `sendfile` fallbacks            |          0 |

The measured TCP-to-vsock bridge logged two connections, 28.29 MiB from client
to guest, 37.37 MiB from guest to client, and zero read/write pump errors.
ByteStream reads remained file-backed and all 6,909 gRPC `sendfile` attempts
succeeded.
