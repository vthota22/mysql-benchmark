#!/usr/bin/env bash
# Run sysbench TPC-C for a fixed duration while triggering a scaling event mid-test.
#
# Usage:
#   ../setup_benchmark.sh
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

# shellcheck source=scaling-benchmarking/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

setup_paths
load_config "${CONFIG}"
require_config

RESULTS_BASE="${SCRIPT_DIR}/${RESULTS_DIR:-results}"
RUN_DIR="${RESULTS_BASE}/run_${TIMESTAMP}_${ENGINE}"
mkdir -p "${RUN_DIR}"
cp "${CONFIG}" "${RUN_DIR}/benchmark.conf"

RUN_LOG="${RUN_DIR}/tpcc_run.log"
SCALE_TIMING_FILE="${RUN_DIR}/scale_timing.env"
SCALE_LOG="${RUN_DIR}/scale.log"
TIMESERIES_CSV="${RUN_DIR}/metrics_timeseries.csv"
SCALE_EVENTS_CSV="${RUN_DIR}/scale_events.csv"
FULL_LOG="${RUN_DIR}/benchmark.log"

export ENGINE MYSQL_HOST MYSQL_PORT MYSQL_USER MYSQL_PASSWORD MYSQL_DB
export TPCC_TABLES="${TPCC_TABLES:-10}"
export TPCC_SCALE="${TPCC_SCALE:-10}"
export TPCC_THREADS="${TPCC_THREADS:-16}"
export TPCC_PREP_THREADS="${TPCC_PREP_THREADS:-${TPCC_THREADS}}"
export TPCC_WARMUP_SEC="${TPCC_WARMUP_SEC:-0}"
export TPCC_REPORT_INTERVAL="${TPCC_REPORT_INTERVAL:-1}"
export TPCC_FORCE_PK="${TPCC_FORCE_PK:-1}"
export TPCC_TRX_LEVEL="${TPCC_TRX_LEVEL:-RR}"
export TPCC_IGNORE_ERRORS="${TPCC_IGNORE_ERRORS:-1290,1836,1053,2013,2006,2055,2011,3100,1205,1213,1020}"
export DO_API_TOKEN="${DO_API_TOKEN:-}"
export DO_API_URL="${DO_API_URL:-}"
export CLUSTER_ID="${CLUSTER_ID:-}"
export SCALE_TARGET_SIZE="${SCALE_TARGET_SIZE:-}"
export SCALE_NUM_NODES="${SCALE_NUM_NODES:-}"
export SCALE_STORAGE_SIZE_MIB="${SCALE_STORAGE_SIZE_MIB:-}"

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

    if tpcc_tables_ready; then
      log_phase "1_INIT" "TPC-C tables present — skipping prepare"
      return 0
    fi

    log_phase "1_INIT" "ERROR: SKIP_PREPARE=1 but TPC-C tables are missing or invalid"
    log_phase "1_INIT" "Run once with SKIP_PREPARE=0 to load data, or run: sysbench tpcc prepare"
    return 1
  fi

  log_phase "1_INIT" "dropping and recreating database '${MYSQL_DB}'"
  mysql_admin -e "DROP DATABASE IF EXISTS \`${MYSQL_DB}\`; CREATE DATABASE \`${MYSQL_DB}\`;"

  log_phase "1_INIT" "running sysbench tpcc prepare (tables=${TPCC_TABLES} scale=${TPCC_SCALE})"
  run_tpcc prepare | tee -a "${RUN_LOG}"
}

