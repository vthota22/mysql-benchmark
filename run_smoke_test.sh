#!/usr/bin/env bash
# Quick sysbench smoke test — prepare + 8-thread run
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
THREADS="${THREADS:-8}"

MYSQL_OPTS=(
  "${MYSQL_BASE_OPTS[@]}"
  "${MYSQL_SSL_OPTS[@]}"
  --tables="${TABLES}"
  --table-size="${TABLE_SIZE}"
)

echo "Using: ${SYSBENCH_BIN} (v${SYSBENCH_VERSION}, SSL mode: ${SYSBENCH_SSL_MODE})"
echo ""

echo "=== Step 1: prepare ==="
run_sysbench "${MYSQL_OPTS[@]}" oltp_read_write prepare

echo ""
echo "=== Step 2: run (${THREADS} threads, 30s warmup + 120s) ==="
run_sysbench "${MYSQL_OPTS[@]}" \
  --threads="${THREADS}" \
  --warmup-time=30 \
  --time=120 \
  --report-interval=10 \
  oltp_read_write run

echo ""
echo "Done. Cleanup: run_sysbench ${MYSQL_OPTS[*]} oltp_read_write cleanup"
