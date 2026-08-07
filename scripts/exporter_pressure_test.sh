#!/bin/bash
# mysqld-exporter MAX memory pressure test.
#
# Pushes the exporter to its memory limit by escalating:
#   - Number of concurrent connections (100 → 500)
#   - Query text size per connection (10KB → 1MB)
#   - Scrape frequency (every 2s during peak phases)
#
# The processlist collector reads ALL active query text per scrape.
# Total processlist payload = connections × query_size.
#
# Phase ladder:
#   1. Baseline (2 min idle)
#   2. Warmup: 100 conn x 10KB   =   1 MB processlist
#   3. Medium: 200 conn x 50KB   =  10 MB processlist
#   4. High:   300 conn x 100KB  =  30 MB processlist
#   5. Extreme:200 conn x 500KB  = 100 MB processlist
#   6. Max:    100 conn x 1MB    = 100 MB processlist
#   7. Cooldown (2 min idle — check GC release)
#
# Usage:
#   POD=<cluster>-mysql-0 KUBECONFIG=/root/.kube/config \
#     bash scripts/exporter_pressure_test.sh
set +e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "${ROOT}/lib/benchmark_common.sh"
EDITION="${EDITION:-advanced}"
CONFIG="${BENCHMARK_CONF:-${ROOT}/benchmark.conf}"
load_benchmark_config "$CONFIG"
set_mysql_env_for_edition "$EDITION"
set +e

KUBECONFIG="${KUBECONFIG:-/root/.kube/config}"
NS="${K8S_NAMESPACE:-percona}"
POD="${POD:-}"

HOLD_SECONDS="${HOLD_SECONDS:-180}"

LOG_DIR="${ROOT}/logs/exporter_pressure_max"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/experiment.log"
MEMORY_CSV="$LOG_DIR/memory_samples.csv"

log() { echo "[$(date -u +%FT%TZ)] $*" | tee -a "$LOG"; }

snapshot() {
  local label="$1"
  local proc cg mib
  proc=$(kubectl --kubeconfig "$KUBECONFIG" -n "$NS" exec "$POD" -c mysqld-exporter -- \
    sh -c 'grep -E "VmRSS|VmHWM" /proc/1/status 2>/dev/null' 2>/dev/null | tr '\n' ' ')
  cg=$(kubectl --kubeconfig "$KUBECONFIG" -n "$NS" exec "$POD" -c mysqld-exporter -- \
    sh -c 'cat /sys/fs/cgroup/memory.current 2>/dev/null' 2>/dev/null | tr -d '[:space:]')
  mib=$(( ${cg:-0} / 1048576 ))

  local rss_kb=$(echo "$proc" | grep -oP 'VmRSS:\s+\K[0-9]+')
  local hwm_kb=$(echo "$proc" | grep -oP 'VmHWM:\s+\K[0-9]+')
  log "[$label] RSS=${rss_kb:-0}kB HWM=${hwm_kb:-0}kB cgroup=${mib}MiB"
  echo "$(date -u +%FT%TZ),${label},${rss_kb:-0},${hwm_kb:-0},${cg:-0}" >> "$MEMORY_CSV"
}

scrape_and_measure() {
  kubectl --kubeconfig "$KUBECONFIG" -n "$NS" exec "$POD" -c mysqld-exporter -- \
    sh -c 'wget -qO /dev/null http://127.0.0.1:9104/metrics' 2>/dev/null
}

exporter_restarts() {
  kubectl --kubeconfig "$KUBECONFIG" -n "$NS" get pod "$POD" \
    -o jsonpath='{.status.containerStatuses[?(@.name=="mysqld-exporter")].restartCount}' 2>/dev/null
}

cat > /tmp/exporter_load.py << 'PYEOF'
import mysql.connector
import sys
import time
import threading
import os

host = os.environ['MYSQL_HOST']
port = int(os.environ.get('MYSQL_PORT', '3306'))
user = os.environ['MYSQL_USER']
password = os.environ['MYSQL_PASSWORD']
db = os.environ.get('MYSQL_DB', 'defaultdb')

