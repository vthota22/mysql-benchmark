#!/usr/bin/env bash
# Generate HTML scaling report for a benchmark run directory.
#
# Usage:
#   ./generate_scaling_report.sh scaling-benchmarking/results/run_20260621_074113_advanced-s-4-16-200-1gb
#   ./generate_scaling_report.sh /path/to/run_dir -o /tmp/report.html
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV="${SCRIPT_DIR}/.venv"

if [[ ! -d "${VENV}" ]]; then
  python3 -m venv "${VENV}"
  "${VENV}/bin/pip" install -q -r "${SCRIPT_DIR}/requirements-report.txt"
fi

exec "${VENV}/bin/python" "${SCRIPT_DIR}/generate_report.py" "$@"
