#!/bin/bash
# Prove the theoretical maximum memory for mysqld-exporter.
#
# MySQL's information_schema.PROCESSLIST truncates query text at 65535 bytes.
# With max_connections=1000, the worst case processlist payload is:
#   1000 × 64 KB = 64 MB
# Plus Go runtime (~15 MiB) = ~80 MiB theoretical max.
#
# This test opens as many connections as possible, each running a 64KB+ query,
# then hammers /metrics to force the exporter to read the full processlist.
#
# Usage:
#   POD=<cluster>-mysql-0 KUBECONFIG=/root/.kube/config \
#     bash scripts/exporter_max_proof.sh [num_connections] [hold_seconds]
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

NUM_CONN="${1:-900}"
HOLD="${2:-120}"

LOG_DIR="${ROOT}/logs/exporter_max_proof"
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

processlist_stats() {
  mysql -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" -p"$MYSQL_PASSWORD" \
    --ssl-mode=REQUIRED "$MYSQL_DB" \
    -e "SELECT COUNT(*) AS active, SUM(LENGTH(INFO)) AS total_bytes, MAX(LENGTH(INFO)) AS max_len FROM information_schema.PROCESSLIST WHERE COMMAND != 'Sleep';" 2>/dev/null | tail -1
}

cat > /tmp/exporter_max_load.py << 'PYEOF'
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

num_connections = int(sys.argv[1]) if len(sys.argv) > 1 else 900
hold_seconds = int(sys.argv[2]) if len(sys.argv) > 2 else 120

padding = 'A' * 70000
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
            if connected % 100 == 0:
                print(f"  Connected: {connected}/{num_connections}", flush=True)
        cursor = conn.cursor()
        cursor.execute(query)
        cursor.fetchall()
        cursor.close()
        conn.close()
    except Exception as e:
        with lock:
            errors += 1
            if errors <= 20:
                print(f"  Conn {idx} error: {e}", file=sys.stderr, flush=True)

print(f"Opening {num_connections} connections with 70KB queries (truncated to 64KB in processlist), hold {hold_seconds}s...", flush=True)
threads = []
for i in range(num_connections):
    t = threading.Thread(target=run_query, args=(i,), daemon=True)
    t.start()
    threads.append(t)
    time.sleep(0.02)

print(f"All threads launched. Connected: {connected}, Errors: {errors}. Holding for {hold_seconds}s...", flush=True)

for t in threads:
    t.join()

print(f"Done. Total connected: {connected}, Errors: {errors}", flush=True)
PYEOF

# =====================================================
log "=========================================="
log "EXPORTER MAX MEMORY PROOF TEST"
log "  POD: $POD"
log "  Target connections: $NUM_CONN"
log "  Hold time: ${HOLD}s"
log "  Each query: 70KB (truncated to 64KB in PROCESSLIST)"
log "  Expected processlist: ${NUM_CONN} x 64KB = $((NUM_CONN * 64 / 1024)) MB"
log "=========================================="

echo "timestamp,label,rss_kb,hwm_kb,cgroup_bytes" > "$MEMORY_CSV"

INITIAL_RESTARTS=$(exporter_restarts)
log "Exporter restarts before: ${INITIAL_RESTARTS:-0}"

# ── Baseline ──
log "── BASELINE (60s) ──"
snapshot "baseline"
for i in $(seq 1 6); do
  scrape_and_measure
  sleep 10
  snapshot "baseline_${i}"
done

# ── Open max connections ──
log "── OPENING ${NUM_CONN} CONNECTIONS ──"
snapshot "before_load"

python3 /tmp/exporter_max_load.py "$NUM_CONN" "$HOLD" 2>&1 | tee -a "$LOG" &
LOAD_PID=$!

log "Waiting 30s for connections to establish..."
sleep 30

log "Processlist stats: $(processlist_stats)"
snapshot "connections_established"

# ── Hammer /metrics while all connections are active ──
log "── RAPID SCRAPING (every 2s) ──"
for i in $(seq 1 40); do
  scrape_and_measure
  snapshot "max_load_scrape_${i}"
  sleep 2

  if (( i % 10 == 0 )); then
    log "Processlist stats: $(processlist_stats)"
  fi

  CUR_RESTARTS=$(exporter_restarts)
  if [[ "${CUR_RESTARTS:-0}" != "${INITIAL_RESTARTS:-0}" ]]; then
    log "*** EXPORTER OOM! Restarts: ${INITIAL_RESTARTS} -> ${CUR_RESTARTS} ***"
    break
  fi
done

wait $LOAD_PID 2>/dev/null
snapshot "after_load"

# ── Cooldown ──
log "── COOLDOWN (2 min) ──"
for i in $(seq 1 12); do
  sleep 10
  snapshot "cooldown_${i}"
done

# ── Results ──
FINAL_RESTARTS=$(exporter_restarts)
log "=========================================="
log "RESULTS"
log "  Restarts before: ${INITIAL_RESTARTS:-0}"
log "  Restarts after:  ${FINAL_RESTARTS:-0}"
if [[ "${FINAL_RESTARTS:-0}" != "${INITIAL_RESTARTS:-0}" ]]; then
  log "  >>> EXPORTER OOM DETECTED <<<"
else
  log "  No OOM — exporter survived"
fi
log "=========================================="

python3 -c "
import csv

print()
samples = []
with open('$MEMORY_CSV') as f:
    for row in csv.DictReader(f):
        samples.append(row)

print(f'Total samples: {len(samples)}')
print()
print(f'{\"Label\":<30} {\"RSS (MiB)\":>12} {\"HWM (MiB)\":>12} {\"cgroup (MiB)\":>14}')
print('=' * 72)
for row in samples:
    rss = int(row['rss_kb']) / 1024
    hwm = int(row['hwm_kb']) / 1024
    cg = int(row['cgroup_bytes']) / 1048576
    print(f'{row[\"label\"]:<30} {rss:>12.1f} {hwm:>12.1f} {cg:>14.1f}')

max_rss = max(int(r['rss_kb']) for r in samples) / 1024
max_hwm = max(int(r['hwm_kb']) for r in samples) / 1024
max_cg = max(int(r['cgroup_bytes']) for r in samples) / 1048576
print()
print(f'Peak RSS:    {max_rss:.1f} MiB')
print(f'Peak HWM:    {max_hwm:.1f} MiB')
print(f'Peak cgroup: {max_cg:.1f} MiB')
print(f'Limit:       256 MiB')
print(f'Utilization: {100*max_hwm/256:.1f}%')
" 2>&1 | tee -a "$LOG"
