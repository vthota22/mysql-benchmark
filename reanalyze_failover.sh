#!/usr/bin/env bash
# Recompute failover KPI / extended metrics from existing run artifacts (no sysbench re-run).
#
# Usage:
#   ./reanalyze_failover.sh results/failover_<timestamp>
#   ./reanalyze_failover.sh results/failover_<timestamp>/advanced/mixed
#
# Requires per scenario: failover_timeseries.csv (and primary_monitor.tsv for monitor KPIs).
# Refreshes failover_parsed.env when sysbench_run.log is present.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${BENCHMARK_CONF:-${SCRIPT_DIR}/benchmark.conf}"
TARGET="${1:?Usage: $0 <failover_results_root|scenario_dir>}"

# shellcheck source=lib/failover_common.sh
source "${SCRIPT_DIR}/lib/failover_common.sh"
load_benchmark_config "${CONFIG}"
failover_defaults

if [[ -f "${TARGET}/failover_timeseries.csv" ]]; then
  reanalyze_failover_scenario "${TARGET}"
  parent="$(cd "$(dirname "${TARGET}")" && pwd)"
  while [[ "${parent}" != "/" && "${parent}" != "${SCRIPT_DIR}/results" ]]; do
    if [[ -f "${parent}/failover_kpi.csv" || -d "${parent}/advanced" || -d "${parent}/standard" ]]; then
      write_failover_comparison "${parent}"
      python3 "${SCRIPT_DIR}/scripts/generate_failover_graphs.py" --html-only "${parent}"
      echo "Updated rollup + HTML under ${parent}"
      break
    fi
    parent="$(dirname "${parent}")"
  done
else
  reanalyze_failover_results "${TARGET}"
fi
