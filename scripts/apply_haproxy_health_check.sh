#!/usr/bin/env bash
# Apply HAProxy backend health-check interval to the Advanced Edition Percona CR.
#
# Usage:
#   ./scripts/apply_haproxy_health_check.sh
#   HAPROXY_HEALTH_CHECK_INTERVAL_SEC=5 ./scripts/apply_haproxy_health_check.sh
#
# Requires in benchmark.conf:
#   ADVANCED_K8S_NAMESPACE, ADVANCED_PSMYSQL_CR_NAME, ADVANCED_KUBECONFIG_PATH
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${BENCHMARK_CONF:-${SCRIPT_DIR}/../benchmark.conf}"

# shellcheck source=lib/failover_common.sh
source "${SCRIPT_DIR}/../lib/failover_common.sh"
load_benchmark_config "${CONFIG}"
failover_defaults

apply_haproxy_health_check ""
