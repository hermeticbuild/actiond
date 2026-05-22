# LLVM VM Smoke Timings

This file records the most recent checked-in LLVM VM smoke run. Re-run it with:

```bash
e2e/run_llvm_vm_smoke.sh
```

The script starts a fresh `darwin-actiond serve-vm` worker, runs `bazel clean
--expunge`, builds `@llvm-project//llvm:llvm-tblgen` from this repo's `@llvm`
module dependency, and writes parsed timing summaries under the printed output
directory. The VM build uses `@llvm//platforms:linux_arm64_musl` for both target
and host platform so generated exec tools run inside the Linux VM without glibc.
The runner also records a mac-host baseline with the same target platform and
the default macOS host platform. The latest output root is written to
`/tmp/actiond-last-llvm-vm-smoke-path`.

Both builds target `@llvm//platforms:linux_arm64_musl`. The VM build also uses
that as the host platform because exec tools run in Linux. The mac-host baseline
keeps the host platform as macOS so local exec tools are runnable on Darwin;
some output paths therefore still contain `darwin_arm64-opt` even though the
compile target triple is Linux musl.

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

- Generated: `2026-05-22 09:20:29 EDT`
- Command: `ACTIOND_LLVM_VM_SMOKE_ROOT=/tmp/actiond-llvm-cas-stage-stats-20260522-091717 ACTIOND_LLVM_SMOKE_MAC_HOST=0 ACTIOND_LLVM_SMOKE_VM=1 ACTIOND_LLVM_SMOKE_JOBS=8 e2e/run_llvm_vm_smoke.sh`
- Output root: `/tmp/actiond-llvm-cas-stage-stats-20260522-091717`
- Workload: `@llvm-project//llvm:llvm-tblgen`, jobs=8
- VM warmup target: `//e2e:llvm_exec_warmup`
- Target platform: `@llvm//platforms:linux_arm64_musl`
- VM host platform: `@llvm//platforms:linux_arm64_musl`
- Build mode: `-c opt --strip=always --stripopt=--strip-all`
- VM warmup elapsed: `55.146s`
- VM warmup processes: `2207 processes: 190 internal, 2017 remote`
- VM Bazel elapsed: `59.657s`
- VM executions: `2106`
- VM timing records parsed: `2106`
- VM Bazel processes: `2310 processes: 4 action cache hit, 204 internal, 2106 remote`
- Mac-host baseline: not run for this VM-focused actiondfs staging check

## Run Comparison

This compares the previous VFS-backed `copy_file_range` run, where the
actiondfs stage lived on `/work` tmpfs, against the current run, where the
stage lives under `/cas/actiondfs-stage` on the VM ext4 CAS image and output
collection can promote same-filesystem staged files into CAS by rename.

| Metric            | Previous |     New |   Delta |
| ----------------- | -------: | ------: | ------: |
| VM measured build |  60.358s | 59.657s | -0.701s |
| VM warmup         |  57.041s | 55.146s | -1.895s |

| VM Stage                | Previous Mean |  New Mean |     Delta |
| ----------------------- | ------------: | --------: | --------: |
| total                   |     194.454ms | 191.940ms |  -2.514ms |
| input fetch/materialize |       0.177ms |   0.769ms |  +0.592ms |
| execute                 |     193.525ms | 190.507ms |  -3.018ms |
| output upload/collect   |       0.751ms |   0.664ms |  -0.087ms |

## VM Stage Timing

All values are milliseconds.

| Stage                   |   Min |    p25 |    p50 |    p75 |      p95 |    Mean |      Max |
| ----------------------- | ----: | -----: | -----: | -----: | -------: | ------: | -------: |
| total                   | 3.270 | 15.173 | 18.612 | 28.997 | 1110.783 | 191.940 | 6422.421 |
| input fetch/materialize | 0.459 |  0.633 |  0.661 |  0.753 |    1.247 |   0.769 |   13.720 |
| execute                 | 2.010 | 14.190 | 17.550 | 27.497 | 1108.179 | 190.507 | 6418.218 |
| output upload/collect   | 0.085 |  0.188 |  0.209 |  0.354 |    1.950 |   0.664 |  196.492 |

## Runner Timing

`process/io` includes the action process runtime, stdout/stderr drain, and lazy
filesystem reads issued by the action through the mounted actiondfs tree.

