#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$(uname -s)" != "Linux" || "$(uname -m)" != "x86_64" ]]; then
  echo "Linux LLVM VM smoke requires a Linux x86_64 host" >&2
  exit 1
fi
if [[ "$#" -gt 1 ]]; then
  echo "usage: e2e/run_llvm_linux_vm_smoke.sh [output-directory]" >&2
  exit 1
fi
output_root="${1:-${ACTIOND_LLVM_LINUX_SMOKE_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/actiond-linux-llvm.XXXXXX")}}"
target="${ACTIOND_LLVM_SMOKE_TARGET:-@llvm-project//llvm:llvm-tblgen}"
warmup_target="${ACTIOND_LLVM_SMOKE_WARMUP_TARGET-//e2e:llvm_exec_warmup}"
llvm_platform="${ACTIOND_LLVM_SMOKE_PLATFORM:-@llvm//platforms:linux_x86_64_musl}"
execution_platform="${ACTIOND_LLVM_SMOKE_EXEC_PLATFORM:-//e2e:actiond_linux_x86_64_musl_exec}"
endpoint="${ACTIOND_LLVM_SMOKE_ENDPOINT:-127.0.0.1:8998}"
server_target="//cmd/linux-actiond:linux-actiond_linux_x86_64"
vm_cpus="${ACTIOND_VM_CPUS:-$(nproc)}"
vm_memory_mib="${ACTIOND_VM_MEMORY_MIB:-4096}"
cas_image_size_mib="${ACTIOND_VM_CAS_IMAGE_SIZE_MIB:-8192}"
jobs="${ACTIOND_LLVM_SMOKE_JOBS-}"
jobs_label="${jobs:-Bazel default}"
jobs_flags=()
if [[ -n "${jobs}" ]]; then
  jobs_flags=(--jobs="${jobs}")
fi

mkdir -p "${output_root}"
output_root="$(cd "${output_root}" && pwd)"
actiond_output_base="${output_root}/actiond-bazel-output-base"
host_output_base="${output_root}/linux-host-bazel-output-base"
server_root="${output_root}/vm"
server_log="${output_root}/linux-actiond.log"
summary_path="${output_root}/linux-llvm-smoke-timings.md"
rm -rf "${actiond_output_base}" "${host_output_base}" "${server_root}"

server_pid=""

stop_server() {
  if [[ -n "${server_pid}" ]]; then
    kill "${server_pid}" >/dev/null 2>&1 || true
    wait "${server_pid}" >/dev/null 2>&1 || true
    server_pid=""
  fi
}

cleanup() {
  local status="${1:-$?}"
  stop_server
  if [[ "${status}" -ne 0 && -f "${server_log}" ]]; then
    echo "----- linux-actiond log (${server_log}) -----" >&2
    tail -200 "${server_log}" >&2 || true
  fi
}

trap 'cleanup $?' EXIT

wait_for_port() {
  local host="${endpoint%:*}"
  local port="${endpoint##*:}"
  local start
  start="$(date +%s)"
  while true; do
    if [[ -n "${server_pid}" ]] && ! kill -0 "${server_pid}" >/dev/null 2>&1; then
      echo "linux-actiond exited before ${endpoint} became ready" >&2
      return 1
    fi
    if (echo >"/dev/tcp/${host}/${port}") >/dev/null 2>&1; then
      return 0
    fi
    if (( "$(date +%s)" - start >= 180 )); then
      echo "timed out waiting for ${endpoint}" >&2
      return 1
    fi
    sleep 0.2
  done
}

