#!/usr/bin/env bash
set -euo pipefail

version="${VERSION:-${1:-}}"

if [[ -z "${version}" ]]; then
  echo "usage: VERSION=v0.1.0 ./release.sh" >&2
  echo "   or: ./release.sh v0.1.0" >&2
  exit 2
fi

git tag -a "${version}" -m "${version}"
git push origin "${version}"
