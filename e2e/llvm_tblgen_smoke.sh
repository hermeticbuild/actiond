#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workspace="${ACTIOND_LLVM_SMOKE_WORKSPACE:-${repo_root}}"
target="${ACTIOND_LLVM_SMOKE_TARGET:-@llvm-project//llvm:llvm-tblgen}"
warmup_target="${ACTIOND_LLVM_SMOKE_WARMUP_TARGET-//e2e:llvm_exec_warmup}"
target_platform="${ACTIOND_LLVM_SMOKE_TARGET_PLATFORM:-@llvm//platforms:linux_arm64_musl}"
# LLVM host tools are built for the VM, not for the macOS launcher.
host_platform="${ACTIOND_LLVM_SMOKE_HOST_PLATFORM:-${target_platform}}"
executor="${ACTIOND_LLVM_SMOKE_EXECUTOR:-grpc://127.0.0.1:8998}"
cache="${ACTIOND_LLVM_SMOKE_CACHE:-${executor}}"
jobs="${ACTIOND_LLVM_SMOKE_JOBS:-8}"
server_log="${ACTIOND_LLVM_SMOKE_SERVER_LOG:-}"
measured_server_log="${ACTIOND_LLVM_SMOKE_MEASURED_SERVER_LOG:-}"
remote_grpc_log="${ACTIOND_LLVM_SMOKE_REMOTE_GRPC_LOG:-}"
sample_pid=""
build_mode_flags=(
  -c opt
  --strip=always
  --stripopt=--strip-all
)

cleanup_sample() {
  if [[ -n "${sample_pid}" ]]; then
    kill "${sample_pid}" >/dev/null 2>&1 || true
    wait "${sample_pid}" >/dev/null 2>&1 || true
    sample_pid=""
  fi
}

trap cleanup_sample EXIT

cd "${workspace}"

build_remote() {
  local label="$1"
  local accept_cached="${2:-0}"
  local download_outputs="${3:-toplevel}"
  local bazel_args=(
    build "${label}"
    "${build_mode_flags[@]}"
    --platforms="${target_platform}"
    --host_platform="${host_platform}"
    --extra_execution_platforms=//e2e:actiond_linux_arm64_musl_exec
    --remote_executor="${executor}"
    --remote_cache="${cache}"
    --experimental_remote_downloader=
    --experimental_remote_downloader_local_fallback=true
    --noremote_cache_compression
    --remote_download_outputs="${download_outputs}"
  )
  if [[ "${accept_cached}" != "1" ]]; then
    bazel_args+=(--noremote_accept_cached)
  fi
  if [[ -n "${remote_grpc_log}" ]]; then
    bazel_args+=(--remote_grpc_log="${remote_grpc_log}")
  fi
  bazel "${bazel_args[@]}" \
    --remote_local_fallback=false \
    --remote_upload_local_results=false \
    --disk_cache= \
    --spawn_strategy=remote \
    --genrule_strategy=remote \
    --jobs="${jobs}"
}

start_measured_sample() {
  local seconds="${ACTIOND_LLVM_SMOKE_SAMPLE_SECONDS:-0}"
  if [[ "${seconds}" == "0" || -z "${seconds}" ]]; then
    return 0
  fi
  if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "darwin-actiond sampling requested but sample(1) is only available on macOS" >&2
    return 0
  fi
  if ! command -v sample >/dev/null 2>&1; then
    echo "darwin-actiond sampling requested but sample(1) was not found" >&2
    return 0
  fi
  if [[ -z "${ACTIOND_LLVM_SMOKE_SAMPLE_PID:-}" ]]; then
    echo "darwin-actiond sampling requested but ACTIOND_LLVM_SMOKE_SAMPLE_PID is unset" >&2
    return 0
  fi

  local sample_path="${ACTIOND_LLVM_SMOKE_SAMPLE_PATH:-darwin-actiond-vm.sample.txt}"
  sample "${ACTIOND_LLVM_SMOKE_SAMPLE_PID}" "${seconds}" -file "${sample_path}" >"${sample_path}.stderr" 2>&1 &
  sample_pid="$!"
  echo "darwin-actiond measured-build sample: ${sample_path}" >&2
}

if [[ "${ACTIOND_LLVM_SMOKE_SKIP_CLEAN:-0}" != "1" ]]; then
  bazel clean --expunge
fi

if [[ -n "${warmup_target}" ]]; then
  echo "LLVM smoke warmup: ${warmup_target}" >&2
  build_remote "${warmup_target}" 0 toplevel
fi

measured_offset=0
if [[ -n "${server_log}" && -n "${measured_server_log}" && -f "${server_log}" ]]; then
  measured_offset="$(wc -c <"${server_log}" | tr -d ' ')"
fi

echo "LLVM smoke measured build: ${target}" >&2
start_measured_sample
if [[ -n "${warmup_target}" ]]; then
  build_remote "${target}" 1 toplevel
else
  build_remote "${target}" 0 toplevel
fi
cleanup_sample

if [[ -n "${server_log}" && -n "${measured_server_log}" && -f "${server_log}" ]]; then
  tail -c "+$((measured_offset + 1))" "${server_log}" >"${measured_server_log}"
fi
