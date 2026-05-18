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

- Generated: `2026-05-18 15:11:12 EDT`
- Command: `e2e/run_llvm_vm_smoke.sh`
- Output root: `/var/folders/p4/xn8y5q_j24l5xwgwd_jx5c340000gn/T/actiond-llvm-vm-smoke.98mzRF`
- Workload: `@llvm-project//llvm:llvm-tblgen`, jobs=8
- VM warmup target: `//e2e:llvm_exec_warmup`
- Target platform: `@llvm//platforms:linux_arm64_musl`
- VM host platform: `@llvm//platforms:linux_arm64_musl`
- Build mode: `-c opt --strip=always --stripopt=--strip-all`
- VM warmup elapsed: `208.903s`
- VM warmup processes: `2207 processes: 190 internal, 2017 remote`
- VM Bazel elapsed: `183.865s`
- VM executions: `2106`
- VM timing records parsed: `2106`
- VM Bazel processes: `2310 processes: 204 internal, 2106 remote`
- Mac-host warmup elapsed: `61.985s`
- Mac-host warmup processes: `703 processes: 157 internal, 546 darwin-sandbox`
- Mac-host Bazel elapsed: `114.642s`
- Mac-host processes: `2310 processes: 2 action cache hit, 204 internal, 2106 darwin-sandbox`

## VM Stage Timing

All values are milliseconds.

| Stage                   |    Min |     p25 |     p50 |     p75 |      p95 |    Mean |       Max |
| ----------------------- | -----: | ------: | ------: | ------: | -------: | ------: | --------: |
| total                   | 33.403 | 214.940 | 263.475 | 463.395 | 2666.949 | 661.268 | 15514.374 |
| input fetch/materialize |  1.193 |   2.804 |   3.584 |   4.837 |    9.702 |   4.624 |   204.571 |
| execute                 | 14.731 | 208.003 | 257.134 | 451.572 | 2655.573 | 651.309 | 15486.625 |
| output upload/collect   |  0.717 |   1.824 |   2.698 |   4.309 |   13.898 |   5.336 |  1844.774 |

## Runner Timing

`process/io` includes the action process runtime, stdout/stderr drain, and lazy
filesystem reads issued by the action through the mounted actiondfs tree.

| Runner Stage   |    Min |     p25 |     p50 |     p75 |      p95 |    Mean |       Max |
| -------------- | -----: | ------: | ------: | ------: | -------: | ------: | --------: |
| parent prepare |  0.077 |   0.122 |   0.152 |   0.209 |    0.452 |   0.205 |     6.238 |
| fork           |  0.124 |   0.225 |   0.254 |   0.298 |    0.609 |   0.302 |     4.305 |
| child setup    |  0.003 |   0.206 |   0.270 |   0.448 |    1.536 |   0.474 |    10.404 |
| process/io     | 13.507 | 203.028 | 250.813 | 444.407 | 2532.944 | 628.614 | 15247.840 |
| wait           |  0.263 |   3.154 |   4.566 |   7.655 |  115.403 |  21.628 |   656.632 |
| stdio digest   |  0.001 |   0.002 |   0.003 |   0.003 |    0.006 |   0.004 |     0.573 |

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
