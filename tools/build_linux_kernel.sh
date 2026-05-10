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

  rm -rf "${kbuild_out}"
  mkdir -p "${kbuild_out}"
  cp "${config}" "${kbuild_out}/.config"
  "${make_bin}" -C "${kernel_src}" O="${kbuild_out}" ARCH=arm64 "${cross_compile_arg[@]}" olddefconfig
  "${make_bin}" -C "${kernel_src}" O="${kbuild_out}" ARCH=arm64 "${cross_compile_arg[@]}" "-j${jobs}" Image
  rm -f "${out}.tmp" "${out}"
  cp "${kbuild_out}/arch/arm64/boot/Image" "${out}.tmp"
  mv -f "${out}.tmp" "${out}"
}

if [[ "${1:-}" == "--inside-docker" ]]; then
  run_kbuild \
    "${ACTIOND_KERNEL_SRC:?}" \
    "${ACTIOND_KERNEL_CONFIG:?}" \
    "${ACTIOND_KBUILD_OUT:?}" \
    "${ACTIOND_KERNEL_OUT:?}"
  exit 0
fi

if [[ "$#" -ne 4 ]]; then
  echo "usage: build_linux_kernel.sh <out> <config> <kernel-makefile> <dockerfile>" >&2
  exit 2
fi

out="$1"
config="$2"
kernel_makefile="$3"
dockerfile="$4"
kernel_src="$(dirname "${kernel_makefile}")"
kbuild_out="$(pwd)/$(dirname "${out}")/kbuild"

case "$(uname -s)" in
  Darwin)
    image="${ACTIOND_KERNEL_DOCKER_IMAGE:-actiond-kernel-builder:24.04}"
    if [[ -n "${ACTIOND_KERNEL_DOCKER_PLATFORM:-}" ]]; then
      docker build --platform="${ACTIOND_KERNEL_DOCKER_PLATFORM}" -f "${dockerfile}" -t "${image}" "$(dirname "${dockerfile}")"
    else
      docker build -f "${dockerfile}" -t "${image}" "$(dirname "${dockerfile}")"
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
      -e "ACTIOND_KBUILD_OUT=/work/$(dirname "${out}")/kbuild"
      -e "ACTIOND_KERNEL_OUT=/work/${out}"
    )
    if [[ -n "${ACTIOND_KERNEL_DOCKER_PLATFORM:-}" ]]; then
      docker_run_args=(--platform="${ACTIOND_KERNEL_DOCKER_PLATFORM}" "${docker_run_args[@]}")
    fi
    docker run "${docker_run_args[@]}" "${image}" bash tools/build_linux_kernel.sh --inside-docker
    ;;
  *)
    run_kbuild "${kernel_src}" "${config}" "${kbuild_out}" "${out}"
    ;;
esac
