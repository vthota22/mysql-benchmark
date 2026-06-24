#!/usr/bin/env bash
# Shared helpers for backup-benchmarking
set -euo pipefail

backup_bench_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd
}

bench_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd
}

log_phase() {
  local phase="${1:?phase required}"
  local message="${2:-}"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "[${ts}] PHASE=${phase} ${message}"
}

epoch_to_utc() {
  local epoch="${1:?epoch required}"
  if date -u -r 0 +%Y >/dev/null 2>&1; then
    date -u -r "${epoch}" +%Y-%m-%dT%H:%M:%SZ
  else
    date -u -d "@${epoch}" +%Y-%m-%dT%H:%M:%SZ
  fi
}

prefix_tpcc_line_timestamp() {
  local line="${1-}"
  if [[ "${line}" =~ ^\[[[:space:]]*([0-9]+)s[[:space:]]*\] ]]; then
    local elapsed="${BASH_REMATCH[1]}"
    local run_start="${TPCC_RUN_START_EPOCH:-0}"
    local offset="${TPCC_SYSBENCH_OFFSET_SEC:-0}"
    if [[ "${run_start}" -gt 0 ]]; then
      local ts
      ts="$(epoch_to_utc $((run_start + offset + elapsed)))"
      printf '[%s] %s\n' "${ts}" "${line}"
      return 0
    fi
  fi
  printf '%s\n' "${line}"
}

load_config() {
  local config_file="${1:?config file required}"
  if [[ ! -f "${config_file}" ]]; then
    echo "ERROR: Config not found: ${config_file}" >&2
    echo "Copy benchmark.conf.example to benchmark.conf and edit credentials." >&2
    exit 1
  fi
  # shellcheck source=/dev/null
  source "${config_file}"
}

require_config() {
  : "${ENGINE:?Set ENGINE in benchmark.conf (standard or advanced)}"
  case "${ENGINE}" in
    standard|advanced) ;;
    *)
      echo "ERROR: ENGINE must be 'standard' or 'advanced' (got: ${ENGINE})" >&2
      exit 1
      ;;
  esac
  : "${MYSQL_HOST:?Set MYSQL_HOST in benchmark.conf}"
  : "${MYSQL_PORT:?Set MYSQL_PORT in benchmark.conf}"
  : "${MYSQL_USER:?Set MYSQL_USER in benchmark.conf}"
  : "${MYSQL_PASSWORD:?Set MYSQL_PASSWORD in benchmark.conf}"
  : "${MYSQL_DB:?Set MYSQL_DB in benchmark.conf}"
  : "${CLUSTER_ID:?Set CLUSTER_ID in benchmark.conf}"
  : "${DO_API_TOKEN:?Set DO_API_TOKEN in benchmark.conf}"
}

setup_paths() {
  local root
  root="$(backup_bench_root)"
  export BENCH_ROOT="$(bench_root)"
  export BACKUP_BENCH_ROOT="${root}"
  export PATH="${BENCH_ROOT}/sysbench-1.1/bin:${PATH}"
  # shellcheck source=/dev/null
  source "${BENCH_ROOT}/sysbench_mysql_opts.sh"
}

mysql_admin() {
  mysql -h "${MYSQL_HOST}" -P "${MYSQL_PORT}" -u "${MYSQL_USER}" -p"${MYSQL_PASSWORD}" \
    --ssl-mode=REQUIRED "$@"
}

mysql_connectivity_check() {
  log_phase "0_CONNECT" "checking MySQL connectivity (${MYSQL_HOST}:${MYSQL_PORT})"
  if mysql_admin -e "SELECT VERSION() AS version, @@hostname AS hostname;"; then
    log_phase "0_CONNECT" "connection OK"
    return 0
  fi
  log_phase "0_CONNECT" "connection FAILED"
  return 1
}

ensure_database_exists() {
  mysql_admin -e "CREATE DATABASE IF NOT EXISTS \`${MYSQL_DB}\`;"
}

tpcc_dir() {
  echo "${TPCC_DIR:-${BENCH_ROOT}/TPCC/sysbench-tpcc}"
}

ensure_tpcc_failover_patch() {
  local tpcc patch_script
  tpcc="$(tpcc_dir)"
  patch_script="${BENCH_ROOT}/scripts/patch_tpcc_failover.sh"
  if [[ ! -f "${patch_script}" ]]; then
    echo "WARNING: missing ${patch_script} — tpcc failover patch skipped" >&2
    return 0
  fi
  bash "${patch_script}" "${tpcc}"
}

