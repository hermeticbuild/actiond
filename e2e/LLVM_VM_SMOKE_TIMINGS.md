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

- Generated: `2026-05-18 22:45:40 EDT`
- Command: `ACTIOND_LLVM_SMOKE_MAC_HOST=0 e2e/run_llvm_vm_smoke.sh`
- Output root: `/var/folders/p4/xn8y5q_j24l5xwgwd_jx5c340000gn/T/actiond-llvm-vm-smoke.nnInNs`
- Workload: `@llvm-project//llvm:llvm-tblgen`, jobs=8
- VM warmup target: `//e2e:llvm_exec_warmup`
- Target platform: `@llvm//platforms:linux_arm64_musl`
- VM host platform: `@llvm//platforms:linux_arm64_musl`
- Build mode: `-c opt --strip=always --stripopt=--strip-all`
- VM warmup elapsed: `93.737s`
- VM warmup processes: `2207 processes: 190 internal, 2017 remote`
- VM Bazel elapsed: `88.784s`
- VM executions: `2106`
- VM timing records parsed: `2106`
- VM Bazel processes: `2310 processes: 4 action cache hit, 204 internal, 2106 remote`
- Mac-host baseline: not run for this mmap pass-through check

## Run Comparison

| Metric            | Previous |     New |    Delta |
| ----------------- | -------: | ------: | -------: |
| VM measured build | 105.417s | 88.784s | -16.633s |
| VM warmup         |  95.063s | 93.737s |  -1.326s |

| VM Stage                | Previous Mean |  New Mean |      Delta |
| ----------------------- | ------------: | --------: | ---------: |
| total                   |     340.710ms | 277.425ms |  -63.285ms |
| input fetch/materialize |       0.290ms |   0.376ms |   +0.086ms |
| execute                 |     337.460ms | 274.071ms |  -63.389ms |
| output upload/collect   |       2.960ms |   2.978ms |   +0.018ms |

## VM Stage Timing

All values are milliseconds.

| Stage                   |   Min |    p25 |    p50 |    p75 |      p95 |    Mean |      Max |
| ----------------------- | ----: | -----: | -----: | -----: | -------: | ------: | -------: |
| total                   | 5.341 | 19.774 | 26.821 | 46.670 | 1643.032 | 277.425 | 9038.902 |
| input fetch/materialize | 0.138 |  0.196 |  0.228 |  0.407 |    0.809 |   0.376 |   56.481 |
| execute                 | 4.643 | 18.634 | 25.515 | 45.088 | 1633.924 | 274.071 | 9007.600 |
| output upload/collect   | 0.256 |  0.459 |  0.637 |  1.418 |   12.902 |   2.978 |  741.781 |

## Runner Timing

`process/io` includes the action process runtime, stdout/stderr drain, and lazy
filesystem reads issued by the action through the mounted actiondfs tree.

| Runner Stage   |   Min |    p25 |    p50 |    p75 |      p95 |    Mean |      Max |
| -------------- | ----: | -----: | -----: | -----: | -------: | ------: | -------: |
| parent prepare | 0.072 |  0.106 |  0.127 |  0.196 |    0.423 |   0.203 |   11.893 |
| fork           | 0.213 |  0.423 |  0.496 |  1.276 |    4.731 |   1.235 |   45.589 |
| child setup    | 0.002 |  0.266 |  0.811 |  2.659 |    7.130 |   2.043 |   38.893 |
| process/io     | 0.287 | 15.665 | 22.121 | 40.236 | 1632.779 | 270.475 | 9001.707 |
| wait           | 0.000 |  0.000 |  0.000 |  0.008 |    0.017 |   0.008 |    4.589 |
| stdio digest   | 0.001 |  0.003 |  0.003 |  0.004 |    0.007 |   0.005 |    0.585 |

## actiondfs Counters

These counters are from `/proc/actiondfs_stats` at the end of the VM run.

| Counter                  |        Value |
| ------------------------ | -----------: |
| mounts                   |         8246 |
| root directory parses    |         8246 |
| cached directory hits    |       173844 |
| cached directory misses  |         5217 |
| lookups                  |      1396390 |
| lookup hits              |       843455 |
| lookup negative          |       552935 |
| blob open attempts       |       457479 |
| node blob cache hits     |        28917 |
| node blob cache misses   |       444016 |
| backing reads            |       419542 |
| backing read bytes       |   1329451317 |
| splice reads             |          148 |
| splice read bytes        |      6084014 |
| mmap calls               |        53243 |
| mmap bytes               | 1901688147968 |
| mmap failures            |            0 |
| directory blob reads     |        13460 |
| directory blob bytes     |      3862752 |

## Notes

The `execute` bucket dominates this workload. With lazy actiondfs inputs, most
filesystem metadata and mapped-file access happen while the child process is
running, so that time appears in `execute`, primarily in `process/io`, rather
than in `input fetch/materialize`.

This run switched actiondfs file contents to kernel backing-file pass-through:
`read_iter`, `splice_read`, and `mmap` delegate to the real CAS blob file.
The old actiondfs folio-copy path was removed after this run showed
`mmap_failures=0`; compiler mmap traffic now uses the native CAS filesystem
page cache through `backing_file_mmap()`.

The mac-host baseline was skipped for this specific mmap pass-through check.
The previous checked-in full comparison had matching measured action counts:
`2310` total processes and `2106` action executions for both VM and mac-host.
