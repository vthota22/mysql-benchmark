#!/usr/bin/env bash
# Relax Percona mysql liveness/readiness probes so GR RECOVERING is not killed mid-rejoin.
#
# One-time (or rare) CR patch — persists until changed. Not re-applied each iteration unless
# MYSQL_PROBE_APPLY_BEFORE_FAILOVER=1 in benchmark.conf.
#
# Usage:
#   ./scripts/apply_mysql_probe_tuning.sh
#   MYSQL_LIVENESS_FAILURE_THRESHOLD=40 ./scripts/apply_mysql_probe_tuning.sh
#
# Requires: ADVANCED_K8S_NAMESPACE, ADVANCED_PSMYSQL_CR_NAME, ADVANCED_KUBECONFIG_PATH
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${BENCHMARK_CONF:-${SCRIPT_DIR}/../benchmark.conf}"

# shellcheck source=lib/failover_common.sh
source "${SCRIPT_DIR}/../lib/failover_common.sh"
load_benchmark_config "${CONFIG}"
failover_defaults

apply_mysql_probe_tuning ""
