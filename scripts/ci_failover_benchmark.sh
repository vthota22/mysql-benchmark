#!/usr/bin/env bash
# Orchestrate a failover benchmark on a remote droplet (GitHub Actions scheduler or local).
#
# GitHub Actions is the scheduler; the droplet is still the execution host (sysbench, kubectl, TPC-C).
#
# Usage:
#   cp ci/benchmark-target.conf.example ci/benchmark-target.conf   # fill in host/repo
#   export BENCHMARK_SSH_PRIVATE_KEY="$(cat ~/.ssh/id_rsa)"        # or GitHub secret
#   ./scripts/ci_failover_benchmark.sh
#
# Optional env overrides:
#   CI_BENCHMARK_CONFIG=/path/to/conf
#   BENCHMARK_DROPLET_HOST, BENCHMARK_DROPLET_USER, BENCHMARK_REMOTE_REPO
#   CI_SKIP_START=1          # only poll + fetch (run already started)
#   CI_ARTIFACTS_DIR=./ci-artifacts
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${CI_BENCHMARK_CONFIG:-${REPO_ROOT}/ci/benchmark-target.conf}"
ARTIFACTS_DIR="${CI_ARTIFACTS_DIR:-${REPO_ROOT}/ci-artifacts}"
SSH_KEY_FILE="${CI_SSH_KEY_FILE:-}"
DIAG_DIR="${ARTIFACTS_DIR}/diagnostics"

DROPLET_HOST=""
DROPLET_USER="root"
DROPLET_SSH_PORT=22
REMOTE_REPO=""
REMOTE_BENCHMARK_CONF="benchmark.conf"
CI_GIT_SYNC=1
DROPLET_GIT_BRANCH=""
CI_POLL_INTERVAL_SEC=60
CI_MAX_WAIT_SEC=10800

RUNNING=""
COMPLETED=""
RESULTS_DIR=""
REPORT_PATH=""

_load_kv_file() {
  local file="$1"
  [[ -f "${file}" ]] || return 0
  local line key value
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -n "${line}" ]] || continue
    [[ "${line}" == *"="* ]] || continue
    key="${line%%=*}"
    value="${line#*=}"
    key="${key%"${key##*[![:space:]]}"}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%\"}"
    value="${value#\"}"
    value="${value%\'}"
    value="${value#\'}"
    case "${key}" in
      DROPLET_HOST) DROPLET_HOST="${value}" ;;
      DROPLET_USER) DROPLET_USER="${value}" ;;
      DROPLET_SSH_PORT) DROPLET_SSH_PORT="${value}" ;;
      REMOTE_REPO) REMOTE_REPO="${value}" ;;
      REMOTE_BENCHMARK_CONF) REMOTE_BENCHMARK_CONF="${value}" ;;
      CI_GIT_SYNC) CI_GIT_SYNC="${value}" ;;
      DROPLET_GIT_BRANCH) DROPLET_GIT_BRANCH="${value}" ;;
      CI_POLL_INTERVAL_SEC) CI_POLL_INTERVAL_SEC="${value}" ;;
      CI_MAX_WAIT_SEC) CI_MAX_WAIT_SEC="${value}" ;;
    esac
  done < "${file}"
}

_apply_env_overrides() {
  [[ -n "${BENCHMARK_DROPLET_HOST:-}" ]] && DROPLET_HOST="${BENCHMARK_DROPLET_HOST}"
  [[ -n "${BENCHMARK_DROPLET_USER:-}" ]] && DROPLET_USER="${BENCHMARK_DROPLET_USER}"
  [[ -n "${BENCHMARK_DROPLET_SSH_PORT:-}" ]] && DROPLET_SSH_PORT="${BENCHMARK_DROPLET_SSH_PORT}"
  [[ -n "${BENCHMARK_REMOTE_REPO:-}" ]] && REMOTE_REPO="${BENCHMARK_REMOTE_REPO}"
  [[ -n "${BENCHMARK_REMOTE_BENCHMARK_CONF:-}" ]] && REMOTE_BENCHMARK_CONF="${BENCHMARK_REMOTE_BENCHMARK_CONF}"
  [[ -n "${BENCHMARK_DROPLET_GIT_BRANCH:-}" ]] && DROPLET_GIT_BRANCH="${BENCHMARK_DROPLET_GIT_BRANCH}"
  [[ -n "${CI_POLL_INTERVAL_SEC_OVERRIDE:-}" ]] && CI_POLL_INTERVAL_SEC="${CI_POLL_INTERVAL_SEC_OVERRIDE}"
  [[ -n "${CI_MAX_WAIT_SEC_OVERRIDE:-}" ]] && CI_MAX_WAIT_SEC="${CI_MAX_WAIT_SEC_OVERRIDE}"
}

