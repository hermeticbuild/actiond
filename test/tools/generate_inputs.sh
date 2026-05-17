#!/usr/bin/env bash
set -euo pipefail

workspace="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bare_count="${ACTIOND_E2E_BARE_COUNT:-160}"
source_dirs="${ACTIOND_E2E_SOURCE_DIRS:-8}"
source_files_per_dir="${ACTIOND_E2E_SOURCE_FILES_PER_DIR:-32}"
nested_groups="${ACTIOND_E2E_NESTED_GROUPS:-8}"
nested_files_per_group="${ACTIOND_E2E_NESTED_FILES_PER_GROUP:-96}"

rm -rf "${workspace}/bare" "${workspace}/source_dir" "${workspace}/nested_files"
mkdir -p "${workspace}/bare" "${workspace}/source_dir" "${workspace}/nested_files"

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

for g in $(seq 1 "${nested_groups}"); do
  dir="${workspace}/nested_files/group_$(printf '%03d' "${g}")/foo/bar/baz"
  mkdir -p "${dir}"
  for f in $(seq 1 "${nested_files_per_group}"); do
    printf 'nested individual group %03d file %04d\npayload %06d\n' "${g}" "${f}" "$((g * 1000 + f))" \
      > "${dir}/$(printf '%04d' "${f}").txt"
  done
done

echo "generated ${bare_count} bare files and $((source_dirs * source_files_per_dir)) source-dir files in ${workspace}" >&2
echo "generated $((nested_groups * nested_files_per_group)) nested individual files in ${workspace}" >&2
