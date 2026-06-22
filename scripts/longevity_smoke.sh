#!/usr/bin/env bash
# 5-minute longevity smoke test (no prepare, short warmup)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="${SCRIPT_DIR}/sysbench-1.1/bin:${PATH}"
export BENCHMARK_CONF="${BENCHMARK_CONF:-${SCRIPT_DIR}/benchmark.conf}"

export SKIP_PREPARE=1
export LONGEVITY_DURATION_SEC=300
export LONGEVITY_WARMUP_SEC=30
export LONGEVITY_REPORT_INTERVAL=10
export LONGEVITY_THREADS="${LONGEVITY_THREADS:-8}"
export LONGEVITY_RUN_TPCC_CHECK=0
export LONGEVITY_GENERATE_GRAPHS=0
export LONGEVITY_MONITOR_PRIMARY=0

echo "=== Longevity smoke: 300s load, ${LONGEVITY_THREADS} threads ==="
exec "${SCRIPT_DIR}/run_longevity_benchmark.sh"
