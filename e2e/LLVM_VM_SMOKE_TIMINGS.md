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

- Generated: `2026-05-21 11:02:31 EDT`
- Command: `ACTIOND_LLVM_SMOKE_MAC_HOST=0 e2e/run_llvm_vm_smoke.sh`
- Output root: `/var/folders/p4/xn8y5q_j24l5xwgwd_jx5c340000gn/T/actiond-llvm-vm-smoke.p6bLf5`
- Workload: `@llvm-project//llvm:llvm-tblgen`, jobs=8
- VM warmup target: `//e2e:llvm_exec_warmup`
- Target platform: `@llvm//platforms:linux_arm64_musl`
- VM host platform: `@llvm//platforms:linux_arm64_musl`
- Build mode: `-c opt --strip=always --stripopt=--strip-all`
- VM warmup elapsed: `68.120s`
- VM warmup processes: `2207 processes: 190 internal, 2017 remote`
- VM Bazel elapsed: `61.317s`
- VM executions: `2106`
- VM timing records parsed: `2106`
- VM Bazel processes: `2310 processes: 4 action cache hit, 204 internal, 2106 remote`
- Mac-host baseline: not run for this VM-focused actiondfs copy-file-range check

## Run Comparison

This compares the previous staged-write stats run against the current
copy-file-range run.

| Metric            | Previous |     New |    Delta |
| ----------------- | -------: | ------: | -------: |
| VM measured build |  74.793s | 61.317s | -13.476s |
| VM warmup         |  76.621s | 68.120s |  -8.501s |

| VM Stage                | Previous Mean |  New Mean |     Delta |
| ----------------------- | ------------: | --------: | --------: |
| total                   |     231.941ms | 190.514ms | -41.427ms |
| input fetch/materialize |       0.300ms |   0.290ms |  -0.010ms |
| execute                 |     230.521ms | 189.311ms | -41.210ms |
| output upload/collect   |       1.119ms |   0.912ms |  -0.207ms |

## VM Stage Timing

All values are milliseconds.

| Stage                   |   Min |    p25 |    p50 |    p75 |      p95 |    Mean |      Max |
| ----------------------- | ----: | -----: | -----: | -----: | -------: | ------: | -------: |
| total                   | 3.494 | 15.565 | 19.844 | 31.844 | 1077.847 | 190.514 | 6231.866 |
| input fetch/materialize | 0.092 |  0.134 |  0.191 |  0.308 |    0.532 |   0.290 |   33.406 |
| execute                 | 2.942 | 14.888 | 19.197 | 30.750 | 1075.575 | 189.311 | 6227.906 |
| output upload/collect   | 0.122 |  0.223 |  0.277 |  0.597 |    2.467 |   0.912 |  346.293 |

## Runner Timing

`process/io` includes the action process runtime, stdout/stderr drain, and lazy
filesystem reads issued by the action through the mounted actiondfs tree.

| Runner Stage   |   Min |    p25 |    p50 |    p75 |      p95 |    Mean |      Max |
| -------------- | ----: | -----: | -----: | -----: | -------: | ------: | -------: |
| parent prepare | 0.057 |  0.082 |  0.103 |  0.203 |    0.338 |   0.169 |    7.530 |
| fork           | 0.189 |  0.370 |  0.450 |  1.253 |    4.529 |   1.123 |   14.288 |
| child setup    | 0.002 |  0.197 |  0.431 |  1.575 |    4.802 |   1.266 |   51.295 |
| process/io     | 0.020 | 12.635 | 16.846 | 27.921 | 1073.156 | 186.682 | 6225.742 |
| wait           | 0.000 |  0.000 |  0.000 |  0.006 |    0.016 |   0.005 |    1.131 |
| stdio digest   | 0.000 |  0.001 |  0.001 |  0.001 |    0.001 |   0.001 |    1.008 |

## VM Bridge Timing

These counters measure the raw TCP-to-vsock pump in `darwin-actiond serve-vm`.
The elapsed column is connection lifetime, not CPU time.

- Bridge connections logged: `2`
- Total client to guest bytes: `28.27 MiB`
- Total guest to client bytes: `37.76 MiB`
- Pump errors: read=`0`, write=`0`

| Bridge Metric          |       Min |       p25 |       p50 |       p75 |       p95 |      Mean |       Max |
| ---------------------- | --------: | --------: | --------: | --------: | --------: | --------: | --------: |
| connection elapsed     | 46370.233 | 50291.404 | 54212.574 | 58133.745 | 61270.681 | 54212.574 | 62054.916 |
| client to guest KiB    |    9288.3 |   11882.4 |   14476.6 |   17070.7 |   19146.0 |   14476.6 |   19664.8 |
| guest to client KiB    |   18376.7 |   18854.4 |   19332.1 |   19809.8 |   20192.0 |   19332.1 |   20287.5 |
| client to guest reads  |      5553 |      6806 |      8058 |      9311 |     10313 |    8058.5 |     10564 |
| client to guest writes |      5552 |      6805 |      8058 |      9310 |     10312 |    8057.5 |     10563 |
| guest to client reads  |     14956 |     18964 |     22972 |     26980 |     30186 |   22972.0 |     30988 |
| guest to client writes |     14955 |     18963 |     22971 |     26979 |     30185 |   22971.0 |     30987 |

## actiondfs Counters

These counters are from `/proc/actiondfs_stats` at the end of the VM run.

| Counter                   |        Value |
| ------------------------- | -----------: |
| mounts                    |         4123 |
| root directory parses     |         4123 |
| cached directory hits     |       155481 |
| cached directory misses   |         5213 |
| lookups                   |      1407093 |
| lookup hits               |       842187 |
| lookup negative           |       564906 |
| blob open attempts        |       453352 |
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
| directory blob reads      |         9335 |
| directory blob bytes      |      3181793 |

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
| stage inode input dir merges    |      18403 |
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

## Staged Output Analysis

| Derived Metric                                |     Value |
| --------------------------------------------- | --------: |
| staged write bytes                            | 101.43MiB |
| copy_file_range bytes                         |  30.17MiB |
| average bytes per staged write call           |   2859.6 |
| staged writes per created file                |     3.10 |
| average bytes per copy_file_range success     |   8263.0 |
| copy_file_range fallback rate                 |    0.00% |
| backing opens beyond staged write calls       |     3860 |
| stage ensure dir components per ensure call   |     8.50 |
| staged inode lookup hit rate                  |    2.53% |
| staged inode lookup negative rate             |   97.47% |

## Notes

The `execute` bucket dominates this workload. With lazy actiondfs inputs, most
filesystem metadata and mapped-file access happen while the child process is
running, so that time appears in `execute`, primarily in `process/io`, rather
than in `input fetch/materialize`.

This run validates the actiondfs `copy_file_range` path under the concurrent
`copy_to_directory` workload used by the LLVM smoke. It used the existing
bounded digest-to-CAS-path cache and the default temporary VM CAS image
settings.

Go's `io.Copy` attempted `copy_file_range` `3828` times. The actiondfs hook
handled all `3828` attempts and copied `30.17MiB` with zero fallbacks. A lower
`vfs_copy_file_range` pass had fallen back for every attempt because the CAS
input root and staged output root are separate filesystems, so this path uses a
bounded in-kernel buffered copy for actiondfs input-or-staged source files into
staged output files.

The staged counters show that `copy_file_range` moved part of the
`copy_to_directory` traffic out of userspace read/write loops. Staged write
callbacks dropped from `41548` to `37194`, and staged write bytes dropped from
`131.60MiB` to `101.43MiB`; the remaining `30.17MiB` was accounted by
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
