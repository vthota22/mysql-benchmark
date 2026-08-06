#!/usr/bin/env bash
# Orchestrator for sidecar memory profiling experiment (v2 — overnight run).
#
# Fully automated: cleanup, prepare (1 thread), tune slow query threshold,
# run load ramp (50/100/200/300 TPS x 30 min each), restore settings.
#
# Phases:
#   0. Cleanup + Prepare (scale 100, tables 1, 1 thread — ~45 min)
#   1. Baseline  (5 min, no load)
#   2a. Low      (50 TPS, 8 threads, 30 min)
#   2b. Medium   (100 TPS, 16 threads, 30 min)
#   2c. High     (200 TPS, 32 threads, 30 min)  ← trigger backup here
#   2d. Peak     (300 TPS, 64 threads, 30 min)
#
# Usage:
#   EDITION=advanced KUBECONFIG=/root/.kube/config_4_16 \
#     POD_PREFIX=<cluster-name>-mysql \
#     nohup bash scripts/run_sidecar_experiment.sh > logs/experiment_full.log 2>&1 &
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "${ROOT}/lib/benchmark_common.sh"

EDITION="${EDITION:-advanced}"
CONFIG="${BENCHMARK_CONF:-${ROOT}/benchmark.conf}"
SAMPLER="${SCRIPT_DIR}/sample_sidecar_memory.sh"
RUN_ID="${RUN_ID:-}"
if [[ -n "$RUN_ID" ]]; then
  LOG_DIR="${ROOT}/logs/${RUN_ID}"
else
  LOG_DIR="${ROOT}/logs"
fi
EXPERIMENT_LOG="${LOG_DIR}/sidecar_experiment.log"

export KUBECONFIG="${KUBECONFIG:-/root/.kube/config}"
export POD_PREFIX="${POD_PREFIX:-mysql}"
export K8S_NAMESPACE="${K8S_NAMESPACE:-percona}"
CLUSTER_NAME="${CLUSTER_NAME:-}"
export CSV_FILE="${LOG_DIR}/sidecar_memory.csv"

DOSYSTEM_PASS="${DOSYSTEM_PASS:-}"

mkdir -p "$LOG_DIR"

load_benchmark_config "$CONFIG"
set_mysql_env_for_edition "$EDITION"

log() { echo "[$(date -u +%FT%TZ)] $*" | tee -a "$EXPERIMENT_LOG"; }
set_phase() { bash "$SAMPLER" set-phase "$1"; log "PHASE -> $1"; }

run_mysql_as_dosystem() {
  mysql -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u dosystem -p"$DOSYSTEM_PASS" \
    --ssl-mode=REQUIRED "$MYSQL_DB" -e "$1" 2>&1
}

run_mysql_query() {
  mysql -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" -p"$MYSQL_PASSWORD" \
    --ssl-mode=REQUIRED "$MYSQL_DB" -e "$1" 2>&1
}

capture_mysql_stats() {
  local label="$1"
  local out="${LOG_DIR}/mysql_status_${label}.txt"
  run_mysql_query "SELECT NOW() AS ts; SHOW GLOBAL STATUS WHERE Variable_name IN ('Queries','Com_select','Com_insert','Com_update','Com_delete','Slow_queries','Threads_running','Innodb_buffer_pool_reads','Innodb_buffer_pool_read_requests','Innodb_rows_read','Innodb_rows_inserted');" \
    > "$out" 2>&1 || true
  log "MySQL status snapshot -> $out"
}

trigger_backup() {
  local label="${1//_/-}"
  local bk_name="sidecar-exp-${label}-$(date -u +%H%M%S)"
  log "Triggering on-demand backup '${bk_name}' during phase ${label}..."
  kubectl --kubeconfig "$KUBECONFIG" -n "$K8S_NAMESPACE" apply -f - <<BKEOF 2>&1 | tee -a "$EXPERIMENT_LOG" || true
apiVersion: ps.percona.com/v1
kind: PerconaServerMySQLBackup
metadata:
  name: ${bk_name}
  namespace: ${K8S_NAMESPACE}
spec:
  clusterName: ${CLUSTER_NAME}
  storageName: s3-storage
  type: full
BKEOF
  log "Backup CR '${bk_name}' submitted"
}

run_tpcc_load() {
  local rate="$1" threads="$2" duration="$3" phase_label="$4"
  local load_log="${LOG_DIR}/sidecar_load_${phase_label}.log"

  set_phase "$phase_label"
  capture_mysql_stats "${phase_label}_start"

  # Trigger a backup at the start of every load phase
  trigger_backup "$phase_label"

  log "Starting TPC-C run: rate=${rate} threads=${threads} duration=${duration}s"

  TPCC_RATE="$rate" TPCC_THREADS="$threads" TPCC_TIME="$duration" \
  TPCC_WARMUP=30 TPCC_REPORT_INTERVAL=10 \
    run_tpcc_command run > "$load_log" 2>&1 || true

  capture_mysql_stats "${phase_label}_end"
  log "TPC-C run finished for phase $phase_label (log: $load_log)"
}

# ============================================================
log "=========================================="
log "SIDECAR MEMORY PROFILING EXPERIMENT v2"
log "  cluster  : ${MYSQL_HOST}"
log "  edition  : ${EDITION}"
log "  sampler  : ${SAMPLER}"
log "=========================================="

