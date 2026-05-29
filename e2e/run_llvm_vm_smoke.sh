#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workspace="${ACTIOND_LLVM_SMOKE_WORKSPACE:-${repo_root}}"
smoke_target="${ACTIOND_LLVM_SMOKE_TARGET:-@llvm-project//llvm:llvm-tblgen}"
warmup_target="${ACTIOND_LLVM_SMOKE_WARMUP_TARGET-//e2e:llvm_exec_warmup}"
target_platform="${ACTIOND_LLVM_SMOKE_TARGET_PLATFORM:-@llvm//platforms:linux_arm64_musl}"
# LLVM builds host-configured tools that execute remotely in the VM.
host_platform="${ACTIOND_LLVM_SMOKE_HOST_PLATFORM:-${target_platform}}"
host="${ACTIOND_LLVM_VM_SMOKE_HOST:-127.0.0.1}"
port="${ACTIOND_LLVM_VM_SMOKE_PORT:-8998}"
endpoint="${host}:${port}"
memory_mib="${ACTIOND_VM_MEMORY_MIB:-4096}"
cpus="${ACTIOND_VM_CPUS:-8}"
if [[ -v ACTIOND_LLVM_SMOKE_JOBS ]]; then
  jobs="${ACTIOND_LLVM_SMOKE_JOBS}"
else
  jobs="8"
fi
jobs_label="${jobs:-bazel default}"
jobs_flags=()
if [[ -n "${jobs}" ]]; then
  jobs_flags=(--jobs="${jobs}")
fi
output_root="${ACTIOND_LLVM_VM_SMOKE_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/actiond-llvm-vm-smoke.XXXXXX")}"
llvm_output_base="${ACTIOND_LLVM_SMOKE_OUTPUT_BASE:-${output_root}/llvm-bazel-output-base}"
cas_image="${ACTIOND_VM_CAS_IMAGE:-${output_root}/server/cas.ext4}"
cas_image_size_mib="${ACTIOND_VM_CAS_IMAGE_SIZE_MIB:-8192}"
run_vm="${ACTIOND_LLVM_SMOKE_VM:-1}"
run_mac_host="${ACTIOND_LLVM_SMOKE_MAC_HOST:-1}"
executor_timing_logs="${ACTIOND_LLVM_SMOKE_EXECUTOR_TIMING_LOGS:-1}"
server_target="${ACTIOND_LLVM_SMOKE_SERVER_TARGET:-//cmd/darwin_actiond:darwin-actiond-standalone_pkg}"
server_script_path="${ACTIOND_LLVM_SMOKE_SERVER_SCRIPT_PATH:-/tmp/darwin-actiond-standalone}"
build_mode_flags=(
  -c opt
  --strip=always
  --stripopt=--strip-all
)
bazel_build_flags=()
if [[ -n "${ACTIOND_BAZEL_BUILD_FLAGS:-}" ]]; then
  read -r -a bazel_build_flags <<<"${ACTIOND_BAZEL_BUILD_FLAGS}"
fi
case "${executor_timing_logs}" in
  1|true|TRUE|yes|YES)
    executor_timing_logs=1
    bazel_build_flags+=(--//:executor_timing_logs=true)
    ;;
  0|false|FALSE|no|NO)
    executor_timing_logs=0
    bazel_build_flags+=(--//:executor_timing_logs=false)
    ;;
  *)
    echo "ACTIOND_LLVM_SMOKE_EXECUTOR_TIMING_LOGS must be 0 or 1" >&2
    exit 1
    ;;
esac

server_pid=""
server_log=""

cleanup_server() {
  local status="${1:-$?}"
  if [[ -n "${server_pid}" ]]; then
    kill "${server_pid}" >/dev/null 2>&1 || true
    wait "${server_pid}" >/dev/null 2>&1 || true
  fi
  if [[ "${status}" -ne 0 && -n "${server_log}" && -f "${server_log}" ]]; then
    echo "----- darwin-actiond VM log (${server_log}) -----" >&2
    tail -200 "${server_log}" >&2 || true
  fi
  server_pid=""
  server_log=""
}

trap 'cleanup_server $?' EXIT

wait_for_port() {
  local timeout="${1:-90}"
  local start
  start="$(date +%s)"
  while true; do
    if [[ -n "${server_pid}" ]] && ! kill -0 "${server_pid}" >/dev/null 2>&1; then
      echo "darwin-actiond exited before ${endpoint} became ready" >&2
      return 1
    fi
    if (echo >"/dev/tcp/${host}/${port}") >/dev/null 2>&1; then
      return 0
    fi
    if (( "$(date +%s)" - start >= timeout )); then
      echo "timed out waiting for ${endpoint}" >&2
      return 1
    fi
    sleep 0.2
  done
}

