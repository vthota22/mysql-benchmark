#!/usr/bin/env bash
# Run sysbench TPC-C for a fixed duration while polling for backup activity.
#
# The cluster is already configured to take scheduled backups. This script:
#   1. Prepares the TPC-C dataset (or skips if SKIP_PREPARE=1)
#   2. Runs TPC-C workload for TPCC_MAX_TIME seconds
#   3. In parallel, polls list-backups every BACKUP_POLL_INTERVAL_SEC to detect new backups
#   4. After workload completes, does a final backup poll
#   5. Generates CSV and HTML report showing backup impact on performance
#
# Usage:
#   cp benchmark.conf.example benchmark.conf
#   # edit benchmark.conf (DB creds + CLUSTER_ID / DO_API_TOKEN)
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
BACKUP_LIST_DIR="${RUN_DIR}/backup_snapshots"
FULL_LOG="${RUN_DIR}/benchmark.log"
TIMING_FILE="${RUN_DIR}/run_timing.env"

mkdir -p "${BACKUP_LIST_DIR}"

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
export TPCC_IGNORE_ERRORS="${TPCC_IGNORE_ERRORS:-1290,1836,1053,2013,2006,2055,2011,3100,1205,1213,1020}"
export DO_API_TOKEN="${DO_API_TOKEN:-}"
export DO_API_URL="${DO_API_URL:-}"
export CLUSTER_ID="${CLUSTER_ID:-}"

exec > >(tee -a "${FULL_LOG}") 2>&1

on_exit() {
  local rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    log_phase "ERROR" "benchmark exited with status ${rc}"
  fi
}
trap on_exit EXIT

phase1_init_database() {
  mysql_connectivity_check || return 1

  if [[ "${SKIP_PREPARE:-0}" == "1" ]]; then
    log_phase "1_INIT" "SKIP_PREPARE=1 — ensuring database exists, checking TPC-C tables"
    ensure_database_exists

    log_phase "1_INIT" "running sysbench tpcc check (threads=${TPCC_CHECK_THREADS})"
    if ! run_tpcc check | tee -a "${RUN_LOG}"; then
      log_phase "1_INIT" "ERROR: TPC-C check failed"
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

# Snapshot backups list and save to a timestamped JSON file.
snapshot_backups() {
  local label="${1:-poll}"
  local epoch
  epoch="$(date +%s)"
  local outfile="${BACKUP_LIST_DIR}/${epoch}_${label}.json"

  if list_backups_json "${CLUSTER_ID}" > "${outfile}" 2>/dev/null; then
    local count
    count="$(python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d.get('Backups',d.get('backups',[]))))" < "${outfile}" 2>/dev/null || echo "?")"
    log_phase "BACKUP_POLL" "${label}: saved ${outfile} (${count} backups)"
  else
    log_phase "BACKUP_POLL" "${label}: FAILED to list backups"
    rm -f "${outfile}"
  fi
}

# Background polling loop: snapshot backups every BACKUP_POLL_INTERVAL_SEC.
run_backup_poller() {
  local poll_interval="${BACKUP_POLL_INTERVAL_SEC:-300}"
  local poll_count=0

  log_phase "BACKUP_POLL" "starting backup poller (interval=${poll_interval}s)"

  # Initial snapshot before workload
  snapshot_backups "initial"

  while true; do
    sleep "${poll_interval}"
    poll_count=$((poll_count + 1))
    snapshot_backups "poll_${poll_count}"
  done
}

phase2_run_with_backup_monitoring() {
  local tpcc_max_time="${TPCC_MAX_TIME:-3600}"
  export TPCC_MAX_TIME="${tpcc_max_time}"

  log_phase "2_RUN" "starting TPC-C (threads=${TPCC_THREADS} duration=${tpcc_max_time}s)"
  log_phase "2_RUN" "backup polling every ${BACKUP_POLL_INTERVAL_SEC:-300}s"

  : > "${RUN_LOG}"
  : > "${TIMING_FILE}"

  local run_start_epoch sysbench_offset_sec=0
  run_start_epoch=$(date +%s)
  TPCC_RUN_START_EPOCH="${run_start_epoch}"
  export TPCC_RUN_START_EPOCH
  {
    echo "ENGINE=${ENGINE}"
    echo "RUN_START_EPOCH=${run_start_epoch}"
    echo "CLUSTER_ID=${CLUSTER_ID}"
    echo "CLUSTER_SLUG=${CLUSTER_SLUG:-unknown}"
    echo "CLUSTER_NUM_NODES=${CLUSTER_NUM_NODES:-1}"
    echo "CLUSTER_STORAGE_SIZE_GIB=${CLUSTER_STORAGE_SIZE_GIB:-0}"
  } >> "${TIMING_FILE}"

  # Start backup poller in background
  run_backup_poller &
  local poller_pid=$!

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

  # Kill poller and do a final backup snapshot
  kill "${poller_pid}" 2>/dev/null || true
  wait "${poller_pid}" 2>/dev/null || true
  snapshot_backups "final"

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
  log_phase "3_LOG" "run dir:        ${RUN_DIR}"
  log_phase "3_LOG" "config copy:    ${RUN_DIR}/benchmark.conf"
  log_phase "3_LOG" "run log:        ${RUN_LOG}"
  log_phase "3_LOG" "backup snaps:   ${BACKUP_LIST_DIR}/"
  log_phase "3_LOG" "timing:         ${TIMING_FILE}"
  log_phase "3_LOG" "full log:       ${FULL_LOG}"
}

phase4_generate_results() {
  log_phase "4_RESULTS" "generating CSV and HTML report"

  python3 "${SCRIPT_DIR}/scripts/parse_results.py" "${RUN_DIR}"
  python3 "${SCRIPT_DIR}/scripts/generate_report.py" "${RUN_DIR}"

  log_phase "4_RESULTS" "CSV:    ${RUN_DIR}/benchmark_with_backup_status.csv"
  log_phase "4_RESULTS" "Report: ${RUN_DIR}/backup_benchmark_report.html"
  echo "${RUN_DIR}" > "${RESULTS_BASE}/LATEST.txt"
}

main() {
  unset phase1 phase2 phase3 phase4 2>/dev/null || true

  phase1_init_database
  do_api_auth_check
  phase2_run_with_backup_monitoring
  phase3_finalize_logs
  phase4_generate_results

  log_phase "DONE" "backup benchmark complete"
}

echo "=== backup-benchmarking: TPC-C with backup impact measurement ==="
echo "Config:   ${CONFIG}"
echo "Engine:   ${ENGINE}"
echo "Cluster:  ${CLUSTER_ID} (${CLUSTER_SLUG:-unknown})"
echo "Run dir:  ${RUN_DIR}"
echo "Sysbench: $("${BENCH_ROOT}/which_sysbench.sh")"
echo "Host:     ${MYSQL_HOST}:${MYSQL_PORT}/${MYSQL_DB}"
echo ""

main "$@"
