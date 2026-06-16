#!/usr/bin/env bash
# Compare MySQL server settings between Standard and Advanced editions
#
# Usage:
#   cp benchmark.conf.example benchmark.conf  # fill in credentials
#   ./check_mysql_settings.sh
#
# Optional:
#   BENCHMARK_CONF=/path/to/benchmark.conf ./check_mysql_settings.sh
#   RESULTS_DIR=/tmp/settings_check ./check_mysql_settings.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${BENCHMARK_CONF:-${SCRIPT_DIR}/benchmark.conf}"
RESULTS_DIR="${RESULTS_DIR:-${SCRIPT_DIR}/results/settings_check_$(date +%Y%m%d_%H%M%S)}"

# shellcheck source=lib/benchmark_common.sh
source "${SCRIPT_DIR}/lib/benchmark_common.sh"
load_benchmark_config "${CONFIG}"

mkdir -p "${RESULTS_DIR}"

echo "=== MySQL Settings Check ==="
echo "Config:  ${CONFIG}"
echo "Results: ${RESULTS_DIR}"
echo ""

run_mysql_settings_check "${RESULTS_DIR}"

echo "Done."
echo "Report: ${RESULTS_DIR}/mysql_settings_comparison.txt"