num_connections = int(sys.argv[1]) if len(sys.argv) > 1 else 100
query_size_kb = int(sys.argv[2]) if len(sys.argv) > 2 else 10
hold_seconds = int(sys.argv[3]) if len(sys.argv) > 3 else 120

padding = 'A' * (query_size_kb * 1024)
query = f"SELECT /* {padding} */ SLEEP({hold_seconds})"

connected = 0
errors = 0
lock = threading.Lock()

def run_query(idx):
    global errors, connected
    try:
        conn = mysql.connector.connect(
            host=host, port=port, user=user, password=password,
            database=db, ssl_disabled=False, use_pure=True,
            connection_timeout=30
        )
        with lock:
            connected += 1
            if connected % 50 == 0:
                print(f"  Connected: {connected}/{num_connections}")
        cursor = conn.cursor()
        cursor.execute(query)
        cursor.fetchall()
        cursor.close()
        conn.close()
    except Exception as e:
        with lock:
            errors += 1
            if errors <= 10:
                print(f"  Connection {idx} error: {e}", file=sys.stderr)

print(f"Opening {num_connections} connections with {query_size_kb}KB queries, holding for {hold_seconds}s...")
threads = []
for i in range(num_connections):
    t = threading.Thread(target=run_query, args=(i,), daemon=True)
    t.start()
    threads.append(t)
    time.sleep(0.05)

print(f"All {num_connections} threads launched. Connected: {connected}, Errors: {errors}. Holding...")

for t in threads:
    t.join()

print(f"Done. Connected: {connected}, Errors: {errors}")
PYEOF

# =====================================================
log "=========================================="
log "MYSQLD-EXPORTER MAX PRESSURE TEST"
log "  POD: $POD"
log "  Hold time: ${HOLD_SECONDS}s per phase"
log "=========================================="

echo "timestamp,label,rss_kb,hwm_kb,cgroup_bytes" > "$MEMORY_CSV"

INITIAL_RESTARTS=$(exporter_restarts)
log "Exporter restarts before test: ${INITIAL_RESTARTS:-0}"
snapshot "baseline"

# ── Phase 1: Baseline (2 min) ──
log "PHASE 1: Baseline — no load, normal scrape (2 min)"
for i in $(seq 1 12); do
  scrape_and_measure
  sleep 10
  snapshot "baseline_${i}"
done

# ── Helper: run a phase ──
run_phase() {
  local phase_name="$1"
  local num_conn="$2"
  local query_kb="$3"
  local total_mb=$(( num_conn * query_kb / 1024 ))
  local scrape_interval="${4:-3}"

  log "──────────────────────────────────────────"
  log "PHASE: $phase_name"
  log "  Connections: $num_conn"
  log "  Query size:  ${query_kb} KB"
  log "  Processlist: ~${total_mb} MB"
  log "  Scrape interval: ${scrape_interval}s"
  log "──────────────────────────────────────────"

  snapshot "before_${phase_name}"

  python3 /tmp/exporter_load.py "$num_conn" "$query_kb" "$HOLD_SECONDS" 2>&1 | tee -a "$LOG" &
  LOAD_PID=$!

  sleep 20

  local scrape_count=$(( (HOLD_SECONDS - 30) / scrape_interval ))
  [[ $scrape_count -gt 40 ]] && scrape_count=40

  for i in $(seq 1 "$scrape_count"); do
    scrape_and_measure
    snapshot "${phase_name}_scrape_${i}"
    sleep "$scrape_interval"

    CUR_RESTARTS=$(exporter_restarts)
    if [[ "${CUR_RESTARTS:-0}" != "${INITIAL_RESTARTS:-0}" ]]; then
      log "*** EXPORTER OOM DETECTED! Restarts: ${INITIAL_RESTARTS} -> ${CUR_RESTARTS} ***"
      wait $LOAD_PID 2>/dev/null
      snapshot "${phase_name}_after_oom"
      return 1
    fi
  done

  wait $LOAD_PID 2>/dev/null
  snapshot "after_${phase_name}"

  log "Cooldown 60s — watching GC release..."
  for i in $(seq 1 6); do
    sleep 10
    snapshot "${phase_name}_cooldown_${i}"
  done

  return 0
}

