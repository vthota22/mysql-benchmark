#!/usr/bin/env bash
# Periodically sample cgroup memory usage for MySQL sidecar containers.
#
# Reads /sys/fs/cgroup/memory.current (cgroup v2) or
# /sys/fs/cgroup/memory/memory.usage_in_bytes (cgroup v1) via kubectl exec.
#
# Usage:
#   ./scripts/sample_sidecar_memory.sh start [phase_label]
#   ./scripts/sample_sidecar_memory.sh stop
#   ./scripts/sample_sidecar_memory.sh status
#   ./scripts/sample_sidecar_memory.sh set-phase <label>
#
# Environment:
#   KUBECONFIG       path to kubeconfig (required)
#   K8S_NAMESPACE    default "percona"
#   SAMPLE_INTERVAL  seconds between samples (default 30)
#   CSV_FILE         output CSV path (default logs/sidecar_memory.csv)
set -uo pipefail

ROOT="${ROOT:-/root/mysql-benchmark}"
KUBECONFIG="${KUBECONFIG:-/root/.kube/config_4_16}"
NS="${K8S_NAMESPACE:-percona}"
INTERVAL="${SAMPLE_INTERVAL:-30}"
CSV_FILE="${CSV_FILE:-${ROOT}/logs/sidecar_memory.csv}"
PIDFILE="${ROOT}/logs/sidecar_sampler.pid"
PHASE_FILE="${ROOT}/logs/sidecar_sampler_phase.txt"

CONTAINERS=(mysql mysqld-exporter slow-log-tailer do-agent)
POD_PREFIX="${POD_PREFIX:-mysql}"
PODS=("${POD_PREFIX}-0" "${POD_PREFIX}-1" "${POD_PREFIX}-2")

export KUBECONFIG

_read_cgroup_memory() {
  local pod="$1" container="$2"
  local val
  # do-agent is a scratch container with no shell/cat — skip it
  if [[ "$container" == "do-agent" ]]; then
    echo "-1"
    return
  fi
  val=$(kubectl -n "$NS" exec "$pod" -c "$container" -- \
    sh -c 'cat /sys/fs/cgroup/memory.current 2>/dev/null || cat /sys/fs/cgroup/memory/memory.usage_in_bytes 2>/dev/null || echo -1' \
    2>/dev/null) || val="-1"
  echo "${val}" | tr -d '[:space:]'
}

_sample_once() {
  local ts phase
  ts=$(date -u +%FT%TZ)
  phase="unknown"
  [[ -f "$PHASE_FILE" ]] && phase=$(cat "$PHASE_FILE" 2>/dev/null || echo "unknown")

  for pod in "${PODS[@]}"; do
    for container in "${CONTAINERS[@]}"; do
      local mem
      mem=$(_read_cgroup_memory "$pod" "$container")
      echo "${ts},${pod},${container},${mem},${phase}" >> "$CSV_FILE"
    done
  done
}

_run_loop() {
  while true; do
    _sample_once
    sleep "$INTERVAL"
  done
}

start() {
  if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "already running pid=$(cat "$PIDFILE")"
    return 0
  fi

  mkdir -p "$(dirname "$CSV_FILE")" "$(dirname "$PIDFILE")"

  local phase="${1:-idle}"
  echo "$phase" > "$PHASE_FILE"

  if [[ ! -f "$CSV_FILE" ]]; then
    echo "timestamp,pod,container,memory_bytes,phase" > "$CSV_FILE"
  fi

  echo "[$(date -u +%FT%TZ)] Starting sidecar memory sampler (interval=${INTERVAL}s, phase=${phase})"
  nohup bash "$0" _loop >> "${ROOT}/logs/sidecar_sampler.log" 2>&1 </dev/null &
  echo $! > "$PIDFILE"
  echo "started pid=$(cat "$PIDFILE") csv=$CSV_FILE"
}

stop() {
  if [[ -f "$PIDFILE" ]]; then
    kill "$(cat "$PIDFILE")" 2>/dev/null || true
    rm -f "$PIDFILE"
  fi
  echo "stopped"
}

status() {
  if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "RUNNING pid=$(cat "$PIDFILE")"
  else
    echo "NOT running"
  fi
  echo "phase: $(cat "$PHASE_FILE" 2>/dev/null || echo 'unset')"
  echo "csv: $CSV_FILE"
  if [[ -f "$CSV_FILE" ]]; then
    local lines
    lines=$(wc -l < "$CSV_FILE")
    echo "samples: $((lines - 1))"
    echo "--- last 5 samples ---"
    tail -5 "$CSV_FILE"
  fi
}

set_phase() {
  local label="${1:?phase label required}"
  echo "$label" > "$PHASE_FILE"
  echo "phase set to: $label"
}

case "${1:-status}" in
  start)     shift; start "${1:-idle}" ;;
  stop)      stop ;;
  status)    status ;;
  set-phase) shift; set_phase "$@" ;;
  _loop)     _run_loop ;;
  *)         echo "usage: $0 start [phase]|stop|status|set-phase <label>" ;;
esac