run_tpcc() {
  local subcommand="${1:?prepare|run|cleanup}"
  shift

  build_mysql_base_opts

  local tpcc tables scale threads force_pk trx_level
  tpcc="$(tpcc_dir)"
  if [[ ! -f "${tpcc}/tpcc.lua" ]]; then
    echo "ERROR: Missing ${tpcc}/tpcc.lua — run ../setup_benchmark.sh first" >&2
    exit 1
  fi

  if [[ "${subcommand}" == "run" ]]; then
    ensure_tpcc_failover_patch
  fi

  tables="${TPCC_TABLES:-10}"
  scale="${TPCC_SCALE:-10}"
  force_pk="${TPCC_FORCE_PK:-1}"
  trx_level="${TPCC_TRX_LEVEL:-RR}"

  case "${subcommand}" in
    check)
      threads="${TPCC_CHECK_THREADS:-${TPCC_PREP_THREADS:-16}}"
      ;;
    prepare|cleanup)
      threads="${TPCC_PREP_THREADS:-16}"
      ;;
    *)
      threads="${TPCC_THREADS:-16}"
      ;;
  esac

  local opts=(
    "${MYSQL_BASE_OPTS[@]}"
    "${MYSQL_SSL_OPTS[@]}"
    --tables="${tables}"
    --scale="${scale}"
    --threads="${threads}"
    --trx_level="${trx_level}"
    --force_pk="${force_pk}"
  )

  case "${subcommand}" in
    prepare|cleanup|check)
      run_sysbench_tpcc "${tpcc}" "${opts[@]}" "${subcommand}"
      ;;
    run)
      local run_time="${TPCC_MAX_TIME:-${TPCC_TOTAL_TIME:-3600}}"
      local ignore_errors="${TPCC_IGNORE_ERRORS:-1290,1836,1053,2013,2006,2055,2011,3100,1205,1213,1020}"
      run_sysbench_tpcc "${tpcc}" "${opts[@]}" \
        --time="${run_time}" \
        --warmup-time="${TPCC_WARMUP_SEC:-0}" \
        --report-interval="${TPCC_REPORT_INTERVAL:-1}" \
        --mysql-ignore-errors="${ignore_errors}" \
        --db-ps-mode=disable \
        run
      ;;
    *)
      echo "Unknown tpcc subcommand: ${subcommand}" >&2
      exit 1
      ;;
  esac
}

do_api_token() {
  echo "${DO_API_TOKEN:-${DIGITALOCEAN_ACCESS_TOKEN:-}}"
}

do_api_url() {
  echo "${DO_API_URL:-https://api.digitalocean.com}"
}

doctl_common_args() {
  echo "-u"
  echo "$(do_api_url)"
  local token
  token="$(do_api_token)"
  if [[ -n "${token}" ]]; then
    echo "-t"
    echo "${token}"
  fi
}

run_doctl() {
  if ! command -v doctl >/dev/null 2>&1; then
    echo "ERROR: doctl is required but not found in PATH" >&2
    return 1
  fi
  local -a args=()
  while IFS= read -r line; do
    [[ -n "${line}" ]] && args+=("${line}")
  done < <(doctl_common_args)
  doctl "${args[@]}" "$@"
}

do_api_auth_check() {
  local api_url
  api_url="$(do_api_url)"

  log_phase "0_DO_API" "checking production API (${api_url})"
  if ! run_doctl account get --format Email --no-header >/dev/null 2>&1; then
    log_phase "0_DO_API" "ERROR: production API token rejected"
    return 1
  fi

  log_phase "0_DO_API" "checking cluster ${CLUSTER_ID}"
  if ! run_doctl databases get "${CLUSTER_ID}" --format Name --no-header >/dev/null 2>&1; then
    log_phase "0_DO_API" "ERROR: cannot read cluster ${CLUSTER_ID} on production API"
    return 1
  fi

  log_phase "0_DO_API" "production API auth OK"
}

# List backups for a cluster via doctl, output raw JSON.
list_backups_json() {
  local cluster_id="${1:?cluster id required}"
  run_doctl databases backups list "${cluster_id}" --output json
}