run_scale_workflow() {
  local run_start_epoch="${1:?run start epoch required}"

  sleep "${SCALE_TRIGGER_DELAY}"

  local scale_start_epoch scale_start_elapsed
  scale_start_epoch=$(date +%s)
  scale_start_elapsed=$((scale_start_epoch - run_start_epoch))
  {
    echo "SCALE_START_EPOCH=${scale_start_epoch}"
    echo "SCALE_START_ELAPSED=${scale_start_elapsed}"
  } >> "${SCALE_TIMING_FILE}"

  log_phase "SCALE_START" \
    "elapsed=${scale_start_elapsed}s command=$(scale_resize_command_description)" \
    | tee -a "${SCALE_LOG}"

  local trigger_rc=0 poll_rc=0 poll_duration=0
  local target_num_nodes="" target_storage_mib=""
  echo "SCALE_TARGET_SIZE=${SCALE_TARGET_SIZE}" >> "${SCALE_TIMING_FILE}"
  if scale_num_nodes_requested; then
    target_num_nodes="${SCALE_NUM_NODES}"
    echo "SCALE_TARGET_NUM_NODES=${target_num_nodes}" >> "${SCALE_TIMING_FILE}"
  fi
  if scale_storage_size_requested; then
    target_storage_mib="${SCALE_STORAGE_SIZE_MIB}"
    echo "SCALE_TARGET_STORAGE_SIZE_MIB=${target_storage_mib}" >> "${SCALE_TIMING_FILE}"
  fi

  if run_scale_resize >> "${SCALE_LOG}" 2>&1; then
    log_phase "SCALE_TRIGGER" "OK — resize request accepted" | tee -a "${SCALE_LOG}"
  else
    trigger_rc=$?
    log_phase "SCALE_TRIGGER" "FAILED rc=${trigger_rc} — see ${SCALE_LOG}" | tee -a "${SCALE_LOG}"
  fi
  echo "SCALE_TRIGGER_RC=${trigger_rc}" >> "${SCALE_TIMING_FILE}"

  if [[ "${trigger_rc}" -ne 0 ]]; then
    poll_rc="${trigger_rc}"
    log_phase "SCALE_POLL" "skipped — resize request failed" | tee -a "${SCALE_LOG}"
  elif [[ -n "${CLUSTER_ID:-}" && -n "${SCALE_TARGET_SIZE:-}" ]]; then
    local poll_msg="cluster=${CLUSTER_ID} target_size=${SCALE_TARGET_SIZE}"
    if [[ -n "${target_num_nodes}" ]]; then
      poll_msg="${poll_msg} target_num_nodes=${target_num_nodes}"
    fi
    if [[ -n "${target_storage_mib}" ]]; then
      poll_msg="${poll_msg} target_storage_mib=${target_storage_mib}"
    fi
    log_phase "SCALE_POLL" "${poll_msg}" | tee -a "${SCALE_LOG}"

    if poll_duration="$(wait_for_cluster_resize \
        "${CLUSTER_ID}" \
        "${SCALE_TARGET_SIZE}" \
        "${SCALE_POLL_INTERVAL_SEC:-10}" \
        "${SCALE_POLL_TIMEOUT_SEC:-1800}" \
        "${SCALE_LOG}" \
        "${target_num_nodes}" \
        "${target_storage_mib}")"; then
      poll_rc=0
    else
      poll_rc=$?
    fi
  else
    log_phase "SCALE_POLL" \
      "skipped (set CLUSTER_ID + SCALE_TARGET_SIZE to poll until resize completes)" \
      | tee -a "${SCALE_LOG}"
    poll_rc=0
  fi

  local scale_complete_epoch scale_complete_elapsed scale_duration
  scale_complete_epoch=$(date +%s)
  scale_complete_elapsed=$((scale_complete_epoch - run_start_epoch))
  scale_duration=$((scale_complete_epoch - scale_start_epoch))
  {
    echo "SCALE_COMPLETE_EPOCH=${scale_complete_epoch}"
    echo "SCALE_COMPLETE_ELAPSED=${scale_complete_elapsed}"
    echo "SCALE_DURATION_SEC=${scale_duration}"
    echo "SCALE_POLL_DURATION_SEC=${poll_duration}"
    echo "SCALE_POLL_RC=${poll_rc}"
    echo "SCALE_SUCCESS=$([[ "${trigger_rc}" -eq 0 && "${poll_rc}" -eq 0 ]] && echo 1 || echo 0)"
  } >> "${SCALE_TIMING_FILE}"

  log_phase "SCALE_COMPLETE" \
    "elapsed=${scale_complete_elapsed}s duration=${scale_duration}s trigger_rc=${trigger_rc} poll_rc=${poll_rc}" \
    | tee -a "${SCALE_LOG}"
}

