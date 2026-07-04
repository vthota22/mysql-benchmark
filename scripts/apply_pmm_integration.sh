#!/usr/bin/env bash
# Enable PMM client on the Advanced Edition Percona cluster (secrets + CR patch + rollout).
# Idempotent: skips when spec.pmm.enabled is already true on the CR.
#
# Usage:
#   ./scripts/apply_pmm_integration.sh
#   PMM_APPLY_BEFORE_FAILOVER=1 ./scripts/apply_pmm_integration.sh
#
# Requires in benchmark.conf (when applying):
#   ADVANCED_K8S_NAMESPACE, ADVANCED_PSMYSQL_CR_NAME, ADVANCED_KUBECONFIG_PATH
#   PMM_SERVER_HOST, PMM_SERVER_TOKEN
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${BENCHMARK_CONF:-${SCRIPT_DIR}/../benchmark.conf}"

# shellcheck source=lib/failover_common.sh
source "${SCRIPT_DIR}/../lib/failover_common.sh"
load_benchmark_config "${CONFIG}"
failover_defaults

# Standalone helper always attempts apply when PMM is not yet enabled.
PMM_APPLY_BEFORE_FAILOVER=1
ensure_pmm_integration ""
