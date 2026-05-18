#!/usr/bin/env bash
set -euo pipefail

create_sparse_image() {
  local path="$1"
  local mib="$2"

  if command -v truncate >/dev/null 2>&1; then
    truncate -s "${mib}M" "${path}"
  elif command -v mkfile >/dev/null 2>&1; then
    mkfile -n "${mib}m" "${path}"
  else
    dd if=/dev/zero of="${path}" bs=1M count=0 seek="${mib}" >/dev/null 2>&1
  fi
}

if [[ "$#" -ne 2 ]]; then
  echo "usage: tools/create_ext4_image.sh IMAGE SIZE_MIB" >&2
  exit 2
fi

image="$1"
size_mib="$2"

if [[ -f "${image}" ]]; then
  exit 0
fi

mkdir -p "$(dirname "${image}")"
base="$(basename "${image}")"

if command -v mkfs.ext4 >/dev/null 2>&1; then
  dir="$(cd "$(dirname "${image}")" && pwd)"
  tmp="${dir}/.${base}.tmp.$$"
  trap 'rm -f "${tmp}"' EXIT
  create_sparse_image "${tmp}" "${size_mib}"
  mkfs.ext4 -F -q "${tmp}"
else
  if ! command -v docker >/dev/null 2>&1; then
    echo "mkfs.ext4 is unavailable and docker is not installed; cannot format ${image}" >&2
    exit 1
  fi
  docker_cmd=(docker)
  if [[ -n "${ACTIOND_EXT4_IMAGE_DOCKER_CONTEXT:-}" ]]; then
    docker_cmd=(docker --context "${ACTIOND_EXT4_IMAGE_DOCKER_CONTEXT}")
  elif ! docker info >/dev/null 2>&1; then
    docker_cmd=()
    for context in colima desktop-linux default; do
      if docker --context "${context}" info >/dev/null 2>&1; then
        docker_cmd=(docker --context "${context}")
        break
      fi
    done
    if [[ "${#docker_cmd[@]}" -eq 0 ]]; then
      echo "no responsive Docker context found for ext4 image formatting" >&2
      exit 1
    fi
  fi
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  staging_dir="${ACTIOND_EXT4_IMAGE_DOCKER_STAGING_DIR:-${repo_root}/.actiond-tmp/ext4-images}"
  mkdir -p "${staging_dir}"
  staging_dir="$(cd "${staging_dir}" && pwd)"
  tmp="${staging_dir}/.${base}.tmp.$$"
  trap 'rm -f "${tmp}"' EXIT
  create_sparse_image "${tmp}" "${size_mib}"
  "${docker_cmd[@]}" run --rm \
    -e IMAGE_BASENAME=".${base}.tmp.$$" \
    -v "${staging_dir}:/work" \
    "${ACTIOND_EXT4_IMAGE_UBUNTU:-ubuntu:24.04}" \
    bash -ceu '
      apt-get update >/dev/null
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends e2fsprogs >/dev/null
      mkfs.ext4 -F -q "/work/${IMAGE_BASENAME}"
    '
fi

mv "${tmp}" "${image}"
trap - EXIT
