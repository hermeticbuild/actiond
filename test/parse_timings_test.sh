#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
log="${TEST_TMPDIR}/actiond.log"
out="${TEST_TMPDIR}/timings.md"

cat >"${log}" <<'EOF'
info: execute timing aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/123: total_ns=10000000 input_fetch_ns=2000000 execution_ns=7000000 output_upload_ns=1000000 file_inputs=96 directory_inputs=0 bind_mounts=101 output_files=1 output_directories=1 stress_case=nested_individual_files
info: runner timing aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/123: parent_prepare_ns=1000000 fork_ns=1000000 child_setup_ns=2000000 process_io_ns=2500000 wait_ns=400000 stdio_digest_ns=100000 bind_mounts=101 setup_signaled=true
info: execute timing bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/124: total_ns=20000000 input_fetch_ns=3000000 execution_ns=15000000 output_upload_ns=2000000 file_inputs=0 directory_inputs=1 bind_mounts=6 output_files=1 output_directories=1 stress_case=generated_tree_reuse
EOF

python3 "${script_dir}/parse_timings.py" "${log}" \
  --mode vm \
  --workload "parser fixture" \
  --output "${out}"

grep -q "## Stage Timing By Stress Case" "${out}"
grep -q "| generated_tree_reuse | 1 |" "${out}"
grep -q "| nested_individual_files | 1 |" "${out}"
grep -q "| Stress Case | Digest | Total |" "${out}"
