#!/usr/bin/env bash
# Run sysbench TPC-C for a fixed duration while optionally profiling backups.
#
# The cluster may have scheduled backups. This script:
#   1. Prepares the TPC-C dataset (or skips if SKIP_PREPARE=1)
#   2. Runs TPC-C workload for TPCC_MAX_TIME seconds
#   3. Optionally runs profile_backup.sh in the background to capture
#      xtrabackup timing and metrics if a backup runs during the workload
#   4. Generates CSV and HTML report
#
# Usage:
#   ../setup_benchmark.sh
#   cp benchmark.conf.example benchmark.conf
#   # edit benchmark.conf (DB creds + K8s config for backup profiling)
#   ./run_benchmark.sh
#
# Optional:
#   BENCHMARK_CONF=/path/to/benchmark.conf ./run_benchmark.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${BENCHMARK_CONF:-${SCRIPT_DIR}/benchmark.conf}"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"

# shellcheck source=backup-benchmarking/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

setup_paths
load_config "${CONFIG}"
require_config

RESULTS_BASE="${SCRIPT_DIR}/${RESULTS_DIR:-results}"
RUN_DIR="${RESULTS_BASE}/run_${TIMESTAMP}_${ENGINE}"
mkdir -p "${RUN_DIR}"
cp "${CONFIG}" "${RUN_DIR}/benchmark.conf"

RUN_LOG="${RUN_DIR}/tpcc_run.log"
TIMING_FILE="${RUN_DIR}/run_timing.env"
FULL_LOG="${RUN_DIR}/benchmark.log"

export ENGINE MYSQL_HOST MYSQL_PORT MYSQL_USER MYSQL_PASSWORD MYSQL_DB
export TPCC_TABLES="${TPCC_TABLES:-10}"
export TPCC_SCALE="${TPCC_SCALE:-10}"
export TPCC_THREADS="${TPCC_THREADS:-16}"
export TPCC_PREP_THREADS="${TPCC_PREP_THREADS:-16}"
export TPCC_CHECK_THREADS="${TPCC_CHECK_THREADS:-${TPCC_PREP_THREADS}}"
export TPCC_WARMUP_SEC="${TPCC_WARMUP_SEC:-0}"
export TPCC_REPORT_INTERVAL="${TPCC_REPORT_INTERVAL:-1}"
export TPCC_FORCE_PK="${TPCC_FORCE_PK:-1}"
export TPCC_TRX_LEVEL="${TPCC_TRX_LEVEL:-RR}"
export TPCC_PERCENTILE="${TPCC_PERCENTILE:-99}"
export TPCC_IGNORE_ERRORS="${TPCC_IGNORE_ERRORS:-1290,1836,1053,2013,2006,2055,2011,3100,1205,1213,1020}"

on_exit() {
  local rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    log_phase "ERROR" "benchmark exited with status ${rc}"
  fi
}
trap on_exit EXIT

print_startup_banner() {
  echo "=== backup-benchmarking: TPC-C with backup profiling ==="
  echo "Config:   ${CONFIG}"
  echo "Engine:   ${ENGINE}"
  echo "Run dir:  ${RUN_DIR}"
  echo "Sysbench: $("${BENCH_ROOT}/which_sysbench.sh")"
  echo "Host:     ${MYSQL_HOST}:${MYSQL_PORT}/${MYSQL_DB}"
  if backup_schedule_patch_needed; then
    echo "Schedule:  patch full='${BACKUP_FULL_SCHEDULE:-<skip>}' incr='${BACKUP_INCREMENTAL_SCHEDULE:-<skip>}'"
  else
    echo "Schedule:  no patch (schedules empty)"
  fi
  if backup_profiling_enabled; then
    echo "Profiling: namespace=${KUBE_NAMESPACE} poll=${BACKUP_PROFILE_POLL_INTERVAL:-10}s"
  else
    echo "Profiling: disabled (SKIP_BACKUP_PROFILING=1)"
  fi
  echo ""
}

preflight_checks
print_startup_banner

