#!/usr/bin/env bash
# Compare MySQL Standard vs Advanced Edition using sysbench-tpcc
#
# Usage:
#   ./setup_benchmark.sh                    # one-time setup
#   cp benchmark.conf.example benchmark.conf
#   # edit benchmark.conf
#   ./run_standard_vs_advanced.sh
#
# Optional:
#   BENCHMARK_CONF=/path/to/benchmark.conf ./run_standard_vs_advanced.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${BENCHMARK_CONF:-${SCRIPT_DIR}/benchmark.conf}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULTS_DIR="${SCRIPT_DIR}/results/comparison_${TIMESTAMP}"
CSV="${RESULTS_DIR}/comparison.csv"
SUMMARY="${RESULTS_DIR}/comparison_summary.txt"
FULL_LOG="${RESULTS_DIR}/full_run.log"

export PATH="${SCRIPT_DIR}/sysbench-1.1/bin:${PATH}"

# shellcheck source=lib/benchmark_common.sh
source "${SCRIPT_DIR}/lib/benchmark_common.sh"
load_benchmark_config "${CONFIG}"

mkdir -p "${RESULTS_DIR}"

exec > >(tee -a "${FULL_LOG}") 2>&1

echo "=== MySQL Standard vs Advanced — TPC-C Benchmark ==="
echo "Started:  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "Results:  ${RESULTS_DIR}"
echo "Config:   ${CONFIG}"
echo "Sysbench: $("${SCRIPT_DIR}/which_sysbench.sh")"
echo ""
echo "Dataset:  tables=${TPCC_TABLES:-10} scale=${TPCC_SCALE:-100} force_pk=${TPCC_FORCE_PK:-1}"
echo "Matrix:   threads=[${THREADS}] durations=[${DURATIONS}] warmup=${WARMUP_SEC:-60}s"
echo ""

if [[ "${MYSQL_SETTINGS_CHECK:-1}" == "1" ]]; then
  run_mysql_settings_check "${RESULTS_DIR}"
fi

echo "edition,threads,duration_sec,tps,qps,lat_avg,lat_p95,lat_p99,tx_total,errors,reconnects" > "${CSV}"

run_edition() {
  local edition="${1:?edition required}"
  local edition_dir="${RESULTS_DIR}/${edition}"
  mkdir -p "${edition_dir}"

  echo ""
  echo "========================================"
  echo " Edition: ${edition}"
  echo "========================================"
  echo ""

  set_mysql_env_for_edition "${edition}"
  export TPCC_TABLES="${TPCC_TABLES:-10}"
  export TPCC_SCALE="${TPCC_SCALE:-100}"
  export TPCC_FORCE_PK="${TPCC_FORCE_PK:-1}"
  export TPCC_TRX_LEVEL="${TPCC_TRX_LEVEL:-RR}"
  export TPCC_WARMUP="${WARMUP_SEC:-60}"
  export TPCC_REPORT_INTERVAL="${TPCC_REPORT_INTERVAL:-10}"

  echo "Host: ${MYSQL_HOST}:${MYSQL_PORT}  DB: ${MYSQL_DB}"
  echo "Sysbench SSL mode: ${SYSBENCH_SSL_MODE}"
  echo ""

  mysql_connectivity_check "${edition}" "${edition_dir}/mysql_info.txt" \
    || { echo "Aborting ${edition}: cannot connect"; return 1; }
  echo ""

  if [[ "${SKIP_PREPARE:-0}" != "1" ]]; then
    echo "--- Cleanup ---"
    run_tpcc_command cleanup 2>&1 | tee "${edition_dir}/cleanup_before.log" || true
    echo ""

    echo "--- Prepare (threads=${PREP_THREADS:-16}) ---"
    export TPCC_THREADS="${PREP_THREADS:-16}"
    PREP_START=$(date +%s)
    run_tpcc_command prepare 2>&1 | tee "${edition_dir}/prepare.log"
    PREP_END=$(date +%s)
    echo "Prepare completed in $((PREP_END - PREP_START))s"
    echo ""
  else
    echo "--- Skipping prepare (SKIP_PREPARE=1) ---"
    echo ""
  fi

  for threads in ${THREADS}; do
    for duration in ${DURATIONS}; do
      local run_file="${edition_dir}/run_${threads}t_${duration}s.txt"
      echo "--- Run: ${edition} | threads=${threads} | duration=${duration}s ---"
      export TPCC_THREADS="${threads}"
      export TPCC_TIME="${duration}"

      RUN_START=$(date +%s)
      run_tpcc_command run 2>&1 | tee "${run_file}"
      RUN_END=$(date +%s)
      echo "Run completed in $((RUN_END - RUN_START))s"

      append_result_row "${CSV}" "${edition}" "${threads}" "${duration}" "${run_file}"

      parse_sysbench_metrics "${run_file}"
      echo "  TPS=${METRIC_TPS}  QPS=${METRIC_QPS}  avg=${METRIC_LAT_AVG}  p95=${METRIC_LAT_P95}  errors=${METRIC_ERRORS}"
      echo ""
    done
  done

  if [[ "${CLEANUP_AFTER:-0}" == "1" ]]; then
    echo "--- Post-run cleanup ---"
    export TPCC_THREADS="${PREP_THREADS:-16}"
    run_tpcc_command cleanup 2>&1 | tee "${edition_dir}/cleanup_after.log" || true
  fi

  echo "${edition}: all runs complete"
}

FAILED=0
for edition in ${EDITIONS:-standard advanced}; do
  if ! run_edition "${edition}"; then
    FAILED=$((FAILED + 1))
  fi
done

echo ""
echo "--- Generating comparison report ---"
write_comparison_summary "${CSV}" "${SUMMARY}"

echo "${RESULTS_DIR}" > "${SCRIPT_DIR}/results/LATEST_COMPARISON.txt"

echo ""
echo "=== Benchmark complete ==="
echo "Summary: ${SUMMARY}"
echo "CSV:     ${CSV}"
echo "Full log: ${FULL_LOG}"

if [[ "${FAILED}" -gt 0 ]]; then
  echo ""
  echo "WARNING: ${FAILED} edition(s) failed — see ${FULL_LOG}"
  exit 1
fi
