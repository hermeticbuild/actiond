#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workspace="${ACTIOND_LLVM_SMOKE_WORKSPACE:-${repo_root}}"
target="${ACTIOND_LLVM_SMOKE_TARGET:-@llvm-project//llvm:llvm-tblgen}"
target_platform="${ACTIOND_LLVM_SMOKE_TARGET_PLATFORM:-@llvm//platforms:linux_arm64_musl}"
host_platform="${ACTIOND_LLVM_SMOKE_HOST_PLATFORM:-${target_platform}}"
executor="${ACTIOND_LLVM_SMOKE_EXECUTOR:-grpc://127.0.0.1:8998}"
cache="${ACTIOND_LLVM_SMOKE_CACHE:-${executor}}"
jobs="${ACTIOND_LLVM_SMOKE_JOBS:-8}"
build_mode_flags=(
  -c opt
  --strip=always
  --stripopt=--strip-all
)

cd "${workspace}"

if [[ "${ACTIOND_LLVM_SMOKE_SKIP_CLEAN:-0}" != "1" ]]; then
  bazel clean --expunge
fi

bazel build "${target}" \
  "${build_mode_flags[@]}" \
  --platforms="${target_platform}" \
  --host_platform="${host_platform}" \
  --remote_executor="${executor}" \
  --remote_cache="${cache}" \
  --experimental_remote_downloader= \
  --experimental_remote_downloader_local_fallback=true \
  --noremote_cache_compression \
  --noremote_accept_cached \
  --remote_local_fallback=false \
  --remote_upload_local_results=false \
  --disk_cache= \
  --spawn_strategy=remote \
  --genrule_strategy=remote \
  --jobs="${jobs}"
