#!/usr/bin/env bash
set -euo pipefail

workspace="${ACTIOND_LLVM_SMOKE_WORKSPACE:-/Users/dzbarsky/bootstrapped2}"
executor="${ACTIOND_LLVM_SMOKE_EXECUTOR:-grpc://127.0.0.1:8998}"
cache="${ACTIOND_LLVM_SMOKE_CACHE:-${executor}}"
jobs="${ACTIOND_LLVM_SMOKE_JOBS:-8}"

cd "${workspace}"

if [[ "${ACTIOND_LLVM_SMOKE_SKIP_CLEAN:-0}" != "1" ]]; then
  bazel clean --expunge
fi

bazel build --config=prebuilt @llvm-project//llvm:llvm-tblgen \
  --platforms=//platforms:linux_arm64_musl \
  --host_platform=//platforms:linux_arm64_musl \
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
