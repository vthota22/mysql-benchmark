#!/usr/bin/env bash
# Generate TPS/QPS graphs (PNG) and interactive HTML report from an existing failover run.
#
# Usage:
#   ./generate_failover_graphs.sh results/failover_<timestamp>/advanced/mixed
#   ./generate_failover_graphs.sh results/failover_<timestamp>/advanced/write_only
#   ./generate_failover_graphs.sh results/failover_<timestamp>   # all editions/scenarios + comparison
#
# Options (pass through to Python):
#   ./generate_failover_graphs.sh --html-only results/failover_<timestamp>/advanced/mixed
#   ./generate_failover_graphs.sh --png-only  results/failover_<timestamp>
#
# Output:
#   Per-run:  <edition>/t<N>/<scenario>/graphs/failover_report.html
#   Combined (thread toggle): <edition>/graphs/failover_report.html
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 [--html-only|--png-only] <edition_dir|failover_results_root>" >&2
  exit 1
fi

TARGET="${@: -1}"
if [[ ! -d "${TARGET}" ]]; then
  echo "ERROR: not a directory: ${TARGET}" >&2
  exit 1
fi

python3 "${SCRIPT_DIR}/scripts/generate_failover_graphs.py" "$@"
