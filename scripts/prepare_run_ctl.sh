#!/usr/bin/env bash
# Droplet-side helper for the local control UI: start/status/log for TPC-C data prepare jobs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOCK_FILE="${REPO_ROOT}/results/.prepare_run.lock"
COMPLETE_MARKER="=== TPC-C prepare complete ==="

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
  pgrep -f "${REPO_ROOT}/scripts/prepare_cluster.sh" 2>/dev/null | head -1 || true
}

_run_log_complete() {
  local results_dir="${1:?results_dir required}"
  [[ -f "${REPO_ROOT}/${results_dir}/full_run.log" ]] \
    && grep -q "${COMPLETE_MARKER}" "${REPO_ROOT}/${results_dir}/full_run.log" 2>/dev/null
}

_find_incomplete_results_dir() {
  local d
  for d in $(ls -1dt "${REPO_ROOT}"/results/prepare_* 2>/dev/null); do
    local rel="${d#${REPO_ROOT}/}"
    [[ -f "${d}/full_run.log" ]] || continue
    if ! _run_log_complete "${rel}"; then
      echo "${rel}"
      return 0
    fi
  done
}

_find_latest_results_dir() {
  local latest
  latest="$(ls -1dt "${REPO_ROOT}"/results/prepare_* 2>/dev/null | head -1 || true)"
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
  for d in $(ls -1dt "${REPO_ROOT}"/results/prepare_* 2>/dev/null); do
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
  local droplet_name="${3:-}"
  mkdir -p "${REPO_ROOT}/results"
  cat > "${LOCK_FILE}" <<EOF
RUN_PID=${pid}
RUN_RESULTS_DIR=${results_dir}
RUN_STARTED_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)
RUN_DROPLET_NAME=${droplet_name}
EOF
}

_cmd_status() {
  local pid="" results_dir="" started="" droplet_name=""
  if _read_lock; then
    pid="${RUN_PID:-}"
    results_dir="${RUN_RESULTS_DIR:-}"
    started="${RUN_STARTED_UTC:-}"
    droplet_name="${RUN_DROPLET_NAME:-}"
  fi

  if ! _pid_alive "${pid}"; then
    pid="$(_find_running_pid)"
  fi

  local running=0 success=0 check_ok=""
  if _pid_alive "${pid}"; then
    running=1
    local active_dir
    active_dir="$(_find_incomplete_results_dir || true)"
    if [[ -n "${active_dir}" ]]; then
      results_dir="${active_dir}"
    elif [[ -z "${results_dir}" || ! -d "${REPO_ROOT}/${results_dir}" ]]; then
      results_dir="$(_find_latest_results_dir || true)"
    fi
    _write_lock "${pid}" "${results_dir}" "${droplet_name}"
    if [[ -z "${started}" ]]; then
      started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    fi
  else
    rm -f "${LOCK_FILE}"
    pid=""
    started=""
    results_dir="$(_find_latest_results_dir || true)"
  fi

  local completed=0 log_path="" meta_path=""
  if [[ -n "${results_dir}" ]]; then
    log_path="${results_dir}/full_run.log"
    meta_path="${results_dir}/prepare_meta.env"
    [[ -f "${REPO_ROOT}/${log_path}" ]] || log_path=""
    if _run_log_complete "${results_dir}"; then
      completed=1
      success=1
    elif [[ -f "${REPO_ROOT}/${log_path}" ]] && ! _pid_alive "${pid}"; then
      completed=1
      success=0
    fi
    if [[ -f "${REPO_ROOT}/${meta_path}" ]]; then
      # shellcheck disable=SC1090
      source "${REPO_ROOT}/${meta_path}" 2>/dev/null || true
      check_ok="${PREPARE_CHECK_OK:-}"
    fi
  fi

  printf 'running=%s\n' "${running}"
  printf 'success=%s\n' "${success}"
  printf 'completed=%s\n' "${completed}"
  printf 'pid=%s\n' "${pid}"
  printf 'results_dir=%s\n' "${results_dir}"
  printf 'started_utc=%s\n' "${started}"
  printf 'droplet_name=%s\n' "${droplet_name}"
  printf 'log_path=%s\n' "${log_path}"
  printf 'check_ok=%s\n' "${check_ok}"
}

_cmd_start() {
  local job_conf="${1:?prepare.conf path required}"
  local edition="${2:-advanced}"
  local droplet_name="${3:-}"

  local existing
  existing="$(_find_running_pid)"
  if _pid_alive "${existing}"; then
    echo "ERROR: TPC-C prepare already running (pid ${existing})" >&2
    exit 1
  fi
  rm -f "${LOCK_FILE}"

  local -a existing_dirs=()
  while IFS= read -r d; do
    [[ -n "${d}" ]] && existing_dirs+=("${d}")
  done < <(ls -1d "${REPO_ROOT}"/results/prepare_* 2>/dev/null || true)

  local timestamp results_dir
  timestamp="$(date +%Y%m%d_%H%M%S)"
  results_dir="results/prepare_${timestamp}"
  mkdir -p "${REPO_ROOT}/${results_dir}"

  cd "${REPO_ROOT}"
  nohup env \
    BENCHMARK_CONF="${job_conf}" \
    PREPARE_RESULTS_DIR="${results_dir}" \
    PREPARE_EDITION="${edition}" \
    "${REPO_ROOT}/scripts/prepare_cluster.sh" \
    >>"${REPO_ROOT}/results/prepare_wrapper.log" 2>&1 &
  local pid=$!

  local found=""
  local attempt
  for attempt in $(seq 1 60); do
    found="$(_find_new_results_dir existing_dirs || true)"
    if [[ -n "${found}" && -f "${REPO_ROOT}/${found}/full_run.log" ]]; then
      results_dir="${found}"
      break
    fi
    sleep 1
  done

  if [[ -z "${found}" ]]; then
    found="$(_find_new_results_dir existing_dirs || true)"
    [[ -n "${found}" ]] && results_dir="${found}"
  fi

  _write_lock "${pid}" "${results_dir}" "${droplet_name}"
  if ! _pid_alive "${pid}"; then
    echo "ERROR: prepare job exited immediately (pid ${pid})." >&2
    if [[ -f "${REPO_ROOT}/results/prepare_wrapper.log" ]]; then
      echo "--- results/prepare_wrapper.log (last 40 lines) ---" >&2
      tail -n 40 "${REPO_ROOT}/results/prepare_wrapper.log" >&2
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
    echo "No prepare job directory found." >&2
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
  local limit="${1:-10}"
  limit=$((limit < 1 ? 1 : limit))
  limit=$((limit > 50 ? 50 : limit))

  cd "${REPO_ROOT}"
  ls -1dt results/prepare_* 2>/dev/null | head -n "${limit}" | while IFS= read -r d; do
    [[ -n "${d}" ]] || continue
    local completed=0 success=0
    if _run_log_complete "${d}"; then
      completed=1
      success=1
    elif [[ -f "${d}/full_run.log" ]]; then
      completed=1
    fi
    printf 'RUN|%s\n' "${d}"
    printf 'STATE|%s|%s|%s\n' "${d}" "${completed}" "${success}"
  done
}

case "${1:-}" in
  status) _cmd_status ;;
  start) _cmd_start "${2:?job conf required}" "${3:-advanced}" "${4:-}" ;;
  log) _cmd_log "${2:-100}" ;;
  list) _cmd_list "${2:-10}" ;;
  *) _usage ;;
esac
