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
only the VM log slice after that warmup. The default is no warmup. Aquery showed
that `@llvm//runtimes:resource_directory` is not the full VM/mac action-count
delta: the VM `llvm-tblgen` graph has 5,341 configured actions, the mac-host
graph has 3,637, and `@llvm//runtimes:resource_directory` has 597.

## Latest Checked-In Result

- Generated: `2026-05-18 14:09:33 EDT`
- Command: `e2e/run_llvm_vm_smoke.sh`
- Output root: `/var/folders/p4/xn8y5q_j24l5xwgwd_jx5c340000gn/T/actiond-llvm-vm-smoke.aUAUeO`
- Workload: `@llvm-project//llvm:llvm-tblgen`, jobs=8
- VM warmup target: none
- Target platform: `@llvm//platforms:linux_arm64_musl`
- VM host platform: `@llvm//platforms:linux_arm64_musl`
- Build mode: `-c opt --strip=always --stripopt=--strip-all`
- VM Bazel elapsed: `321.090s`
- VM executions: `4123`
- VM timing records parsed: `4122`
- VM Bazel processes: `4516 processes: 393 internal, 4123 remote`
- Mac-host Bazel elapsed: `193.305s`
- Mac-host processes: `3012 processes: 360 internal, 2652 darwin-sandbox`

## VM Stage Timing

All values are milliseconds.

| Stage                   |    Min |     p25 |     p50 |     p75 |      p95 |    Mean |       Max |
| ----------------------- | -----: | ------: | ------: | ------: | -------: | ------: | --------: |
| total                   | 32.014 | 200.249 | 240.661 | 377.857 | 2141.498 | 541.183 | 10425.888 |
| input fetch/materialize |  0.951 |   2.468 |   3.261 |   4.700 |   10.250 |   4.752 |   314.354 |
| execute                 | 19.342 | 193.957 | 234.034 | 367.058 | 2116.214 | 531.266 | 10393.075 |
| output upload/collect   |  0.577 |   1.658 |   2.376 |   4.051 |   13.010 |   5.165 |  1733.846 |

## Runner Timing

`process/io` includes the action process runtime, stdout/stderr drain, and lazy
filesystem reads issued by the action through the mounted actiondfs tree.

| Runner Stage   |    Min |     p25 |     p50 |     p75 |      p95 |    Mean |       Max |
| -------------- | -----: | ------: | ------: | ------: | -------: | ------: | --------: |
| parent prepare |  0.073 |   0.115 |   0.143 |   0.180 |    0.398 |   0.240 |    39.640 |
| fork           |  0.079 |   0.172 |   0.206 |   0.246 |    0.478 |   0.241 |     4.341 |
| child setup    |  0.003 |   0.202 |   0.262 |   0.426 |    1.471 |   0.605 |    92.437 |
| process/io     | 18.507 | 189.255 | 228.557 | 359.750 | 2015.105 | 512.210 | 10018.439 |
| wait           |  0.007 |   2.766 |   3.909 |   6.723 |   87.393 |  17.902 |  1007.270 |
| stdio digest   |  0.001 |   0.002 |   0.002 |   0.003 |    0.005 |   0.005 |     7.038 |

## Notes

The `execute` bucket dominates this workload. With lazy actiondfs inputs, most
filesystem page and metadata misses happen while the child process is running,
so that time appears in `execute`, primarily in `process/io`, rather than in
`input fetch/materialize`.

The mac-host baseline uses the default macOS host platform. The log shows Bazel
running `darwin-sandbox` actions; the script only fixes the target platform to
the same Linux arm64 musl platform for an apples-to-apples target build.
