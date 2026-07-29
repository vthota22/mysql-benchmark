#!/usr/bin/env bash
# Run Percona sysbench-tpcc against managed MySQL
# Usage:
#   export MYSQL_HOST, MYSQL_PORT, MYSQL_USER, MYSQL_PASSWORD, MYSQL_DB
#   ./run_tpcc.sh prepare
#   ./run_tpcc.sh run
#   ./run_tpcc.sh check
#   ./run_tpcc.sh cleanup
#
# Optional env:
#   TPCC_TABLES=1 TPCC_SCALE=10 TPCC_THREADS=4 TPCC_TIME=300
#   TPCC_TIME=0           # unlimited duration
#   TPCC_RATE=250         # sysbench --rate (events/sec); unset = unlimited
#   TPCC_MYSQL_IGNORE_ERRORS=1053,2013,...  # keep load alive across transient errors

set -euo pipefail

: "${MYSQL_HOST:?Set MYSQL_HOST}"
: "${MYSQL_PORT:?Set MYSQL_PORT}"
: "${MYSQL_USER:?Set MYSQL_USER}"
: "${MYSQL_PASSWORD:?Set MYSQL_PASSWORD}"
: "${MYSQL_DB:?Set MYSQL_DB}"

COMMAND="${1:?Usage: $0 prepare|run|check|cleanup}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TPCC_DIR="${TPCC_DIR:-${SCRIPT_DIR}/TPCC/sysbench-tpcc}"
# shellcheck source=bootstrap/sysbench_mysql_opts.sh
source "${SCRIPT_DIR}/bootstrap/sysbench_mysql_opts.sh"

TPCC_TABLES="${TPCC_TABLES:-1}"
TPCC_SCALE="${TPCC_SCALE:-10}"
TPCC_THREADS="${TPCC_THREADS:-4}"
TPCC_TIME="${TPCC_TIME:-300}"
TPCC_WARMUP="${TPCC_WARMUP:-30}"
TPCC_REPORT_INTERVAL="${TPCC_REPORT_INTERVAL:-10}"
TPCC_TRX_LEVEL="${TPCC_TRX_LEVEL:-RR}"
# Managed MySQL (DO Advanced) often has sql_require_primary_key=ON; history table needs a PK
TPCC_FORCE_PK="${TPCC_FORCE_PK:-1}"
# Same default as FAILOVER_MYSQL_IGNORE_ERRORS in lib/failover_common.sh
TPCC_MYSQL_IGNORE_ERRORS="${TPCC_MYSQL_IGNORE_ERRORS:-1053,2013,1290,3100,1205,1213,2006,2014,2003,2055,1047,1158,1159,1161,3011,4094}"
# Optional: average events/sec across all threads (sysbench --rate); empty = unlimited
TPCC_RATE="${TPCC_RATE:-}"

if [[ ! -f "${TPCC_DIR}/tpcc.lua" ]]; then
  echo "Missing ${TPCC_DIR}/tpcc.lua"
  echo "Clone: git clone https://github.com/Percona-Lab/sysbench-tpcc.git ${TPCC_DIR}"
  exit 1
fi

# sysbench-tpcc uses require("tpcc_common") — must run from repo dir (Lua cwd)
# sysbench 1.0.x SSL — needs client-key.pem + client-cert.pem in cwd
link_tpcc_ssl() {
  : # SSL setup handled by run_sysbench_tpcc / setup_tpcc_ssl.sh
}

run_tpcc() {
  run_sysbench_tpcc "${TPCC_DIR}" "$@"
}

TPCC_OPTS=(
  "${MYSQL_BASE_OPTS[@]}"
  "${MYSQL_SSL_OPTS[@]}"
  --tables="${TPCC_TABLES}"
  --scale="${TPCC_SCALE}"
  --threads="${TPCC_THREADS}"
  --trx_level="${TPCC_TRX_LEVEL}"
  --force_pk="${TPCC_FORCE_PK}"
)

echo "TPC-C dir:  ${TPCC_DIR}"
echo "Command:    ${COMMAND}"
echo "Tables:     ${TPCC_TABLES}  Scale (warehouses): ${TPCC_SCALE}  Threads: ${TPCC_THREADS}"
echo "sysbench:   ${SYSBENCH_BIN} (v${SYSBENCH_VERSION}, SSL: ${SYSBENCH_SSL_MODE})"
if [[ -n "${TPCC_RATE}" ]]; then
  echo "Rate:       ${TPCC_RATE} events/s"
fi
if [[ "${COMMAND}" == "run" ]]; then
  echo "Ignore err: ${TPCC_MYSQL_IGNORE_ERRORS}"
  echo "Time:       ${TPCC_TIME} (0=unlimited)"
fi
echo ""

case "${COMMAND}" in
  prepare)
    run_tpcc "${TPCC_OPTS[@]}" prepare
    ;;
  run)
    RUN_OPTS=(
      "${TPCC_OPTS[@]}"
      --time="${TPCC_TIME}"
      --warmup-time="${TPCC_WARMUP}"
      --report-interval="${TPCC_REPORT_INTERVAL}"
      --mysql-ignore-errors="${TPCC_MYSQL_IGNORE_ERRORS}"
    )
    if [[ -n "${TPCC_RATE}" ]]; then
      RUN_OPTS+=(--rate="${TPCC_RATE}")
    fi
    run_tpcc "${RUN_OPTS[@]}" run
    ;;
  check)
    run_tpcc "${TPCC_OPTS[@]}" check
    ;;
  cleanup)
    run_tpcc "${TPCC_OPTS[@]}" cleanup
    ;;
  *)
    echo "Unknown command: ${COMMAND} (use prepare|run|check|cleanup)"
    exit 1
    ;;
esac
