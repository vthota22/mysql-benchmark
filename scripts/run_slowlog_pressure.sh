#!/usr/bin/env bash
# Slow-log-tailer memory pressure experiment.
#
# Phases:
#   1. Baseline      (5 min idle, record tailer memory)
#   2. Bulk INSERTs  (TPC-C prepare scale=5400 tables=1 threads=1)
#   3. OLTP load     (200 TPS, 30 min — small queries after big prepare)
#
# Monitors slow-log-tailer cgroup memory + slow.log file size every 10s.
# Captures /proc VmRSS and VmHWM snapshots at key moments.
#
# Usage:
#   KUBECONFIG=/root/.kube/config \
#   BENCHMARK_CONF=/root/mysql-benchmark/benchmark_sidecar.conf \
#   nohup bash scripts/run_slowlog_pressure.sh > logs/slowlog_pressure/full.log 2>&1 &
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "${ROOT}/lib/benchmark_common.sh"
set +e  # benchmark_common enables -e; we need to survive partial failures

EDITION="${EDITION:-advanced}"
CONFIG="${BENCHMARK_CONF:-${ROOT}/benchmark_sidecar.conf}"
export KUBECONFIG="${KUBECONFIG:-/root/.kube/config}"
NS="${K8S_NAMESPACE:-percona}"
POD_PREFIX="${POD_PREFIX:-mysql}"
PODS=("${POD_PREFIX}-0" "${POD_PREFIX}-1" "${POD_PREFIX}-2")

DOSYSTEM_PASS="${DOSYSTEM_PASS:-}"
SAMPLE_INTERVAL=10

LOG_DIR="${ROOT}/logs/slowlog_pressure"
EXPERIMENT_LOG="${LOG_DIR}/experiment.log"
MEMORY_CSV="${LOG_DIR}/memory_samples.csv"
SLOWLOG_CSV="${LOG_DIR}/slowlog_size.csv"
PROC_SNAPSHOTS="${LOG_DIR}/proc_snapshots.txt"
SAMPLER_PID_FILE="${LOG_DIR}/sampler.pid"
PHASE_FILE="${LOG_DIR}/phase.txt"

mkdir -p "$LOG_DIR"
load_benchmark_config "$CONFIG"
set_mysql_env_for_edition "$EDITION"

log() { echo "[$(date -u +%FT%TZ)] $*" | tee -a "$EXPERIMENT_LOG"; }

run_mysql_as_dosystem() {
  mysql -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u dosystem -p"$DOSYSTEM_PASS" \
    --ssl-mode=REQUIRED "$MYSQL_DB" -e "$1" 2>&1
}

run_mysql_query() {
  mysql -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" -p"$MYSQL_PASSWORD" \
    --ssl-mode=REQUIRED "$MYSQL_DB" -e "$1" 2>&1
}

# ── Resolve dosystem password ──
if [[ -z "$DOSYSTEM_PASS" ]]; then
  log "Fetching dosystem password from k8s secret..."
  CLUSTER_NAME=$(kubectl --kubeconfig "$KUBECONFIG" -n "$NS" get pods --no-headers \
    -o custom-columns=':metadata.name' 2>/dev/null | grep 'mysql-0' | sed 's/-mysql-0//')
  if [[ -n "$CLUSTER_NAME" ]]; then
    DOSYSTEM_PASS=$(kubectl --kubeconfig "$KUBECONFIG" -n "$NS" \
      get secret "${CLUSTER_NAME}-dosystem-secrets" \
      -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null) || true
  fi
  [[ -z "$DOSYSTEM_PASS" ]] && log "WARNING: no dosystem password — long_query_time unchanged"
fi

# ── Sampler: cgroup memory + slow.log size ──
_read_tailer_memory() {
  local pod="$1"
  kubectl --kubeconfig "$KUBECONFIG" -n "$NS" exec "$pod" -c slow-log-tailer -- \
    sh -c 'cat /sys/fs/cgroup/memory.current 2>/dev/null || cat /sys/fs/cgroup/memory/memory.usage_in_bytes 2>/dev/null || echo -1' \
    2>/dev/null | tr -d '[:space:]'
}

_read_slowlog_size() {
  local pod="$1"
  kubectl --kubeconfig "$KUBECONFIG" -n "$NS" exec "$pod" -c mysql -- \
    sh -c 'wc -c < /var/lib/mysql/slow.log 2>/dev/null || echo -1' \
    2>/dev/null | tr -d '[:space:]'
}

