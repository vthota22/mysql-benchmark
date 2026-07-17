#!/usr/bin/env bash
# Droplet-side helper for scaling benchmarks (STUB).
# After merging scaling-benchmarking/, wire this to scaling-benchmarking/run_benchmark.sh
# the same way scripts/failover_run_ctl.sh wraps run_failover_benchmark.sh.
#
# Usage: $0 {status|start|log [lines]|list [limit]}
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FEATURE_DIR="${REPO_ROOT}/scaling-benchmarking"
LOCK_FILE="${FEATURE_DIR}/results/.scaling_run.lock"
HARNESS="${FEATURE_DIR}/run_benchmark.sh"
CONF="${BENCHMARK_CONF:-${FEATURE_DIR}/benchmark.conf}"

_usage() {
  echo "Usage: $0 {status|start|log [lines]|list [limit]}" >&2
  exit 1
}

cmd="${1:-}"
case "${cmd}" in
  status)
    if [[ ! -x "${HARNESS}" ]]; then
      echo "running=0"
      echo "pid="
      echo "results_dir="
      echo "completed=0"
      echo "stub=1"
      echo "note=scaling harness not present yet (merge scaling-benchmarking/)"
      exit 0
    fi
    echo "ERROR: scaling_run_ctl status not implemented — replace stub after merge" >&2
    exit 1
    ;;
  start)
    if [[ ! -x "${HARNESS}" ]]; then
      echo "ERROR: missing ${HARNESS} — merge scaling-benchmarking/ first" >&2
      exit 1
    fi
    echo "ERROR: scaling_run_ctl start not implemented — replace stub after merge" >&2
    echo "  expected: start ${HARNESS} with conf=${CONF}, write ${LOCK_FILE}" >&2
    exit 1
    ;;
  log|list)
    echo "ERROR: scaling_run_ctl ${cmd} not implemented — replace stub after merge" >&2
    exit 1
    ;;
  *)
    _usage
    ;;
esac
