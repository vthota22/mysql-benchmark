#!/bin/bash
# Reproduce slow-log-tailer OOM by firing a single massive INSERT
# whose slow log entry exceeds the 32 MiB cgroup limit.
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

MYSQL_CMD="mysql -h $MYSQL_HOST -P $MYSQL_PORT -u $MYSQL_USER -p$MYSQL_PASSWORD --ssl-mode=REQUIRED $MYSQL_DB"

log() { echo "[$(date -u +%FT%TZ)] $*"; }

snapshot() {
  local label="$1"
  log "SNAPSHOT: $label"
  local proc
  proc=$(kubectl --kubeconfig "$KUBECONFIG" -n "$NS" exec "$POD" -c slow-log-tailer -- \
    sh -c 'grep -E "VmRSS|VmHWM|VmSize" /proc/1/status 2>/dev/null' 2>/dev/null)
  echo "  $proc"
  local cg
  cg=$(kubectl --kubeconfig "$KUBECONFIG" -n "$NS" exec "$POD" -c slow-log-tailer -- \
    sh -c 'cat /sys/fs/cgroup/memory.current 2>/dev/null || echo -1' 2>/dev/null | tr -d '[:space:]')
  local mib=$(( cg / 1048576 ))
  log "  cgroup_memory: ${cg} bytes (${mib} MiB)"
}

log "=========================================="
log "SLOW-LOG-TAILER OOM REPRODUCTION TEST"
log "=========================================="

# Create test table
log "Creating test table..."
$MYSQL_CMD -e "DROP TABLE IF EXISTS oom_test; CREATE TABLE oom_test (id INT AUTO_INCREMENT PRIMARY KEY, data LONGTEXT) ENGINE=InnoDB;" 2>&1

snapshot "before_big_insert"

# Generate a ~25 MB INSERT using python
log "Building ~25 MB INSERT statement..."
QUERY_FILE="/tmp/big_insert.sql"
python3 -c "
n = 25000
val = 'X' * 1000
parts = []
for i in range(n):
    parts.append(\"('\" + val + \"')\")
sql = 'INSERT INTO oom_test (data) VALUES ' + ','.join(parts) + ';'
with open('$QUERY_FILE', 'w') as f:
    f.write(sql)
print(f'Wrote {len(sql)} bytes ({len(sql)//1048576} MiB)')
"

log "Query file ready: $(ls -lh $QUERY_FILE | awk '{print $5}')"

log "Firing the big INSERT..."
$MYSQL_CMD < "$QUERY_FILE" 2>&1 &
INSERT_PID=$!

# Monitor tailer memory while INSERT runs and slow log is written
for i in $(seq 1 30); do
  sleep 2
  snapshot "during_insert_${i}"
  if ! kill -0 $INSERT_PID 2>/dev/null; then
    log "INSERT process finished"
    break
  fi
done
wait $INSERT_PID 2>/dev/null
INSERT_RC=$?
log "INSERT exit code: $INSERT_RC"

# Give slow log time to be written and tailer to process it
log "Waiting for tailer to process the slow log entry..."
for i in $(seq 1 10); do
  sleep 3
  snapshot "after_insert_${i}"
done

# Check if tailer is still alive
log "Checking if slow-log-tailer is still running..."
kubectl --kubeconfig "$KUBECONFIG" -n "$NS" exec "$POD" -c slow-log-tailer -- \
  sh -c 'echo "PID 1 status:"; cat /proc/1/status | head -5' 2>/dev/null \
  && log "Tailer is ALIVE" || log "Tailer may be DEAD or restarted"

# Check container restarts
log "Container restart count:"
kubectl --kubeconfig "$KUBECONFIG" -n "$NS" get pod "$POD" \
  -o jsonpath='{range .status.containerStatuses[*]}{.name}: restarts={.restartCount}{"\n"}{end}' 2>/dev/null

# Check for OOM events
log "Recent events:"
kubectl --kubeconfig "$KUBECONFIG" -n "$NS" get events --sort-by=.lastTimestamp 2>/dev/null \
  | grep -i -E "oom|kill|slow-log|OOMKill" | tail -10

# Cleanup
log "Cleaning up..."
$MYSQL_CMD -e "DROP TABLE IF EXISTS oom_test;" 2>&1
rm -f "$QUERY_FILE"

log "=========================================="
log "TEST COMPLETE"
log "=========================================="
