#!/usr/bin/env bash
# Load TPC-C data on a cluster via sysbench-tpcc (cleanup → prepare → check).
#
# Usage (on benchmark droplet):
#   PREPARE_RESULTS_DIR=results/prepare_20260704_120000 \
#   BENCHMARK_CONF=results/prepare_20260704_120000/prepare.conf \
#   PREPARE_EDITION=advanced \
#   ./scripts/prepare_cluster.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG="${BENCHMARK_CONF:?Set BENCHMARK_CONF}"
EDITION="${PREPARE_EDITION:-advanced}"
RESULTS_ROOT="${PREPARE_RESULTS_DIR:?Set PREPARE_RESULTS_DIR}"
FULL_LOG="${RESULTS_ROOT}/full_run.log"
PREPARE_LOG="${RESULTS_ROOT}/prepare.log"
CHECK_LOG="${RESULTS_ROOT}/check.log"
META_FILE="${RESULTS_ROOT}/prepare_meta.env"
COMPLETE_MARKER="=== TPC-C prepare complete ==="

export PATH="${REPO_ROOT}/sysbench-1.1/bin:${PATH}"

# shellcheck source=lib/benchmark_common.sh
source "${REPO_ROOT}/lib/benchmark_common.sh"

mkdir -p "${RESULTS_ROOT}"
exec > >(tee -a "${FULL_LOG}") 2>&1

echo "=== TPC-C Data Prepare ==="
echo "Started:  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "Results:  ${RESULTS_ROOT}"
echo "Config:   ${CONFIG}"
echo "Edition:  ${EDITION}"
echo "Sysbench: $("${REPO_ROOT}/which_sysbench.sh" 2>/dev/null || echo sysbench)"
echo ""

load_benchmark_config "${CONFIG}"
set_mysql_env_for_edition "${EDITION}"

{
  echo "PREPARE_STARTED_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "PREPARE_EDITION=${EDITION}"
  echo "MYSQL_HOST=${MYSQL_HOST}"
  echo "MYSQL_PORT=${MYSQL_PORT}"
  echo "MYSQL_DB=${MYSQL_DB}"
  echo "TPCC_TABLES=${TPCC_TABLES:-10}"
  echo "TPCC_SCALE=${TPCC_SCALE:-100}"
  echo "PREP_THREADS=${PREP_THREADS:-16}"
} > "${META_FILE}"

echo "--- Connectivity ---"
mysql_connectivity_check "${EDITION}" "${RESULTS_ROOT}/mysql_info.txt" \
  || { echo "ERROR: cannot connect to ${EDITION} cluster"; exit 1; }
echo ""

echo "--- Cleanup (ignore errors if empty) ---"
export TPCC_THREADS="${PREP_THREADS:-16}"
run_tpcc_command cleanup 2>&1 | tee "${RESULTS_ROOT}/cleanup.log" || true
echo ""

echo "--- Prepare (tables=${TPCC_TABLES:-10}, scale=${TPCC_SCALE:-100}, threads=${PREP_THREADS:-16}) ---"
PREP_START=$(date +%s)
run_tpcc_command prepare 2>&1 | tee "${PREPARE_LOG}"
PREP_END=$(date +%s)
echo "Prepare duration: $((PREP_END - PREP_START))s"
echo ""

echo "--- Check ---"
if run_tpcc_command check 2>&1 | tee "${CHECK_LOG}"; then
  echo "PREPARE_CHECK_OK=1" >> "${META_FILE}"
else
  echo "PREPARE_CHECK_OK=0" >> "${META_FILE}"
  echo "ERROR: TPC-C check failed after prepare" >&2
  exit 1
fi
echo ""

echo "PREPARE_FINISHED_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "${META_FILE}"
echo "PREPARE_DURATION_SEC=$((PREP_END - PREP_START))" >> "${META_FILE}"
echo "${COMPLETE_MARKER}"
echo "=== Done ==="
