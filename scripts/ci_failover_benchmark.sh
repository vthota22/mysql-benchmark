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

DROPLET_HOST=""
DROPLET_USER="root"
DROPLET_SSH_PORT=22
REMOTE_REPO=""
REMOTE_BENCHMARK_CONF="benchmark.conf"
CI_GIT_SYNC=0
DROPLET_GIT_BRANCH=""
CI_POLL_INTERVAL_SEC=60
CI_MAX_WAIT_SEC=10800

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

_setup_ssh_key() {
  if [[ -n "${SSH_KEY_FILE}" && -f "${SSH_KEY_FILE}" ]]; then
    chmod 600 "${SSH_KEY_FILE}"
    return 0
  fi
  if [[ -z "${BENCHMARK_SSH_PRIVATE_KEY:-}" ]]; then
    echo "ERROR: set BENCHMARK_SSH_PRIVATE_KEY or CI_SSH_KEY_FILE" >&2
    exit 1
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

_sync_repo() {
  if [[ "${CI_GIT_SYNC}" != "1" ]]; then
    return 0
  fi
  local repo_q branch_cmd=""
  repo_q="$(printf '%q' "${REMOTE_REPO}")"
  if [[ -n "${DROPLET_GIT_BRANCH}" ]]; then
    branch_cmd="git fetch origin ${DROPLET_GIT_BRANCH} && git checkout ${DROPLET_GIT_BRANCH} && git pull --ff-only origin ${DROPLET_GIT_BRANCH}"
  else
    branch_cmd="git pull --ff-only"
  fi
  echo "--- Syncing droplet repo (${REMOTE_REPO}) ---"
  _ssh "set -euo pipefail; cd ${repo_q}; ${branch_cmd}"
}

_start_run() {
  local repo_q conf_q ctl_q
  repo_q="$(printf '%q' "${REMOTE_REPO}")"
  conf_q="$(printf '%q' "$(_remote_conf_path)")"
  ctl_q="$(printf '%q' "${REMOTE_REPO}/scripts/failover_run_ctl.sh")"
  echo "--- Starting failover benchmark on droplet ---"
  _ssh "set -euo pipefail; cd ${repo_q}; BENCHMARK_CONF=${conf_q} ${ctl_q} start"
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
    status_out="$(_ssh "set -euo pipefail; cd ${repo_q}; BENCHMARK_CONF=${conf_q} ${ctl_q} status" || true)"
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
      _ssh "tail -n 80 $(printf '%q' "${REMOTE_REPO}/${RESULTS_DIR}/full_run.log")" >&2 || true
      return 1
    fi

    sleep "${CI_POLL_INTERVAL_SEC}"
    elapsed=$((elapsed + CI_POLL_INTERVAL_SEC))
  done

  echo "ERROR: timed out after ${CI_MAX_WAIT_SEC}s" >&2
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
  local git_sync_env="${CI_GIT_SYNC:-}"

  _load_kv_file "${CONFIG_FILE}"
  _apply_env_overrides
  if [[ -n "${git_sync_env}" ]]; then
    CI_GIT_SYNC="${git_sync_env}"
  fi

  if [[ -z "${DROPLET_HOST}" || -z "${REMOTE_REPO}" ]]; then
    echo "ERROR: DROPLET_HOST and REMOTE_REPO required (config or env)" >&2
    exit 1
  fi

  _setup_ssh_key

  echo "=== CI failover benchmark ==="
  echo "Droplet:  ${DROPLET_USER}@${DROPLET_HOST}:${DROPLET_SSH_PORT}"
  echo "Repo:     ${REMOTE_REPO}"
  echo "Config:   $(_remote_conf_path)"
  echo ""

  _ssh "echo SSH_OK"
  _sync_repo

  if [[ "${CI_SKIP_START:-0}" != "1" ]]; then
    _start_run
  fi

  local status_out
  status_out="$(_ssh "cd $(printf '%q' "${REMOTE_REPO}") && BENCHMARK_CONF=$(printf '%q' "$(_remote_conf_path)") $(printf '%q' "${REMOTE_REPO}/scripts/failover_run_ctl.sh") status")"
  _parse_status "${status_out}"

  if [[ "${COMPLETED:-0}" != "1" ]]; then
    _poll_until_complete
    status_out="$(_ssh "cd $(printf '%q' "${REMOTE_REPO}") && BENCHMARK_CONF=$(printf '%q' "$(_remote_conf_path)") $(printf '%q' "${REMOTE_REPO}/scripts/failover_run_ctl.sh") status")"
    _parse_status "${status_out}"
  fi

  if [[ -z "${RESULTS_DIR:-}" ]]; then
    echo "ERROR: no results_dir from ctl status" >&2
    exit 1
  fi

  _fetch_artifacts "${RESULTS_DIR}"

  if [[ ! -f "${ARTIFACTS_DIR}/${RESULTS_DIR##*/}/failover_report.html" ]]; then
    echo "ERROR: HTML report was not fetched" >&2
    exit 1
  fi

  echo ""
  echo "=== CI failover benchmark complete ==="
}

main "$@"