wait_for_guest_ready() {
  local stats_path="$1"
  local timeout="${2:-120}"
  local start
  start="$(date +%s)"
  while true; do
    if [[ -n "${server_pid}" ]] && ! kill -0 "${server_pid}" >/dev/null 2>&1; then
      echo "darwin-actiond exited before the guest became ready" >&2
      return 1
    fi
    if [[ -s "${stats_path}" ]]; then
      return 0
    fi
    if (( "$(date +%s)" - start >= timeout )); then
      echo "timed out waiting for guest actiond readiness; stats path: ${stats_path}" >&2
      return 1
    fi
    sleep 0.2
  done
}

prepare_server() {
  mkdir -p "$(dirname "${server_script_path}")"
  (
    cd "${repo_root}"
    bazel run --config=remote \
      --script_path="${server_script_path}" \
      "${build_mode_flags[@]}" \
      --bes_backend= \
      ${bazel_build_flags[@]+"${bazel_build_flags[@]}"} \
      "${server_target}"
  ) >&2
  printf '%s\n' "${server_script_path}"
}

run_smoke() {
  local build_log="${output_root}/llvm_tblgen_smoke.log"
  local measured_server_log="${output_root}/darwin-actiond-vm.measured.log"
  local remote_grpc_log="${ACTIOND_LLVM_SMOKE_REMOTE_GRPC_LOG:-}"
  local timings="${output_root}/timings.md"
  local server
  local elapsed

  mkdir -p "${output_root}"
  server="$(prepare_server)"
  server_log="${output_root}/darwin-actiond-vm.log"

  local server_args=(
    --listen="${endpoint}"
    --root="${output_root}/server"
    --cas-image="${cas_image}"
    --cas-image-size-mib="${cas_image_size_mib}"
    --memory-mib="${memory_mib}"
    --cpus="${cpus}"
  )
  if [[ "${executor_timing_logs}" == "1" ]]; then
    server_args+=(
      --actiondfs-stats-path="${output_root}/actiondfs_stats.txt"
    )
  fi
  "${server}" serve-vm "${server_args[@]}" >"${server_log}" 2>&1 &
  server_pid="$!"

  wait_for_port 90
  if [[ "${executor_timing_logs}" == "1" ]]; then
    wait_for_guest_ready "${output_root}/actiondfs_stats.txt" 120
  fi

  if ! ACTIOND_LLVM_SMOKE_EXECUTOR="grpc://${endpoint}" \
    ACTIOND_LLVM_SMOKE_CACHE="grpc://${endpoint}" \
    ACTIOND_LLVM_SMOKE_JOBS="${jobs}" \
    ACTIOND_LLVM_SMOKE_WORKSPACE="${workspace}" \
    ACTIOND_LLVM_SMOKE_TARGET="${smoke_target}" \
    ACTIOND_LLVM_SMOKE_WARMUP_TARGET="${warmup_target}" \
    ACTIOND_LLVM_SMOKE_TARGET_PLATFORM="${target_platform}" \
    ACTIOND_LLVM_SMOKE_HOST_PLATFORM="${host_platform}" \
    ACTIOND_LLVM_SMOKE_SERVER_LOG="${server_log}" \
    ACTIOND_LLVM_SMOKE_MEASURED_SERVER_LOG="${measured_server_log}" \
    ACTIOND_LLVM_SMOKE_REMOTE_GRPC_LOG="${remote_grpc_log}" \
    ACTIOND_LLVM_SMOKE_OUTPUT_BASE="${llvm_output_base}" \
    ACTIOND_LLVM_SMOKE_SKIP_CLEAN=0 \
    "${repo_root}/e2e/llvm_tblgen_smoke.sh" >"${build_log}" 2>&1; then
    echo "LLVM smoke failed; build log: ${build_log}" >&2
    if [[ -n "${remote_grpc_log}" ]]; then
      echo "remote gRPC log: ${remote_grpc_log}" >&2
    fi
    tail -200 "${build_log}" >&2 || true
    return 1
  fi

  elapsed="$(sed -n 's/.*Elapsed time: \([0-9.]*s\).*/\1/p' "${build_log}" | tail -n 1)"
  if [[ "${executor_timing_logs}" == "1" && ! -s "${measured_server_log}" ]]; then
    echo "measured VM log slice is empty; source log: ${server_log}" >&2
    return 1
  fi

  if [[ "${executor_timing_logs}" == "1" ]]; then
    "${repo_root}/test/parse_timings.py" "${measured_server_log}" \
      --mode "llvm-vm" \
      --command "e2e/run_llvm_vm_smoke.sh" \
      --bazel-elapsed "${elapsed:-unknown}" \
      --workload "${smoke_target}, warmup=${warmup_target:-none}, jobs=${jobs_label}" \
      --output "${timings}"
  fi

  cleanup_server 0
  if [[ "${executor_timing_logs}" == "1" ]]; then
    echo "timing summary: ${timings}" >&2
  else
    echo "timing summary: skipped; executor timing logs are compiled out" >&2
  fi
  if [[ "${executor_timing_logs}" == "1" ]]; then
    echo "actiondfs stats: ${output_root}/actiondfs_stats.txt" >&2
  fi
}

