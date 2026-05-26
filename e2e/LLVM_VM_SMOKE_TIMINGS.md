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

- Generated: `2026-05-26 19:35:00 EDT`
- Command: `ACTIOND_LLVM_VM_SMOKE_ROOT=/tmp/actiond-llvm-stage-negative-filter-20260526-192841 ACTIOND_LLVM_SMOKE_MAC_HOST=0 ACTIOND_LLVM_SMOKE_VM=1 ACTIOND_LLVM_SMOKE_JOBS=10 ACTIOND_LLVM_SMOKE_ACTIONDFS_STATS=1 e2e/run_llvm_vm_smoke.sh`
- Output root: `/tmp/actiond-llvm-stage-negative-filter-20260526-192841`
- Workload: `@llvm-project//llvm:llvm-tblgen`, jobs=10
- VM warmup target: `//e2e:llvm_exec_warmup`
- Target platform: `@llvm//platforms:linux_arm64_musl`
- VM host platform: `@llvm//platforms:linux_arm64_musl`
- Build mode: `-c opt --strip=always --stripopt=--strip-all`
- VM warmup elapsed: `71.028s`
- VM warmup processes: `2207 processes: 190 internal, 2017 remote`
- VM Bazel elapsed: `87.967s`
- VM executions: `2106`
- VM timing records parsed: `2106`
- VM Bazel processes: `2310 processes: 4 action cache hit, 204 internal, 2106 remote`
- Mac-host baseline: not run for this counter-focused actiondfs check

Wall-clock timings were noisy on this host during this run. Treat the
fine-grained counters below as the signal for actiondfs changes.

## Stage-Negative Filter Comparison

This compares the per-open staged backing reuse run against the staged-negative
filter run. Both runs used the same LLVM VM smoke shape, jobs=10, and `2106`
remote executions.

| Counter / Timer                         | Open Reuse | Stage Filter | Delta |
| --------------------------------------- | ---------: | -----------: | ----: |
| actiondfs lookups                       |    1406663 |      1407093 |  +430 |
| staged inode lookup attempts            |    1406663 |        75178 | -1331485 |
| staged inode lookup skipped empty dir   |          0 |      1331915 | +1331915 |
| staged inode lookup hits                |      35518 |        35524 |    +6 |
| staged inode lookup negative            |    1371145 |        39654 | -1331491 |
| staged inode input-dir merges           |      18382 |        18388 |    +6 |
| staged child lookups                    |      12211 |        12214 |    +3 |
| stage backing open attempts             |      19654 |        19656 |    +2 |
| copy_file_range attempts                |       3828 |         3828 |     0 |
| copy_file_range fallbacks               |          0 |            0 |     0 |

The filter shifted `1.33M` staged lookup probes into a cheap in-memory skip. The
remaining actual staged lookup attempts are the directories that have staged
children, might have staged children, or are conservatively unknown.

## Open-Path Reuse Comparison

This compares the instrumented baseline immediately before per-open staged
backing-file reuse against the first instrumented run with reuse enabled.

| Counter / Timer                    | Baseline | Reuse | Delta |
| ---------------------------------- | -------: | ----: | ----: |
| stage backing open attempts        |   41054 | 19654 | -21400 |
| stage backing open cached hits     |       0 | 37224 | +37224 |
| stage backing open cached misses   |       0 |     0 |      0 |
| stage backing open total           | 46.570ms | 41.349ms | -5.222ms |
| stage backing lookup               | 29.378ms | 15.952ms | -13.426ms |
| stage backing file open            | 13.431ms | 12.407ms | -1.024ms |
| staged write calls                 |   37194 | 37194 |      0 |
| staged write bytes                 | 101.43MiB | 101.43MiB | 0 |
| copy_file_range attempts           |    3828 |  3828 |      0 |
| copy_file_range success            |    3828 |  3828 |      0 |
| copy_file_range fallbacks          |       0 |     0 |      0 |
| copy_file_range bytes              | 30.17MiB | 30.17MiB | 0 |

The reuse is working mechanically: staged write and mmap operations reused the
backing file `37224` times with no fallback opens. The direct timer win is
modest because each staged file still needs an initial backing open and because
this workload also spends time in writes, mmap, copy_file_range, process runtime,
and CAS output collection.

## VM Stage Timing

All values are milliseconds. These wall-clock buckets are retained for context,
but they were noisy on this machine.

