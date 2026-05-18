#!/usr/bin/env bash
set -euo pipefail

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
dir="$(cd "$(dirname "${image}")" && pwd)"
base="$(basename "${image}")"
tmp="${dir}/.${base}.tmp.$$"
trap 'rm -f "${tmp}"' EXIT

if command -v truncate >/dev/null 2>&1; then
  truncate -s "${size_mib}M" "${tmp}"
elif command -v mkfile >/dev/null 2>&1; then
  mkfile -n "${size_mib}m" "${tmp}"
else
  dd if=/dev/zero of="${tmp}" bs=1M count=0 seek="${size_mib}" >/dev/null 2>&1
fi

if command -v mkfs.ext4 >/dev/null 2>&1; then
  mkfs.ext4 -F -q "${tmp}"
else
  if ! command -v docker >/dev/null 2>&1; then
    echo "mkfs.ext4 is unavailable and docker is not installed; cannot format ${image}" >&2
    exit 1
  fi
  docker run --rm \
    -e IMAGE_BASENAME=".${base}.tmp.$$" \
    -v "${dir}:/work" \
    "${ACTIOND_EXT4_IMAGE_UBUNTU:-ubuntu:24.04}" \
    bash -ceu '
      apt-get update >/dev/null
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends e2fsprogs >/dev/null
      mkfs.ext4 -F -q "/work/${IMAGE_BASENAME}"
    '
fi

mv "${tmp}" "${image}"
trap - EXIT