_normalize_ci_flags() {
  local git_sync_from_env="${1:-}"

  if [[ -n "${git_sync_from_env}" ]]; then
    CI_GIT_SYNC="${git_sync_from_env}"
  else
    CI_GIT_SYNC="${CI_GIT_SYNC:-1}"
  fi
  case "${CI_GIT_SYNC}" in
    1|true|yes|on) CI_GIT_SYNC=1 ;;
    0|false|no|off) CI_GIT_SYNC=0 ;;
    *)
      echo "ERROR: invalid CI_GIT_SYNC='${CI_GIT_SYNC}' (use 0 or 1)" >&2
      exit 1
      ;;
  esac

  DROPLET_GIT_BRANCH="${DROPLET_GIT_BRANCH:-main_2}"
}

_validate_required() {
  if [[ -z "${BENCHMARK_SSH_PRIVATE_KEY:-}" && ( -z "${SSH_KEY_FILE}" || ! -f "${SSH_KEY_FILE}" ) ]]; then
    echo "ERROR: BENCHMARK_SSH_PRIVATE_KEY is required (or set CI_SSH_KEY_FILE)" >&2
    exit 1
  fi
  if [[ -z "${DROPLET_HOST}" ]]; then
    echo "ERROR: BENCHMARK_DROPLET_HOST is required (repository variable or ci/benchmark-target.conf)" >&2
    exit 1
  fi
  if [[ -z "${REMOTE_REPO}" ]]; then
    echo "ERROR: BENCHMARK_REMOTE_REPO is required (repository variable or ci/benchmark-target.conf)" >&2
    exit 1
  fi
}

_setup_ssh_key() {
  if [[ -n "${SSH_KEY_FILE}" && -f "${SSH_KEY_FILE}" ]]; then
    chmod 600 "${SSH_KEY_FILE}"
    return 0
  fi
  SSH_KEY_FILE="$(mktemp)"
  chmod 600 "${SSH_KEY_FILE}"
  printf '%s\n' "${BENCHMARK_SSH_PRIVATE_KEY}" > "${SSH_KEY_FILE}"
}

_ssh() {
  ssh \
    -i "${SSH_KEY_FILE}" \
    -o BatchMode=yes \
    -o ConnectTimeout=15 \
    -o StrictHostKeyChecking=accept-new \
    -p "${DROPLET_SSH_PORT}" \
    "${DROPLET_USER}@${DROPLET_HOST}" \
    "$@"
}

_ssh_capture() {
  local label="$1"
  shift
  local out rc=0
  out="$(_ssh "$@" 2>&1)" || rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    echo "ERROR: remote command failed (${label}, exit ${rc})" >&2
    echo "${out}" >&2
    return "${rc}"
  fi
  printf '%s' "${out}"
}

_scp_from() {
  local remote_path="$1"
  local local_path="$2"
  scp \
    -i "${SSH_KEY_FILE}" \
    -o BatchMode=yes \
    -o ConnectTimeout=15 \
    -o StrictHostKeyChecking=accept-new \
    -P "${DROPLET_SSH_PORT}" \
    -r \
    "${DROPLET_USER}@${DROPLET_HOST}:${remote_path}" \
    "${local_path}"
}

_remote_conf_path() {
  local repo="${REMOTE_REPO%/}"
  local conf="${REMOTE_BENCHMARK_CONF#/}"
  echo "${repo}/${conf}"
}