run_mac_host_smoke() {
  local warmup_log="${output_root}/llvm_tblgen_mac_host_warmup.log"
  local build_log="${output_root}/llvm_tblgen_mac_host.log"
  local timings="${output_root}/mac_host_timings.md"
  local elapsed
  local startup_flags=()
  if [[ -n "${llvm_output_base}" ]]; then
    mkdir -p "${llvm_output_base}"
    startup_flags=(--output_base="${llvm_output_base}")
  fi

  if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "mac-host LLVM smoke must run on macOS" >&2
    return 1
  fi

  (
    cd "${workspace}"
    bazel "${startup_flags[@]}" clean --expunge
  ) >"${build_log}.clean" 2>&1

  if [[ -n "${warmup_target}" ]]; then
    if ! (
      cd "${workspace}"
      bazel "${startup_flags[@]}" build "${warmup_target}" \
        "${build_mode_flags[@]}" \
        --bes_backend= \
        --platforms="${target_platform}" \
        --remote_executor= \
        --remote_cache= \
        --experimental_remote_downloader= \
        --experimental_remote_downloader_local_fallback=true \
        --noremote_cache_compression \
        --noremote_accept_cached \
        --remote_upload_local_results=false \
        --disk_cache= \
        "${jobs_flags[@]}"
    ) >"${warmup_log}" 2>&1; then
      echo "LLVM mac-host warmup failed; build log: ${warmup_log}" >&2
      tail -200 "${warmup_log}" >&2 || true
      return 1
    fi
  fi

  if ! (
    cd "${workspace}"
    bazel "${startup_flags[@]}" build "${smoke_target}" \
      "${build_mode_flags[@]}" \
      --bes_backend= \
      --platforms="${target_platform}" \
      --remote_executor= \
      --remote_cache= \
      --experimental_remote_downloader= \
      --experimental_remote_downloader_local_fallback=true \
      --noremote_cache_compression \
      --noremote_accept_cached \
      --remote_upload_local_results=false \
      --disk_cache= \
      "${jobs_flags[@]}"
  ) >"${build_log}" 2>&1; then
    echo "LLVM mac-host smoke failed; build log: ${build_log}" >&2
    tail -200 "${build_log}" >&2 || true
    return 1
  fi

  elapsed="$(sed -n 's/.*Elapsed time: \([0-9.]*s\).*/\1/p' "${build_log}" | tail -n 1)"
  cat >"${timings}" <<EOF
# LLVM Mac-Host Smoke Timing

- Generated: \`$(date '+%Y-%m-%d %H:%M:%S %Z')\`
- Command: \`e2e/run_llvm_vm_smoke.sh\`
- Warmup log: \`${warmup_log}\`
- Source log: \`${build_log}\`
- Workload: \`${smoke_target}\`, warmup=${warmup_target:-none}, jobs=${jobs_label}
- Target platform: \`${target_platform}\`
- Host platform: default macOS host platform
- Platform note: target actions compile for Linux musl; local exec/host tools remain macOS binaries so Bazel can run them locally.
- Build mode: \`-c opt --strip=always --stripopt=--strip-all\`
- Bazel elapsed: \`${elapsed:-unknown}\`
EOF

  echo "mac-host timing summary: ${timings}" >&2
}

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "LLVM VM smoke must run on macOS with Virtualization.framework" >&2
  exit 1
fi

mkdir -p "${output_root}"
echo "smoke output: ${output_root}" >&2
if [[ "${run_vm}" == "1" ]]; then
  run_smoke
fi
if [[ "${run_mac_host}" == "1" ]]; then
  run_mac_host_smoke
fi

printf '%s\n' "${output_root}" >/tmp/actiond-last-llvm-vm-smoke-path
