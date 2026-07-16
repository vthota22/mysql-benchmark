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
CI_EXPECTED_RESULTS_DIR=""

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
  # IMPORTANT: under `set -e`, a function's exit status is the last command.
  # A failing `[[ -n ... ]] && ...` as the last line would abort the script.
  if [[ -n "${BENCHMARK_DROPLET_HOST:-}" ]]; then DROPLET_HOST="${BENCHMARK_DROPLET_HOST}"; fi
  if [[ -n "${BENCHMARK_DROPLET_USER:-}" ]]; then DROPLET_USER="${BENCHMARK_DROPLET_USER}"; fi
  if [[ -n "${BENCHMARK_DROPLET_SSH_PORT:-}" ]]; then DROPLET_SSH_PORT="${BENCHMARK_DROPLET_SSH_PORT}"; fi
  if [[ -n "${BENCHMARK_REMOTE_REPO:-}" ]]; then REMOTE_REPO="${BENCHMARK_REMOTE_REPO}"; fi
  if [[ -n "${BENCHMARK_REMOTE_BENCHMARK_CONF:-}" ]]; then REMOTE_BENCHMARK_CONF="${BENCHMARK_REMOTE_BENCHMARK_CONF}"; fi
  if [[ -n "${BENCHMARK_DROPLET_GIT_BRANCH:-}" ]]; then DROPLET_GIT_BRANCH="${BENCHMARK_DROPLET_GIT_BRANCH}"; fi
  if [[ -n "${CI_POLL_INTERVAL_SEC_OVERRIDE:-}" ]]; then CI_POLL_INTERVAL_SEC="${CI_POLL_INTERVAL_SEC_OVERRIDE}"; fi
  if [[ -n "${CI_MAX_WAIT_SEC_OVERRIDE:-}" ]]; then CI_MAX_WAIT_SEC="${CI_MAX_WAIT_SEC_OVERRIDE}"; fi
  return 0
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
  echo "Validating required inputs..."
  if [[ -z "${SSH_KEY_FILE}" || ! -f "${SSH_KEY_FILE}" ]]; then
    if [[ -z "${BENCHMARK_SSH_PRIVATE_KEY:-}" ]]; then
      echo "ERROR: provide CI_SSH_KEY_FILE or BENCHMARK_SSH_PRIVATE_KEY"
      exit 1
    fi
  else
    echo "  SSH key file: ${SSH_KEY_FILE}"
  fi
  if [[ -z "${DROPLET_HOST}" ]]; then
    echo "ERROR: BENCHMARK_DROPLET_HOST is required (repository variable or ci/benchmark-target.conf)"
    exit 1
  fi
  echo "  DROPLET_HOST=${DROPLET_HOST}"
  if [[ -z "${REMOTE_REPO}" ]]; then
    echo "ERROR: BENCHMARK_REMOTE_REPO is required (repository variable or ci/benchmark-target.conf)"
    exit 1
  fi
  echo "  REMOTE_REPO=${REMOTE_REPO}"
}