_log_runtime_config() {
  echo "=== CI failover benchmark ==="
  echo "Droplet:  ${DROPLET_USER}@${DROPLET_HOST}:${DROPLET_SSH_PORT}"
  echo "Repo:     ${REMOTE_REPO}"
  echo "Config:   $(_remote_conf_path)"
  echo "CI_GIT_SYNC=${CI_GIT_SYNC}"
  echo "DROPLET_GIT_BRANCH=${DROPLET_GIT_BRANCH}"
  echo "CI_SKIP_START=${CI_SKIP_START:-0}"
  echo "CI_MAX_WAIT_SEC=${CI_MAX_WAIT_SEC}"
  echo ""
}

_dump_failure_diagnostics() {
  local reason="${1:-unknown failure}"
  mkdir -p "${DIAG_DIR}"
  {
    echo "reason=${reason}"
    echo "droplet=${DROPLET_USER}@${DROPLET_HOST}"
    echo "remote_repo=${REMOTE_REPO}"
    echo "ci_git_sync=${CI_GIT_SYNC}"
    echo "droplet_git_branch=${DROPLET_GIT_BRANCH}"
    echo "results_dir=${RESULTS_DIR:-}"
    echo "failed_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "${DIAG_DIR}/failure_reason.env"

  local repo_q conf_q ctl_q
  repo_q="$(printf '%q' "${REMOTE_REPO}")"
  conf_q="$(printf '%q' "$(_remote_conf_path)")"
  ctl_q="$(printf '%q' "${REMOTE_REPO}/scripts/failover_run_ctl.sh")"

  {
    echo "----- remote: ctl status -----"
    _ssh "cd ${repo_q} && BENCHMARK_CONF=${conf_q} ${ctl_q} status" 2>&1 || true
    echo
    echo "----- remote: repo HEAD -----"
    _ssh "cd ${repo_q} && git rev-parse --abbrev-ref HEAD && git rev-parse --short HEAD && git status -sb" 2>&1 || true
    echo
    echo "----- remote: control_wrapper.log (tail 100) -----"
    _ssh "tail -n 100 ${repo_q}/results/control_wrapper.log" 2>&1 || true
    if [[ -n "${RESULTS_DIR:-}" ]]; then
      echo
      echo "----- remote: ${RESULTS_DIR}/full_run.log (tail 100) -----"
      _ssh "tail -n 100 ${repo_q}/${RESULTS_DIR}/full_run.log" 2>&1 || true
    fi
  } > "${DIAG_DIR}/remote_diagnostics.txt" 2>&1 || true

  if [[ -n "${RESULTS_DIR:-}" ]]; then
    _fetch_artifacts "${RESULTS_DIR}" || true
  fi

  echo "Diagnostics written to ${DIAG_DIR}/"
}

_sync_repo() {
  if [[ "${CI_GIT_SYNC}" != "1" ]]; then
    echo "--- Skipping git sync (CI_GIT_SYNC=0); using existing droplet checkout ---"
    _ssh_capture "repo HEAD" "set -euo pipefail; cd $(printf '%q' "${REMOTE_REPO}"); git rev-parse --abbrev-ref HEAD; git rev-parse --short HEAD" \
      | sed 's/^/  /' || return 1
    return 0
  fi

  local repo_q branch_cmd=""
  repo_q="$(printf '%q' "${REMOTE_REPO}")"
  branch_cmd="git fetch origin ${DROPLET_GIT_BRANCH} && git checkout ${DROPLET_GIT_BRANCH} && git pull --ff-only origin ${DROPLET_GIT_BRANCH}"
  echo "--- Syncing droplet repo (${REMOTE_REPO}) to branch ${DROPLET_GIT_BRANCH} ---"
  _ssh_capture "git sync" "set -euo pipefail; cd ${repo_q}; ${branch_cmd}"
}

_preflight_remote() {
  local repo_q conf_q ctl_q run_q
  repo_q="$(printf '%q' "${REMOTE_REPO}")"
  conf_q="$(printf '%q' "$(_remote_conf_path)")"
  ctl_q="$(printf '%q' "${REMOTE_REPO}/scripts/failover_run_ctl.sh")"
  run_q="$(printf '%q' "${REMOTE_REPO}/run_failover_benchmark.sh")"

  echo "--- Preflight checks on droplet ---"
  _ssh_capture "SSH connectivity" "echo SSH_OK" >/dev/null
  _ssh_capture "repo path" "test -d ${repo_q} && echo REPO_OK" | grep -q REPO_OK
  _ssh_capture "benchmark.conf" "test -f ${conf_q} && echo CONF_OK" | grep -q CONF_OK
  _ssh_capture "ctl script" "test -x ${ctl_q} && echo CTL_OK" | grep -q CTL_OK
  _ssh_capture "run script" "test -x ${run_q} && echo RUN_OK" | grep -q RUN_OK
  echo "Preflight OK"
  echo ""
}

_start_run() {
  local repo_q conf_q ctl_q start_out
  repo_q="$(printf '%q' "${REMOTE_REPO}")"
  conf_q="$(printf '%q' "$(_remote_conf_path)")"
  ctl_q="$(printf '%q' "${REMOTE_REPO}/scripts/failover_run_ctl.sh")"
  echo "--- Starting failover benchmark on droplet ---"
  start_out="$(_ssh_capture "failover_run_ctl start" "set -euo pipefail; cd ${repo_q}; BENCHMARK_CONF=${conf_q} ${ctl_q} start")"
  echo "${start_out}"
}

_parse_status() {
  local stdout="$1"
  local line key value
  RUNNING=""
  COMPLETED=""
  RESULTS_DIR=""
  REPORT_PATH=""
  while IFS= read -r line; do
    [[ "${line}" == *"="* ]] || continue
    key="${line%%=*}"
    value="${line#*=}"
    case "${key}" in
      running) RUNNING="${value}" ;;
      completed) COMPLETED="${value}" ;;
      results_dir) RESULTS_DIR="${value}" ;;
      report_path) REPORT_PATH="${value}" ;;
    esac
  done <<< "${stdout}"
}

