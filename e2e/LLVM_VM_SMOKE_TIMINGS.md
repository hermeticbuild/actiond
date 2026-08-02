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

- Generated: `2026-08-02 17:30:51 EDT`
- Command: `ACTIOND_BAZEL_BUILD_FLAGS="--jobs=32 --distdir=/private/tmp/actiond-audit-distdir --override_repository=llvm++osx+macos_sdk=/private/tmp/actiond-audit-macos-sdk" ACTIOND_LLVM_SMOKE_MAC_HOST=0 e2e/run_llvm_vm_smoke.sh`
- Output root: `/var/folders/p4/xn8y5q_j24l5xwgwd_jx5c340000gn/T/actiond-llvm-vm-smoke.gybdrT`
- Workload: `@llvm-project//llvm:llvm-tblgen`, jobs=8
- VM warmup target: `//e2e:llvm_exec_warmup`
- Target and VM host platform: `@llvm//platforms:linux_arm64_musl`
- Build mode: `-c opt --strip=always --stripopt=--strip-all`
- VM warmup: `96.797s`; `2207 processes: 190 internal, 2017 remote`
- Measured VM build: `117.050s`; `2310 processes: 4 action cache hit, 204 internal, 2106 remote`
- Measured executions and timing records: `2106`
- Mac-host baseline: not run (`ACTIOND_LLVM_SMOKE_MAC_HOST=0`)

The prior checked-in run completed the warmup in `92.411s` and the measured
build in `109.140s` with the same 2,017 warmup actions and 2,106 measured
actions. The current warmup is 4.7% slower and the measured build is 7.2%
slower. An earlier checked-in run completed in `97.375s`/`144.161s`, and an
intermediate run after the first ten changes completed in
`151.588s`/`155.934s`. Earlier runs of the same action sets completed in
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
| actiondfs mounts                     |       4,123 |       4,122 |
| root directory parses                |       1,406 |       1,406 |
| directory loads                      |     169,665 |     169,617 |
| cached directory requests            |     169,665 |     169,617 |
| cached directory hits                |     163,046 |     163,009 |
| cached directory misses              |       6,619 |       6,608 |
| cached directory races               |           0 |           2 |
| cached file records                  |      16,722 |      16,634 |
| cached directory records             |      12,934 |      12,914 |
| directory blob reads                 |       6,618 |       6,607 |
| staged ensure-directory calls        |      15,999 |      15,996 |
| staged ensure-directory components   |          16 |          16 |
| staged ensure-directory existing     |           0 |           0 |
| staged ensure-directory created      |          16 |          16 |
| staged parent dentry hits            |      15,983 |      15,980 |
| blob-path cache hits                 |     460,970 |     460,692 |
| blob-path cache misses               |       6,970 |       6,883 |
| blob-path cache evictions            |           0 |           0 |
| blob-path cache insertion races      |           0 |           0 |
| backing reads                        |     415,500 |     415,332 |
| input backing-file acquisitions      |     472,567 |     472,190 |
| mmap calls                           |      53,239 |      53,030 |
| staged write calls                   |      37,194 |      37,072 |
| staged backing open attempts         |      15,827 |      15,825 |
| staged backing open lookup           | 0.296 ms    | 0.295 ms    |
| staged `copy_file_range` successes   |       3,828 |       3,828 |
| staged `copy_file_range` fallbacks   |           0 |           0 |

The workload retained the same 2,017 warmup actions and 2,106 measured actions.
The 163,009 cached-directory hits used RCU without a per-node mutex. The
1,406,668 lookups retained the staged-negative filter, while cached input inode
lookups used `iget5_locked_rcu` without the global inode-hash lookup lock;
hashed inode identity and filesystem watches were preserved. Cached-directory
checks were inlined without constructing the directory-parser stack frame, and
input inode numbers used cached-child indexes instead of hashing filenames.
Immutable input inodes reused their mount root's timestamps.