| Stage                   |   Min |    p25 |    p50 |    p75 |      p95 |    Mean |      Max |
| ----------------------- | ----: | -----: | -----: | -----: | -------: | ------: | -------: |
| total                   | 3.521 | 35.231 | 52.139 | 84.087 | 1891.440 | 338.377 | 9377.006 |
| input fetch/materialize | 0.463 |  0.653 |  0.697 |  1.126 |    3.813 |   1.351 |   56.792 |
| execute                 | 2.586 | 33.309 | 50.300 | 82.075 | 1882.890 | 335.887 | 9372.042 |
| output upload/collect   | 0.083 |  0.194 |  0.225 |  0.525 |    3.385 |   1.140 |  404.416 |

## Runner Timing

`process/io` includes the action process runtime, stdout/stderr drain, and lazy
filesystem reads issued by the action through the mounted actiondfs tree.

| Runner Stage   |   Min |    p25 |    p50 |    p75 |      p95 |    Mean |      Max |
| -------------- | ----: | -----: | -----: | -----: | -------: | ------: | -------: |
| parent prepare | 0.077 |  0.115 |  0.130 |  0.165 |    0.522 |   0.282 |   20.582 |
| fork           | 0.191 |  0.354 |  0.395 |  0.929 |    5.628 |   1.289 |   23.465 |
| child setup    | 0.001 |  0.748 |  2.995 |  6.921 |   21.536 |   5.797 |  209.903 |
| process/io     | 0.019 | 27.692 | 41.769 | 72.459 | 1879.095 | 328.378 | 9349.091 |
| wait           | 0.000 |  0.000 |  0.000 |  0.000 |    0.016 |   0.020 |   12.320 |
| stdio digest   | 0.000 |  0.000 |  0.001 |  0.001 |    0.001 |   0.001 |    1.145 |

## VM Bridge Timing

These counters measure the raw TCP-to-vsock pump in `darwin-actiond serve-vm`.
The elapsed column is connection lifetime, not CPU time.

- Bridge connections logged: `2`
- Total client to guest bytes: `28.39 MiB`
- Total guest to client bytes: `37.76 MiB`
- Pump errors: read=`0`, write=`0`

| Bridge Metric          |       Min |       p25 |       p50 |       p75 |       p95 |      Mean |       Max |
| ---------------------- | --------: | --------: | --------: | --------: | --------: | --------: | --------: |
| connection elapsed     | 84302.563 | 85213.388 | 86124.212 | 87035.037 | 87763.697 | 86124.212 | 87945.862 |
| client to guest KiB    |   11649.5 |   13093.6 |   14537.7 |   15981.8 |   17137.0 |   14537.7 |   17425.8 |
| guest to client KiB    |   15773.6 |   17553.4 |   19333.3 |   21113.2 |   22537.1 |   19333.3 |   22893.1 |
| client to guest reads  |      8088 |      8394 |      8701 |      9008 |      9253 |    8701.0 |      9314 |
| client to guest writes |      8087 |      8394 |      8700 |      9006 |      9252 |    8700.0 |      9313 |
| guest to client reads  |     20220 |     21672 |     23124 |     24576 |     25738 |   23124.0 |     26028 |
| guest to client writes |     20219 |     21671 |     23123 |     24575 |     25737 |   23123.0 |     26027 |

## actiondfs Counters

These counters are from `/proc/actiondfs_stats` at the end of the VM run. They
are VM-lifetime counters, so they include both warmup and measured builds.

| Counter                   |        Value |
| ------------------------- | -----------: |
| mounts                    |         4123 |
| root directory parses     |         4123 |
| cached directory hits     |       155482 |
| cached directory misses   |         5212 |
| lookups                   |      1407093 |
| lookup hits               |       842187 |
| lookup negative           |       564906 |
| blob open attempts        |       453350 |
| blob path cache hits      |       437047 |
| blob path cache misses    |         6969 |
| node blob cache hits      |        28555 |
| node blob cache misses    |       440188 |
| backing reads             |       415500 |
| backing read bytes        |   1303976522 |
| mmap calls                |        53243 |
| mmap bytes                | 1901688811520 |
| mmap failures             |            0 |
| directory blob reads      |         9335 |
| directory blob bytes      |      3181793 |

## actiondfs Staged Counters

