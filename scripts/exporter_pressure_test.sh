#!/bin/bash
# mysqld-exporter memory pressure test.
#
# Stresses the exporter by:
#   1. Opening many concurrent MySQL connections with large SQL queries
#   2. Hammering the /metrics endpoint with rapid scrapes
#   3. Monitoring exporter memory throughout
#
# The processlist collector holds ALL active query text in memory per scrape.
# Many connections with large queries = large memory during scrape.
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

LOG_DIR="${ROOT}/logs/exporter_pressure"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/experiment.log"
MEMORY_CSV="$LOG_DIR/memory_samples.csv"

log() { echo "[$(date -u +%FT%TZ)] $*" | tee -a "$LOG"; }

snapshot() {
  local label="$1"
  local proc cg mib scrape_ms
  proc=$(kubectl --kubeconfig "$KUBECONFIG" -n "$NS" exec "$POD" -c mysqld-exporter -- \
    sh -c 'grep -E "VmRSS|VmHWM" /proc/1/status 2>/dev/null' 2>/dev/null | tr '\n' ' ')
  cg=$(kubectl --kubeconfig "$KUBECONFIG" -n "$NS" exec "$POD" -c mysqld-exporter -- \
    sh -c 'cat /sys/fs/cgroup/memory.current 2>/dev/null' 2>/dev/null | tr -d '[:space:]')
  mib=$(( ${cg:-0} / 1048576 ))

  local rss_kb=$(echo "$proc" | grep -oP 'VmRSS:\s+\K[0-9]+')
  local hwm_kb=$(echo "$proc" | grep -oP 'VmHWM:\s+\K[0-9]+')
  log "[$label] RSS=${rss_kb}kB HWM=${hwm_kb}kB cgroup=${mib}MiB"
  echo "$(date -u +%FT%TZ),${label},${rss_kb:-0},${hwm_kb:-0},${cg:-0}" >> "$MEMORY_CSV"
}

scrape_and_measure() {
  kubectl --kubeconfig "$KUBECONFIG" -n "$NS" exec "$POD" -c mysqld-exporter -- \
    sh -c 'wget -qO /dev/null http://127.0.0.1:9104/metrics' 2>/dev/null
}

log "=========================================="
log "MYSQLD-EXPORTER MEMORY PRESSURE TEST"
log "=========================================="

echo "timestamp,label,rss_kb,hwm_kb,cgroup_bytes" > "$MEMORY_CSV"
snapshot "baseline"

# ── Phase 1: Baseline scrape pattern (2 min) ──
log "PHASE 1: Baseline - normal scrape load (2 min)"
for i in $(seq 1 12); do
  scrape_and_measure
  sleep 10
  snapshot "baseline_${i}"
done

# ── Phase 2: Many connections with large queries ──
# Create a python script that opens N connections with large queries
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
# Use SELECT SLEEP() with a large comment to pad the query text
query = f"SELECT /* {padding} */ SLEEP({hold_seconds})"

connections = []
threads = []
errors = 0

def run_query(idx):
    global errors
    try:
        conn = mysql.connector.connect(
            host=host, port=port, user=user, password=password,
            database=db, ssl_disabled=False, use_pure=True,
            connection_timeout=10
        )
        connections.append(conn)
        cursor = conn.cursor()
        cursor.execute(query)
        cursor.fetchall()
        cursor.close()
        conn.close()
    except Exception as e:
        errors += 1
        if errors <= 5:
            print(f"  Connection {idx} error: {e}", file=sys.stderr)

print(f"Opening {num_connections} connections with {query_size_kb}KB queries, holding for {hold_seconds}s...")
for i in range(num_connections):
    t = threading.Thread(target=run_query, args=(i,), daemon=True)
    t.start()
    threads.append(t)
    if (i + 1) % 50 == 0:
        print(f"  Launched {i+1}/{num_connections} connections")

print(f"All {num_connections} threads launched ({errors} errors so far). Holding...")

# Wait for threads to complete
for t in threads:
    t.join()

print(f"Done. Total errors: {errors}")
PYEOF

