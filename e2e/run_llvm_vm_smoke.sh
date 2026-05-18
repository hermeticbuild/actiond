#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workspace="${ACTIOND_LLVM_SMOKE_WORKSPACE:-${repo_root}}"
smoke_target="${ACTIOND_LLVM_SMOKE_TARGET:-@llvm-project//llvm:llvm-tblgen}"
warmup_target="${ACTIOND_LLVM_SMOKE_WARMUP_TARGET-//e2e:llvm_exec_warmup}"
target_platform="${ACTIOND_LLVM_SMOKE_TARGET_PLATFORM:-@llvm//platforms:linux_arm64_musl}"
host="${ACTIOND_LLVM_VM_SMOKE_HOST:-127.0.0.1}"
port="${ACTIOND_LLVM_VM_SMOKE_PORT:-8998}"
endpoint="${host}:${port}"
memory_mib="${ACTIOND_VM_MEMORY_MIB:-4096}"
cpus="${ACTIOND_VM_CPUS:-8}"
jobs="${ACTIOND_LLVM_SMOKE_JOBS:-8}"
output_root="${ACTIOND_LLVM_VM_SMOKE_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/actiond-llvm-vm-smoke.XXXXXX")}"
run_vm="${ACTIOND_LLVM_SMOKE_VM:-1}"
run_mac_host="${ACTIOND_LLVM_SMOKE_MAC_HOST:-1}"
build_mode_flags=(
  -c opt
  --strip=always
  --stripopt=--strip-all
)

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

bazel_output() {
  local label="$1"
  (cd "${repo_root}" && bazel cquery --output=files "${label}") | tail -n 1
}

build_vm_artifacts() {
  (
    cd "${repo_root}"
    bazel build \
      //cmd/darwin_actiond:darwin-actiond-signed \
      //vm:linux_kernel_zst \
      //vm:initramfs \
      //runtimes:runtimes_squashfs
  )
}

run_smoke() {
  local build_log="${output_root}/llvm_tblgen_smoke.log"
  local measured_server_log="${output_root}/darwin-actiond-vm.measured.log"
  local timings="${output_root}/timings.md"
  local server
  local kernel
  local initramfs
  local runtimes
  local elapsed

  mkdir -p "${output_root}"
  server="$(bazel_output //cmd/darwin_actiond:darwin-actiond-signed)"
  kernel="$(bazel_output //vm:linux_kernel_zst)"
  initramfs="$(bazel_output //vm:initramfs)"
  runtimes="$(bazel_output //runtimes:runtimes_squashfs)"
  server_log="${output_root}/darwin-actiond-vm.log"

  "${server}" serve-vm \
    --listen="${endpoint}" \
    --root="${output_root}/server" \
    --memory-mib="${memory_mib}" \
    --cpus="${cpus}" \
    --kernel="${kernel}" \
    --initramfs="${initramfs}" \
    --runtime-image="${runtimes}" \
    --actiondfs-stats-path="${output_root}/actiondfs_stats.txt" \
    >"${server_log}" 2>&1 &
  server_pid="$!"

  wait_for_port 90

  if ! ACTIOND_LLVM_SMOKE_EXECUTOR="grpc://${endpoint}" \
    ACTIOND_LLVM_SMOKE_CACHE="grpc://${endpoint}" \
    ACTIOND_LLVM_SMOKE_JOBS="${jobs}" \
    ACTIOND_LLVM_SMOKE_WORKSPACE="${workspace}" \
    ACTIOND_LLVM_SMOKE_TARGET="${smoke_target}" \
    ACTIOND_LLVM_SMOKE_WARMUP_TARGET="${warmup_target}" \
    ACTIOND_LLVM_SMOKE_TARGET_PLATFORM="${target_platform}" \
    ACTIOND_LLVM_SMOKE_HOST_PLATFORM="${target_platform}" \
    ACTIOND_LLVM_SMOKE_SERVER_LOG="${server_log}" \
    ACTIOND_LLVM_SMOKE_MEASURED_SERVER_LOG="${measured_server_log}" \
    ACTIOND_LLVM_SMOKE_SKIP_CLEAN=0 \
    "${repo_root}/e2e/llvm_tblgen_smoke.sh" >"${build_log}" 2>&1; then
    echo "LLVM smoke failed; build log: ${build_log}" >&2
    tail -200 "${build_log}" >&2 || true
    return 1
  fi

  elapsed="$(sed -n 's/.*Elapsed time: \([0-9.]*s\).*/\1/p' "${build_log}" | tail -n 1)"
  if [[ ! -s "${measured_server_log}" ]]; then
    echo "measured VM log slice is empty; source log: ${server_log}" >&2
    return 1
  fi

  "${repo_root}/test/parse_timings.py" "${measured_server_log}" \
    --mode "llvm-vm" \
    --command "e2e/run_llvm_vm_smoke.sh" \
    --bazel-elapsed "${elapsed:-unknown}" \
    --workload "${smoke_target}, warmup=${warmup_target:-none}, jobs=${jobs}" \
    --output "${timings}"

  cleanup_server 0
  echo "timing summary: ${timings}" >&2
  echo "actiondfs stats: ${output_root}/actiondfs_stats.txt" >&2
}

run_mac_host_smoke() {
  local warmup_log="${output_root}/llvm_tblgen_mac_host_warmup.log"
  local build_log="${output_root}/llvm_tblgen_mac_host.log"
  local timings="${output_root}/mac_host_timings.md"
  local elapsed

  if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "mac-host LLVM smoke must run on macOS" >&2
    return 1
  fi

  (
    cd "${workspace}"
    bazel clean --expunge
  ) >"${build_log}.clean" 2>&1

  if [[ -n "${warmup_target}" ]]; then
    if ! (
      cd "${workspace}"
      bazel build "${warmup_target}" \
        "${build_mode_flags[@]}" \
        --platforms="${target_platform}" \
        --remote_executor= \
        --remote_cache= \
        --experimental_remote_downloader= \
        --experimental_remote_downloader_local_fallback=true \
        --noremote_cache_compression \
        --noremote_accept_cached \
        --remote_upload_local_results=false \
        --disk_cache= \
        --jobs="${jobs}"
    ) >"${warmup_log}" 2>&1; then
      echo "LLVM mac-host warmup failed; build log: ${warmup_log}" >&2
      tail -200 "${warmup_log}" >&2 || true
      return 1
    fi
  fi

  if ! (
    cd "${workspace}"
    bazel build "${smoke_target}" \
      "${build_mode_flags[@]}" \
      --platforms="${target_platform}" \
      --remote_executor= \
      --remote_cache= \
      --experimental_remote_downloader= \
      --experimental_remote_downloader_local_fallback=true \
      --noremote_cache_compression \
      --noremote_accept_cached \
      --remote_upload_local_results=false \
      --disk_cache= \
      --jobs="${jobs}"
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
- Workload: \`${smoke_target}\`, warmup=${warmup_target:-none}, jobs=${jobs}
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
  build_vm_artifacts
  run_smoke
fi
if [[ "${run_mac_host}" == "1" ]]; then
  run_mac_host_smoke
fi

printf '%s\n' "${output_root}" >/tmp/actiond-last-llvm-vm-smoke-path