| Runner Stage   |   Min |    p25 |    p50 |    p75 |      p95 |    Mean |      Max |
| -------------- | ----: | -----: | -----: | -----: | -------: | ------: | -------: |
| parent prepare | 0.076 |  0.111 |  0.123 |  0.141 |    0.280 |   0.147 |    1.300 |
| fork           | 0.189 |  0.384 |  0.412 |  0.519 |    4.190 |   0.875 |    8.956 |
| child setup    | 0.002 |  0.196 |  0.381 |  1.876 |    4.646 |   1.202 |    9.335 |
| process/io     | 0.071 | 12.023 | 15.826 | 25.333 | 1103.368 | 188.210 | 6413.176 |
| wait           | 0.000 |  0.000 |  0.000 |  0.007 |    0.015 |   0.006 |    2.646 |
| stdio digest   | 0.000 |  0.000 |  0.001 |  0.001 |    0.001 |   0.001 |    0.124 |

## VM Bridge Timing

These counters measure the raw TCP-to-vsock pump in `darwin-actiond serve-vm`.
The elapsed column is connection lifetime, not CPU time.

- Bridge connections logged: `2`
- Total client to guest bytes: `28.47 MiB`
- Total guest to client bytes: `37.76 MiB`
- Pump errors: read=`0`, write=`0`

| Bridge Metric          |       Min |       p25 |       p50 |       p75 |       p95 |      Mean |       Max |
| ---------------------- | --------: | --------: | --------: | --------: | --------: | --------: | --------: |
| connection elapsed     | 58487.024 | 58945.210 | 59403.396 | 59861.582 | 60228.131 | 59403.396 | 60319.768 |
| client to guest KiB    |   10708.4 |   12643.2 |   14577.9 |   16512.7 |   18060.5 |   14577.9 |   18447.5 |
| guest to client KiB    |   17063.6 |   18197.9 |   19332.2 |   20466.5 |   21374.0 |   19332.2 |   21600.8 |
| client to guest reads  |      8447 |      8554 |      8661 |      8768 |      8854 |    8661.0 |      8875 |
| client to guest writes |      8446 |      8553 |      8660 |      8767 |      8853 |    8660.0 |      8874 |
| guest to client reads  |     21741 |     22158 |     22575 |     22992 |     23326 |   22575.0 |     23409 |
| guest to client writes |     21740 |     22157 |     22574 |     22991 |     23325 |   22574.0 |     23408 |

## actiondfs Counters

These counters are from `/proc/actiondfs_stats` at the end of the VM run.

| Counter                   |        Value |
| ------------------------- | -----------: |
| mounts                    |         4123 |
| root directory parses     |         4123 |
| cached directory hits     |       155471 |
| cached directory misses   |         5223 |
| lookups                   |      1407093 |
| lookup hits               |       842187 |
| lookup negative           |       564906 |
| blob open attempts        |       453362 |
| blob path cache hits      |       437047 |
| blob path cache misses    |         6969 |
| blob path cache inserts   |         6969 |
| blob path cache evictions |            0 |
| blob path cache races     |            0 |
| node blob cache hits      |        28555 |
| node blob cache misses    |       440188 |
| backing reads             |       415500 |
| backing read bytes        |   1303976522 |
| splice reads              |            0 |
| splice read bytes         |            0 |
| mmap calls                |        53243 |
| mmap bytes                | 1901688811520 |
| mmap failures             |            0 |
| directory blob reads      |         9344 |
| directory blob bytes      |      3182957 |

## actiondfs Staged Counters

| Counter                         |      Value |
| ------------------------------- | ---------: |
| stage parent path lookups       |       7852 |
| stage parent path errors        |          0 |
| stage child lookups             |        214 |
| stage child lookup hits         |         16 |
| stage child lookup negative     |        198 |
| stage child lookup errors       |          0 |
| stage ensure dir calls          |      12182 |
| stage ensure dir components     |     103548 |
| stage ensure dir existing       |     103548 |
| stage ensure dir created        |          0 |
| stage ensure dir errors         |          0 |
| stage inode lookups             |    1407093 |
| stage inode lookup hits         |      35540 |
| stage inode lookup negative     |    1371553 |
| stage inode lookup errors       |          0 |
| stage inode input dir merges    |      18402 |
| stage backing open attempts     |      41054 |
| stage backing open failures     |          0 |
| stage read calls                |          0 |
| stage read bytes                |          0 |
| stage write calls               |      37194 |
| stage write bytes               |  106358935 |
| stage splice read calls         |          0 |
| stage splice read bytes         |          0 |
| stage mmap calls                |         32 |
| stage mmap bytes                |    7905280 |
| stage mmap failures             |          0 |
| stage create calls              |      11984 |
| stage create success            |      11984 |
| stage create failures           |          0 |
| stage mkdir calls               |        198 |
| stage mkdir success             |        198 |
| stage mkdir failures            |          0 |
| stage unlink calls              |         16 |
| stage unlink success            |         16 |
| stage unlink failures           |          0 |
| stage rmdir calls               |          0 |
| stage rename calls              |       3819 |
| stage rename success            |       3819 |
| stage rename failures           |          0 |
| stage setattr size calls        |       3876 |
| stage setattr size success      |       3876 |
| stage setattr size failures     |          0 |
| stage readdir calls             |          0 |
| stage copy_file_range attempts  |       3828 |
| stage copy_file_range success   |       3828 |
| stage copy_file_range bytes     |   31630764 |
| stage copy_file_range fallbacks |          0 |

