#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_workspace="${repo_root}/test"

usage() {
  cat >&2 <<'EOF'
usage: tools/e2e.sh <build|linux|vm|all>

Modes:
  build   Run repository build/test checks and build the stress action tools.
  linux   Start linux-actiond on this Linux host and run test/ via Bazel remote execution.
  vm      Start darwin-actiond serve-vm and run test/ via Bazel remote execution.
  all     Run build plus the host-appropriate e2e mode when configured.

Environment:
  ACTIOND_E2E_PORT=8980
  ACTIOND_E2E_HOST=127.0.0.1
  ACTIOND_VM_MEMORY_MIB=1024
  ACTIOND_VM_CPUS=4
  ACTIOND_VM_CAS_IMAGE=/path/to/cas.ext4
  ACTIOND_VM_CAS_IMAGE_SIZE_MIB=8192
  ACTIOND_E2E_BARE_COUNT=160
  ACTIOND_E2E_SOURCE_DIRS=8
  ACTIOND_E2E_SOURCE_FILES_PER_DIR=32
  ACTIOND_E2E_NESTED_GROUPS=8
  ACTIOND_E2E_NESTED_FILES_PER_GROUP=96
  ACTIOND_E2E_STANDALONE=1
  ACTIOND_E2E_JOBS=8
  ACTIOND_REPO_BAZEL_FLAGS="--config=remote"
  ACTIOND_E2E_REMOTE_GRPC_LOG=/path/to/remote_grpc.log
  ACTIOND_E2E_ACTIONDFS_STATS_PATH=/path/to/actiondfs_stats.txt
EOF
}

e2e_host="${ACTIOND_E2E_HOST:-127.0.0.1}"
e2e_port="${ACTIOND_E2E_PORT:-8980}"
endpoint="${e2e_host}:${e2e_port}"
e2e_server_pid=""
e2e_root=""
e2e_log=""
e2e_log_label="actiond log"
last_e2e_root=""
repo_bazel_flags=()
if [[ -n "${ACTIOND_REPO_BAZEL_FLAGS:-}" ]]; then
  read -r -a repo_bazel_flags <<<"${ACTIOND_REPO_BAZEL_FLAGS}"
fi

cleanup_e2e_server() {
  local status="${1:-$?}"
  if [[ "${status}" -ne 0 && -n "${ACTIOND_E2E_ACTIONDFS_STATS_PATH:-}" ]]; then
    sleep 1.1
  fi
  if [[ "${status}" -ne 0 && -n "${e2e_log}" && -f "${e2e_log}" ]]; then
    echo "----- ${e2e_log_label} (${e2e_log}) -----" >&2
    tail -200 "${e2e_log}" >&2 || true
  fi
  if [[ "${status}" -ne 0 && -n "${ACTIOND_E2E_ACTIONDFS_STATS_PATH:-}" && -f "${ACTIOND_E2E_ACTIONDFS_STATS_PATH}" ]]; then
    echo "----- actiondfs stats (${ACTIOND_E2E_ACTIONDFS_STATS_PATH}) -----" >&2
    tail -200 "${ACTIOND_E2E_ACTIONDFS_STATS_PATH}" >&2 || true
  fi
  if [[ -n "${e2e_server_pid}" ]]; then
    kill "${e2e_server_pid}" >/dev/null 2>&1 || true
    wait "${e2e_server_pid}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${e2e_root}" && "$(uname -s)" == "Linux" ]]; then
    local runtime_mount="${e2e_root}/server/runtimes"
    if [[ -d "${runtime_mount}" ]] && awk -v path="${runtime_mount}" '$5 == path { found = 1 } END { exit(found ? 0 : 1) }' /proc/self/mountinfo; then
      umount -l "${runtime_mount}" >/dev/null 2>&1 || true
    fi
  fi
  if [[ -n "${e2e_root}" ]]; then
    if [[ "${ACTIOND_E2E_KEEP_TMP:-0}" == "1" ]]; then
      echo "kept e2e root: ${e2e_root}" >&2
      last_e2e_root="${e2e_root}"
    else
      rm -rf "${e2e_root}"
      last_e2e_root=""
    fi
  fi
  e2e_server_pid=""
  e2e_root=""
  e2e_log=""
}

