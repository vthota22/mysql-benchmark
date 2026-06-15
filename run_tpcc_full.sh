#!/usr/bin/env bash
# Full TPC-C pipeline: cleanup -> prepare -> run -> summary
set -euo pipefail

: "${MYSQL_HOST:?Set MYSQL_HOST}"
: "${MYSQL_PORT:?Set MYSQL_PORT}"
: "${MYSQL_USER:?Set MYSQL_USER}"
: "${MYSQL_PASSWORD:?Set MYSQL_PASSWORD}"
: "${MYSQL_DB:?Set MYSQL_DB}"

export PATH="${HOME}/mysql-benchmark/sysbench-1.1/bin:${PATH}"

SCRIPT_DIR="$(dirname "$0")"
RESULTS_DIR="${SCRIPT_DIR}/results/tpcc_run_$(date +%Y%m%d_%H%M%S)"
mkdir -p "${RESULTS_DIR}"

TPCC_TABLES="${TPCC_TABLES:-1}"
TPCC_SCALE="${TPCC_SCALE:-10}"
TPCC_PREP_THREADS="${TPCC_PREP_THREADS:-4}"
TPCC_RUN_THREADS="${TPCC_RUN_THREADS:-8}"
TPCC_TIME="${TPCC_TIME:-120}"
TPCC_WARMUP="${TPCC_WARMUP:-30}"
TPCC_FORCE_PK="${TPCC_FORCE_PK:-1}"

export TPCC_TABLES TPCC_SCALE TPCC_THREADS="${TPCC_PREP_THREADS}" TPCC_FORCE_PK
export TPCC_TIME TPCC_WARMUP

LOG="${RESULTS_DIR}/full_run.log"
SUMMARY="${RESULTS_DIR}/summary.txt"

exec > >(tee -a "${LOG}") 2>&1

echo "=== TPC-C Full Benchmark ==="
echo "Results: ${RESULTS_DIR}"
echo "Started: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ""

echo "--- MySQL connectivity ---"
mysql -h "${MYSQL_HOST}" -P "${MYSQL_PORT}" -u "${MYSQL_USER}" -p"${MYSQL_PASSWORD}" \
  --ssl-mode=REQUIRED "${MYSQL_DB}" \
  -e "SELECT VERSION() AS version, @@hostname AS hostname, @@sql_require_primary_key AS require_pk;" \
  | tee "${RESULTS_DIR}/mysql_info.txt"
echo ""

cd "${SCRIPT_DIR}"

echo "--- Cleanup ---"
./run_tpcc.sh cleanup || true
echo ""

echo "--- Prepare (tables=${TPCC_TABLES}, scale=${TPCC_SCALE}, threads=${TPCC_PREP_THREADS}, force_pk=${TPCC_FORCE_PK}) ---"
PREP_START=$(date +%s)
./run_tpcc.sh prepare
PREP_END=$(date +%s)
echo "Prepare duration: $((PREP_END - PREP_START))s"
echo ""

echo "--- Run (threads=${TPCC_RUN_THREADS}, warmup=${TPCC_WARMUP}s, time=${TPCC_TIME}s) ---"
export TPCC_THREADS="${TPCC_RUN_THREADS}"
RUN_START=$(date +%s)
./run_tpcc.sh run | tee "${RESULTS_DIR}/run_output.txt"
RUN_END=$(date +%s)
echo "Run duration: $((RUN_END - RUN_START))s"
echo ""

echo "--- Parsing results ---"
{
  echo "=== TPC-C Benchmark Summary ==="
  echo "Results dir: ${RESULTS_DIR}"
  echo "Completed: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo ""
  cat "${RESULTS_DIR}/mysql_info.txt" 2>/dev/null || true
  echo ""
  echo "Config: tables=${TPCC_TABLES} scale=${TPCC_SCALE} force_pk=${TPCC_FORCE_PK}"
  echo "Prepare: ${TPCC_PREP_THREADS} threads, $((PREP_END - PREP_START))s"
  echo "Run: ${TPCC_RUN_THREADS} threads, warmup=${TPCC_WARMUP}s, time=${TPCC_TIME}s, $((RUN_END - RUN_START))s"
  echo ""
  grep -E 'transactions:|queries:|avg:|95th percentile:|99th percentile:|errors:|reconnects:' \
    "${RESULTS_DIR}/run_output.txt" 2>/dev/null | tail -10 || echo "(parse run_output.txt manually)"
} | tee "${SUMMARY}"

echo "${RESULTS_DIR}" > "${SCRIPT_DIR}/results/LATEST_TPCC_RUN.txt"
echo ""
echo "=== Done ==="
echo "Summary: ${SUMMARY}"
echo "Full log: ${LOG}"
