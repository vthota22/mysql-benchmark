#!/usr/bin/env bash
# Quick TPC-C try-run: fire a workload against the cluster and see how it performs.
# No scaling, no database init — just connect, run, and print results.
#
# Usage:
#   ./try_run.sh <threads> <duration_seconds>
#   ./try_run.sh 16 120          # 16 threads for 2 minutes
#   ./try_run.sh 64 300          # 64 threads for 5 minutes
#
# Prerequisites:
#   ../setup_benchmark.sh        # one-time sysbench install
#   cp benchmark.conf.example benchmark.conf   # edit DB creds
#
# Optional env overrides:
#   BENCHMARK_CONF=/path/to/benchmark.conf ./try_run.sh 16 120
#   TPCC_WARMUP_SEC=30 ./try_run.sh 16 120
set -euo pipefail

usage() {
  echo "Usage: $0 <threads> <duration_seconds>"
  echo ""
  echo "Examples:"
  echo "  $0 16 120     # 16 threads, 2 minutes"
  echo "  $0 64 300     # 64 threads, 5 minutes"
  exit 1
}

if [[ $# -lt 2 ]]; then
  usage
fi

THREADS="${1}"
DURATION="${2}"

if ! [[ "${THREADS}" =~ ^[0-9]+$ ]] || [[ "${THREADS}" -lt 1 ]]; then
  echo "ERROR: threads must be a positive integer (got: ${THREADS})" >&2
  exit 1
fi
if ! [[ "${DURATION}" =~ ^[0-9]+$ ]] || [[ "${DURATION}" -lt 1 ]]; then
  echo "ERROR: duration must be a positive integer in seconds (got: ${DURATION})" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${BENCHMARK_CONF:-${SCRIPT_DIR}/benchmark.conf}"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"

# shellcheck source=scaling-benchmarking/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

setup_paths
load_config "${CONFIG}"

# Only need DB connection vars, not scaling config.
: "${ENGINE:?Set ENGINE in benchmark.conf (standard or advanced)}"
: "${MYSQL_HOST:?Set MYSQL_HOST in benchmark.conf}"
: "${MYSQL_PORT:?Set MYSQL_PORT in benchmark.conf}"
: "${MYSQL_USER:?Set MYSQL_USER in benchmark.conf}"
: "${MYSQL_PASSWORD:?Set MYSQL_PASSWORD in benchmark.conf}"
: "${MYSQL_DB:?Set MYSQL_DB in benchmark.conf}"

export ENGINE MYSQL_HOST MYSQL_PORT MYSQL_USER MYSQL_PASSWORD MYSQL_DB

export TPCC_TABLES="${TPCC_TABLES:-10}"
export TPCC_SCALE="${TPCC_SCALE:-10}"
export TPCC_THREADS="${THREADS}"
export TPCC_WARMUP_SEC="${TPCC_WARMUP_SEC:-0}"
export TPCC_REPORT_INTERVAL="${TPCC_REPORT_INTERVAL:-1}"
export TPCC_FORCE_PK="${TPCC_FORCE_PK:-1}"
export TPCC_TRX_LEVEL="${TPCC_TRX_LEVEL:-RR}"
export TPCC_PERCENTILE="${TPCC_PERCENTILE:-99}"
export TPCC_MAX_TIME="${DURATION}"
export TPCC_IGNORE_ERRORS="${TPCC_IGNORE_ERRORS:-1290,1836,1053,2013,2006,2055,2011,3100,1205,1213,1020}"

RESULTS_BASE="${SCRIPT_DIR}/${RESULTS_DIR:-results}"
RUN_DIR="${RESULTS_BASE}/tryrun_${TIMESTAMP}_${ENGINE}_${THREADS}t_${DURATION}s"
mkdir -p "${RUN_DIR}"

RUN_LOG="${RUN_DIR}/tpcc_run.log"
FULL_LOG="${RUN_DIR}/benchmark.log"

preflight_checks

echo "=== TPC-C try-run ==="
echo "Config:   ${CONFIG}"
echo "Engine:   ${ENGINE}"
echo "Host:     ${MYSQL_HOST}:${MYSQL_PORT}/${MYSQL_DB}"
echo "Threads:  ${THREADS}"
echo "Duration: ${DURATION}s"
echo "Warmup:   ${TPCC_WARMUP_SEC}s"
echo "Tables:   ${TPCC_TABLES}  Scale: ${TPCC_SCALE}"
echo "Run dir:  ${RUN_DIR}"
echo "Sysbench: $("${BENCH_ROOT}/which_sysbench.sh")"
echo ""

exec > >(tee -a "${FULL_LOG}") 2>&1

# Connectivity check
mysql_connectivity_check || { echo "ERROR: cannot connect to MySQL — aborting" >&2; exit 1; }

# Verify TPC-C tables exist (data must already be loaded)
if ! tpcc_tables_exist; then
  echo "ERROR: TPC-C tables not found in database '${MYSQL_DB}'." >&2
  echo "Load data first with run_benchmark.sh (or SKIP_PREPARE=0)." >&2
  exit 1
fi
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] TPC-C tables verified — starting workload"
echo ""

: > "${RUN_LOG}"

run_tpcc run 2>&1 | tee -a "${RUN_LOG}"
tpcc_rc=${PIPESTATUS[0]}

echo ""
if [[ "${tpcc_rc}" -eq 0 ]]; then
  echo "=== try-run complete (OK) ==="
else
  echo "=== try-run finished with errors (rc=${tpcc_rc}) ==="
fi
echo "Run log: ${RUN_LOG}"
echo "Full log: ${FULL_LOG}"

exit "${tpcc_rc}"