phase1_init_database() {
  mysql_connectivity_check || return 1

  if [[ "${SKIP_PREPARE:-0}" == "1" ]]; then
    log_phase "1_INIT" "SKIP_PREPARE=1 — ensuring database exists, checking TPC-C tables"
    ensure_database_exists

    if ! verify_tpcc_tables | tee -a "${RUN_LOG}"; then
      log_phase "1_INIT" "ERROR: TPC-C table verification failed"
      return 1
    fi

    log_phase "1_INIT" "TPC-C tables present — skipping prepare"
    return 0
  fi

  log_phase "1_INIT" "dropping and recreating database '${MYSQL_DB}'"
  mysql_admin -e "DROP DATABASE IF EXISTS \`${MYSQL_DB}\`; CREATE DATABASE \`${MYSQL_DB}\`;"

  log_phase "1_INIT" "running sysbench tpcc prepare (tables=${TPCC_TABLES} scale=${TPCC_SCALE})"
  run_tpcc prepare | tee -a "${RUN_LOG}"
}

phase2_run_with_profiling() {
  local tpcc_max_time="${TPCC_MAX_TIME:-${TPCC_TOTAL_TIME:-3600}}"
  export TPCC_MAX_TIME="${tpcc_max_time}"

  log_phase "2_RUN" "starting TPC-C (threads=${TPCC_THREADS} duration=${tpcc_max_time}s)"
  if backup_profiling_enabled; then
    log_phase "2_RUN" "backup profiling active — namespace=${KUBE_NAMESPACE}"
  else
    log_phase "2_RUN" "SKIP_BACKUP_PROFILING=1 — no backup profiling"
  fi

  : > "${RUN_LOG}"
  : > "${TIMING_FILE}"

  local run_start_epoch sysbench_offset_sec=0
  run_start_epoch=$(date +%s)
  TPCC_RUN_START_EPOCH="${run_start_epoch}"
  export TPCC_RUN_START_EPOCH
  {
    echo "ENGINE=${ENGINE}"
    echo "RUN_START_EPOCH=${run_start_epoch}"
    echo "CLUSTER_ID=${CLUSTER_ID:-unknown}"
    echo "CLUSTER_SLUG=${CLUSTER_SLUG:-unknown}"
    echo "CLUSTER_NUM_NODES=${CLUSTER_NUM_NODES:-1}"
    echo "CLUSTER_STORAGE_SIZE_GIB=${CLUSTER_STORAGE_SIZE_GIB:-0}"
  } >> "${TIMING_FILE}"

  # Start backup profiler in background if enabled
  local profiler_pid=""
  if backup_profiling_enabled; then
    local profile_dir="${RUN_DIR}/backup_profile"
    mkdir -p "${profile_dir}"

    local profiler_args=(
      --kubeconfig "${KUBECONFIG_PATH}"
      --namespace "${KUBE_NAMESPACE}"
      --timeout "${tpcc_max_time}"
      --poll-interval "${BACKUP_PROFILE_POLL_INTERVAL:-10}"
      --mysql-host "${MYSQL_HOST}"
      --mysql-port "${MYSQL_PORT}"
      --mysql-user "${MYSQL_USER}"
      --mysql-password "${MYSQL_PASSWORD}"
    )
    if [[ -n "${KUBE_POD:-}" ]]; then
      profiler_args+=(--pod "${KUBE_POD}")
    fi

    log_phase "2_RUN" "launching backup profiler -> ${profile_dir}"
    RESULTS_BASE="${profile_dir}" "${SCRIPT_DIR}/profile_backup.sh" \
      "${profiler_args[@]}" > "${RUN_DIR}/backup_profiler.log" 2>&1 &
    profiler_pid=$!
    log_phase "2_RUN" "backup profiler pid=${profiler_pid}"
  fi

  # Run TPC-C workload
  local tpcc_rc=0
  local sysbench_offset_recorded=0
  local tpcc_fifo
  tpcc_fifo="$(mktemp -u "${RUN_DIR}/.tpcc.XXXXXX")"
  mkfifo "${tpcc_fifo}"
  run_tpcc run > "${tpcc_fifo}" 2>&1 &
  local tpcc_pid=$!
  while IFS= read -r line; do
    if [[ "${sysbench_offset_recorded}" -eq 0 && "${line}" == "[ 1s ]"* ]]; then
      local first_report_epoch
      first_report_epoch=$(date +%s)
      sysbench_offset_sec=$((first_report_epoch - run_start_epoch - 1))
      TPCC_SYSBENCH_OFFSET_SEC="${sysbench_offset_sec}"
      export TPCC_SYSBENCH_OFFSET_SEC
      echo "SYSBENCH_OFFSET_SEC=${sysbench_offset_sec}" >> "${TIMING_FILE}"
      sysbench_offset_recorded=1
    fi
    prefix_tpcc_line_timestamp "${line}"
  done < "${tpcc_fifo}" | tee -a "${RUN_LOG}"
  rm -f "${tpcc_fifo}"
  if ! wait "${tpcc_pid}"; then
    tpcc_rc=$?
    log_phase "2_RUN" "sysbench exited with status ${tpcc_rc}"
  else
    log_phase "2_RUN" "sysbench completed successfully"
  fi

  # Wait for profiler to finish (it has its own timeout matching tpcc_max_time)
  if [[ -n "${profiler_pid}" ]]; then
    log_phase "2_RUN" "waiting for backup profiler to finish..."
    kill "${profiler_pid}" 2>/dev/null || true
    wait "${profiler_pid}" 2>/dev/null || true
    log_phase "2_RUN" "backup profiler finished"
  fi

  local run_end_epoch
  run_end_epoch=$(date +%s)
  local run_duration=$((run_end_epoch - run_start_epoch))
  {
    echo "RUN_END_EPOCH=${run_end_epoch}"
    echo "RUN_DURATION_SEC=${run_duration}"
  } >> "${TIMING_FILE}"

  log_phase "2_RUN" "workload complete (duration=${run_duration}s)"

  if [[ "${tpcc_rc}" -ne 0 ]]; then
    return "${tpcc_rc}"
  fi
}

