#!/usr/bin/env bash
set -euo pipefail

artifact_dir="${1:-release}"
target="//cmd/darwin-actiond"
bazel_flags=(
  --config=remote
  --platforms=@llvm//platforms:macos_arm64
  --remote_executor=grpcs://remote.buildbuddy.io
  --remote_cache=grpcs://remote.buildbuddy.io
  --bes_backend=grpcs://remote.buildbuddy.io
  --bes_results_url=https://app.buildbuddy.io/invocation/
)

if command -v bazel >/dev/null 2>&1; then
  bazel_cmd=(bazel)
elif command -v bazelisk >/dev/null 2>&1; then
  bazel_cmd=(bazelisk)
else
  bazelisk_version="${BAZELISK_VERSION:-v1.29.0}"
  case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) bazelisk_asset="bazelisk-darwin-arm64" ;;
    Darwin-x86_64) bazelisk_asset="bazelisk-darwin-amd64" ;;
    Linux-aarch64 | Linux-arm64) bazelisk_asset="bazelisk-linux-arm64" ;;
    Linux-x86_64) bazelisk_asset="bazelisk-linux-amd64" ;;
    *)
      echo "unsupported Bazelisk host: $(uname -s)-$(uname -m)" >&2
      exit 1
      ;;
  esac
  bazelisk_path="${RUNNER_TEMP:-/tmp}/bazelisk"
  curl -fsSL "https://github.com/bazelbuild/bazelisk/releases/download/${bazelisk_version}/${bazelisk_asset}" -o "${bazelisk_path}"
  chmod +x "${bazelisk_path}"
  bazel_cmd=("${bazelisk_path}")
fi

if [[ -n "${BUILDBUDDY_API_KEY:-}" ]]; then
  bazel_flags+=(--remote_header="x-buildbuddy-api-key=${BUILDBUDDY_API_KEY}")
fi

if [[ -n "${ACTIOND_RELEASE_BAZEL_FLAGS:-}" ]]; then
  read -r -a extra_bazel_flags <<<"${ACTIOND_RELEASE_BAZEL_FLAGS}"
  bazel_flags+=("${extra_bazel_flags[@]}")
fi

"${bazel_cmd[@]}" build "${bazel_flags[@]}" -c opt "${target}"

src="$("${bazel_cmd[@]}" cquery "${bazel_flags[@]}" -c opt --output=files "${target}" | tail -n 1)"
mkdir -p "${artifact_dir}"
cp "${src}" "${artifact_dir}/darwin-actiond_macos_arm64"
chmod +x "${artifact_dir}/darwin-actiond_macos_arm64"

(
  cd "${artifact_dir}"
  tar -czf darwin-actiond_macos_arm64.tar.gz darwin-actiond_macos_arm64
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 darwin-actiond_macos_arm64 darwin-actiond_macos_arm64.tar.gz > SHA256.txt
  else
    sha256sum darwin-actiond_macos_arm64 darwin-actiond_macos_arm64.tar.gz > SHA256.txt
  fi
)