_poll_until_complete() {
  local repo_q conf_q ctl_q status_out elapsed=0
  repo_q="$(printf '%q' "${REMOTE_REPO}")"
  conf_q="$(printf '%q' "$(_remote_conf_path)")"
  ctl_q="$(printf '%q' "${REMOTE_REPO}/scripts/failover_run_ctl.sh")"

  echo "--- Waiting for benchmark completion (poll=${CI_POLL_INTERVAL_SEC}s, max=${CI_MAX_WAIT_SEC}s) ---"
  while [[ "${elapsed}" -lt "${CI_MAX_WAIT_SEC}" ]]; do
    status_out="$(_ssh "set -euo pipefail; cd ${repo_q}; BENCHMARK_CONF=${conf_q} ${ctl_q} status" 2>&1 || true)"
    _parse_status "${status_out}"
    echo "[${elapsed}s] running=${RUNNING:-?} completed=${COMPLETED:-?} results_dir=${RESULTS_DIR:-}"

    if [[ "${COMPLETED:-0}" == "1" && -n "${RESULTS_DIR:-}" ]]; then
      echo "Benchmark completed: ${RESULTS_DIR}"
      return 0
    fi
    if [[ "${RUNNING:-0}" != "1" && "${COMPLETED:-0}" == "1" ]]; then
      return 0
    fi
    if [[ "${RUNNING:-0}" != "1" && -n "${RESULTS_DIR:-}" ]]; then
      if _ssh "grep -q '=== Failover benchmark complete ===' $(printf '%q' "${REMOTE_REPO}/${RESULTS_DIR}/full_run.log") 2>/dev/null"; then
        echo "Benchmark completed (log marker): ${RESULTS_DIR}"
        return 0
      fi
      echo "ERROR: benchmark process stopped before completion marker" >&2
      _dump_failure_diagnostics "benchmark exited before completion marker"
      return 1
    fi

    sleep "${CI_POLL_INTERVAL_SEC}"
    elapsed=$((elapsed + CI_POLL_INTERVAL_SEC))
  done

  echo "ERROR: timed out after ${CI_MAX_WAIT_SEC}s" >&2
  _dump_failure_diagnostics "timed out waiting for benchmark"
  return 1
}

