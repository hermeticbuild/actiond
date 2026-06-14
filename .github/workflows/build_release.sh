#!/usr/bin/env bash
set -euo pipefail

artifact_dir="${1:-release}"
artifact_dir="$(mkdir -p "${artifact_dir}" && cd "${artifact_dir}" && pwd)"
bazel_flags=(
  --config=remote
  --strip=always
)

if [[ -n "${BUILDBUDDY_API_KEY:-}" ]]; then
  bazel_flags+=(--remote_header="x-buildbuddy-api-key=${BUILDBUDDY_API_KEY}")
fi

if [[ -n "${ACTIOND_RELEASE_BAZEL_FLAGS:-}" ]]; then
  read -r -a extra_bazel_flags <<<"${ACTIOND_RELEASE_BAZEL_FLAGS}"
  bazel_flags+=("${extra_bazel_flags[@]}")
fi

bazel build "${bazel_flags[@]}" -c opt \
  //cmd/darwin-actiond:darwin-actiond_macos_arm64 \
  //cmd/linux-actiond:linux-actiond_linux_arm64 \
  //cmd/linux-actiond:linux-actiond_linux_x86_64 \
  //cmd/windows-actiond:windows-actiond_windows_arm64 \
  //cmd/windows-actiond:windows-actiond_windows_x86_64

cp -f \
  bazel-bin/cmd/darwin-actiond/darwin-actiond_macos_arm64/darwin-actiond_macos_arm64 \
  bazel-bin/cmd/linux-actiond/linux-actiond_linux_arm64/linux-actiond_linux_arm64 \
  bazel-bin/cmd/linux-actiond/linux-actiond_linux_x86_64/linux-actiond_linux_x86_64 \
  bazel-bin/cmd/windows-actiond/windows-actiond_windows_arm64/windows-actiond_windows_arm64.exe \
  bazel-bin/cmd/windows-actiond/windows-actiond_windows_x86_64/windows-actiond_windows_x86_64.exe \
  "${artifact_dir}/"

cd "${artifact_dir}"
shasum -a 256 \
  darwin-actiond_macos_arm64 \
  linux-actiond_linux_arm64 \
  linux-actiond_linux_x86_64 \
  windows-actiond_windows_arm64.exe \
  windows-actiond_windows_x86_64.exe \
  > SHA256.txt
