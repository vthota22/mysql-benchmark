#!/usr/bin/env bash
# Poll @@hostname and @@read_only every second during a failover benchmark.
#
# Usage:
#   monitor_mysql_primary.sh <results_dir>
#
# Stop with: kill $(cat <results_dir>/primary_monitor.pid)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${BENCHMARK_CONF:-${SCRIPT_DIR}/benchmark.conf}"
RESULTS_DIR="${1:?Usage: $0 <results_dir>}"

# shellcheck source=lib/failover_common.sh
source "${SCRIPT_DIR}/lib/failover_common.sh"
load_benchmark_config "${CONFIG}"

EDITION="${FAILOVER_EDITION:-${MONITOR_EDITION:-standard}}"
set_mysql_env_for_edition "${EDITION}"

mkdir -p "${RESULTS_DIR}"
start_primary_monitor "${RESULTS_DIR}"

echo "Monitoring ${EDITION} at ${MYSQL_HOST} — log: ${RESULTS_DIR}/primary_monitor.tsv"
wait "$(cat "${RESULTS_DIR}/primary_monitor.pid")"
