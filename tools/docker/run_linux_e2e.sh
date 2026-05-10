#!/usr/bin/env bash
set -euo pipefail

workspace="${BUILD_WORKSPACE_DIRECTORY:-$(pwd)}"
image="actiond-linux-tests:9.1.0"

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

docker build -f tools/docker/linux.Dockerfile -t "${image}" .
docker run --rm --privileged \
  -v "${workspace}:/work" \
  -w /work \
  "${image}" \
  tools/e2e.sh linux

