#!/usr/bin/env bash
# Generate TPS/QPS/error graphs from an existing failover benchmark run.
#
# Usage:
#   ./generate_failover_graphs.sh results/failover_<timestamp>/advanced
#   ./generate_failover_graphs.sh results/failover_<timestamp>   # all editions + comparison
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="${1:?Usage: $0 <edition_dir|failover_results_root>}"

if [[ ! -d "${TARGET}" ]]; then
  echo "ERROR: not a directory: ${TARGET}" >&2
  exit 1
fi

python3 "${SCRIPT_DIR}/scripts/generate_failover_graphs.py" "${TARGET}"
