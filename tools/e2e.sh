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
  ACTIOND_VM_KERNEL=/path/to/arm64/Image    required for vm unless //vm:linux_kernel builds locally
  ACTIOND_VM_MEMORY_MIB=1024
  ACTIOND_VM_CPUS=4
  ACTIOND_E2E_BARE_COUNT=160
  ACTIOND_E2E_SOURCE_DIRS=8
  ACTIOND_E2E_SOURCE_FILES_PER_DIR=32
EOF
}

e2e_host="${ACTIOND_E2E_HOST:-127.0.0.1}"
e2e_port="${ACTIOND_E2E_PORT:-8980}"
endpoint="${e2e_host}:${e2e_port}"

run_bazel() {
  (cd "${repo_root}" && bazel "$@")
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
  (
    cd "${test_workspace}"
    bazel build //:stress_all \
      --remote_executor="grpc://${endpoint}" \
      --remote_local_fallback=false \
      --remote_upload_local_results=false \
      --spawn_strategy=remote \
      --genrule_strategy=remote
  )
}

run_build_checks() {
  run_bazel test //src:unit_tests
  run_bazel build //cmd/linux_actiond:linux-actiond-guest-aarch64
  run_bazel build //vm:initramfs
  run_bazel build //vm:linux_kernel --nobuild
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

  run_bazel build //cmd/linux_actiond:linux-actiond
  local server
  server="$(bazel_output //cmd/linux_actiond:linux-actiond)"
  local root
  root="$(mktemp -d "${TMPDIR:-/tmp}/actiond-e2e.XXXXXX")"
  local log="${root}/linux-actiond.log"

  "${server}" serve --listen="${endpoint}" --root="${root}/server" >"${log}" 2>&1 &
  local server_pid="$!"
  cleanup() {
    kill "${server_pid}" >/dev/null 2>&1 || true
    wait "${server_pid}" >/dev/null 2>&1 || true
    rm -rf "${root}"
  }
  trap cleanup RETURN

  wait_for_port "${e2e_host}" "${e2e_port}" 30
  run_stress_workspace
}

kernel_path() {
  if [[ -n "${ACTIOND_VM_KERNEL:-}" ]]; then
    echo "${ACTIOND_VM_KERNEL}"
    return 0
  fi
  if run_bazel build //vm:linux_kernel; then
    bazel_output //vm:linux_kernel
    return 0
  fi
  echo "ACTIOND_VM_KERNEL is required when //vm:linux_kernel cannot build locally" >&2
  return 1
}

run_vm_e2e() {
  if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "vm e2e must run on macOS with Virtualization.framework" >&2
    return 1
  fi

  prepare_stress_workspace aarch64
  run_bazel build //cmd/darwin_actiond:darwin-actiond-signed //vm:initramfs

  local kernel initramfs server root log
  kernel="$(kernel_path)"
  initramfs="$(bazel_output //vm:initramfs)"
  server="$(bazel_output //cmd/darwin_actiond:darwin-actiond-signed)"
  root="$(mktemp -d "${TMPDIR:-/tmp}/actiond-vm-e2e.XXXXXX")"
  log="${root}/darwin-actiond-vm.log"

  "${server}" serve-vm \
    --listen="${endpoint}" \
    --root="${root}/server" \
    --kernel="${kernel}" \
    --initramfs="${initramfs}" \
    --memory-mib="${ACTIOND_VM_MEMORY_MIB:-1024}" \
    --cpus="${ACTIOND_VM_CPUS:-4}" >"${log}" 2>&1 &
  local server_pid="$!"
  cleanup() {
    kill "${server_pid}" >/dev/null 2>&1 || true
    wait "${server_pid}" >/dev/null 2>&1 || true
    rm -rf "${root}"
  }
  trap cleanup RETURN

  wait_for_port "${e2e_host}" "${e2e_port}" 90
  run_stress_workspace
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
      Darwin)
        if [[ -n "${ACTIOND_VM_KERNEL:-}" ]]; then
          run_vm_e2e
        else
          echo "skipping vm e2e: set ACTIOND_VM_KERNEL to run it" >&2
        fi
        ;;
      *) echo "no e2e mode for $(uname -s)" >&2 ;;
    esac
    ;;
  *)
    usage
    exit 2
    ;;
esac

