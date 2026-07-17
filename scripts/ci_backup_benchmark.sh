#!/usr/bin/env bash
# Orchestrate a backup benchmark on a remote droplet (STUB — exits 0 immediately).
#
# After merging backup-benchmarking/, replace this with a full clone of
# scripts/ci_failover_benchmark.sh wired to scripts/backup_run_ctl.sh.
#
# Usage:
#   ./scripts/ci_backup_benchmark.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FEATURE="${BENCHMARK_FEATURE:-backup}"
DROPLET_HOST="${BENCHMARK_DROPLET_HOST:-}"
DROPLET_NAME="${BENCHMARK_DROPLET_NAME:-}"
REMOTE_REPO="${BENCHMARK_REMOTE_REPO:-/root/mysql-benchmark}"
ARTIFACTS_DIR="${CI_ARTIFACTS_DIR:-${REPO_ROOT}/ci-artifacts}"

echo "=== CI ${FEATURE} benchmark (STUB) ==="
echo "  droplet_name=${DROPLET_NAME:-}"
echo "  droplet_host=${DROPLET_HOST:-}"
echo "  remote_repo=${REMOTE_REPO}"
echo "  artifacts_dir=${ARTIFACTS_DIR}"
echo ""
echo "Stub mode: no remote SSH / harness yet. Exiting 0 immediately."
echo "Replace this script after merging backup-benchmarking/."
echo ""

mkdir -p "${ARTIFACTS_DIR}/diagnostics"
{
  echo "feature=${FEATURE}"
  echo "stub=1"
  echo "droplet_name=${DROPLET_NAME:-}"
  echo "droplet_host=${DROPLET_HOST:-}"
  echo "reason=backup harness not merged — stub no-op success"
  echo "finished_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "${ARTIFACTS_DIR}/diagnostics/stub_status.env"

echo "Wrote ${ARTIFACTS_DIR}/diagnostics/stub_status.env"
exit 0