phase3_finalize_logs() {
  log_phase "3_LOG" "run dir:       ${RUN_DIR}"
  log_phase "3_LOG" "config copy:   ${RUN_DIR}/benchmark.conf"
  log_phase "3_LOG" "run log:       ${RUN_LOG}"
  log_phase "3_LOG" "timing:        ${TIMING_FILE}"
  log_phase "3_LOG" "full log:      ${FULL_LOG}"
  if backup_profiling_enabled; then
    log_phase "3_LOG" "profiler log:  ${RUN_DIR}/backup_profiler.log"
    log_phase "3_LOG" "profile data:  ${RUN_DIR}/backup_profile/"
  fi
}

phase4_generate_results() {
  log_phase "4_RESULTS" "generating CSV and HTML report"

  local parse_script="${SCRIPT_DIR}/scripts/parse_results.py"
  local report_script="${SCRIPT_DIR}/scripts/generate_report.py"

  if [[ -f "${parse_script}" ]]; then
    python3 "${parse_script}" "${RUN_DIR}"
    log_phase "4_RESULTS" "CSV:    ${RUN_DIR}/benchmark_with_backup_status.csv"
  else
    log_phase "4_RESULTS" "WARNING: ${parse_script} not found — skipping CSV generation"
  fi

  if [[ -f "${report_script}" ]]; then
    python3 "${report_script}" "${RUN_DIR}"
    log_phase "4_RESULTS" "Report: ${RUN_DIR}/backup_benchmark_report.html"
  else
    log_phase "4_RESULTS" "WARNING: ${report_script} not found — skipping report generation"
  fi

  echo "${RUN_DIR}" > "${RESULTS_BASE}/LATEST.txt"
}

main() {
  unset phase1 phase2 phase3 phase4 2>/dev/null || true

  exec > >(tee -a "${FULL_LOG}") 2>&1

  phase1_init_database

  if backup_schedule_patch_needed; then
    patch_backup_schedule
  else
    log_phase "0_BACKUP_SCHEDULE" "no schedule config — skipping patch"
  fi

  phase2_run_with_profiling
  phase3_finalize_logs
  phase4_generate_results

  log_phase "DONE" "benchmark complete"
}

main "$@"