_read_slowlog_entries() {
  local pod="$1"
  kubectl --kubeconfig "$KUBECONFIG" -n "$NS" exec "$pod" -c mysql -- \
    sh -c 'grep -c "^# Time:" /var/lib/mysql/slow.log 2>/dev/null || echo 0' \
    2>/dev/null | tr -d '[:space:]'
}

_sample_loop() {
  while true; do
    local ts phase
    ts=$(date -u +%FT%TZ)
    phase=$(cat "$PHASE_FILE" 2>/dev/null || echo "unknown")
    for pod in "${PODS[@]}"; do
      local mem slowlog_sz
      mem=$(_read_tailer_memory "$pod")
      echo "${ts},${pod},slow-log-tailer,${mem},${phase}" >> "$MEMORY_CSV"
      slowlog_sz=$(_read_slowlog_size "$pod")
      echo "${ts},${pod},${slowlog_sz},${phase}" >> "$SLOWLOG_CSV"
    done
    sleep "$SAMPLE_INTERVAL"
  done
}

start_sampler() {
  echo "timestamp,pod,container,memory_bytes,phase" > "$MEMORY_CSV"
  echo "timestamp,pod,file_size_bytes,phase" > "$SLOWLOG_CSV"
  echo "$1" > "$PHASE_FILE"
  _sample_loop &
  echo $! > "$SAMPLER_PID_FILE"
  log "Sampler started (pid=$(cat "$SAMPLER_PID_FILE"), interval=${SAMPLE_INTERVAL}s)"
}

stop_sampler() {
  [[ -f "$SAMPLER_PID_FILE" ]] && kill "$(cat "$SAMPLER_PID_FILE")" 2>/dev/null || true
  rm -f "$SAMPLER_PID_FILE"
  log "Sampler stopped"
}

set_phase() {
  echo "$1" > "$PHASE_FILE"
  log "PHASE -> $1"
}

# ── Proc snapshots: VmRSS, VmHWM ──
capture_proc_snapshot() {
  local label="$1"
  echo "=== $label ($(date -u +%FT%TZ)) ===" >> "$PROC_SNAPSHOTS"
  for pod in "${PODS[@]}"; do
    echo "  $pod:" >> "$PROC_SNAPSHOTS"
    local out
    out=$(kubectl --kubeconfig "$KUBECONFIG" -n "$NS" exec "$pod" -c slow-log-tailer -- \
      sh -c 'grep -E "VmRSS|VmHWM|VmSize" /proc/1/status 2>/dev/null || echo "proc not available"' \
      2>/dev/null)
    echo "    $out" >> "$PROC_SNAPSHOTS"
    local mem
    mem=$(_read_tailer_memory "$pod")
    echo "    cgroup_memory: $mem" >> "$PROC_SNAPSHOTS"
  done
  log "Proc snapshot: $label"
}

# ── Clear slow.log on a pod ──
clear_slowlog() {
  local pod="$1"
  kubectl --kubeconfig "$KUBECONFIG" -n "$NS" exec "$pod" -c mysql -- \
    sh -c ': > /var/lib/mysql/slow.log' 2>&1 || true
}

# ============================================================
log "=========================================="
log "SLOW-LOG-TAILER PRESSURE EXPERIMENT"
log "  cluster : ${MYSQL_HOST}"
log "  pods    : ${PODS[*]}"
log "=========================================="

# ── Phase 1: Baseline ──
BASELINE_SECS="${BASELINE_SECS:-120}"
log "PHASE 1: Baseline (${BASELINE_SECS}s idle)"
start_sampler "baseline_before_clear"
capture_proc_snapshot "baseline_before_clear"
sleep "$BASELINE_SECS"

log "Clearing slow.log on all pods..."
set_phase "baseline_after_clear"
for pod in "${PODS[@]}"; do
  clear_slowlog "$pod"
  log "  Cleared slow.log on $pod"
done
capture_proc_snapshot "baseline_after_clear"
sleep "$BASELINE_SECS"
capture_proc_snapshot "baseline_end"
log "Baseline complete."

# ── Phase 2: Bulk INSERTs ──
log "PHASE 2: TPC-C Prepare (scale=5400, tables=1, 1 thread)"

if [[ -n "$DOSYSTEM_PASS" ]]; then
  log "Lowering long_query_time to 0.1s..."
  run_mysql_as_dosystem "SET GLOBAL long_query_time = 0.1;"