_fetch_artifacts() {
  local results_dir="$1"
  local remote_base="${REMOTE_REPO}/${results_dir}"
  local local_run_dir="${ARTIFACTS_DIR}/${results_dir##*/}"

  rm -rf "${local_run_dir}"
  mkdir -p "${ARTIFACTS_DIR}"

  echo "--- Fetching results from droplet ---"
  _scp_from "${remote_base}/failover_kpi.csv" "${local_run_dir}/failover_kpi.csv" 2>/dev/null \
    || echo "WARN: failover_kpi.csv not found"
  _scp_from "${remote_base}/failover_comparison.txt" "${local_run_dir}/failover_comparison.txt" 2>/dev/null \
    || true
  _scp_from "${remote_base}/full_run.log" "${local_run_dir}/full_run.log" 2>/dev/null \
    || true

  local report_rel="advanced/graphs/failover_report.html"
  if [[ -n "${REPORT_PATH:-}" ]]; then
    report_rel="${REPORT_PATH#${results_dir}/}"
  fi
  _scp_from "${remote_base}/${report_rel}" "${local_run_dir}/failover_report.html" 2>/dev/null \
    || echo "WARN: failover_report.html not found at ${report_rel}"

  {
    echo "results_dir=${results_dir}"
    echo "fetched_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "droplet=${DROPLET_USER}@${DROPLET_HOST}"
    echo "remote_repo=${REMOTE_REPO}"
    [[ -f "${local_run_dir}/failover_report.html" ]] && echo "report_html=${local_run_dir}/failover_report.html"
    [[ -f "${local_run_dir}/failover_kpi.csv" ]] && echo "kpi_csv=${local_run_dir}/failover_kpi.csv"
  } > "${ARTIFACTS_DIR}/run-summary.env"

  echo "Artifacts: ${local_run_dir}"
}

main() {
  local git_sync_from_env="${CI_GIT_SYNC:-}"

  _load_kv_file "${CONFIG_FILE}"
  _apply_env_overrides
  _normalize_ci_flags "${git_sync_from_env}"
  _validate_required
  _setup_ssh_key
  _log_runtime_config
  _preflight_remote
  _sync_repo

  if [[ "${CI_SKIP_START:-0}" != "1" ]]; then
    _start_run
  fi

  local status_out
  status_out="$(_ssh_capture "failover_run_ctl status" \
    "cd $(printf '%q' "${REMOTE_REPO}") && BENCHMARK_CONF=$(printf '%q' "$(_remote_conf_path)") $(printf '%q' "${REMOTE_REPO}/scripts/failover_run_ctl.sh") status")"
  _parse_status "${status_out}"

  if [[ "${COMPLETED:-0}" != "1" ]]; then
    _poll_until_complete
    status_out="$(_ssh_capture "failover_run_ctl status" \
      "cd $(printf '%q' "${REMOTE_REPO}") && BENCHMARK_CONF=$(printf '%q' "$(_remote_conf_path)") $(printf '%q' "${REMOTE_REPO}/scripts/failover_run_ctl.sh") status")"
    _parse_status "${status_out}"
  fi

  if [[ -z "${RESULTS_DIR:-}" ]]; then
    echo "ERROR: no results_dir from ctl status" >&2
    _dump_failure_diagnostics "missing results_dir"
    exit 1
  fi

  _fetch_artifacts "${RESULTS_DIR}"

  if [[ ! -f "${ARTIFACTS_DIR}/${RESULTS_DIR##*/}/failover_report.html" ]]; then
    echo "ERROR: HTML report was not fetched" >&2
    _dump_failure_diagnostics "html report missing"
    exit 1
  fi

  echo ""
  echo "=== CI failover benchmark complete ==="
}

_cleanup_on_exit() {
  local rc=$?
  trap - EXIT
  if [[ ${rc} -ne 0 ]]; then
    _dump_failure_diagnostics "exit ${rc}" 2>/dev/null || true
  fi
  exit "${rc}"
}

trap '_cleanup_on_exit' EXIT
main "$@"
