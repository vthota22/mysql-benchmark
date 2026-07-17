#!/usr/bin/env bash
# Droplet-side helper for backup benchmarks (STUB).
# After merging backup-benchmarking/, wire this to backup-benchmarking/run_benchmark.sh
# the same way scripts/failover_run_ctl.sh wraps run_failover_benchmark.sh.
#
# Usage: $0 {status|start|log [lines]|list [limit]}
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FEATURE_DIR="${REPO_ROOT}/backup-benchmarking"
LOCK_FILE="${FEATURE_DIR}/results/.backup_run.lock"
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
      echo "note=backup harness not present yet (merge backup-benchmarking/)"
      exit 0
    fi
    echo "ERROR: backup_run_ctl status not implemented — replace stub after merge" >&2
    exit 1
    ;;
  start)
    if [[ ! -x "${HARNESS}" ]]; then
      echo "ERROR: missing ${HARNESS} — merge backup-benchmarking/ first" >&2
      exit 1
    fi
    echo "ERROR: backup_run_ctl start not implemented — replace stub after merge" >&2
    echo "  expected: start ${HARNESS} with conf=${CONF}, write ${LOCK_FILE}" >&2
    exit 1
    ;;
  log|list)
    echo "ERROR: backup_run_ctl ${cmd} not implemented — replace stub after merge" >&2
    exit 1
    ;;
  *)
    _usage
    ;;
esac