The 16,634 cached file records and 12,914 cached directory records used 48-byte
cached-child records. Replacing each filename pointer with a 32-bit name offset
saved 236,384 bytes across those 29,548 records. Their 32-byte binary SHA-256
digests saved another 945,536 bytes compared with hexadecimal digests, and
decoding directly into each cached child avoided another 945,536 bytes of
temporary digest copies. Each cached directory used one
sorted child vector instead of separate file, directory, and symlink vectors;
packed filenames reused unused child-vector capacity when possible and needed
a separate allocation only when that capacity was insufficient.
Cached-directory records borrowed persistent child digests, compared matching
digest pointers before bytes, rejected full cache-key mismatches before digest
comparisons, and skipped sorting already ordered children.
Directories containing one child type skipped sorting entirely, protobuf
parsing decoded single-byte varints directly, and packed filename sizes were
accumulated while parsing instead of rescanning completed child records.
Each filesystem node omitted its former directory-loading mutex, and each of
the 4,122 mounts borrowed its mount-option buffer. Production cached-directory
publication used a release store instead of an atomic exchange for each
directory load; this instrumented run recorded 169,617 directory loads and
retained atomic exchanges for exact race statistics.

The 472,190 input backing-file acquisitions borrowed open backing files without
per-operation references. The 415,332 synchronous backing reads, 53,030 mmap
calls, and 37,072 synchronous staged writes avoided redundant credential swaps.
Staged creates reused VFS negative lookup results, initialized staged ownership
directly, and retained backing-inode ownership through the staged mount idmap.
Directory-blob closes and blob-cache entry releases omitted deferred close and
release workqueues; private directory-blob handles also avoided global file
accounting. Staged create, mkdir, unlink, rename, size updates, mmap, and child
lookups reported zero failures. Staged-directory iteration allocated state
only when staged entries existed; the separate synthetic VM stress run
recorded 13 staged-directory hits with zero misses.

Input inode owners used `current_fsuid_fsgid`, while identity-mapped staged
inodes copied backing UID/GID directly instead of performing idmap conversions
or taking owner spinlocks when those identities already matched. Immutable
inode identity was initialized exactly once before RCU publication. Synchronous
backing reads and staged writes constructed backing
credential contexts only for asynchronous or direct-I/O requests, and immutable
input reads let `iov_iter_truncate` clamp the requested byte count directly.
Directory attributes used `generic_fillattr` directly, while regular files and
symlinks used the VFS generic attribute fallback. Staged writes and
`copy_file_range` skipped `file_remove_privs` only when `IS_NOSEC` confirmed no
security attributes required processing.

All 18,382 staged input-directory merges searched cached input directories, and
75,360 staged positive or negative inode lookups avoided exclusive backing
directory locks. Resolving 6,883 blob-path cache misses and 6,607 directory
blobs directly avoided 13,490 temporary `PATH_MAX` pathname allocations, or
about 52.7 MiB of cumulative allocation. Unsupported extended attributes were
skipped without bypassing inode permission checks, and backing filesystem
security flags were inherited only when the backing filesystem advertised the
same guarantees.

## VM Stage Timing

All timing values are milliseconds.

| Stage                 |   Min |    p25 |    p50 |    p75 |      p95 |    Mean |       Max |
| --------------------- | ----: | -----: | -----: | -----: | -------: | ------: | --------: |
| total                 | 6.250 | 21.243 | 31.585 | 96.870 | 2035.553 | 387.824 | 26588.199 |
| input fetch/setup     | 0.408 |  0.578 |  0.619 |  0.974 |    2.850 |   1.676 |   342.861 |
| execute               | 5.306 | 19.571 | 29.290 | 93.815 | 2028.774 | 384.406 | 26542.337 |
| output upload/collect | 0.023 |  0.127 |  0.224 |  1.308 |    5.351 |   1.742 |   192.466 |

## Runner Timing

`child setup` includes successful `execve`. `process/io` starts after
close-on-exec confirmation and includes action execution, stdout/stderr drain,
and lazy actiondfs input reads. All timing values are milliseconds.

