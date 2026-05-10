#!/usr/bin/env bash
set -euo pipefail

workspace="${BUILD_WORKSPACE_DIRECTORY:-$(pwd)}"
image="actiond-linux-tests:9.1.0"

cd "${workspace}"
docker build -f tools/docker/linux.Dockerfile -t "${image}" .
docker run --rm \
  -v "${workspace}:/work" \
  -w /work \
  "${image}" \
  bazel test //...
