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

- Generated: `2026-05-18 21:45:05 EDT`
- Command: `e2e/run_llvm_vm_smoke.sh`
- Output root: `/var/folders/p4/xn8y5q_j24l5xwgwd_jx5c340000gn/T/actiond-llvm-vm-smoke.ayzPsh`
- Workload: `@llvm-project//llvm:llvm-tblgen`, jobs=8
- VM warmup target: `//e2e:llvm_exec_warmup`
- Target platform: `@llvm//platforms:linux_arm64_musl`
- VM host platform: `@llvm//platforms:linux_arm64_musl`
- Build mode: `-c opt --strip=always --stripopt=--strip-all`
- VM warmup elapsed: `95.063s`
- VM warmup processes: `2207 processes: 190 internal, 2017 remote`
- VM Bazel elapsed: `105.417s`
- VM executions: `2106`
- VM timing records parsed: `2106`
- VM Bazel processes: `2310 processes: 4 action cache hit, 204 internal, 2106 remote`
- Mac-host warmup elapsed: `81.445s`
- Mac-host warmup processes: `703 processes: 157 internal, 546 darwin-sandbox`
- Mac-host Bazel elapsed: `110.815s`
- Mac-host processes: `2310 processes: 2 action cache hit, 204 internal, 2106 darwin-sandbox`

## Run Comparison

| Metric                  | Previous |      New |     Delta |
| ----------------------- | -------: | -------: | --------: |
| VM measured build       | 115.276s | 105.417s |  -9.859s |
| Mac-host measured build | 103.509s | 110.815s |  +7.306s |
| VM gap vs mac-host      | +11.767s |  -5.398s | -17.165s |
| VM warmup               | 119.817s |  95.063s | -24.754s |

| VM Stage                | Previous Mean |  New Mean |      Delta |
| ----------------------- | ------------: | --------: | ---------: |
| total                   |     355.384ms | 340.710ms |  -14.674ms |
| input fetch/materialize |       0.387ms |   0.290ms |   -0.097ms |
| execute                 |     351.650ms | 337.460ms |  -14.190ms |
| output upload/collect   |       3.343ms |   2.960ms |   -0.383ms |

## VM Stage Timing

All values are milliseconds.

| Stage                   |   Min |    p25 |    p50 |    p75 |      p95 |    Mean |       Max |
| ----------------------- | ----: | -----: | -----: | -----: | -------: | ------: | --------: |
| total                   | 8.228 | 39.548 | 49.131 | 77.070 | 1936.939 | 340.710 | 9877.661 |
| input fetch/materialize | 0.121 |  0.167 |  0.187 |  0.346 |    0.624 |   0.290 |   12.630 |
| execute                 | 3.508 | 38.676 | 48.094 | 75.348 | 1915.125 | 337.460 | 9847.977 |
| output upload/collect   | 0.206 |  0.378 |  0.478 |  1.100 |   12.264 |   2.960 |  814.224 |

## Runner Timing

`process/io` includes the action process runtime, stdout/stderr drain, and lazy
filesystem reads issued by the action through the mounted actiondfs tree.

| Runner Stage   |   Min |    p25 |    p50 |    p75 |      p95 |    Mean |       Max |
| -------------- | ----: | -----: | -----: | -----: | -------: | ------: | --------: |
| parent prepare | 0.068 |  0.104 |  0.121 |  0.176 |    0.393 |   0.192 |   26.415 |
| fork           | 0.194 |  0.469 |  0.554 |  1.080 |    4.776 |   1.204 |   21.438 |
| child setup    | 0.002 |  0.233 |  0.597 |  2.185 |    5.149 |   1.608 |   68.695 |
| process/io     | 0.111 | 33.690 | 42.466 | 68.456 | 1896.021 | 330.452 | 9835.441 |
| wait           | 0.000 |  1.400 |  2.292 |  4.697 |   10.916 |   3.886 |  170.370 |
| stdio digest   | 0.002 |  0.004 |  0.005 |  0.005 |    0.010 |   0.009 |    3.256 |

## actiondfs Counters

These counters are from `/proc/actiondfs_stats` at the end of the VM run.

| Counter                  |        Value |
| ------------------------ | -----------: |
| mounts                   |         8246 |
| root directory parses    |         8246 |
| cached directory hits    |       173845 |
| cached directory misses  |         5216 |
| lookups                  |      1396390 |
| lookup hits              |       843455 |
| lookup negative          |       552935 |
| blob open attempts       |       457478 |
| node blob cache hits     |     31508122 |
| node blob cache misses   |       444016 |
| direct reads             |       419542 |
| direct read bytes        |   1329451317 |
| splice reads             |          148 |
| splice read bytes        |      6084014 |
| read folios              |     31532448 |
| read folio bytes         | 129095649184 |

## Notes

The `execute` bucket dominates this workload. With lazy actiondfs inputs, most
filesystem page and metadata misses happen while the child process is running,
so that time appears in `execute`, primarily in `process/io`, rather than in
`input fetch/materialize`.

The measured VM and mac-host phases now have matching Bazel action counts after
their respective exec-config warmups: `2310` total processes and `2106` action
executions. The VM warmup is larger because it builds Linux-musl exec tools and
runtimes inside the VM; the mac-host warmup builds the analogous macOS exec
tools locally. The measured phase is the apples-to-apples target build.

Compared with the previous checked-in run, the measured VM phase improved from
`115.276s` to `105.417s`; mac-host moved from `103.509s` to `110.815s`, so the
measured VM leg was slightly faster in this run. The direct read/splice path is
active, but mmap remains on the safe generic readonly path, so most large lazy
file reads still show up through folios and are counted under
`execute/process/io`.
