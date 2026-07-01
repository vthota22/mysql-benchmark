#!/usr/bin/env bash
# Droplet-side helper for the local control UI: start/status/log for failover runs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOCK_FILE="${REPO_ROOT}/results/.failover_run.lock"
CONFIG="${BENCHMARK_CONF:-${REPO_ROOT}/benchmark.conf}"

_usage() {
  echo "Usage: $0 {status|start|log [lines]}" >&2
  exit 1
}

_read_lock() {
  [[ -f "${LOCK_FILE}" ]] || return 1
  # shellcheck disable=SC1090
  source "${LOCK_FILE}"
}

_pid_alive() {
  local pid="${1:-}"
  [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null
}

_find_running_pid() {
  pgrep -f "${REPO_ROOT}/run_failover_benchmark.sh" 2>/dev/null | head -1 || true
}

_resolve_results_dir() {
  local from_lock="${1:-}"
  if [[ -n "${from_lock}" && -d "${REPO_ROOT}/${from_lock}" ]]; then
    echo "${from_lock}"
    return 0
  fi
  local latest
  latest="$(ls -td "${REPO_ROOT}"/results/failover_* 2>/dev/null | head -1 || true)"
  if [[ -n "${latest}" ]]; then
    echo "${latest#${REPO_ROOT}/}"
  fi
}

_write_lock() {
  local pid="$1"
  local results_dir="$2"
  mkdir -p "${REPO_ROOT}/results"
  cat > "${LOCK_FILE}" <<EOF
RUN_PID=${pid}
RUN_RESULTS_DIR=${results_dir}
RUN_STARTED_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
}

_cmd_status() {
  local pid="" results_dir="" started=""
  if _read_lock; then
    pid="${RUN_PID:-}"
    results_dir="${RUN_RESULTS_DIR:-}"
    started="${RUN_STARTED_UTC:-}"
  fi

  if ! _pid_alive "${pid}"; then
    pid="$(_find_running_pid)"
  fi

  local running=0
  if _pid_alive "${pid}"; then
    running=1
    results_dir="$(_resolve_results_dir "${results_dir}")"
    if [[ -n "${pid}" && -f "${LOCK_FILE}" ]] && ! grep -q "^RUN_PID=${pid}$" "${LOCK_FILE}" 2>/dev/null; then
      _write_lock "${pid}" "${results_dir}"
    fi
  else
    rm -f "${LOCK_FILE}"
    pid=""
    results_dir="$(_resolve_results_dir "")"
  fi

  local log_path="" report_path=""
  if [[ -n "${results_dir}" ]]; then
    log_path="${results_dir}/full_run.log"
    report_path="${results_dir}/advanced/graphs/failover_report.html"
    [[ -f "${REPO_ROOT}/${log_path}" ]] || log_path=""
    [[ -f "${REPO_ROOT}/${report_path}" ]] || report_path=""
  fi

  printf 'running=%s\n' "${running}"
  printf 'pid=%s\n' "${pid}"
  printf 'results_dir=%s\n' "${results_dir}"
  printf 'started_utc=%s\n' "${started}"
  printf 'log_path=%s\n' "${log_path}"
  printf 'report_path=%s\n' "${report_path}"
}

_cmd_start() {
  local existing
  existing="$(_find_running_pid)"
  if _pid_alive "${existing}"; then
    echo "ERROR: failover benchmark already running (pid ${existing})" >&2
    exit 1
  fi
  rm -f "${LOCK_FILE}"

  cd "${REPO_ROOT}"
  mkdir -p results
  nohup env BENCHMARK_CONF="${CONFIG}" "${REPO_ROOT}/run_failover_benchmark.sh" \
    >>"${REPO_ROOT}/results/control_wrapper.log" 2>&1 &
  local pid=$!

  local results_dir=""
  local attempt
  for attempt in $(seq 1 45); do
    results_dir="$(_resolve_results_dir "")"
    if [[ -n "${results_dir}" && -f "${REPO_ROOT}/${results_dir}/full_run.log" ]]; then
      break
    fi
    sleep 1
  done

  if [[ -z "${results_dir}" ]]; then
    results_dir="results/failover_pending"
  fi

  _write_lock "${pid}" "${results_dir}"
  echo "started pid=${pid} results_dir=${results_dir}"
}

_cmd_log() {
  local lines="${1:-100}"
  local results_dir=""
  if _read_lock; then
    results_dir="${RUN_RESULTS_DIR:-}"
  fi
  results_dir="$(_resolve_results_dir "${results_dir}")"
  if [[ -z "${results_dir}" ]]; then
    echo "No failover run directory found." >&2
    exit 1
  fi
  local log_file="${REPO_ROOT}/${results_dir}/full_run.log"
  if [[ ! -f "${log_file}" ]]; then
    echo "Log not found yet: ${log_file}" >&2
    exit 1
  fi
  tail -n "${lines}" "${log_file}"
}

case "${1:-}" in
  status) _cmd_status ;;
  start) _cmd_start ;;
  log) _cmd_log "${2:-100}" ;;
  *) _usage ;;
esac