_setup_ssh_key() {
  echo "Setting up SSH key..."
  if [[ -n "${SSH_KEY_FILE}" && -f "${SSH_KEY_FILE}" ]]; then
    chmod 600 "${SSH_KEY_FILE}" || true
  elif [[ -n "${BENCHMARK_SSH_PRIVATE_KEY:-}" ]]; then
    mkdir -p "${ARTIFACTS_DIR}/.ssh"
    SSH_KEY_FILE="${ARTIFACTS_DIR}/.ssh/benchmark_ci_key"
    chmod 700 "${ARTIFACTS_DIR}/.ssh"
    # Preserve multiline key material from env (GitHub secret).
    printf '%s\n' "${BENCHMARK_SSH_PRIVATE_KEY}" > "${SSH_KEY_FILE}"
    chmod 600 "${SSH_KEY_FILE}"
  else
    echo "ERROR: no SSH private key provided (CI_SSH_KEY_FILE or BENCHMARK_SSH_PRIVATE_KEY)"
    exit 1
  fi

  # GitHub secrets sometimes include Windows CRLF; strip CR so ssh-keygen accepts the key.
  if command -v sed >/dev/null 2>&1; then
    sed -i 's/\r$//' "${SSH_KEY_FILE}" 2>/dev/null \
      || sed -i.bak 's/\r$//' "${SSH_KEY_FILE}" 2>/dev/null \
      || true
  fi
  # Ensure trailing newline.
  if [[ -s "${SSH_KEY_FILE}" ]] && [[ "$(tail -c1 "${SSH_KEY_FILE}" | wc -l)" -eq 0 ]]; then
    printf '\n' >> "${SSH_KEY_FILE}"
  fi
  chmod 600 "${SSH_KEY_FILE}"

  if [[ ! -s "${SSH_KEY_FILE}" ]]; then
    echo "ERROR: SSH key file is empty: ${SSH_KEY_FILE}"
    exit 1
  fi

  local first_line
  first_line="$(head -1 "${SSH_KEY_FILE}" | tr -d '\r')"
  echo "  key header: ${first_line}"
  echo "  key bytes: $(wc -c < "${SSH_KEY_FILE}" | tr -d ' ')"

  if [[ "${first_line}" != *"PRIVATE KEY"* ]]; then
    echo "ERROR: SSH key file does not look like a private key"
    echo "       Expected a line like: -----BEGIN OPENSSH PRIVATE KEY-----"
    echo "       Got: ${first_line}"
    echo "       Paste the full private key into secret BENCHMARK_SSH_PRIVATE_KEY (not the .pub file)."
    exit 1
  fi

  local pubkey
  if ! pubkey="$(ssh-keygen -y -f "${SSH_KEY_FILE}" 2>&1)"; then
    echo "ERROR: SSH private key is invalid or passphrase-protected"
    echo "       ssh-keygen says: ${pubkey}"
    echo "       Use an unencrypted key (ssh-keygen -N \"\")."
    exit 1
  fi
  echo "  pubkey fingerprint: $(ssh-keygen -lf "${SSH_KEY_FILE}" 2>/dev/null | awk '{print $1" "$2}' || true)"
  echo "SSH key loaded OK"
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
  # Always end with newline so callers can parse safely.
  printf '%s\n' "${out}"
}