| Runner Stage   |   Min |    p25 |    p50 |    p75 |      p95 |    Mean |       Max |
| -------------- | ----: | -----: | -----: | -----: | -------: | ------: | --------: |
| parent prepare | 0.055 |  0.100 |  0.125 |  0.158 |    0.464 |   0.343 |   214.156 |
| fork           | 0.336 |  0.550 |  0.628 |  0.983 |    6.875 |   3.591 |   612.222 |
| child setup    | 0.006 |  1.887 |  3.547 |  7.841 |   54.526 |  12.610 |   823.940 |
| process/io     | 1.964 | 15.055 | 22.290 | 65.937 | 1999.065 | 367.155 | 26393.116 |
| wait           | 0.000 |  0.000 |  0.000 |  0.000 |    3.027 |   0.325 |    41.446 |
| stdio digest   | 0.000 |  0.000 |  0.001 |  0.001 |    0.001 |   0.008 |    15.187 |

## actiondfs Counters

These `/proc/actiondfs_stats` counters cover the VM lifetime.

| Counter                       |           Value |
| ----------------------------- | --------------: |
| mounts                        |           4,122 |
| root directory parses         |           1,406 |
| directory loads               |         169,617 |
| cached directory requests     |         169,617 |
| cached directory hits         |         163,009 |
| cached directory misses       |           6,608 |
| cached directory races        |               2 |
| lookups                       |       1,406,668 |
| lookup hits                   |         841,778 |
| lookup negative               |         564,890 |
| blob open attempts            |         474,182 |
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
| directory blob reads          |           6,607 |
| directory blob bytes          |       2,720,991 |

## Staged Filesystem Counters

| Counter                              |       Value |
| ------------------------------------ | ----------: |
| staged ensure-directory calls        |      15,996 |
| staged ensure-directory components   |          16 |
| staged ensure-directory existing     |           0 |
| staged ensure-directory created      |          16 |
| staged parent dentry hits            |      15,980 |
| staged child lookups                 |      87,570 |
| staged child lookup hits             |      35,533 |
| staged child lookup negative         |      52,037 |
| staged child lookup failures         |           0 |
| staged inode lookups                 |   1,406,668 |
| staged inode unstaged-parent skips   |   1,331,308 |
| staged inode lookup hits             |      35,518 |
| staged inode lookup negative         |      39,842 |
| staged inode lookup failures         |           0 |
| staged inode input-directory merges  |      18,382 |
| staged backing open attempts         |      15,825 |
| staged backing open failures         |           0 |
| staged backing open total            |   14.041 ms |
| staged backing open lookup           |    0.295 ms |
| staged backing open file             |    9.564 ms |
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
| staged write calls                   |      37,072 |
| staged write bytes                   | 105,802,304 |
| staged mmap calls                    |          30 |
| staged mmap bytes                    |   2,084,864 |
| staged mmap failures                 |           0 |
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
| CAS promoted bytes                   | 31,753,839 |
| CAS digest bytes                     | 84,087,791 |
| CAS promotion digest                 | 848.446 ms |
| CAS promotion rename                 | 165.918 ms |
| CAS cross-device fallbacks           |          0 |
| CAS permission fallbacks             |          0 |
| CAS put-file copy calls              |          0 |

## ByteStream, gRPC, And VM Bridge Counters

| Counter                              |      Value |
| ------------------------------------ | ---------: |
| ByteStream file reads                |      4,038 |
| ByteStream file bytes                | 57,615,015 |
| ByteStream buffered reads            |          0 |
| gRPC response tasks started          |     36,229 |
| gRPC response tasks failed           |          0 |
| gRPC response concurrency waits      |          0 |
| gRPC data frames                     |     37,011 |
| gRPC file payload frames             |      6,902 |
| gRPC `sendfile` attempts/successes   |      6,902 |
| gRPC `sendfile` bytes                | 57,615,015 |
| gRPC `sendfile` fallbacks            |          0 |

The measured TCP-to-vsock bridge logged two connections, 28.18 MiB from client
to guest, 37.37 MiB from guest to client, and zero read/write pump errors.
ByteStream reads remained file-backed and all 6,902 gRPC `sendfile` attempts
succeeded.
