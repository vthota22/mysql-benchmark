#!/usr/bin/env bash
# OLTP baseline benchmark for managed MySQL (Advanced Edition)
# Usage: export MYSQL_HOST, MYSQL_PORT, MYSQL_USER, MYSQL_PASSWORD, MYSQL_DB
#        ./run_oltp_baseline.sh

set -euo pipefail

: "${MYSQL_HOST:?Set MYSQL_HOST}"
: "${MYSQL_PORT:?Set MYSQL_PORT}"
: "${MYSQL_USER:?Set MYSQL_USER}"
: "${MYSQL_PASSWORD:?Set MYSQL_PASSWORD}"
: "${MYSQL_DB:?Set MYSQL_DB}"

SCRIPT_DIR="$(dirname "$0")"
source "${SCRIPT_DIR}/sysbench_mysql_opts.sh"

TABLES="${TABLES:-10}"
TABLE_SIZE="${TABLE_SIZE:-100000}"
WARMUP_SEC="${WARMUP_SEC:-30}"
RUN_SEC="${RUN_SEC:-120}"
THREADS="${THREADS:-1 4 8 16 32}"
RESULTS_DIR="${RESULTS_DIR:-${SCRIPT_DIR}/results}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RUN_DIR="${RESULTS_DIR}/run_${TIMESTAMP}"

MYSQL_OPTS=(
  "${MYSQL_BASE_OPTS[@]}"
  "${MYSQL_SSL_OPTS[@]}"
  --tables="${TABLES}"
  --table-size="${TABLE_SIZE}"
)

mkdir -p "${RUN_DIR}"

echo "=== MySQL OLTP Baseline ===" | tee "${RUN_DIR}/summary.txt"
echo "Sysbench: ${SYSBENCH_BIN} v${SYSBENCH_VERSION} (SSL: ${SYSBENCH_SSL_MODE})" | tee -a "${RUN_DIR}/summary.txt"
echo "Host:     ${MYSQL_HOST}:${MYSQL_PORT}" | tee -a "${RUN_DIR}/summary.txt"
echo "Database: ${MYSQL_DB}" | tee -a "${RUN_DIR}/summary.txt"
echo "Tables:   ${TABLES} x ${TABLE_SIZE} rows" | tee -a "${RUN_DIR}/summary.txt"
echo "Warmup:   ${WARMUP_SEC}s | Run: ${RUN_SEC}s per thread count" | tee -a "${RUN_DIR}/summary.txt"
echo "Run dir:  ${RUN_DIR}" | tee -a "${RUN_DIR}/summary.txt"
echo "" | tee -a "${RUN_DIR}/summary.txt"

echo "--- Connectivity check ---" | tee -a "${RUN_DIR}/summary.txt"
if mysql -h "${MYSQL_HOST}" -P "${MYSQL_PORT}" -u "${MYSQL_USER}" -p"${MYSQL_PASSWORD}" \
    --ssl-mode=REQUIRED -e "SELECT VERSION() AS version, @@hostname AS hostname;" "${MYSQL_DB}" \
    2>/dev/null | tee "${RUN_DIR}/mysql_info.txt"; then
  echo "MySQL connection OK" | tee -a "${RUN_DIR}/summary.txt"
else
  echo "WARNING: mysql CLI check failed" | tee -a "${RUN_DIR}/summary.txt"
fi
echo "" | tee -a "${RUN_DIR}/summary.txt"

echo "--- Preparing dataset ---" | tee -a "${RUN_DIR}/summary.txt"
run_sysbench "${MYSQL_OPTS[@]}" oltp_read_write prepare 2>&1 | tee "${RUN_DIR}/prepare.log"
echo "" | tee -a "${RUN_DIR}/summary.txt"

printf "%-8s %12s %12s %12s %12s %12s\n" \
  "Threads" "TPS" "QPS" "Lat_avg" "Lat_p95" "Lat_p99" \
  | tee -a "${RUN_DIR}/summary.txt"

for t in ${THREADS}; do
  echo "--- Running: ${t} threads ---" | tee -a "${RUN_DIR}/summary.txt"
  OUT="${RUN_DIR}/run_${t}threads.txt"

  run_sysbench "${MYSQL_OPTS[@]}" \
    --threads="${t}" \
    --time="${RUN_SEC}" \
    --warmup-time="${WARMUP_SEC}" \
    --report-interval=10 \
    oltp_read_write run 2>&1 | tee "${OUT}"

  TPS=$(grep -E 'transactions:' "${OUT}" | tail -1 | awk '{print $3}' | tr -d '()' || echo "N/A")
  QPS=$(grep -E 'queries:' "${OUT}" | tail -1 | awk '{print $3}' | tr -d '()' || echo "N/A")
  LAT_AVG=$(grep -E 'avg:' "${OUT}" | tail -1 | awk '{print $2}' || echo "N/A")
  LAT_P95=$(grep '95th percentile:' "${OUT}" | awk '{print $3}' || echo "N/A")
  LAT_P99=$(grep '99th percentile:' "${OUT}" | awk '{print $3}' || echo "N/A")

  printf "%-8s %12s %12s %12s %12s %12s\n" \
    "${t}" "${TPS}" "${QPS}" "${LAT_AVG}" "${LAT_P95}" "${LAT_P99}" \
    | tee -a "${RUN_DIR}/summary.txt"
done

echo "" | tee -a "${RUN_DIR}/summary.txt"
if [[ "${CLEANUP:-0}" == "1" ]]; then
  run_sysbench "${MYSQL_OPTS[@]}" oltp_read_write cleanup 2>&1 | tee "${RUN_DIR}/cleanup.log"
  echo "Cleanup done." | tee -a "${RUN_DIR}/summary.txt"
else
  echo "Skipped cleanup — set CLEANUP=1 to drop sbtest tables" | tee -a "${RUN_DIR}/summary.txt"
fi

echo "" | tee -a "${RUN_DIR}/summary.txt"
echo "=== Benchmark complete ===" | tee -a "${RUN_DIR}/summary.txt"
echo "Results: ${RUN_DIR}/summary.txt"