# ── Phase 2: Warmup — 100 conn x 10KB = 1 MB ──
run_phase "warmup_1MB" 100 10 5
WARMUP_OK=$?

# ── Phase 3: Medium — 200 conn x 50KB = 10 MB ──
if [[ $WARMUP_OK -eq 0 ]]; then
  run_phase "medium_10MB" 200 50 3
  MEDIUM_OK=$?
else
  log "SKIPPING remaining phases — OOM already detected"
  MEDIUM_OK=1
fi

# ── Phase 4: High — 300 conn x 100KB = 30 MB ──
if [[ ${MEDIUM_OK:-1} -eq 0 ]]; then
  run_phase "high_30MB" 300 100 3
  HIGH_OK=$?
else
  HIGH_OK=1
fi

# ── Phase 5: Extreme — 200 conn x 500KB = 100 MB ──
if [[ ${HIGH_OK:-1} -eq 0 ]]; then
  run_phase "extreme_100MB" 200 500 2
  EXTREME_OK=$?
else
  EXTREME_OK=1
fi

# ── Phase 6: Max — 100 conn x 1MB = 100 MB ──
if [[ ${EXTREME_OK:-1} -eq 0 ]]; then
  run_phase "max_100MB_1M" 100 1024 2
  MAX_OK=$?
else
  MAX_OK=1
fi

# ── Phase 7: Final cooldown (2 min) ──
log "PHASE 7: Final cooldown (2 min)"
for i in $(seq 1 12); do
  sleep 10
  snapshot "final_cooldown_${i}"
done

# ── Summary ──
FINAL_RESTARTS=$(exporter_restarts)
log "=========================================="
log "EXPERIMENT COMPLETE"
log "  Exporter restarts before: ${INITIAL_RESTARTS:-0}"
log "  Exporter restarts after:  ${FINAL_RESTARTS:-0}"
if [[ "${FINAL_RESTARTS:-0}" != "${INITIAL_RESTARTS:-0}" ]]; then
  log "  >>> EXPORTER OOM KILL DETECTED <<<"
  kubectl --kubeconfig "$KUBECONFIG" -n "$NS" get events --sort-by=.lastTimestamp 2>/dev/null \
    | grep -i -E "oom|kill|exporter|BackOff" | tail -10
else
  log "  No OOM — exporter survived all phases"
fi
log "  Memory CSV: $MEMORY_CSV"
log "  Experiment log: $LOG"
log "=========================================="

python3 -c "
import csv
from collections import defaultdict

print()
print('Exporter memory summary by phase:')
print(f'{\"Phase\":<35} {\"RSS (MiB)\":>12} {\"HWM (MiB)\":>12} {\"cgroup (MiB)\":>14}')
print('=' * 77)

data = defaultdict(list)
with open('$MEMORY_CSV') as f:
    for row in csv.DictReader(f):
        phase = row['label'].rsplit('_', 1)[0] if '_' in row['label'] else row['label']
        rss = int(row['rss_kb']) / 1024
        hwm = int(row['hwm_kb']) / 1024
        cg = int(row['cgroup_bytes']) / 1048576
        data[phase].append((rss, hwm, cg))

for phase, samples in data.items():
    max_rss = max(s[0] for s in samples)
    max_hwm = max(s[1] for s in samples)
    max_cg = max(s[2] for s in samples)
    print(f'{phase:<35} {max_rss:>12.1f} {max_hwm:>12.1f} {max_cg:>14.1f}')

print()
overall_hwm = max(int(row['hwm_kb']) for row in csv.DictReader(open('$MEMORY_CSV'))) / 1024
print(f'Overall peak VmHWM: {overall_hwm:.1f} MiB')
print(f'Current limit:      256 MiB')
print(f'Utilization:        {100*overall_hwm/256:.1f}%')
" 2>&1 | tee -a "$LOG"
