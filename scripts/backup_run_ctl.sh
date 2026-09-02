#!/usr/bin/env bash
# Droplet-side helper for backup benchmarks: start/status/log/list.
# Mirrors scripts/failover_run_ctl.sh for backup-benchmarking/run_benchmark.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FEATURE_DIR="${REPO_ROOT}/backup-benchmarking"
LOCK_FILE="${FEATURE_DIR}/results/.backup_run.lock"
HARNESS="${FEATURE_DIR}/run_benchmark.sh"
CONFIG="${BENCHMARK_CONF:-${FEATURE_DIR}/benchmark.conf}"
COMPLETE_MARKER="PHASE=DONE"

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
  pgrep -f "${FEATURE_DIR}/run_benchmark.sh" 2>/dev/null | head -1 || true
}

_run_log_complete() {
  local results_dir="${1:?results_dir required}"
  [[ -f "${REPO_ROOT}/${results_dir}/benchmark.log" ]] \
    && grep -q "${COMPLETE_MARKER}" "${REPO_ROOT}/${results_dir}/benchmark.log" 2>/dev/null
}

_find_incomplete_results_dir() {
  local d
  for d in $(ls -1dt "${FEATURE_DIR}"/results/run_* 2>/dev/null); do
    local rel="${d#${REPO_ROOT}/}"
    [[ -f "${d}/benchmark.log" ]] || continue
    if ! _run_log_complete "${rel}"; then
      echo "${rel}"
      return 0
    fi
  done
}

_find_latest_results_dir() {
  local latest
  latest="$(ls -1dt "${FEATURE_DIR}"/results/run_* 2>/dev/null | head -1 || true)"
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

_find_new_results_dir() {
  local -n _known_ref="${1:?known dirs array name required}"
  local d existing known
  for d in $(ls -1dt "${FEATURE_DIR}"/results/run_* 2>/dev/null); do
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
  mkdir -p "${FEATURE_DIR}/results"
  cat > "${LOCK_FILE}" <<EOF
RUN_PID=${pid}
RUN_RESULTS_DIR=${results_dir}
RUN_STARTED_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
}

_pick_report_path() {
  local results_dir="${1:?}"
  local base="${REPO_ROOT}/${results_dir}"
  local candidate
  for candidate in \
    "${base}/backup_benchmark_report.html"
  do
    if [[ -f "${candidate}" ]]; then
      echo "${candidate#${REPO_ROOT}/}"
      return 0
    fi
  done
  # Newest HTML in the run dir (if generate_report was run manually).
  candidate="$(
    {
      find "${base}" -maxdepth 1 -name '*.html' 2>/dev/null | sort | tail -1
    } || true
  )"
  if [[ -n "${candidate}" && -f "${candidate}" ]]; then
    echo "${candidate#${REPO_ROOT}/}"
    return 0
  fi
  return 1
}

_cmd_status() {
  if [[ ! -x "${HARNESS}" ]]; then
    echo "running=0"
    echo "pid="
    echo "results_dir="
    echo "completed=0"
    echo "stub=0"
    echo "note=missing ${HARNESS}"
    exit 0
  fi

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
    log_path="${results_dir}/benchmark.log"
    report_path="$(_pick_report_path "${results_dir}" || true)"
    [[ -f "${REPO_ROOT}/${log_path}" ]] || log_path=""
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
  if [[ ! -x "${HARNESS}" ]]; then
    echo "ERROR: missing ${HARNESS}" >&2
    exit 1
  fi
  if [[ ! -f "${CONFIG}" ]]; then
    echo "ERROR: missing ${CONFIG} (copy from benchmark.conf.example)" >&2
    exit 1
  fi

  local existing
  existing="$(_find_running_pid)"
  if _pid_alive "${existing}"; then
    echo "ERROR: backup benchmark already running (pid ${existing})" >&2
    exit 1
  fi
  rm -f "${LOCK_FILE}"

  local -a existing_dirs=()
  while IFS= read -r d; do
    [[ -n "${d}" ]] && existing_dirs+=("${d}")
  done < <(ls -1d "${FEATURE_DIR}"/results/run_* 2>/dev/null || true)

  mkdir -p "${FEATURE_DIR}/results"
  cd "${FEATURE_DIR}"
  nohup env BENCHMARK_CONF="${CONFIG}" "${HARNESS}" \
    >>"${FEATURE_DIR}/results/control_wrapper.log" 2>&1 &
  local pid=$!

  local results_dir=""
  local attempt
  for attempt in $(seq 1 90); do
    results_dir="$(_find_new_results_dir existing_dirs || true)"
    if [[ -n "${results_dir}" && -f "${REPO_ROOT}/${results_dir}/benchmark.log" ]]; then
      break
    fi
    # Harness creates RUN_DIR before redirecting logs; accept dir existence too.
    if [[ -n "${results_dir}" && -d "${REPO_ROOT}/${results_dir}" ]]; then
      break
    fi
    sleep 1
  done

  if [[ -z "${results_dir}" ]]; then
    results_dir="$(_find_new_results_dir existing_dirs || true)"
  fi
  if [[ -z "${results_dir}" ]]; then
    results_dir="backup-benchmarking/results/run_pending"
  fi

  _write_lock "${pid}" "${results_dir}"
  if ! _pid_alive "${pid}"; then
    echo "ERROR: benchmark exited immediately (pid ${pid})." >&2
    if [[ -f "${FEATURE_DIR}/results/control_wrapper.log" ]]; then
      echo "--- backup-benchmarking/results/control_wrapper.log (last 40 lines) ---" >&2
      tail -n 40 "${FEATURE_DIR}/results/control_wrapper.log" >&2
    fi
    rm -f "${LOCK_FILE}"
    exit 1
  fi
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
    echo "No backup run directory found." >&2
    exit 1
  fi
  local log_file="${REPO_ROOT}/${results_dir}/benchmark.log"
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
  ls -1dt backup-benchmarking/results/run_* 2>/dev/null | head -n "${limit}" | while IFS= read -r d; do
    [[ -n "${d}" ]] || continue
    printf 'RUN|%s\n' "${d}"
    local completed=0
    if _run_log_complete "${d}"; then
      completed=1
    fi
    printf 'STATE|%s|%s\n' "${d}" "${completed}"
    find "${d}" -maxdepth 1 -name '*.html' 2>/dev/null | sort | while IFS= read -r f; do
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