| Counter                          |      Value |
| -------------------------------- | ---------: |
| stage parent path lookups        |      19836 |
| stage child lookups              |      12214 |
| stage child lookup hits          |         16 |
| stage child lookup negative      |      12198 |
| stage ensure dir calls           |      12182 |
| stage ensure dir components      |     103548 |
| stage ensure dir existing        |     103532 |
| stage ensure dir created         |         16 |
| stage inode lookups              |      75178 |
| stage inode lookup skipped empty |    1331915 |
| stage inode lookup hits          |      35524 |
| stage inode lookup negative      |      39654 |
| stage inode input dir merges     |      18388 |
| stage backing open attempts      |      19656 |
| stage backing open cached hits   |      37226 |
| stage backing open cached misses |          0 |
| stage backing open total         |  23775716ns |
| stage backing open lookup        |  10350804ns |
| stage backing open file          |  10450663ns |
| stage real open attempts         |       3828 |
| stage real open copy-out calls   |       3828 |
| stage real open total            |   5473092ns |
| stage write calls                |      37194 |
| stage write bytes                |  106358935 |
| stage write total                | 257702612ns |
| stage mmap calls                 |         32 |
| stage mmap bytes                 |    7905280 |
| stage copy_file_range attempts   |       3828 |
| stage copy_file_range success    |       3828 |
| stage copy_file_range bytes      |   31630764 |
| stage copy_file_range fallbacks  |          0 |
| stage copy_file_range total      | 106308480ns |

## CAS Put-File Promotion Counters

These counters are VM-lifetime counters collected with the actiondfs stats, so
they include both warmup and measured builds.

| Counter                                      |       Value |
| -------------------------------------------- | ----------: |
| CAS put file calls                           |        7949 |
| CAS put file promote attempts                |        7949 |
| CAS put file promote success                 |        2089 |
| CAS put file promote existing blob           |        5860 |
| CAS put file promote bytes                   |    38021375 |
| CAS put file promote digest bytes            |    90355327 |
| CAS put file promote preexisting hits        |        5860 |
| CAS put file promote cross-device fallbacks  |           0 |
| CAS put file promote permission fallbacks    |           0 |
| CAS put file promote open                    |  37245626ns |
| CAS put file promote stat                    |   2283263ns |
| CAS put file promote digest                  | 1655309753ns |
| CAS put file promote preexisting check       |  57960806ns |
| CAS put file promote mkdir                   |  14073020ns |
| CAS put file promote chmod                   |  14797981ns |
| CAS put file promote rename                  | 154249626ns |
| CAS put file promote existing                |        0ns |
| CAS put file copy calls                      |           0 |
| CAS put file copy bytes                      |           0 |

## Staged Output Analysis

| Derived Metric                                |     Value |
| --------------------------------------------- | --------: |
| staged write bytes                            | 101.43MiB |
| copy_file_range bytes                         |  30.17MiB |
| CAS promoted bytes                            |  36.26MiB |
| CAS digest bytes                              |  86.17MiB |
| average bytes per staged write call           |   2859.6 |
| staged writes per created file                |     3.10 |
| average bytes per copy_file_range success     |   8263.0 |
| copy_file_range fallback rate                 |    0.00% |
| CAS put-file actual rename rate               |   26.28% |
| CAS put-file existing-blob rate               |   73.72% |
| CAS put-file copy fallback rate               |    0.00% |
| stage ensure dir components per ensure call   |     8.50 |
| staged lookup skipped known-empty rate        |   94.66% |
| actual staged lookup hit rate                 |   47.25% |
| actual staged lookup negative rate            |   52.75% |

## Notes

The `execute` bucket dominates this workload. With lazy actiondfs inputs, most
filesystem metadata and mapped-file access happen while the child process is
running, so that time appears in `execute`, primarily in `process/io`, rather
than in `input fetch/materialize`.

The staged-negative filter is the strongest actiondfs metadata counter win so
far. Directories start with a known-empty staged view; once create, mkdir, or
rename makes staged entries possible, actiondfs stops skipping staged lookup for
that directory. The root is conservative on staged mounts so an externally
provided non-empty stage root is still observed.

Go's `io.Copy` attempted `copy_file_range` `3828` times. The actiondfs hook
handled all `3828` attempts and copied `30.17MiB`. There is no bounded in-kernel
buffered fallback in actiondfs; a selected backing-copy failure increments
`stage_copy_file_range_fallbacks` and returns the backing error.

Directory pre-creation still leaves repeated validation work:
`stage_ensure_dir_components=103548` and only `16` created components. A
directory-level `stage_dir_ready` bit remains a good next target.

CAS output collection spent `1.66s` hashing `86.17MiB` over the VM lifetime.
That makes known-digest propagation from exact `copy_file_range` cases more
interesting than trying to optimize the final rename itself.