setup_server() {
  local build_log="${output_root}/linux-actiond-build.log"
  local cquery_log="${output_root}/linux-actiond-cquery.log"
  local -a headers=()
  if [[ -n "${BUILDBUDDY_API_KEY:-}" ]]; then
    headers+=(
      --bes_header="x-buildbuddy-api-key=${BUILDBUDDY_API_KEY}"
      --remote_header="x-buildbuddy-api-key=${BUILDBUDDY_API_KEY}"
    )
  fi

  echo "Building ${server_target}" >&2
  if ! (
    cd "${repo_root}"
    bazel build --config=remote --remote_timeout=900 "${headers[@]}" "${server_target}"
  ) >"${build_log}" 2>&1; then
    echo "linux-actiond build failed; log: ${build_log}" >&2
    tail -200 "${build_log}" >&2 || true
    return 1
  fi

  local server
  if ! server="$({
    cd "${repo_root}"
    bazel cquery --config=remote --output=files --bes_backend= --noshow_progress "${headers[@]}" "${server_target}"
  } 2>"${cquery_log}" | tail -n 1)"; then
    echo "linux-actiond cquery failed; log: ${cquery_log}" >&2
    tail -200 "${cquery_log}" >&2 || true
    return 1
  fi
  if [[ "${server}" != /* ]]; then
    server="${repo_root}/${server}"
  fi
  if [[ ! -x "${server}" ]]; then
    echo "linux-actiond executable does not exist: ${server}" >&2
    return 1
  fi

  (
    cd "${repo_root}"
    bazel shutdown
  ) >>"${build_log}" 2>&1

  "${server}" serve-vm \
    --listen="${endpoint}" \
    --root="${server_root}" \
    --cas-image-size-mib="${cas_image_size_mib}" \
    --memory-mib="${vm_memory_mib}" \
    --cpus="${vm_cpus}" \
    --connect-timeout-ms=900000 \
    >"${server_log}" 2>&1 &
  server_pid="$!"
  wait_for_port
}

process_total() {
  sed -E 's/^([0-9]+) processes:.*/\1/' <<<"$1"
}

process_executed() {
  local summary="$1"
  local total="$2"
  awk -v total="${total}" -F',' '
    {
      skipped = 0
      for (i = 1; i <= NF; i++) {
        part = $i
        sub(/^[^:]*: /, "", part)
        gsub(/^[[:space:]]+|[[:space:].]+$/, "", part)
        if (part ~ /^[0-9]+ (action cache hit|disk cache hit|remote cache hit|internal)$/) {
          split(part, fields, " ")
          skipped += fields[1]
        }
      }
      print total - skipped
    }
  ' <<<"${summary}"
}

measurement_common_flags=(
  -c opt
  --strip=always
  --stripopt=--strip-all
  --color=no
  --curses=no
  --bes_backend=
  --platforms="${llvm_platform}"
  --host_platform="${llvm_platform}"
  --extra_execution_platforms="${execution_platform}"
  --shell_executable=/bin/bash
  --experimental_remote_downloader=
  --experimental_remote_downloader_local_fallback=true
  --noremote_cache_compression
  --remote_upload_local_results=false
  --disk_cache=
)

measure() {
  local mode="$1"
  local output_base="$2"
  local warmup_log="${output_root}/llvm-tblgen-${mode}-warmup.log"
  local build_log="${output_root}/llvm-tblgen-${mode}.log"
  local shutdown_log="${output_root}/llvm-tblgen-${mode}-shutdown.log"
  local -a mode_flags=()
  local -a warmup_cache_flags=(--noremote_accept_cached)
  local -a measured_cache_flags=()

  rm -rf "${output_base}"
  if [[ "${mode}" == "actiond" ]]; then
    mode_flags=(
      --remote_executor="grpc://${endpoint}"
      --remote_cache="grpc://${endpoint}"
      --remote_local_fallback=false
      --remote_download_outputs=toplevel
      --remote_timeout=900
      --spawn_strategy=remote
      --genrule_strategy=remote
    )
    measured_cache_flags=(--remote_accept_cached)
  else
    mode_flags=(
      --remote_executor=
      --remote_cache=
      --spawn_strategy=local
      --genrule_strategy=local
    )
    measured_cache_flags=(--noremote_accept_cached)
  fi

  echo "Starting ${mode} LLVM warmup" >&2
  if ! (
    cd "${repo_root}"
    bazel --output_base="${output_base}" build "${warmup_target}" \
      "${measurement_common_flags[@]}" \
      "${mode_flags[@]}" \
      "${warmup_cache_flags[@]}" \
      "${jobs_flags[@]}"
  ) >"${warmup_log}" 2>&1; then
    echo "${mode} LLVM warmup failed; log: ${warmup_log}" >&2
    tail -200 "${warmup_log}" >&2 || true
    return 1
  fi

  local start_ns end_ns wall_elapsed bazel_elapsed process_summary total executed
  start_ns="$(date +%s%N)"
  echo "Starting ${mode} LLVM measurement" >&2
  if ! (
    cd "${repo_root}"
    bazel --output_base="${output_base}" build "${target}" \
      "${measurement_common_flags[@]}" \
      "${mode_flags[@]}" \
      "${measured_cache_flags[@]}" \
      "${jobs_flags[@]}"
  ) >"${build_log}" 2>&1; then
    echo "${mode} LLVM measurement failed; log: ${build_log}" >&2
    tail -200 "${build_log}" >&2 || true
    return 1
  fi
  end_ns="$(date +%s%N)"

  (
    cd "${repo_root}"
    bazel --output_base="${output_base}" shutdown
  ) >"${shutdown_log}" 2>&1

  wall_elapsed="$(awk -v start="${start_ns}" -v end="${end_ns}" 'BEGIN { printf "%.3f", (end - start) / 1000000000 }')"
  bazel_elapsed="$(sed -n 's/.*Elapsed time: \([0-9.]*\)s.*/\1/p' "${build_log}" | tail -n 1)"
  process_summary="$(sed -n 's/^INFO: \(.*processes:.*\)$/\1/p' "${build_log}" | tail -n 1)"
  if [[ -z "${bazel_elapsed}" || -z "${process_summary}" ]]; then
    echo "could not parse ${mode} LLVM result; log: ${build_log}" >&2
    return 1
  fi
  total="$(process_total "${process_summary}")"
  executed="$(process_executed "${process_summary}" "${total}")"
  if [[ ! "${total}" =~ ^[0-9]+$ || ! "${executed}" =~ ^[0-9]+$ || "${executed}" -eq 0 ]]; then
    echo "could not parse ${mode} process counts: ${process_summary}" >&2
    return 1
  fi

  if [[ "${mode}" == "actiond" ]]; then
    actiond_bazel_elapsed="${bazel_elapsed}"
    actiond_wall_elapsed="${wall_elapsed}"
    actiond_process_summary="${process_summary}"
    actiond_total="${total}"
    actiond_executed="${executed}"
  else
    host_bazel_elapsed="${bazel_elapsed}"
    host_wall_elapsed="${wall_elapsed}"
    host_process_summary="${process_summary}"
    host_total="${total}"
    host_executed="${executed}"
  fi
  echo "${mode} LLVM measurement: Bazel ${bazel_elapsed}s, wall ${wall_elapsed}s, ${process_summary}" >&2
}

if [[ -z "${warmup_target}" ]]; then
  echo "Linux LLVM VM smoke requires ACTIOND_LLVM_SMOKE_WARMUP_TARGET" >&2
  exit 1
fi

echo "Linux LLVM smoke output: ${output_root}" >&2
setup_server
measure actiond "${actiond_output_base}"
stop_server
measure linux-host "${host_output_base}"

if [[ "${actiond_total}" -ne "${host_total}" || "${actiond_executed}" -ne "${host_executed}" ]]; then
  echo "LLVM process-count mismatch:" >&2
  echo "  actiond total=${actiond_total} executed=${actiond_executed}: ${actiond_process_summary}" >&2
  echo "  Linux host total=${host_total} executed=${host_executed}: ${host_process_summary}" >&2
  exit 1
fi

ratio="$(awk -v actiond="${actiond_bazel_elapsed}" -v host="${host_bazel_elapsed}" 'BEGIN { printf "%.3f", actiond / host }')"
revision="$(git -C "${repo_root}" rev-parse HEAD)"
cat >"${summary_path}" <<EOF
# Linux QEMU LLVM Performance Comparison

- Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')
- Revision: ${revision}
- Workload: \`${target}\`, warmup=\`${warmup_target}\`
- Target and host platform: \`${llvm_platform}\`
- Execution platform: \`${execution_platform}\`
- Build mode: \`-c opt --strip=always --stripopt=--strip-all\`
- Jobs: ${jobs_label}
- VM: q35 with TCG, CPUs=${vm_cpus}, memory=${vm_memory_mib} MiB
- Comparison: actiond uses Linux x86_64 musl tools in QEMU; the Linux host runs the same tools natively. This is an end-to-end comparison, not an executor-only comparison.

| Execution | Bazel elapsed | Wall elapsed | Total processes | Executed processes | Process summary |
| --- | ---: | ---: | ---: | ---: | --- |
| actiond | ${actiond_bazel_elapsed}s | ${actiond_wall_elapsed}s | ${actiond_total} | ${actiond_executed} | ${actiond_process_summary} |
| Linux host | ${host_bazel_elapsed}s | ${host_wall_elapsed}s | ${host_total} | ${host_executed} | ${host_process_summary} |

actiond / Linux host Bazel elapsed ratio: ${ratio}x

Both measurements use fresh Bazel output bases on the same Linux host. The actiond measurement runs first; QEMU is stopped before the Linux-host measurement.
EOF

cat "${summary_path}"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  cat "${summary_path}" >>"${GITHUB_STEP_SUMMARY}"
fi

trap - EXIT