# -- Resolve dosystem password if not provided --
if [[ -z "$DOSYSTEM_PASS" ]]; then
  log "Fetching dosystem password from k8s secret..."
  CLUSTER_NAME=$(kubectl --kubeconfig "$KUBECONFIG" -n "$K8S_NAMESPACE" get pods --no-headers -o custom-columns=':metadata.name' 2>/dev/null | grep 'mysql-0' | sed 's/-mysql-0//')
  if [[ -n "$CLUSTER_NAME" ]]; then
    DOSYSTEM_PASS=$(kubectl --kubeconfig "$KUBECONFIG" -n "$K8S_NAMESPACE" get secret "${CLUSTER_NAME}-dosystem-secrets" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null) || true
  fi
  if [[ -z "$DOSYSTEM_PASS" ]]; then
    log "WARNING: Could not fetch dosystem password. long_query_time will NOT be changed."
  else
    log "dosystem password resolved."
  fi
fi

export TPCC_SCALE=100
export TPCC_TABLES=1
export TPCC_FORCE_PK=1
export TPCC_TRX_LEVEL=RR

SKIP_PREPARE="${SKIP_PREPARE:-0}"
if [[ "$SKIP_PREPARE" == "1" ]]; then
  log "SKIP_PREPARE=1 — skipping cleanup and prepare, reusing existing data"
else
  # -- Phase 0: Cleanup + Prepare --
  log "PHASE 0: Cleanup old data + Prepare (scale=100, tables=1, 1 thread)"
  set_phase "prepare"

  export TPCC_THREADS=1

  log "Cleaning up old tables..."
  run_tpcc_command cleanup 2>&1 | tee -a "$EXPERIMENT_LOG" || true
  sleep 5

  log "Starting TPC-C prepare (scale=100, tables=1, 1 thread — expect ~45 min)..."
  capture_mysql_stats "prepare_start"
  run_tpcc_command prepare > "${LOG_DIR}/sidecar_prepare.log" 2>&1
  prep_rc=$?
  capture_mysql_stats "prepare_end"

  if [[ $prep_rc -eq 0 ]]; then
    log "TPC-C prepare completed successfully."
  else
    log "TPC-C prepare FAILED (rc=$prep_rc). Check ${LOG_DIR}/sidecar_prepare.log"
    log "ABORTING — cannot run load without data."
    exit 1
  fi
fi

# Verify row count
stock_rows=$(run_mysql_query "SELECT COUNT(*) FROM stock1;" 2>/dev/null | tail -1 | tr -d '[:space:]')
log "Verification: stock1 row count = ${stock_rows} (expected ~10000000)"

# -- Lower long_query_time --
if [[ -n "$DOSYSTEM_PASS" ]]; then
  log "Lowering long_query_time to 0.1s (was 2s) to stress slow-log-tailer..."
  run_mysql_as_dosystem "SET GLOBAL long_query_time = 0.1;"
  log "long_query_time set to 0.1s"
else
  log "SKIPPING long_query_time change (no dosystem password)"
fi

# -- Clear old memory CSV --
rm -f "${LOG_DIR}/sidecar_memory.csv"

# -- Start sampler --
log "Starting memory sampler..."
bash "$SAMPLER" start idle

# -- Phase 1: Baseline --
log "PHASE 1: Baseline (5 min, no load)"
set_phase "baseline"
capture_mysql_stats "baseline_start"
sleep 300
capture_mysql_stats "baseline_end"
log "Baseline complete."

# -- Phase 2: Load ramp --
log "PHASE 2: OLTP load ramp-up (30 min per level)"

export TPCC_SCALE=100
export TPCC_TABLES=1

# 2a: 50 TPS, 8 threads, 30 min
run_tpcc_load 50 8 1800 "load_50tps"
log "Cooldown 2 min..."
set_phase "cooldown_50_100"
sleep 120

# 2b: 100 TPS, 16 threads, 30 min
run_tpcc_load 100 16 1800 "load_100tps"
log "Cooldown 2 min..."
set_phase "cooldown_100_200"
sleep 120

# 2c: 200 TPS, 32 threads, 30 min
run_tpcc_load 200 32 1800 "load_200tps"
log "Cooldown 2 min..."
set_phase "cooldown_200_300"
sleep 120

# 2d: 300 TPS, 64 threads, 30 min
run_tpcc_load 300 64 1800 "load_300tps"

# -- Done --
set_phase "done"
log "All load phases complete."

# -- Restore long_query_time --
if [[ -n "$DOSYSTEM_PASS" ]]; then
  log "Restoring long_query_time to 2s..."
  run_mysql_as_dosystem "SET GLOBAL long_query_time = 2;"
  log "long_query_time restored."
fi

# -- Stop sampler --
log "Stopping memory sampler..."
bash "$SAMPLER" stop

# -- Generate report --
CSV="${LOG_DIR}/sidecar_memory.csv"
log "Generating sidecar memory report..."
python3 "${SCRIPT_DIR}/build_sidecar_report.py" "$CSV" 2>&1 | tee -a "$EXPERIMENT_LOG" || true

log "=========================================="
log "EXPERIMENT COMPLETE"
log "  Memory CSV     : $CSV"
log "  HTML report    : ${LOG_DIR}/sidecar_report.html"
log "  Experiment log : $EXPERIMENT_LOG"
log "  Load logs      : ${LOG_DIR}/sidecar_load_*.log"
log "  MySQL snapshots: ${LOG_DIR}/mysql_status_*.txt"
log "=========================================="