## CAS Put-File Promotion Counters

These counters are VM-lifetime counters collected at the same time as the
actiondfs stats, so they include both warmup and measured builds.

| Counter                                      |    Value |
| -------------------------------------------- | -------: |
| CAS put file calls                           |     7949 |
| CAS put file promote attempts                |     7949 |
| CAS put file promote success                 |     2089 |
| CAS put file promote existing blob           |     5860 |
| CAS put file promote bytes                   | 38021375 |
| CAS put file promote cross-device fallbacks  |        0 |
| CAS put file promote permission fallbacks    |        0 |
| CAS put file copy calls                      |        0 |
| CAS put file copy bytes                      |        0 |

## Staged Output Analysis

| Derived Metric                                |     Value |
| --------------------------------------------- | --------: |
| staged write bytes                            | 101.43MiB |
| copy_file_range bytes                         |  30.17MiB |
| CAS promote bytes                             |  36.26MiB |
| average bytes per staged write call           |   2859.6 |
| staged writes per created file                |     3.10 |
| average bytes per copy_file_range success     |   8263.0 |
| copy_file_range fallback rate                 |    0.00% |
| CAS put-file actual rename rate               |   26.28% |
| CAS put-file existing-blob rate               |   73.72% |
| CAS put-file copy fallback rate               |    0.00% |
| backing opens beyond staged write calls       |     3860 |
| stage ensure dir components per ensure call   |     8.50 |
| staged inode lookup hit rate                  |    2.53% |
| staged inode lookup negative rate             |   97.47% |

## Notes

The `execute` bucket dominates this workload. With lazy actiondfs inputs, most
filesystem metadata and mapped-file access happen while the child process is
running, so that time appears in `execute`, primarily in `process/io`, rather
than in `input fetch/materialize`.

This run validates the actiondfs `copy_file_range` path and the ext4-backed
stage under the concurrent `copy_to_directory` workload used by the LLVM smoke.
The actiondfs stage is now under `/cas/actiondfs-stage`, so staged outputs and
CAS blobs live on the same ext4 filesystem inside the guest.

Go's `io.Copy` attempted `copy_file_range` `3828` times. The actiondfs hook
handled all `3828` attempts and copied `30.17MiB`. For CAS or staged actiondfs
source files, actiondfs opens the real source backing file and the real staged
output file, then calls `vfs_copy_file_range`. There is no bounded in-kernel
buffered fallback in actiondfs; a selected backing-copy failure increments
`stage_copy_file_range_fallbacks` and is treated as an error.

CAS output collection saw `7949` `putFile` calls during the VM lifetime. All of
them attempted same-filesystem promotion; `2089` were actual staged-file renames
into CAS, `5860` found that the destination blob already existed, and none fell
back to byte-copying. The actual rename path promoted `36.26MiB` of output data
into CAS without a second file copy.

The staged counters show that `copy_file_range` moved part of the
`copy_to_directory` traffic out of userspace read/write loops. Staged write
bytes were `101.43MiB`, while another `30.17MiB` was accounted by
`stage_copy_file_range_bytes`. The `3860` backing opens beyond staged write
calls are the `3828` copy-file-range output opens plus `32` staged mmap opens.

Directory pre-creation is doing its job: `stage_ensure_dir_created=0`, while
`stage_ensure_dir_existing=103548`. The remaining cost is repeated validation
and walking of already-existing parent paths.

Staged lookup is mostly negative: `35540` hits versus `1371553` misses. That is
expected for overlay-style lookup, but it makes negative-stage lookup caching or
directory-level "has staged children" filtering worth measuring. The hot
negative counter itself is also expensive instrumentation; if these stats stay
long term, prefer derived values or per-CPU counters on this path.

The raw VM bridge moved about 66 MiB across two long-lived measured
connections, so the dumb TCP-to-vsock pump is not the visible bottleneck in
this run. Most time remains in `process/io`, which includes compiler runtime
plus lazy actiondfs filesystem work issued by the compiler itself.

The mac-host baseline was skipped for this VM-focused actiondfs copy-file-range
check.
The previous checked-in full comparison had matching measured action counts:
`2310` total processes and `2106` action executions for both VM and mac-host.
