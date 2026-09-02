#!/usr/bin/env bash
# Quick TPC-C try-run: fire a workload against the cluster and see how it performs.
# No scaling, no database init, no saved results — just connect, run, and print output.
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

# shellcheck source=scaling-benchmarking/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

setup_paths
load_config "${CONFIG}"

: "${ENGINE:?Set ENGINE in benchmark.conf (standard or advanced)}"
: "${MYSQL_DB:?Set MYSQL_DB in benchmark.conf}"

export DO_API_TOKEN="${DO_API_TOKEN:-}"
export DO_API_URL="${DO_API_URL:-}"
export CLUSTER_ID="${CLUSTER_ID:-}"

# Always fetch live cluster details + connection info from doctl; save back to config.
# Failures are non-fatal — fall back to values already in benchmark.conf.
if [[ -n "${CLUSTER_ID:-}" && -n "${DO_API_TOKEN:-}" ]]; then
  fetch_cluster_details "${CONFIG}" || true
fi

apply_mysql_host_override "${CONFIG}"

: "${MYSQL_HOST:?Set MYSQL_HOST, OVERRIDE_MYSQL_HOST, or provide CLUSTER_ID + DO_API_TOKEN}"
: "${MYSQL_PORT:?Set MYSQL_PORT in benchmark.conf or provide CLUSTER_ID + DO_API_TOKEN}"
: "${MYSQL_USER:?Set MYSQL_USER in benchmark.conf or provide CLUSTER_ID + DO_API_TOKEN}"
: "${MYSQL_PASSWORD:?Set MYSQL_PASSWORD in benchmark.conf or provide CLUSTER_ID + DO_API_TOKEN}"

host_source="benchmark.conf"
if [[ -n "${OVERRIDE_MYSQL_HOST:-}" ]]; then
  host_source="OVERRIDE_MYSQL_HOST"
elif [[ -n "${DO_API_TOKEN:-}" ]]; then
  host_source="doctl (auto-fetched)"
fi
log_phase "0_CONFIG" "effective MYSQL_HOST=${MYSQL_HOST} (source: ${host_source})"
log_phase "0_CONFIG" "effective MYSQL_PORT=${MYSQL_PORT} MYSQL_USER=${MYSQL_USER}"

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
export TPCC_VERBOSITY="${TPCC_VERBOSITY:-}"
export TPCC_RECONNECT="${TPCC_RECONNECT:-0}"

# Group Replication tuning
export K8S_KUBECONFIG="${K8S_KUBECONFIG:-}"
export K8S_NAMESPACE="${K8S_NAMESPACE:-percona}"
export PXC_CLUSTER_NAME="${PXC_CLUSTER_NAME:-}"
export PXC_MYSQL_ROOT_USER="${PXC_MYSQL_ROOT_USER:-root}"
export PXC_MYSQL_ROOT_PASSWORD="${PXC_MYSQL_ROOT_PASSWORD:-}"
export PXC_MYSQL_ROOT_SECRET="${PXC_MYSQL_ROOT_SECRET:-}"
export WITHOUT_SCALING_GR_EXIT_STATE_ACTION="${WITHOUT_SCALING_GR_EXIT_STATE_ACTION:-}"
export WITHOUT_SCALING_GR_FLOW_CONTROL_APPLIER_THRESHOLD="${WITHOUT_SCALING_GR_FLOW_CONTROL_APPLIER_THRESHOLD:-}"
export WITHOUT_SCALING_GR_FLOW_CONTROL_CERTIFIER_THRESHOLD="${WITHOUT_SCALING_GR_FLOW_CONTROL_CERTIFIER_THRESHOLD:-}"
export WITHOUT_SCALING_GR_FLOW_CONTROL_HOLD_PERCENT="${WITHOUT_SCALING_GR_FLOW_CONTROL_HOLD_PERCENT:-}"
export GR_REPLICA_PARALLEL_WORKERS="${GR_REPLICA_PARALLEL_WORKERS:-}"

preflight_checks

echo "=== TPC-C try-run ==="
echo "Config:   ${CONFIG}"
echo "Engine:   ${ENGINE}"
echo "Host:     ${MYSQL_HOST}:${MYSQL_PORT}/${MYSQL_DB}"
echo "Threads:  ${THREADS}"
echo "Duration: ${DURATION}s"
echo "Warmup:   ${TPCC_WARMUP_SEC}s"
echo "Tables:   ${TPCC_TABLES}  Scale: ${TPCC_SCALE}"
if [[ "${TPCC_RECONNECT}" != "0" ]]; then
  echo "Reconn:   each thread reconnects every ${TPCC_RECONNECT} events"
fi
if [[ -n "${TPCC_VERBOSITY:-}" ]]; then
  echo "Verbosity: ${TPCC_VERBOSITY}"
fi
echo "Sysbench: $("${BENCH_ROOT}/which_sysbench.sh")"
echo ""

# Connectivity check
mysql_connectivity_check || { echo "ERROR: cannot connect to MySQL — aborting" >&2; exit 1; }

# Verify TPC-C tables exist (data must already be loaded)
if ! tpcc_tables_exist; then
  echo "ERROR: TPC-C tables not found in database '${MYSQL_DB}'." >&2
  echo "Load data first with run_benchmark.sh (or SKIP_PREPARE=0)." >&2
  exit 1
fi
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] TPC-C tables verified"
echo ""

snapshot_cr_config

# Check Group Replication settings before workload
log_phase "GR_CHECK" "querying Group Replication flow-control and exit-state settings"
gr_vars="$(mysql_admin -e "
  SELECT variable_name, variable_value
  FROM performance_schema.global_variables
  WHERE variable_name IN (
    'group_replication_flow_control_applier_threshold',
    'group_replication_flow_control_certifier_threshold',
    'group_replication_flow_control_hold_percent',
    'group_replication_exit_state_action',
    'group_replication_flow_control_mode',
    'replica_parallel_workers',
    'replica_preserve_commit_order'
  )
  ORDER BY variable_name;
" 2>&1)" || true

if [[ -z "${gr_vars}" ]]; then
  log_phase "GR_CHECK" "no Group Replication variables found (plugin may not be active)"
else
  log_phase "GR_CHECK" "current values:"
  while IFS= read -r line; do
    log_phase "GR_CHECK" "  ${line}"
  done <<< "${gr_vars}"
fi

gr_members="$(mysql_admin -e "
  SELECT member_host, member_port, member_state, member_role
  FROM performance_schema.replication_group_members;
" 2>&1)" || true

if [[ -n "${gr_members}" ]]; then
  log_phase "GR_CHECK" "group members:"
  while IFS= read -r line; do
    log_phase "GR_CHECK" "  ${line}"
  done <<< "${gr_members}"
fi

echo ""
gr_apply_without_scaling
gr_apply_replica_parallel_workers
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] starting workload"
echo ""

run_tpcc run 2>&1
tpcc_rc=$?

echo ""
if [[ "${tpcc_rc}" -eq 0 ]]; then
  echo "=== try-run complete (OK) ==="
else
  echo "=== try-run finished with errors (rc=${tpcc_rc}) ==="
fi

exit "${tpcc_rc}"
