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

backup_profiling_enabled() {
  [[ "${SKIP_BACKUP_PROFILING:-0}" != "1" ]]
}

backup_schedule_patch_needed() {
  [[ -n "${BACKUP_FULL_SCHEDULE:-}" || -n "${BACKUP_INCREMENTAL_SCHEDULE:-}" ]]
}

kube_access_needed() {
  backup_profiling_enabled || backup_schedule_patch_needed
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

  if kube_access_needed; then
    : "${KUBECONFIG_PATH:?Set KUBECONFIG_PATH in benchmark.conf (required for backup profiling / schedule patching)}"
    : "${KUBE_NAMESPACE:?Set KUBE_NAMESPACE in benchmark.conf (required for backup profiling / schedule patching)}"
  fi
}

setup_paths() {
  local root
  root="$(backup_bench_root)"
  export BENCH_ROOT="$(bench_root)"
  export BACKUP_BENCH_ROOT="${root}"
  if [[ ! -f "${BENCH_ROOT}/sysbench_mysql_opts.sh" ]]; then
    echo "ERROR: benchmark repo root not found at BENCH_ROOT=${BENCH_ROOT}" >&2
    echo "Missing: ${BENCH_ROOT}/sysbench_mysql_opts.sh" >&2
    echo "Clone the full mysql-benchmark repo (not just backup-benchmarking/) and run:" >&2
    echo "  cd ${BENCH_ROOT} && ./setup_benchmark.sh" >&2
    exit 1
  fi
  export PATH="${BENCH_ROOT}/sysbench-1.1/bin:${PATH}"
  # shellcheck source=/dev/null
  source "${BENCH_ROOT}/sysbench_mysql_opts.sh"
}

preflight_checks() {
  local sysbench tpcc
  sysbench="$("${BENCH_ROOT}/which_sysbench.sh")"
  if [[ ! -x "${sysbench}" ]]; then
    echo "ERROR: sysbench not executable: ${sysbench}" >&2
    echo "Run from repo root: ./setup_benchmark.sh" >&2
    exit 1
  fi

  tpcc="$(tpcc_dir)"
  if [[ ! -f "${tpcc}/tpcc.lua" ]]; then
    echo "ERROR: Missing ${tpcc}/tpcc.lua" >&2
    echo "Run from repo root: ./setup_benchmark.sh" >&2
    exit 1
  fi

  if ! command -v mysql >/dev/null 2>&1; then
    echo "ERROR: mysql client not found in PATH" >&2
    echo "Install with: apt-get install -y mysql-client" >&2
    exit 1
  fi

  if kube_access_needed && ! command -v kubectl >/dev/null 2>&1; then
    echo "ERROR: kubectl not found in PATH (required for backup profiling / schedule patching)" >&2
    exit 1
  fi
}

mysql_admin() {
  mysql -h "${MYSQL_HOST}" -P "${MYSQL_PORT}" -u "${MYSQL_USER}" -p"${MYSQL_PASSWORD}" \
    --ssl-mode=REQUIRED "$@"
}

mysql_connectivity_check() {
  log_phase "0_CONNECT" "checking MySQL connectivity (${MYSQL_HOST}:${MYSQL_PORT})"
  if mysql_admin -e "SELECT VERSION() AS version, @@hostname AS hostname, @@sql_require_primary_key AS require_pk;"; then
    log_phase "0_CONNECT" "connection OK"
    return 0
  fi
  log_phase "0_CONNECT" "connection FAILED"
  return 1
}

ensure_database_exists() {
  mysql_admin -e "CREATE DATABASE IF NOT EXISTS \`${MYSQL_DB}\`;"
}

tpcc_tables_exist() {
  local tables="${TPCC_TABLES:-10}"
  local expected=$((tables * 9))
  local found
  found="$(mysql_admin -N -e "
    SELECT COUNT(*)
    FROM information_schema.tables
    WHERE table_schema = '${MYSQL_DB}'
      AND table_name REGEXP '^(warehouse|district|customer|orders|new_orders|order_line|stock|item|history)[0-9]+\$'
  ")"
  if [[ "${found}" -ge "${expected}" ]]; then
    return 0
  fi
  log_phase "1_INIT" "found ${found}/${expected} TPC-C tables in ${MYSQL_DB}"
  return 1
}

