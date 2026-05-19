#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
log="${TEST_TMPDIR}/actiond.log"
out="${TEST_TMPDIR}/timings.md"

cat >"${log}" <<'EOF'
info: execute timing aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/123: total_ns=10000000 input_fetch_ns=2000000 execution_ns=7000000 output_upload_ns=1000000 file_inputs=96 directory_inputs=0 bind_mounts=101 output_files=1 output_directories=1 stress_case=nested_individual_files
info: runner timing aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/123: parent_prepare_ns=1000000 fork_ns=1000000 child_setup_ns=2000000 process_io_ns=2500000 wait_ns=400000 stdio_digest_ns=100000 bind_mounts=101 setup_signaled=true
info: execute timing bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/124: total_ns=20000000 input_fetch_ns=3000000 execution_ns=15000000 output_upload_ns=2000000 file_inputs=0 directory_inputs=0 bind_mounts=1 actiondfs_mounts=1 output_files=1 output_directories=1 stress_case=generated_tree_reuse
info: vm bridge timing elapsed_ns=50000000 client_to_guest_bytes=1048576 guest_to_client_bytes=2097152 client_to_guest_reads=16 client_to_guest_writes=16 guest_to_client_reads=32 guest_to_client_writes=32 read_errors=0 write_errors=0
EOF

python3 "${script_dir}/parse_timings.py" "${log}" \
  --mode vm \
  --workload "parser fixture" \
  --output "${out}"

grep -q "## Stage Timing By Stress Case" "${out}"
grep -Eq '^\| Stage +\| +Min +\| +p25 +\| +p50 +\| +p75 +\| +p95 +\| +Mean +\| +Max +\|' "${out}"
grep -q "## Visible Overhead Estimate" "${out}"
grep -Eq '^\| fixed overhead, no wait +\|' "${out}"
grep -q "Execute records parsed" "${out}"
grep -q "Unique action digests" "${out}"
grep -Eq '^\| generated_tree_reuse +\| +1 +\|' "${out}"
grep -Eq '^\| nested_individual_files +\| +1 +\|' "${out}"
grep -Eq '^\| Stress Case +\| Digest +\| +Total +\|' "${out}"
grep -q "## VM Bridge Timing" "${out}"
grep -q "Total client to guest bytes" "${out}"
grep -Eq '^\| connection elapsed +\|' "${out}"
grep -q "lazy actiondfs input-root path" "${out}"
