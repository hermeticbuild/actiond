#!/usr/bin/env bash
set -euo pipefail

workspace="${BUILD_WORKSPACE_DIRECTORY:-$(pwd)}"
image="actiond-linux-tests:ubuntu24.04"
platform_args=()
if [[ -n "${ACTIOND_DOCKER_PLATFORM:-}" ]]; then
  platform_args=(--platform="${ACTIOND_DOCKER_PLATFORM}")
fi
env_args=()
for name in \
  ACTIOND_E2E_PORT \
  ACTIOND_E2E_HOST \
  ACTIOND_E2E_KEEP_TMP \
  ACTIOND_E2E_BARE_COUNT \
  ACTIOND_E2E_SOURCE_DIRS \
  ACTIOND_E2E_SOURCE_FILES_PER_DIR; do
  if [[ -n "${!name:-}" ]]; then
    env_args+=(-e "${name}=${!name}")
  fi
done

run_with_timeout() {
  local seconds="$1"
  shift

  "$@" &
  local pid="$!"
  (
    sleep "${seconds}"
    kill "${pid}" 2>/dev/null || true
  ) &
  local watchdog="$!"

  local status=0
  if wait "${pid}"; then
    status=0
  else
    status="$?"
  fi

  kill "${watchdog}" 2>/dev/null || true
  wait "${watchdog}" 2>/dev/null || true
  return "${status}"
}

cd "${workspace}"
if ! run_with_timeout "${DOCKER_PING_TIMEOUT_SECONDS:-15}" docker info >/dev/null 2>&1; then
  echo "docker daemon did not respond; start Docker or increase DOCKER_PING_TIMEOUT_SECONDS" >&2
  exit 1
fi

docker build "${platform_args[@]}" \
  --build-arg "BAZELISK_VERSION=${ACTIOND_BAZELISK_VERSION:-v1.29.0}" \
  -f tools/docker/linux.Dockerfile \
  -t "${image}" \
  .
docker run --rm --privileged "${platform_args[@]}" \
  "${env_args[@]}" \
  -v "${workspace}:/work" \
  -w /work \
  "${image}" \
  tools/e2e.sh linux