verify_tpcc_tables() {
  if [[ "${SKIP_TPCC_CHECK:-0}" == "1" ]]; then
    log_phase "1_INIT" "SKIP_TPCC_CHECK=1 — verifying TPC-C table names only (no consistency check)"
    tpcc_tables_exist
    return $?
  fi

  log_phase "1_INIT" "running sysbench tpcc check (threads=${TPCC_CHECK_THREADS})"
  run_tpcc check
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

ensure_tpcc_prepare_commit_patch() {
  local tpcc patch_script
  tpcc="$(tpcc_dir)"
  patch_script="${BENCH_ROOT}/scripts/patch_tpcc_prepare_commit.sh"
  if [[ ! -f "${patch_script}" ]]; then
    echo "WARNING: missing ${patch_script} — tpcc prepare commit patch skipped" >&2
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
  elif [[ "${subcommand}" == "prepare" ]]; then
    ensure_tpcc_prepare_commit_patch
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
        --percentile="${TPCC_PERCENTILE:-99}" \
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

# ---------------------------------------------------------------------------
# Kubernetes / Percona CR helpers
# ---------------------------------------------------------------------------

kctl() {
  kubectl --kubeconfig="${KUBECONFIG_PATH}" -n "${KUBE_NAMESPACE}" "$@"
}

# Auto-detect whether the cluster runs PerconaServerMySQL (ps) or
# PerconaXtraDBCluster (pxc). Caches result in _DETECTED_CR_TYPE.
_DETECTED_CR_TYPE=""
detect_cr_type() {
  if [[ -n "${BACKUP_CR_TYPE:-}" ]]; then
    _DETECTED_CR_TYPE="${BACKUP_CR_TYPE}"
    return 0
  fi
  if [[ -n "${_DETECTED_CR_TYPE}" ]]; then
    return 0
  fi
  local t
  for t in ps pxc; do
    if kctl get "${t}" -o name >/dev/null 2>&1; then
      _DETECTED_CR_TYPE="${t}"
      return 0
    fi
  done
  return 1
}

detect_cr_name() {
  if [[ -n "${BACKUP_CR_NAME:-}" ]]; then
    echo "${BACKUP_CR_NAME}"
    return 0
  fi
  detect_cr_type || return 1
  local name
  name="$(kctl get "${_DETECTED_CR_TYPE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)" || true
  if [[ -n "${name}" ]]; then
    echo "${name}"
    return 0
  fi
  return 1
}

show_backup_schedule() {
  local cr_name="${1:?cr name required}"
  detect_cr_type || return 1
  kctl get "${_DETECTED_CR_TYPE}" "${cr_name}" \
    -o jsonpath='{range .spec.backup.schedule[*]}  name={.name} schedule={.schedule} keep={.keep} type={.type}{"\n"}{end}' 2>/dev/null || true
}

patch_backup_schedule() {
  local cr_name cr_type storage_name
  cr_name="$(detect_cr_name)" || {
    log_phase "0_BACKUP_SCHEDULE" "ERROR: no Percona CR (ps/pxc) found in namespace ${KUBE_NAMESPACE}"
    return 1
  }
  detect_cr_type
  cr_type="${_DETECTED_CR_TYPE}"
  storage_name="${BACKUP_STORAGE_NAME:-s3-storage}"

  log_phase "0_BACKUP_SCHEDULE" "detected CR type='${cr_type}' name='${cr_name}'"

  local current_schedule
  current_schedule="$(show_backup_schedule "${cr_name}")"
  log_phase "0_BACKUP_SCHEDULE" "current schedule:"
  echo "${current_schedule}" | while IFS= read -r line; do
    [[ -n "${line}" ]] && log_phase "0_BACKUP_SCHEDULE" "${line}"
  done

  local schedule_json="["
  local comma=""

  if [[ -n "${BACKUP_FULL_SCHEDULE:-}" ]]; then
    local full_keep="${BACKUP_FULL_KEEP:-7}"
    schedule_json="${schedule_json}${comma}{\"name\":\"daily-backup\",\"schedule\":\"${BACKUP_FULL_SCHEDULE}\",\"keep\":${full_keep},\"storageName\":\"${storage_name}\",\"type\":\"full\"}"
    comma=","
    log_phase "0_BACKUP_SCHEDULE" "full: schedule='${BACKUP_FULL_SCHEDULE}' keep=${full_keep}"
  fi

  if [[ -n "${BACKUP_INCREMENTAL_SCHEDULE:-}" ]]; then
    local incr_keep="${BACKUP_INCREMENTAL_KEEP:-7}"
    schedule_json="${schedule_json}${comma}{\"name\":\"incremental-backup\",\"schedule\":\"${BACKUP_INCREMENTAL_SCHEDULE}\",\"keep\":${incr_keep},\"storageName\":\"${storage_name}\",\"type\":\"incremental\"}"
    log_phase "0_BACKUP_SCHEDULE" "incremental: schedule='${BACKUP_INCREMENTAL_SCHEDULE}' keep=${incr_keep}"
  fi

  schedule_json="${schedule_json}]"

  local patch_body="{\"spec\":{\"backup\":{\"schedule\":${schedule_json}}}}"

  if kctl patch "${cr_type}" "${cr_name}" --type=merge -p "${patch_body}"; then
    log_phase "0_BACKUP_SCHEDULE" "patch applied successfully"
  else
    log_phase "0_BACKUP_SCHEDULE" "ERROR: failed to patch backup schedule"
    return 1
  fi

  log_phase "0_BACKUP_SCHEDULE" "updated schedule:"
  local new_schedule
  new_schedule="$(show_backup_schedule "${cr_name}")"
  echo "${new_schedule}" | while IFS= read -r line; do
    [[ -n "${line}" ]] && log_phase "0_BACKUP_SCHEDULE" "${line}"
  done
}