phase2_run_with_scaling() {
  local tpcc_max_time="${TPCC_MAX_TIME:-${TPCC_TOTAL_TIME:-3600}}"
  export TPCC_MAX_TIME="${tpcc_max_time}"

  log_phase "2_RUN" "starting TPC-C (threads=${TPCC_THREADS} duration=${tpcc_max_time}s)"
  log_phase "2_RUN" "scale trigger at +${SCALE_TRIGGER_DELAY}s — timing in ${SCALE_TIMING_FILE}"

  : > "${RUN_LOG}"
  : > "${SCALE_TIMING_FILE}"
  : > "${SCALE_LOG}"

  local run_start_epoch
  run_start_epoch=$(date +%s)
  {
    echo "ENGINE=${ENGINE}"
    echo "RUN_START_EPOCH=${run_start_epoch}"
  } >> "${SCALE_TIMING_FILE}"

  run_scale_workflow "${run_start_epoch}" &
  local scale_pid=$!

  local tpcc_rc=0
  local sysbench_offset_recorded=0
  if ! run_tpcc run 2>&1 | while IFS= read -r line; do
    if [[ "${sysbench_offset_recorded}" -eq 0 && "${line}" == "[ 1s ]"* ]]; then
      local first_report_epoch
      first_report_epoch=$(date +%s)
      echo "SYSBENCH_OFFSET_SEC=$((first_report_epoch - run_start_epoch - 1))" \
        >> "${SCALE_TIMING_FILE}"
      sysbench_offset_recorded=1
    fi
    printf '%s\n' "${line}"
  done | tee -a "${RUN_LOG}"; then
    tpcc_rc=$?
    log_phase "2_RUN" "sysbench exited with status ${tpcc_rc}"
  else
    log_phase "2_RUN" "sysbench completed successfully"
  fi

  wait "${scale_pid}" || true

  if [[ "${tpcc_rc}" -ne 0 ]]; then
    return "${tpcc_rc}"
  fi
}

phase3_finalize_logs() {
  log_phase "3_LOG" "run dir:       ${RUN_DIR}"
  log_phase "3_LOG" "config copy:   ${RUN_DIR}/benchmark.conf"
  log_phase "3_LOG" "run log:       ${RUN_LOG}"
  log_phase "3_LOG" "scale timing:  ${SCALE_TIMING_FILE}"
  log_phase "3_LOG" "scale log:     ${SCALE_LOG}"
  log_phase "3_LOG" "full log:      ${FULL_LOG}"
}

phase4_parse_metrics() {
  local run_start_epoch=0
  if [[ -f "${SCALE_TIMING_FILE}" ]]; then
    # shellcheck source=/dev/null
    source "${SCALE_TIMING_FILE}"
    run_start_epoch="${RUN_START_EPOCH:-0}"
  fi

  log_phase "4_PARSE" "building per-timestamp metrics CSV"
  python3 "${SCRIPT_DIR}/scripts/parse_timeseries.py" \
    --run-log "${RUN_LOG}" \
    --scale-timing-file "${SCALE_TIMING_FILE}" \
    --timeseries-csv "${TIMESERIES_CSV}" \
    --scale-events-csv "${SCALE_EVENTS_CSV}" \
    --run-start-epoch "${run_start_epoch}"

  log_phase "4_PARSE" "timeseries:   ${TIMESERIES_CSV}"
  log_phase "4_PARSE" "scale events: ${SCALE_EVENTS_CSV}"
  echo "${RUN_DIR}" > "${RESULTS_BASE}/LATEST.txt"
}

main() {
  # Guard against env vars like phase2= breaking phaseN_* function names.
  unset phase1 phase2 phase3 phase4 2>/dev/null || true

  phase1_init_database
  do_api_auth_check
  phase2_run_with_scaling
  phase3_finalize_logs
  phase4_parse_metrics

  log_phase "DONE" "benchmark complete"
}

echo "=== scaling-benchmarking: TPC-C under scale ==="
echo "Config:   ${CONFIG}"
echo "Engine:   ${ENGINE}"
echo "Run dir:  ${RUN_DIR}"
echo "Sysbench: $("${BENCH_ROOT}/which_sysbench.sh")"
echo "Host:     ${MYSQL_HOST}:${MYSQL_PORT}/${MYSQL_DB}"
echo ""

main "$@"