run_bazel() {
  local command="$1"
  shift
  (cd "${repo_root}" && bazel "${command}" "${repo_bazel_flags[@]}" "$@")
}

bazel_output() {
  local label="$1"
  run_bazel cquery --output=files "${label}" | tail -n 1
}

host_arch() {
  case "$(uname -m)" in
    arm64|aarch64) echo "aarch64" ;;
    x86_64|amd64) echo "x86_64" ;;
    *) echo "unsupported" ;;
  esac
}

tool_label_for_arch() {
  case "$1" in
    aarch64) echo "//tools:e2e_action_tool_linux_aarch64" ;;
    x86_64) echo "//tools:e2e_action_tool_linux_x86_64" ;;
    *) echo "unsupported architecture: $1" >&2; exit 1 ;;
  esac
}

prepare_stress_workspace() {
  local arch="$1"
  local label
  label="$(tool_label_for_arch "${arch}")"

  run_bazel build "${label}"
  mkdir -p "${test_workspace}/tool"
  cp "$(bazel_output "${label}")" "${test_workspace}/tool/action-tool"
  chmod +x "${test_workspace}/tool/action-tool"
  "${test_workspace}/tools/generate_inputs.sh"
}

wait_for_port() {
  local host="$1"
  local port="$2"
  local timeout="${3:-30}"
  local start
  start="$(date +%s)"

  while true; do
    if (echo >"/dev/tcp/${host}/${port}") >/dev/null 2>&1; then
      return 0
    fi
    if (( "$(date +%s)" - start >= timeout )); then
      echo "timed out waiting for ${host}:${port}" >&2
      return 1
    fi
    sleep 0.2
  done
}

run_stress_workspace() {
  local -a remote_grpc_log_flags=()
  if [[ -n "${ACTIOND_E2E_REMOTE_GRPC_LOG:-}" ]]; then
    remote_grpc_log_flags+=(--remote_grpc_log="${ACTIOND_E2E_REMOTE_GRPC_LOG}")
  fi

  (
    cd "${test_workspace}"
    bazel clean --expunge >/dev/null
    bazel build "${ACTIOND_E2E_TARGET:-//:stress_all}" \
      --bes_backend= \
      --bes_upload_mode=nowait_for_upload_complete \
      --remote_executor="grpc://${endpoint}" \
      --remote_cache="grpc://${endpoint}" \
      --remote_default_exec_properties=libc=glibc2.35 \
      --noremote_accept_cached \
      --remote_local_fallback=false \
      --remote_upload_local_results=false \
      --remote_download_outputs=toplevel \
      "${remote_grpc_log_flags[@]}" \
      --disk_cache= \
      --jobs="${ACTIOND_E2E_JOBS:-8}" \
      --spawn_strategy=remote \
      --genrule_strategy=remote
  )
}

run_build_checks() {
  run_bazel test //src:unit_tests
  run_bazel build //vm:initramfs_aarch64
  run_bazel build //runtimes:runtimes_squashfs
  run_bazel build //vm:linux_kernel_aarch64 --nobuild
  run_bazel build //tools:e2e_action_tool_linux_aarch64 //tools:e2e_action_tool_linux_x86_64
  run_bazel build //...
  run_bazel test //...
}