# Phase 2a: 100 connections, 10 KB query each (1 MB total in processlist)
log "PHASE 2a: 100 connections x 10KB query (hold 120s)"
snapshot "before_100conn"
python3 /tmp/exporter_load.py 100 10 120 2>&1 | tee -a "$LOG" &
LOAD_PID=$!
sleep 10

# Rapid scrapes while connections are active
for i in $(seq 1 10); do
  scrape_and_measure
  snapshot "100conn_scrape_${i}"
  sleep 5
done
wait $LOAD_PID 2>/dev/null
snapshot "after_100conn"
sleep 30
snapshot "100conn_settled"

# Phase 2b: 300 connections, 10 KB query each (3 MB total)
log "PHASE 2b: 300 connections x 10KB query (hold 120s)"
snapshot "before_300conn"
python3 /tmp/exporter_load.py 300 10 120 2>&1 | tee -a "$LOG" &
LOAD_PID=$!
sleep 15

for i in $(seq 1 10); do
  scrape_and_measure
  snapshot "300conn_scrape_${i}"
  sleep 5
done
wait $LOAD_PID 2>/dev/null
snapshot "after_300conn"
sleep 30
snapshot "300conn_settled"

# Phase 2c: 500 connections, 10 KB query each (5 MB total)
log "PHASE 2c: 500 connections x 10KB query (hold 120s)"
snapshot "before_500conn"
python3 /tmp/exporter_load.py 500 10 120 2>&1 | tee -a "$LOG" &
LOAD_PID=$!
sleep 15

for i in $(seq 1 10); do
  scrape_and_measure
  snapshot "500conn_scrape_${i}"
  sleep 5
done
wait $LOAD_PID 2>/dev/null
snapshot "after_500conn"
sleep 30
snapshot "500conn_settled"

# Phase 2d: 200 connections, 50 KB query each (10 MB total)
log "PHASE 2d: 200 connections x 50KB query (hold 120s)"
snapshot "before_200conn_50k"
python3 /tmp/exporter_load.py 200 50 120 2>&1 | tee -a "$LOG" &
LOAD_PID=$!
sleep 15

for i in $(seq 1 10); do
  scrape_and_measure
  snapshot "200conn50k_scrape_${i}"
  sleep 5
done
wait $LOAD_PID 2>/dev/null
snapshot "after_200conn_50k"
sleep 30
snapshot "200conn50k_settled"

# ── Phase 3: Rapid scraping under TPC-C load ──
log "PHASE 3: TPC-C load (200 TPS) + rapid scrapes (2 min)"
snapshot "before_tpcc"

# Start TPC-C if data exists
cd "$ROOT"

export TPCC_SCALE=100 TPCC_TABLES=1
TPCC_RATE=200 TPCC_THREADS=32 TPCC_TIME=120 TPCC_WARMUP=10 TPCC_REPORT_INTERVAL=10 \
  run_tpcc_command run > "$LOG_DIR/tpcc.log" 2>&1 &
TPCC_PID=$!
sleep 15

for i in $(seq 1 20); do
  scrape_and_measure
  snapshot "tpcc_scrape_${i}"
  sleep 5
done
wait $TPCC_PID 2>/dev/null
snapshot "after_tpcc"
sleep 30
snapshot "tpcc_settled"

# ── Summary ──
log "=========================================="
log "EXPERIMENT COMPLETE"
log "=========================================="

python3 -c "
import csv
print()
print('Exporter memory by phase:')
print(f'{\"Label\":<30} {\"RSS (MiB)\":>12} {\"HWM (MiB)\":>12} {\"cgroup (MiB)\":>14}')
print('-' * 72)
with open('$MEMORY_CSV') as f:
    for row in csv.DictReader(f):
        rss = int(row['rss_kb']) / 1024
        hwm = int(row['hwm_kb']) / 1024
        cg = int(row['cgroup_bytes']) / 1048576
        print(f'{row[\"label\"]:<30} {rss:>12.1f} {hwm:>12.1f} {cg:>14.1f}')
" 2>&1 | tee -a "$LOG"