_step() {
  echo ""
  echo ">>> $*"
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
    echo "ssh_key_file=${SSH_KEY_FILE:-}"
    echo "ssh_key_exists=$([ -f "${SSH_KEY_FILE:-}" ] && echo yes || echo no)"
    echo "failed_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "${DIAG_DIR}/failure_reason.env"
  echo "Wrote ${DIAG_DIR}/failure_reason.env"
  cat "${DIAG_DIR}/failure_reason.env"

  if [[ -z "${SSH_KEY_FILE:-}" || ! -f "${SSH_KEY_FILE}" ]]; then
    echo "Skipping remote SSH diagnostics (SSH key file not configured)." | tee "${DIAG_DIR}/remote_diagnostics.txt"
    echo "Diagnostics written to ${DIAG_DIR}/"
    return 0
  fi

  if ! ssh-keygen -y -f "${SSH_KEY_FILE}" >/dev/null 2>&1; then
    echo "Skipping remote SSH diagnostics (SSH key failed ssh-keygen -y)." | tee "${DIAG_DIR}/remote_diagnostics.txt"
    echo "Diagnostics written to ${DIAG_DIR}/"
    return 0
  fi

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

_remote_contains() {
  local label="$1"
  local needle="$2"
  shift 2
  local out
  out="$(_ssh_capture "${label}" "$@")" || return 1
  if [[ "${out}" != *"${needle}"* ]]; then
    echo "ERROR: preflight '${label}' missing expected marker '${needle}'" >&2
    echo "${out}" >&2
    return 1
  fi
  return 0
}

_sync_repo() {
  local repo_q branch_q out
  repo_q="$(printf '%q' "${REMOTE_REPO}")"
  branch_q="$(printf '%q' "${DROPLET_GIT_BRANCH}")"

  if [[ "${CI_GIT_SYNC}" != "1" ]]; then
    _step "Skipping git sync (CI_GIT_SYNC=0)"
    out="$(_ssh_capture "repo HEAD" "set -euo pipefail; cd ${repo_q}; git rev-parse --abbrev-ref HEAD; git rev-parse --short HEAD")" || return 1
    echo "${out}" | sed 's/^/  /'
    return 0
  fi

  _step "Syncing droplet repo to origin/${DROPLET_GIT_BRANCH}"
  # Prefer fetch + hard reset over pull: avoids ff-only failures and dirty-index edge cases.
  # benchmark.conf is gitignored and is preserved.
  out="$(_ssh_capture "git sync" "set -euo pipefail
    cd ${repo_q}
    git remote -v
    git fetch --prune origin ${branch_q}
    git checkout ${branch_q} 2>/dev/null || git checkout -B ${branch_q} origin/${branch_q}
    git reset --hard origin/${branch_q}
    git rev-parse --abbrev-ref HEAD
    git rev-parse --short HEAD
    git status -sb
  ")" || return 1
  echo "${out}" | sed 's/^/  /'
}

_preflight_remote() {
  local repo_q conf_q ctl_q run_q
  repo_q="$(printf '%q' "${REMOTE_REPO}")"
  conf_q="$(printf '%q' "$(_remote_conf_path)")"
  ctl_q="$(printf '%q' "${REMOTE_REPO}/scripts/failover_run_ctl.sh")"
  run_q="$(printf '%q' "${REMOTE_REPO}/run_failover_benchmark.sh")"

  _step "Preflight checks on droplet"
  # Avoid `cmd | grep -q` (SIGPIPE + pipefail can abort the script under set -e).
  _remote_contains "SSH connectivity" "SSH_OK" "echo SSH_OK"
  _remote_contains "repo path" "REPO_OK" "test -d ${repo_q} && echo REPO_OK"
  _remote_contains "benchmark.conf" "CONF_OK" "test -f ${conf_q} && echo CONF_OK"
  _remote_contains "ctl script" "CTL_OK" "test -x ${ctl_q} && echo CTL_OK"
  _remote_contains "run script" "RUN_OK" "test -x ${run_q} && echo RUN_OK"
  echo "Preflight OK"
}

_ctl_status() {
  local repo_q conf_q ctl_q
  repo_q="$(printf '%q' "${REMOTE_REPO}")"
  conf_q="$(printf '%q' "$(_remote_conf_path)")"
  ctl_q="$(printf '%q' "${REMOTE_REPO}/scripts/failover_run_ctl.sh")"
  _ssh_capture "failover_run_ctl status" \
    "set -euo pipefail; cd ${repo_q}; BENCHMARK_CONF=${conf_q} ${ctl_q} status"
}

_attach_if_running() {
  local status_out
  status_out="$(_ctl_status)" || return 1
  echo "${status_out}" | sed 's/^/  /'
  _parse_status "${status_out}"

  if [[ "${RUNNING:-0}" == "1" && -n "${RESULTS_DIR:-}" ]]; then
    CI_EXPECTED_RESULTS_DIR="${RESULTS_DIR}"
    echo "Benchmark already running — attaching to ${CI_EXPECTED_RESULTS_DIR}"
    return 0
  fi
  return 1
}

_start_run() {
  local repo_q conf_q ctl_q start_out status_out results_dir
  repo_q="$(printf '%q' "${REMOTE_REPO}")"
  conf_q="$(printf '%q' "$(_remote_conf_path)")"
  ctl_q="$(printf '%q' "${REMOTE_REPO}/scripts/failover_run_ctl.sh")"

  if _attach_if_running; then
    return 0
  fi

  _step "Starting failover benchmark on droplet"
  start_out="$(_ssh_capture "failover_run_ctl start" "set -euo pipefail; cd ${repo_q}; BENCHMARK_CONF=${conf_q} ${ctl_q} start")"
  echo "${start_out}"

  results_dir="$(sed -n 's/.*results_dir=\([^[:space:]]*\).*/\1/p' <<< "${start_out}" | tail -1)"
  if [[ -z "${results_dir}" ]]; then
    echo "WARN: could not parse results_dir from start output; querying status" >&2
    sleep 2
    status_out="$(_ctl_status)" || return 1
    echo "${status_out}"
    results_dir="$(sed -n 's/^results_dir=//p' <<< "${status_out}" | tail -1)"
    _parse_status "${status_out}"
  fi

  if [[ -z "${results_dir}" || "${results_dir}" == "results/failover_pending" ]]; then
    echo "ERROR: could not determine results_dir after start (got '${results_dir:-}')" >&2
    return 1
  fi

  CI_EXPECTED_RESULTS_DIR="${results_dir}"
  echo "Tracking new run: ${CI_EXPECTED_RESULTS_DIR}"
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
  if [[ -n "${CI_EXPECTED_RESULTS_DIR}" ]]; then
    echo "Expected results dir: ${CI_EXPECTED_RESULTS_DIR}"
  fi

  while [[ "${elapsed}" -lt "${CI_MAX_WAIT_SEC}" ]]; do
    status_out="$(_ssh "set -euo pipefail; cd ${repo_q}; BENCHMARK_CONF=${conf_q} ${ctl_q} status" 2>&1 || true)"
    _parse_status "${status_out}"
    echo "[${elapsed}s] running=${RUNNING:-?} completed=${COMPLETED:-?} results_dir=${RESULTS_DIR:-}"

    if [[ -n "${CI_EXPECTED_RESULTS_DIR}" && -n "${RESULTS_DIR:-}" && "${RESULTS_DIR}" != "${CI_EXPECTED_RESULTS_DIR}" ]]; then
      if [[ "${COMPLETED:-0}" == "1" && "${RUNNING:-0}" != "1" ]]; then
        echo "[${elapsed}s] ignoring stale completed run ${RESULTS_DIR}; waiting for ${CI_EXPECTED_RESULTS_DIR}"
        sleep "${CI_POLL_INTERVAL_SEC}"
        elapsed=$((elapsed + CI_POLL_INTERVAL_SEC))
        continue
      fi
    fi

    if [[ "${COMPLETED:-0}" == "1" && -n "${RESULTS_DIR:-}" ]]; then
      if [[ -z "${CI_EXPECTED_RESULTS_DIR}" || "${RESULTS_DIR}" == "${CI_EXPECTED_RESULTS_DIR}" ]]; then
        echo "Benchmark completed: ${RESULTS_DIR}"
        return 0
      fi
    fi

    if [[ "${RUNNING:-0}" != "1" && -n "${RESULTS_DIR:-}" ]]; then
      if [[ -n "${CI_EXPECTED_RESULTS_DIR}" && "${RESULTS_DIR}" != "${CI_EXPECTED_RESULTS_DIR}" ]]; then
        sleep "${CI_POLL_INTERVAL_SEC}"
        elapsed=$((elapsed + CI_POLL_INTERVAL_SEC))
        continue
      fi
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
  mkdir -p "${local_run_dir}"

  echo "--- Fetching results from droplet ---"
  echo "Remote: ${remote_base}"
  _scp_from "${remote_base}/failover_kpi.csv" "${local_run_dir}/failover_kpi.csv" 2>/dev/null \
    || echo "WARN: failover_kpi.csv not found"
  _scp_from "${remote_base}/failover_comparison.txt" "${local_run_dir}/failover_comparison.txt" 2>/dev/null \
    || true
  _scp_from "${remote_base}/full_run.log" "${local_run_dir}/full_run.log" 2>/dev/null \
    || true

  local report_rel="advanced/graphs/failover_report.html"
  if [[ -n "${REPORT_PATH:-}" ]]; then
    report_rel="${REPORT_PATH#${results_dir}/}"
    report_rel="${report_rel#/}"
  fi
  if ! _scp_from "${remote_base}/${report_rel}" "${local_run_dir}/failover_report.html" 2>/dev/null; then
    echo "WARN: failover_report.html not found at ${report_rel}; trying default path"
    _scp_from "${remote_base}/advanced/graphs/failover_report.html" "${local_run_dir}/failover_report.html" 2>/dev/null \
      || echo "WARN: default failover_report.html path also missing"
  fi

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
  local status_out

  _step "Load config / validate"
  _load_kv_file "${CONFIG_FILE}"
  echo "  config file loaded (or missing): ${CONFIG_FILE}"
  _apply_env_overrides
  echo "  env overrides applied (host=${DROPLET_HOST} repo=${REMOTE_REPO})"
  _normalize_ci_flags "${git_sync_from_env}"
  echo "  flags normalized (CI_GIT_SYNC=${CI_GIT_SYNC} branch=${DROPLET_GIT_BRANCH})"
  _validate_required
  _setup_ssh_key
  _log_runtime_config

  _preflight_remote

  # If a run is already in progress, attach and skip git sync (avoid disrupting the live harness).
  _step "Check for in-progress benchmark"
  if [[ "${CI_SKIP_START:-0}" != "1" ]] && _attach_if_running; then
    echo "Skipping git sync because a run is already in progress."
  else
    _sync_repo
    if [[ "${CI_SKIP_START:-0}" != "1" ]]; then
      _start_run
    else
      _step "CI_SKIP_START=1 — not launching a new benchmark"
    fi
  fi

  # Always poll for the tracked run; never treat a stale completed=1 as success.
  _poll_until_complete
  status_out="$(_ctl_status)" || true
  echo "${status_out}" | sed 's/^/  /'
  _parse_status "${status_out}"

  if [[ -n "${CI_EXPECTED_RESULTS_DIR}" ]]; then
    RESULTS_DIR="${CI_EXPECTED_RESULTS_DIR}"
  fi

  if [[ -z "${RESULTS_DIR:-}" ]]; then
    echo "ERROR: no results_dir from ctl status" >&2
    exit 1
  fi

  # Confirm completion for the tracked directory (not some older run).
  if [[ "${COMPLETED:-0}" != "1" || ( -n "${CI_EXPECTED_RESULTS_DIR}" && "${RESULTS_DIR}" != "${CI_EXPECTED_RESULTS_DIR}" ) ]]; then
    # Re-check completion marker directly for the expected dir.
    if ! _ssh "grep -q '=== Failover benchmark complete ===' $(printf '%q' "${REMOTE_REPO}/${RESULTS_DIR}/full_run.log") 2>/dev/null"; then
      echo "ERROR: benchmark did not complete successfully for ${RESULTS_DIR}" >&2
      exit 1
    fi
    COMPLETED=1
  fi

  _fetch_artifacts "${RESULTS_DIR}"

  if [[ ! -f "${ARTIFACTS_DIR}/${RESULTS_DIR##*/}/failover_report.html" ]]; then
    echo "ERROR: HTML report was not fetched" >&2
    exit 1
  fi

  echo ""
  echo "=== CI failover benchmark complete ==="
  echo "Results: ${RESULTS_DIR}"
}

_cleanup_on_exit() {
  local rc=$?
  trap - EXIT
  if [[ ${rc} -ne 0 ]]; then
    echo ""
    echo "=== FAILURE (exit ${rc}) — collecting diagnostics ==="
    # Do not swallow stderr; we need to see why setup/SSH failed.
    _dump_failure_diagnostics "exit ${rc}" || true
  fi
  exit "${rc}"
}

trap '_cleanup_on_exit' EXIT
main "$@"
