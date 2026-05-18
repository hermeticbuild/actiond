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

- Generated: `2026-05-18 19:48:51 EDT`
- Command: `e2e/run_llvm_vm_smoke.sh`
- Output root: `/var/folders/p4/xn8y5q_j24l5xwgwd_jx5c340000gn/T/actiond-llvm-vm-smoke.qKL7wM`
- Workload: `@llvm-project//llvm:llvm-tblgen`, jobs=8
- VM warmup target: `//e2e:llvm_exec_warmup`
- Target platform: `@llvm//platforms:linux_arm64_musl`
- VM host platform: `@llvm//platforms:linux_arm64_musl`
- Build mode: `-c opt --strip=always --stripopt=--strip-all`
- VM warmup elapsed: `119.817s`
- VM warmup processes: `2207 processes: 190 internal, 2017 remote`
- VM Bazel elapsed: `115.276s`
- VM executions: `2106`
- VM timing records parsed: `2106`
- VM Bazel processes: `2310 processes: 4 action cache hit, 204 internal, 2106 remote`
- Mac-host warmup elapsed: `53.758s`
- Mac-host warmup processes: `703 processes: 157 internal, 546 darwin-sandbox`
- Mac-host Bazel elapsed: `103.509s`
- Mac-host processes: `2310 processes: 2 action cache hit, 204 internal, 2106 darwin-sandbox`

## Run Comparison

| Metric                  | Previous |      New |     Delta |
| ----------------------- | -------: | -------: | --------: |
| VM measured build       | 183.865s | 115.276s | -68.589s |
| Mac-host measured build | 114.642s | 103.509s | -11.133s |
| VM gap vs mac-host      | +69.223s | +11.767s | -57.456s |
| VM warmup               | 208.903s | 119.817s | -89.086s |

| VM Stage                | Previous Mean |  New Mean |      Delta |
| ----------------------- | ------------: | --------: | ---------: |
| total                   |     661.268ms | 355.384ms | -305.884ms |
| input fetch/materialize |       4.624ms |   0.387ms |   -4.237ms |
| execute                 |     651.309ms | 351.650ms | -299.659ms |
| output upload/collect   |       5.336ms |   3.343ms |   -1.993ms |

## VM Stage Timing

All values are milliseconds.

| Stage                   |   Min |    p25 |    p50 |    p75 |      p95 |    Mean |       Max |
| ----------------------- | ----: | -----: | -----: | -----: | -------: | ------: | --------: |
| total                   | 8.565 | 44.714 | 59.586 | 94.307 | 2029.841 | 355.384 | 10151.611 |
| input fetch/materialize | 0.121 |  0.169 |  0.208 |  0.389 |    0.877 |   0.387 |    17.359 |
| execute                 | 5.413 | 43.557 | 58.327 | 92.327 | 2017.664 | 351.650 | 10130.017 |
| output upload/collect   | 0.168 |  0.378 |  0.497 |  1.258 |   15.145 |   3.343 |   656.042 |

## Runner Timing

`process/io` includes the action process runtime, stdout/stderr drain, and lazy
filesystem reads issued by the action through the mounted actiondfs tree.

| Runner Stage   |   Min |    p25 |    p50 |    p75 |      p95 |    Mean |       Max |
| -------------- | ----: | -----: | -----: | -----: | -------: | ------: | --------: |
| parent prepare | 0.067 |  0.105 |  0.141 |  0.219 |    0.532 |   0.222 |    18.367 |
| fork           | 0.171 |  0.377 |  0.436 |  1.124 |    4.599 |   1.109 |    31.977 |
| child setup    | 0.002 |  0.298 |  1.063 |  3.164 |   10.039 |   2.702 |    60.060 |
| process/io     | 0.818 | 36.165 | 48.565 | 79.597 | 2001.443 | 340.796 | 10121.955 |
| wait           | 0.000 |  2.245 |  4.047 |  8.193 |   19.182 |   6.703 |   227.150 |
| stdio digest   | 0.002 |  0.004 |  0.006 |  0.007 |    0.011 |   0.009 |     1.904 |

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
`183.865s` to `115.276s`. The largest visible stage change is input
fetch/materialization, whose mean dropped from `4.624ms` to `0.387ms`; most
remaining time is inside the action process and lazy actiondfs reads, which are
counted under `execute/process/io`.
