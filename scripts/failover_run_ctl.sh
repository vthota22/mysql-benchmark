#!/usr/bin/env bash
# Droplet-side helper for the local control UI: start/status/log for failover runs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOCK_FILE="${REPO_ROOT}/results/.failover_run.lock"
CONFIG="${BENCHMARK_CONF:-${REPO_ROOT}/benchmark.conf}"
COMPLETE_MARKER="=== Failover benchmark complete ==="

_usage() {
  echo "Usage: $0 {status|start|log [lines]|list [limit]}" >&2
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

_run_log_complete() {
  local results_dir="${1:?results_dir required}"
  [[ -f "${REPO_ROOT}/${results_dir}/full_run.log" ]] \
    && grep -q "${COMPLETE_MARKER}" "${REPO_ROOT}/${results_dir}/full_run.log" 2>/dev/null
}

# Newest results dir whose run has not finished yet (active benchmark).
_find_incomplete_results_dir() {
  local d
  for d in $(ls -1dt "${REPO_ROOT}"/results/failover_* 2>/dev/null); do
    local rel="${d#${REPO_ROOT}/}"
    [[ -f "${d}/full_run.log" ]] || continue
    if ! _run_log_complete "${rel}"; then
      echo "${rel}"
      return 0
    fi
  done
}

# Newest results dir by mtime (for idle UI — show last run).
_find_latest_results_dir() {
  local latest
  latest="$(ls -1dt "${REPO_ROOT}"/results/failover_* 2>/dev/null | head -1 || true)"
  if [[ -n "${latest}" ]]; then
    echo "${latest#${REPO_ROOT}/}"
  fi
}

_resolve_results_dir() {
  local from_lock="${1:-}"
  if [[ -n "${from_lock}" && -d "${REPO_ROOT}/${from_lock}" ]]; then
    echo "${from_lock}"
    return 0
  fi
  _find_latest_results_dir
}

# After start: first failover_* directory that did not exist before launch.
_find_new_results_dir() {
  local -n _known_ref="${1:?known dirs array name required}"
  local d existing known
  for d in $(ls -1dt "${REPO_ROOT}"/results/failover_* 2>/dev/null); do
    known=0
    for existing in "${_known_ref[@]:-}"; do
      if [[ "${d}" == "${existing}" ]]; then
        known=1
        break
      fi
    done
    [[ "${known}" -eq 1 ]] && continue
    echo "${d#${REPO_ROOT}/}"
    return 0
  done
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

_active_results_dir() {
  local pid="$(_find_running_pid)"
  if _pid_alive "${pid}"; then
    _find_incomplete_results_dir
  fi
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
    local active_dir
    active_dir="$(_find_incomplete_results_dir || true)"
    if [[ -n "${active_dir}" ]]; then
      results_dir="${active_dir}"
    elif [[ -z "${results_dir}" || ! -d "${REPO_ROOT}/${results_dir}" ]]; then
      results_dir="$(_find_latest_results_dir || true)"
    fi
    _write_lock "${pid}" "${results_dir}"
    if [[ -z "${started}" ]]; then
      started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    fi
  else
    rm -f "${LOCK_FILE}"
    pid=""
    started=""
    results_dir="$(_find_latest_results_dir || true)"
  fi

  local log_path="" report_path="" completed=0
  if [[ -n "${results_dir}" ]]; then
    log_path="${results_dir}/full_run.log"
    report_path="${results_dir}/advanced/graphs/failover_report.html"
    [[ -f "${REPO_ROOT}/${log_path}" ]] || log_path=""
    [[ -f "${REPO_ROOT}/${report_path}" ]] || report_path=""
    if _run_log_complete "${results_dir}"; then
      completed=1
    fi
  fi

  printf 'running=%s\n' "${running}"
  printf 'pid=%s\n' "${pid}"
  printf 'results_dir=%s\n' "${results_dir}"
  printf 'started_utc=%s\n' "${started}"
  printf 'log_path=%s\n' "${log_path}"
  printf 'report_path=%s\n' "${report_path}"
  printf 'completed=%s\n' "${completed}"
}

_cmd_start() {
  local existing
  existing="$(_find_running_pid)"
  if _pid_alive "${existing}"; then
    echo "ERROR: failover benchmark already running (pid ${existing})" >&2
    exit 1
  fi
  rm -f "${LOCK_FILE}"

  local -a existing_dirs=()
  while IFS= read -r d; do
    [[ -n "${d}" ]] && existing_dirs+=("${d}")
  done < <(ls -1d "${REPO_ROOT}"/results/failover_* 2>/dev/null || true)

  cd "${REPO_ROOT}"
  mkdir -p results
  nohup env BENCHMARK_CONF="${CONFIG}" "${REPO_ROOT}/run_failover_benchmark.sh" \
    >>"${REPO_ROOT}/results/control_wrapper.log" 2>&1 &
  local pid=$!

  local results_dir=""
  local attempt
  for attempt in $(seq 1 60); do
    results_dir="$(_find_new_results_dir existing_dirs || true)"
    if [[ -n "${results_dir}" && -f "${REPO_ROOT}/${results_dir}/full_run.log" ]]; then
      break
    fi
    sleep 1
  done

  if [[ -z "${results_dir}" ]]; then
    results_dir="$(_find_new_results_dir existing_dirs || true)"
  fi
  if [[ -z "${results_dir}" ]]; then
    results_dir="results/failover_pending"
  fi

  _write_lock "${pid}" "${results_dir}"
  echo "started pid=${pid} results_dir=${results_dir}"
}

_cmd_log() {
  local lines="${1:-100}"
  local results_dir=""
  local pid="$(_find_running_pid)"

  if _pid_alive "${pid}"; then
    results_dir="$(_find_incomplete_results_dir || true)"
  fi
  if [[ -z "${results_dir}" ]]; then
    if _read_lock; then
      results_dir="${RUN_RESULTS_DIR:-}"
    fi
    results_dir="$(_resolve_results_dir "${results_dir}")"
  fi
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

_cmd_list() {
  local limit="${1:-25}"
  limit=$((limit < 1 ? 1 : limit))
  limit=$((limit > 100 ? 100 : limit))

  cd "${REPO_ROOT}"
  ls -1dt results/failover_* 2>/dev/null | head -n "${limit}" | while IFS= read -r d; do
    [[ -n "${d}" ]] || continue
    printf 'RUN|%s\n' "${d}"
    local completed=0
    if _run_log_complete "${d}"; then
      completed=1
    fi
    printf 'STATE|%s|%s\n' "${d}" "${completed}"
    find "${d}" -name failover_report.html 2>/dev/null | sort | while IFS= read -r f; do
      ts=$(stat -c %Y "${f}" 2>/dev/null || echo 0)
      printf 'REPORT|%s|%s|%s\n' "${d}" "${f}" "${ts}"
    done
  done
}

case "${1:-}" in
  status) _cmd_status ;;
  start) _cmd_start ;;
  log) _cmd_log "${2:-100}" ;;
  list) _cmd_list "${2:-25}" ;;
  *) _usage ;;
esac