run_linux_e2e() {
  if [[ "$(uname -s)" != "Linux" ]]; then
    echo "linux e2e must run on Linux; use tools/docker/run_linux_e2e.sh from macOS" >&2
    return 1
  fi

  local arch
  arch="$(host_arch)"
  prepare_stress_workspace "${arch}"

  local server root
  root="$(mktemp -d "${TMPDIR:-/tmp}/actiond-e2e.XXXXXX")"
  local -a server_args
  server_args=(
    --listen="${endpoint}"
    --root="${root}/server"
  )
  if [[ "${ACTIOND_E2E_STANDALONE:-0}" == "1" ]]; then
    run_bazel build //cmd/linux_actiond:linux-actiond-standalone
    server="$(bazel_output //cmd/linux_actiond:linux-actiond-standalone)"
  else
    run_bazel build //cmd/linux_actiond:linux-actiond
    run_bazel build //runtimes:runtimes_squashfs
    server="$(bazel_output //cmd/linux_actiond:linux-actiond)"
    local runtimes
    runtimes="$(bazel_output //runtimes:runtimes_squashfs)"
    server_args+=(--runtime-image="${runtimes}")
  fi
  local log="${root}/linux-actiond.log"

  "${server}" serve "${server_args[@]}" >"${log}" 2>&1 &
  e2e_server_pid="$!"
  e2e_root="${root}"
  e2e_log="${log}"
  e2e_log_label="linux-actiond log"
  trap 'cleanup_e2e_server $?' EXIT

  wait_for_port "${e2e_host}" "${e2e_port}" 30
  run_stress_workspace
  cleanup_e2e_server 0
  trap - EXIT
}

run_vm_e2e() {
  if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "vm e2e must run on macOS with Virtualization.framework" >&2
    return 1
  fi

  prepare_stress_workspace aarch64

  local server root log
  local cas_image cas_image_size_mib
  local -a server_args
  root="$(mktemp -d "${TMPDIR:-/tmp}/actiond-vm-e2e.XXXXXX")"
  log="${root}/darwin-actiond-vm.log"
  cas_image="${ACTIOND_VM_CAS_IMAGE:-${root}/server/cas.ext4}"
  cas_image_size_mib="${ACTIOND_VM_CAS_IMAGE_SIZE_MIB:-8192}"
  server_args=(
    --listen="${endpoint}"
    --root="${root}/server"
    --cas-image="${cas_image}"
    --cas-image-size-mib="${cas_image_size_mib}"
    --memory-mib="${ACTIOND_VM_MEMORY_MIB:-1024}"
    --cpus="${ACTIOND_VM_CPUS:-4}"
  )

  if [[ "${ACTIOND_E2E_STANDALONE:-0}" == "1" ]]; then
    run_bazel build //cmd/darwin-actiond
    server="$(bazel_output //cmd/darwin-actiond)"
  else
    run_bazel build \
      //cmd/darwin-actiond \
      //vm:linux_kernel_aarch64_zst \
      //vm:initramfs_aarch64 \
      //runtimes:runtimes_squashfs
    local kernel initramfs runtimes
    kernel="$(bazel_output //vm:linux_kernel_aarch64_zst)"
    initramfs="$(bazel_output //vm:initramfs_aarch64)"
    runtimes="$(bazel_output //runtimes:runtimes_squashfs)"
    server="$(bazel_output //cmd/darwin-actiond)"
    server_args+=(
      --kernel="${kernel}"
      --initramfs="${initramfs}"
      --runtime-image="${runtimes}"
    )
  fi
  if [[ -n "${ACTIOND_E2E_ACTIONDFS_STATS_PATH:-}" ]]; then
    server_args+=(
      --actiondfs-stats-path="${ACTIOND_E2E_ACTIONDFS_STATS_PATH}"
    )
  fi

  "${server}" serve-vm "${server_args[@]}" >"${log}" 2>&1 &
  e2e_server_pid="$!"
  e2e_root="${root}"
  e2e_log="${log}"
  e2e_log_label="darwin-actiond VM log"
  trap 'cleanup_e2e_server $?' EXIT

  wait_for_port "${e2e_host}" "${e2e_port}" 90
  run_stress_workspace
  cleanup_e2e_server 0
  trap - EXIT
}

case "${1:-}" in
  build)
    run_build_checks
    ;;
  linux)
    run_linux_e2e
    ;;
  vm)
    run_vm_e2e
    ;;
  all)
    run_build_checks
    case "$(uname -s)" in
      Linux) run_linux_e2e ;;
      Darwin) run_vm_e2e ;;
      *) echo "no e2e mode for $(uname -s)" >&2 ;;
    esac
    ;;
  *)
    usage
    exit 2
    ;;
esac
