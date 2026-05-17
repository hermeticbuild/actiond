#!/usr/bin/env bash
set -euo pipefail

run_kbuild() {
  local kernel_src="$1"
  local config="$2"
  local kbuild_out="$3"
  local out="$4"

  local make_bin
  make_bin="$(command -v gmake || command -v make)"
  local cross_compile_arg=()
  if command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
    cross_compile_arg=("CROSS_COMPILE=aarch64-linux-gnu-")
  fi
  local jobs
  jobs="${ACTIOND_KERNEL_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"

  local config_abs
  case "${config}" in
    /*) config_abs="${config}" ;;
    *) config_abs="$(pwd)/${config}" ;;
  esac

  rm -rf "${kbuild_out}"
  mkdir -p "${kbuild_out}"
  KCONFIG_ALLCONFIG="${config_abs}" "${make_bin}" -C "${kernel_src}" O="${kbuild_out}" ARCH=arm64 "${cross_compile_arg[@]}" allnoconfig
  "${make_bin}" -C "${kernel_src}" O="${kbuild_out}" ARCH=arm64 "${cross_compile_arg[@]}" "-j${jobs}" Image
  rm -f "${out}.tmp" "${out}"
  cp "${kbuild_out}/arch/arm64/boot/Image" "${out}.tmp"
  mv -f "${out}.tmp" "${out}"
}

integrate_actiondfs() {
  local kernel_src="$1"
  local actiondfs_src="$2"

  if [[ -z "${actiondfs_src}" ]]; then
    return 0
  fi

  actiondfs_src="$(cd "${actiondfs_src}" && pwd -P)"
  mkdir -p "${kernel_src}/fs/actiondfs"
  rsync -a --delete "${actiondfs_src}/" "${kernel_src}/fs/actiondfs/"

  if ! grep -q 'CONFIG_ACTIONDFS_FS' "${kernel_src}/fs/Makefile"; then
    printf '\nobj-$(CONFIG_ACTIONDFS_FS) += actiondfs/\n' >>"${kernel_src}/fs/Makefile"
  fi
  if ! grep -q 'fs/actiondfs/Kconfig' "${kernel_src}/fs/Kconfig"; then
    printf '\nsource "fs/actiondfs/Kconfig"\n' >>"${kernel_src}/fs/Kconfig"
  fi
}

localize_kernel_src() {
  local src="$1"
  local dst="$2"

  rm -rf "${dst}"
  mkdir -p "${dst}"
  src="$(cd "${src}" && pwd -P)"
  rsync -a --delete --exclude .git "${src}/" "${dst}/"
}

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

docker_command() {
  if [[ -n "${ACTIOND_KERNEL_DOCKER_CONTEXT:-}" ]]; then
    printf '%s\n' docker --context "${ACTIOND_KERNEL_DOCKER_CONTEXT}"
    return 0
  fi

  if run_with_timeout "${ACTIOND_DOCKER_PING_TIMEOUT_SECONDS:-5}" docker info >/dev/null 2>&1; then
    printf '%s\n' docker
    return 0
  fi

  local context
  for context in colima desktop-linux default; do
    if run_with_timeout "${ACTIOND_DOCKER_PING_TIMEOUT_SECONDS:-5}" docker --context "${context}" info >/dev/null 2>&1; then
      printf '%s\n' docker --context "${context}"
      return 0
    fi
  done

  echo "no responsive Docker context found for Darwin kernel build" >&2
  return 1
}

if [[ "${1:-}" == "--inside-docker" ]]; then
  kernel_src="${ACTIOND_KERNEL_SRC:?}"
  if [[ -n "${ACTIOND_KERNEL_LOCAL_SRC:-}" ]]; then
    localize_kernel_src "${kernel_src}" "${ACTIOND_KERNEL_LOCAL_SRC}"
    kernel_src="${ACTIOND_KERNEL_LOCAL_SRC}"
  fi
  integrate_actiondfs "${kernel_src}" "${ACTIOND_ACTIONDFS_SRC:-}"
  run_kbuild \
    "${kernel_src}" \
    "${ACTIOND_KERNEL_CONFIG:?}" \
    "${ACTIOND_KBUILD_OUT:?}" \
    "${ACTIOND_KERNEL_OUT:?}"
  exit 0
fi

if [[ "$#" -lt 4 || "$#" -gt 5 ]]; then
  echo "usage: build_linux_kernel.sh <out> <config> <kernel-makefile> <dockerfile> [actiondfs-src]" >&2
  exit 2
fi

out="$1"
config="$2"
kernel_makefile="$3"
dockerfile="$4"
actiondfs_src="${5:-}"
if [[ -n "${actiondfs_src}" && -f "${actiondfs_src}" ]]; then
  actiondfs_src="$(dirname "${actiondfs_src}")"
fi
kernel_src="$(dirname "${kernel_makefile}")"
kbuild_out="$(pwd)/$(dirname "${out}")/kbuild"

case "$(uname -s)" in
  Darwin)
    image="${ACTIOND_KERNEL_DOCKER_IMAGE:-actiond-kernel-builder:24.04}"
    if ! mapfile -t docker_cmd < <(docker_command); then
      exit 1
    fi
    if [[ "${#docker_cmd[@]}" -eq 0 ]]; then
      exit 1
    fi
    if [[ -n "${ACTIOND_KERNEL_DOCKER_PLATFORM:-}" ]]; then
      "${docker_cmd[@]}" build --platform="${ACTIOND_KERNEL_DOCKER_PLATFORM}" -f "${dockerfile}" -t "${image}" "$(dirname "${dockerfile}")"
    else
      "${docker_cmd[@]}" build -f "${dockerfile}" -t "${image}" "$(dirname "${dockerfile}")"
    fi
    mount_args=(-v "$(pwd):/work")
    if [[ -d /Users ]]; then
      mount_args+=(-v /Users:/Users)
    fi
    docker_run_args=(
      --rm
      "${mount_args[@]}"
      -w /work
      -e "ACTIOND_KERNEL_SRC=/work/${kernel_src}"
      -e "ACTIOND_KERNEL_CONFIG=/work/${config}"
      -e "ACTIOND_KBUILD_OUT=/tmp/actiond-kbuild"
      -e "ACTIOND_KERNEL_OUT=/work/${out}"
      -e "ACTIOND_KERNEL_LOCAL_SRC=/tmp/actiond-kernel-src"
    )
    if [[ -n "${actiondfs_src}" ]]; then
      docker_run_args+=(-e "ACTIOND_ACTIONDFS_SRC=/work/${actiondfs_src}")
    fi
    if [[ -n "${ACTIOND_KERNEL_DOCKER_PLATFORM:-}" ]]; then
      docker_run_args=(--platform="${ACTIOND_KERNEL_DOCKER_PLATFORM}" "${docker_run_args[@]}")
    fi
    "${docker_cmd[@]}" run "${docker_run_args[@]}" "${image}" bash tools/build_linux_kernel.sh --inside-docker
    ;;
  *)
    integrate_actiondfs "${kernel_src}" "${actiondfs_src}"
    run_kbuild "${kernel_src}" "${config}" "${kbuild_out}" "${out}"
    ;;
esac
