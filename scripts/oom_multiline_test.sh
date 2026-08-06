#!/bin/bash
# Reproduce slow-log-tailer OOM with multi-line queries > 32 MiB each.
# Each INSERT has VALUES on separate lines so the slow log entry
# has thousands of lines, causing O(n^2) string concat in the tailer.
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

MYSQL_CMD="mysql -h $MYSQL_HOST -P $MYSQL_PORT -u $MYSQL_USER -p$MYSQL_PASSWORD --ssl-mode=REQUIRED --max-allowed-packet=64M $MYSQL_DB"

NUM_QUERIES="${1:-1000}"
TARGET_MB="${2:-35}"

log() { echo "[$(date -u +%FT%TZ)] $*"; }

snapshot() {
  local label="$1"
  local proc cg mib
  proc=$(kubectl --kubeconfig "$KUBECONFIG" -n "$NS" exec "$POD" -c slow-log-tailer -- \
    sh -c 'grep -E "VmRSS|VmHWM" /proc/1/status 2>/dev/null' 2>/dev/null | tr '\n' ' ')
  cg=$(kubectl --kubeconfig "$KUBECONFIG" -n "$NS" exec "$POD" -c slow-log-tailer -- \
    sh -c 'cat /sys/fs/cgroup/memory.current 2>/dev/null || echo -1' 2>/dev/null | tr -d '[:space:]')
  mib=$(( cg / 1048576 ))
  log "[$label] ${proc} | cgroup: ${mib} MiB"
}

restarts() {
  kubectl --kubeconfig "$KUBECONFIG" -n "$NS" get pod "$POD" \
    -o jsonpath='{.status.containerStatuses[?(@.name=="slow-log-tailer")].restartCount}' 2>/dev/null
}

log "=========================================="
log "MULTI-LINE OOM TEST"
log "  queries: $NUM_QUERIES x ~${TARGET_MB} MiB (multi-line)"
log "=========================================="

# Record initial restarts
INITIAL_RESTARTS=$(restarts)
log "slow-log-tailer restarts before test: $INITIAL_RESTARTS"

# Create table
log "Creating test table..."
$MYSQL_CMD -e "DROP TABLE IF EXISTS oom_test; CREATE TABLE oom_test (id INT AUTO_INCREMENT PRIMARY KEY, data TEXT) ENGINE=InnoDB;" 2>&1 | grep -v Warning

snapshot "baseline"

# Generate multi-line INSERT: one value per line, ~1400 bytes per line
# 35 MiB / 1400 bytes ≈ 26000 lines
log "Generating ${TARGET_MB} MiB multi-line INSERT file..."
QUERY_FILE="/tmp/multiline_insert.sql"
python3 << PYEOF
target_bytes = ${TARGET_MB} * 1048576
val = 'X' * 1300  # ~1300 char payload per row
with open('${QUERY_FILE}', 'w') as f:
    f.write('INSERT INTO oom_test (data) VALUES\n')
    written = 0
    row_num = 0
    while written < target_bytes:
        row_num += 1
        line = "('" + val + "')"
        if written + len(line) + 2 < target_bytes:
            line += ',\n'
        else:
            line += ';\n'
        f.write(line)
        written += len(line)
    print(f'Generated {row_num} rows, {written} bytes ({written//1048576} MiB), one value per line')
PYEOF

log "Query file: $(ls -lh $QUERY_FILE | awk '{print $5}')"
log "Line count: $(wc -l < $QUERY_FILE)"

# Fire queries one after another
for q in $(seq 1 $NUM_QUERIES); do
  log "--- Sending query $q of $NUM_QUERIES ---"
  snapshot "before_query_${q}"

  $MYSQL_CMD < "$QUERY_FILE" 2>&1 | grep -v Warning &
  INSERT_PID=$!

  # Monitor while INSERT runs
  while kill -0 $INSERT_PID 2>/dev/null; do
    sleep 3
    snapshot "during_q${q}"
    CUR_RESTARTS=$(restarts)
    if [[ "$CUR_RESTARTS" != "$INITIAL_RESTARTS" ]]; then
      log "*** OOM DETECTED! Restarts: $INITIAL_RESTARTS -> $CUR_RESTARTS ***"
    fi
  done
  wait $INSERT_PID 2>/dev/null
  log "Query $q finished (rc=$?)"

  # Brief wait for tailer to process, check for OOM
  sleep 3
  snapshot "after_q${q}"
  CUR_RESTARTS=$(restarts)
  if [[ "$CUR_RESTARTS" != "$INITIAL_RESTARTS" ]]; then
    log "*** OOM DETECTED after query $q! Restarts: $INITIAL_RESTARTS -> $CUR_RESTARTS ***"
    break
  fi
done

# Final check
FINAL_RESTARTS=$(restarts)
log "=========================================="
log "RESULTS"
log "  Restarts before: $INITIAL_RESTARTS"
log "  Restarts after:  $FINAL_RESTARTS"
if [[ "$FINAL_RESTARTS" != "$INITIAL_RESTARTS" ]]; then
  log "  >>> OOM KILL CONFIRMED <<<"
  kubectl --kubeconfig "$KUBECONFIG" -n "$NS" get events --sort-by=.lastTimestamp 2>/dev/null \
    | grep -i -E "oom|kill|slow-log|BackOff" | tail -10
else
  log "  No OOM — tailer survived"
fi
log "=========================================="

# Cleanup
$MYSQL_CMD -e "DROP TABLE IF EXISTS oom_test;" 2>&1 | grep -v Warning
rm -f "$QUERY_FILE"
