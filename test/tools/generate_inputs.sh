#!/usr/bin/env bash
set -euo pipefail

workspace="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bare_count="${ACTIOND_E2E_BARE_COUNT:-160}"
source_dirs="${ACTIOND_E2E_SOURCE_DIRS:-8}"
source_files_per_dir="${ACTIOND_E2E_SOURCE_FILES_PER_DIR:-32}"

rm -rf "${workspace}/bare" "${workspace}/source_dir"
mkdir -p "${workspace}/bare" "${workspace}/source_dir"

for i in $(seq 1 "${bare_count}"); do
  printf 'bare input %04d\npayload %04d\n' "${i}" "$((i * 17))" \
    > "${workspace}/bare/file_$(printf '%04d' "${i}").txt"
done

for d in $(seq 1 "${source_dirs}"); do
  dir="${workspace}/source_dir/pkg_$(printf '%03d' "${d}")"
  mkdir -p "${dir}"
  for f in $(seq 1 "${source_files_per_dir}"); do
    printf 'source dir %03d file %04d\npayload %06d\n' "${d}" "${f}" "$((d * 1000 + f))" \
      > "${dir}/source_$(printf '%04d' "${f}").txt"
  done
done

echo "generated ${bare_count} bare files and $((source_dirs * source_files_per_dir)) source-dir files in ${workspace}" >&2

