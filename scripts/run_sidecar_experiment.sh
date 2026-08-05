#!/usr/bin/env bash
# Orchestrator for sidecar memory profiling experiment.
#
# Phases:
#   1. Baseline  (5 min, no load)
#   2. Prepare   (TPC-C prepare, scale 100 tables 1)
#   3a. Low      (50 TPS, 8 threads, 20 min)
#   3b. Medium   (100 TPS, 16 threads, 20 min)
#   3c. High     (200 TPS, 32 threads, 20 min)
#   3d. Peak     (300 TPS, 64 threads, 20 min)
#
# Each phase tags the memory sampler so CSV rows are labeled.
# Between load phases there is a 2-min cooldown.
#
# Usage:
#   EDITION=advanced ./scripts/run_sidecar_experiment.sh
#
# Prerequisites:
#   - benchmark.conf configured for the target cluster
#   - kubeconfig available for kubectl exec (KUBECONFIG env or default)
#   - TPC-C sysbench installed (setup_benchmark.sh)
#   - sample_sidecar_memory.sh available
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "${ROOT}/lib/benchmark_common.sh"

EDITION="${EDITION:-advanced}"
CONFIG="${BENCHMARK_CONF:-${ROOT}/benchmark.conf}"
SAMPLER="${SCRIPT_DIR}/sample_sidecar_memory.sh"
LOG_DIR="${ROOT}/logs"
EXPERIMENT_LOG="${LOG_DIR}/sidecar_experiment.log"

export KUBECONFIG="${KUBECONFIG:-/root/.kube/config_4_16}"
export POD_PREFIX="${POD_PREFIX:-compare-am-gp-n3-4-16-i-adv-mysql}"
export K8S_NAMESPACE="${K8S_NAMESPACE:-percona}"

mkdir -p "$LOG_DIR"

load_benchmark_config "$CONFIG"
set_mysql_env_for_edition "$EDITION"

log() { echo "[$(date -u +%FT%TZ)] $*" | tee -a "$EXPERIMENT_LOG"; }
set_phase() { bash "$SAMPLER" set-phase "$1"; log "PHASE -> $1"; }

capture_mysql_stats() {
  local label="$1"
  local out="${LOG_DIR}/mysql_status_${label}.txt"
  mysql -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" -p"$MYSQL_PASSWORD" \
    --ssl-mode=REQUIRED "$MYSQL_DB" -e \
    "SELECT NOW() AS ts; SHOW GLOBAL STATUS WHERE Variable_name IN ('Queries','Com_select','Com_insert','Com_update','Com_delete','Slow_queries','Threads_running','Innodb_buffer_pool_reads','Innodb_buffer_pool_read_requests','Innodb_rows_read','Innodb_rows_inserted');" \
    > "$out" 2>&1 || true
  log "MySQL status snapshot -> $out"
}

run_tpcc_load() {
  local rate="$1" threads="$2" duration="$3" phase_label="$4"
  local load_log="${LOG_DIR}/sidecar_load_${phase_label}.log"

  set_phase "$phase_label"
  capture_mysql_stats "${phase_label}_start"

  log "Starting TPC-C run: rate=${rate} threads=${threads} duration=${duration}s"

  TPCC_RATE="$rate" TPCC_THREADS="$threads" TPCC_TIME="$duration" \
  TPCC_WARMUP=30 TPCC_REPORT_INTERVAL=10 \
    run_tpcc_command run > "$load_log" 2>&1 || true

  capture_mysql_stats "${phase_label}_end"
  log "TPC-C run finished for phase $phase_label (log: $load_log)"
}

# ============================================================
log "=========================================="
log "SIDECAR MEMORY PROFILING EXPERIMENT"
log "  cluster  : ${MYSQL_HOST}"
log "  edition  : ${EDITION}"
log "  sampler  : ${SAMPLER}"
log "=========================================="

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

# -- Phase 2: TPC-C Prepare --
log "PHASE 2: TPC-C Prepare (scale=100, tables=1, threads=4)"
set_phase "prepare"
capture_mysql_stats "prepare_start"

export TPCC_SCALE=100
export TPCC_TABLES=1
export TPCC_THREADS=4
export TPCC_FORCE_PK=1
export TPCC_TRX_LEVEL=RR

run_tpcc_command cleanup 2>&1 | tee -a "$EXPERIMENT_LOG" || true
run_tpcc_command prepare > "${LOG_DIR}/sidecar_prepare.log" 2>&1
prep_rc=$?

capture_mysql_stats "prepare_end"
if [[ $prep_rc -eq 0 ]]; then
  log "TPC-C prepare completed successfully."
else
  log "TPC-C prepare FAILED (rc=$prep_rc). Check ${LOG_DIR}/sidecar_prepare.log"
  log "Continuing with experiment anyway (data may be partial)."
fi

# -- Phase 3: Load ramp --
log "PHASE 3: OLTP load ramp-up"

# Reset threads/scale for run phase (scale & tables stay from prepare)
export TPCC_SCALE=100
export TPCC_TABLES=1

# 3a: 50 TPS, 8 threads, 20 min
run_tpcc_load 50 8 1200 "load_50tps"
log "Cooldown 2 min..."
set_phase "cooldown_50_100"
sleep 120

# 3b: 100 TPS, 16 threads, 20 min
run_tpcc_load 100 16 1200 "load_100tps"
log "Cooldown 2 min..."
set_phase "cooldown_100_200"
sleep 120

# 3c: 200 TPS, 32 threads, 20 min
run_tpcc_load 200 32 1200 "load_200tps"
log "Cooldown 2 min..."
set_phase "cooldown_200_300"
sleep 120

# 3d: 300 TPS, 64 threads, 20 min
run_tpcc_load 300 64 1200 "load_300tps"

# -- Done --
set_phase "done"
log "All load phases complete."

# -- Stop sampler --
log "Stopping memory sampler..."
bash "$SAMPLER" stop

# -- Quick summary --
CSV="${ROOT}/logs/sidecar_memory.csv"
log "=========================================="
log "EXPERIMENT COMPLETE"
log "  Memory CSV     : $CSV"
log "  Experiment log : $EXPERIMENT_LOG"
log "  Load logs      : ${LOG_DIR}/sidecar_load_*.log"
log "  MySQL snapshots: ${LOG_DIR}/mysql_status_*.txt"
log ""
log "Run: python3 scripts/build_sidecar_report.py $CSV"
log "=========================================="
