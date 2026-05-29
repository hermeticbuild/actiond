#!/usr/bin/env bash
set -euo pipefail

artifact_dir="${1:-release}"
target="//cmd/darwin-actiond"
artifact_dir="$(mkdir -p "${artifact_dir}" && cd "${artifact_dir}" && pwd)"
bazel_flags=(
  --config=remote
  --platforms=@llvm//platforms:macos_arm64
)

if [[ -n "${BUILDBUDDY_API_KEY:-}" ]]; then
  bazel_flags+=(--remote_header="x-buildbuddy-api-key=${BUILDBUDDY_API_KEY}")
fi

if [[ -n "${ACTIOND_RELEASE_BAZEL_FLAGS:-}" ]]; then
  read -r -a extra_bazel_flags <<<"${ACTIOND_RELEASE_BAZEL_FLAGS}"
  bazel_flags+=("${extra_bazel_flags[@]}")
fi

artifact="${artifact_dir}/darwin-actiond_macos_arm64"

bazel run "${bazel_flags[@]}" -c opt --run_under="cp -f" "${target}" -- "${artifact}"

cd "${artifact_dir}"
shasum -a 256 darwin-actiond_macos_arm64 > SHA256.txt