fi

set_phase "prepare_cleanup"
log "Cleaning up old TPC-C tables..."
PREPARE_SCALE="${PREPARE_SCALE:-5400}"
PREPARE_THREADS="${PREPARE_THREADS:-4}"
export TPCC_SCALE="$PREPARE_SCALE"
export TPCC_TABLES=1
export TPCC_THREADS="$PREPARE_THREADS"
export TPCC_FORCE_PK=1
export TPCC_TRX_LEVEL=RR
run_tpcc_command cleanup 2>&1 | tee -a "$EXPERIMENT_LOG" || true
sleep 5

set_phase "prepare_running"
capture_proc_snapshot "prepare_start"
log "Starting TPC-C prepare (scale=${PREPARE_SCALE}, tables=1, ${PREPARE_THREADS} threads)..."
run_tpcc_command prepare > "${LOG_DIR}/tpcc_prepare.log" 2>&1 &
PREPARE_PID=$!

SNAPSHOT_INTERVAL="${SNAPSHOT_INTERVAL:-120}"
SNAPSHOT_COUNT=0
while kill -0 "$PREPARE_PID" 2>/dev/null; do
  sleep "$SNAPSHOT_INTERVAL"
  SNAPSHOT_COUNT=$((SNAPSHOT_COUNT + 1))
  if kill -0 "$PREPARE_PID" 2>/dev/null; then
    capture_proc_snapshot "prepare_during_${SNAPSHOT_COUNT}"
  fi
done
wait "$PREPARE_PID" || true
prep_rc=$?

capture_proc_snapshot "prepare_end"
if [[ $prep_rc -eq 0 ]]; then
  log "TPC-C prepare completed successfully."
else
  log "TPC-C prepare finished with rc=$prep_rc (may have failed, check ${LOG_DIR}/tpcc_prepare.log)"
fi

# ── Phase 3: OLTP load (small queries) ──
log "PHASE 3: OLTP load (200 TPS, 32 threads, 30 min)"
set_phase "oltp_running"
capture_proc_snapshot "oltp_start"

export TPCC_SCALE="$PREPARE_SCALE"
export TPCC_TABLES=1
export TPCC_THREADS=32
OLTP_TIME="${OLTP_TIME:-1800}"
log "  rate=200, threads=32, time=${OLTP_TIME}s"
TPCC_RATE=200 TPCC_TIME="$OLTP_TIME" TPCC_WARMUP=30 TPCC_REPORT_INTERVAL=10 \
  run_tpcc_command run > "${LOG_DIR}/tpcc_oltp.log" 2>&1 || true

capture_proc_snapshot "oltp_end"
log "OLTP load finished."

# ── Cleanup ──
set_phase "done"
stop_sampler

# ── Summary ──
log "=========================================="
log "EXPERIMENT COMPLETE"
log "  Memory CSV       : $MEMORY_CSV"
log "  Slowlog size CSV : $SLOWLOG_CSV"
log "  Proc snapshots   : $PROC_SNAPSHOTS"
log "  Experiment log   : $EXPERIMENT_LOG"
log "  TPC-C prepare log: ${LOG_DIR}/tpcc_prepare.log"
log "  TPC-C OLTP log   : ${LOG_DIR}/tpcc_oltp.log"
log "=========================================="

# Quick inline summary
python3 -c "
import csv
from collections import defaultdict

data = defaultdict(list)
with open('$MEMORY_CSV') as f:
    for row in csv.DictReader(f):
        mem = int(row['memory_bytes'])
        if mem < 0: continue
        data[(row['pod'], row['phase'])].append(mem)

phases = ['baseline_before_clear','baseline_after_clear','prepare_running','oltp_running','done']
pods = ['${PODS[0]}','${PODS[1]}','${PODS[2]}']
print()
print('Peak slow-log-tailer memory (MiB) by phase:')
print(f'{\"Phase\":<25} {\"mysql-0\":>12} {\"mysql-1\":>12} {\"mysql-2\":>12}')
print('-' * 65)
for p in phases:
    vals = []
    for pod in pods:
        samples = data.get((pod, p), [])
        peak = max(samples) / 1048576 if samples else 0
        vals.append(f'{peak:.1f}')
    print(f'{p:<25} {vals[0]:>12} {vals[1]:>12} {vals[2]:>12}')
" 2>&1 | tee -a "$EXPERIMENT_LOG" || true
