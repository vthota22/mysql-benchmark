#!/usr/bin/env bash
# Upgrade the Percona Server MySQL Operator on a DigitalOcean managed cluster.
#
# Fetches kubeconfig via perconactl, then applies CRDs, RBAC, operator deployment,
# and patches the PerconaServerMySQL CR crVersion. Waits for rollout and verifies.
#
# Edit the configuration block below, then run:
#   ./upgrade_percona_operator.sh
set -euo pipefail

# =============================================================================
# Configuration — edit these values before running
# =============================================================================
USER_ID="38711157"
CLUSTER_UUID="f73eea6b-d66e-4358-a27d-ca780c5befa3"
REGION="nyc3"
ENVIRONMENT="production"

NAMESPACE="percona"
OPERATOR_VERSION="1.2.0"

CLUSTER_NAME=""  # PerconaServerMySQL CR name (auto-detected if empty)
ROLLOUT_TIMEOUT="5m"
# =============================================================================

GITHUB_BASE="https://raw.githubusercontent.com/percona/percona-server-mysql-operator"

log() {
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "[${ts}] $*"
}

die() {
  log "ERROR: $*"
  exit 1
}

require_cmd() {
  local cmd="${1}"
  command -v "${cmd}" >/dev/null 2>&1 || die "${cmd} not found in PATH"
}

KUBECONFIG_FILE=""

kubectl_ns() {
  kubectl --kubeconfig="${KUBECONFIG_FILE}" --namespace="${NAMESPACE}" "$@"
}

auto_detect_cluster_name() {
  local name
  name="$(kubectl_ns get ps -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "${name}" ]] || die "CLUSTER_NAME is empty and no PerconaServerMySQL CR found in namespace ${NAMESPACE}"
  CLUSTER_NAME="${name}"
  log "Auto-detected cluster name: ${CLUSTER_NAME}"
}

fetch_kubeconfig() {
  require_cmd perconactl

  local perconactl_out
  log "Fetching kubeconfig (user=${USER_ID} cluster=${CLUSTER_UUID} region=${REGION} env=${ENVIRONMENT})"
  if ! perconactl_out="$(perconactl cluster kubeconfig \
    --user-id="${USER_ID}" \
    --cluster-uuid="${CLUSTER_UUID}" \
    -r "${REGION}" \
    -e "${ENVIRONMENT}" 2>&1)"; then
    die "perconactl cluster kubeconfig failed: ${perconactl_out}"
  fi

  KUBECONFIG_FILE="$(printf '%s\n' "${perconactl_out}" | sed -n 's/.*KUBECONFIG=\(.*\)/\1/p' | tail -1 | tr -d '[:space:]')"
  [[ -n "${KUBECONFIG_FILE}" ]] || die "could not parse kubeconfig path from perconactl output"
  [[ -f "${KUBECONFIG_FILE}" ]] || die "perconactl kubeconfig file not found: ${KUBECONFIG_FILE}"
  grep -q '^apiVersion:' "${KUBECONFIG_FILE}" || die "invalid kubeconfig at ${KUBECONFIG_FILE}"

  export KUBECONFIG="${KUBECONFIG_FILE}"
  log "Using kubeconfig: ${KUBECONFIG_FILE}"

  log "Verifying cluster connectivity"
  kubectl --kubeconfig="${KUBECONFIG_FILE}" cluster-info >/dev/null \
    || die "kubectl cluster-info failed with fetched kubeconfig"
}

show_current_state() {
  log "=== Current state ==="

  local operator_image
  operator_image="$(kubectl_ns get deploy percona-server-mysql-operator \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "not found")"
  log "Operator image: ${operator_image}"

  log "Cluster CRs:"
  kubectl_ns get ps \
    -o custom-columns='NAME:.metadata.name,CR_VERSION:.spec.crVersion,STATUS:.status.state' 2>/dev/null \
    || log "  (no PS clusters found)"

  log "Operator pod:"
  kubectl_ns get pods -l app.kubernetes.io/name=percona-server-mysql-operator \
    --no-headers 2>/dev/null || log "  (not found)"
}

step_update_crds() {
  local url="${GITHUB_BASE}/v${OPERATOR_VERSION}/deploy/crd.yaml"
  log "Step 1/5: Updating CRDs from ${url}"
  kubectl apply --server-side --force-conflicts -f "${url}" \
    || die "CRD apply failed"
  log "CRDs updated"
}

step_update_rbac() {
  local url="${GITHUB_BASE}/v${OPERATOR_VERSION}/deploy/rbac.yaml"
  log "Step 2/5: Updating RBAC from ${url}"
  kubectl apply --server-side --force-conflicts -f "${url}" -n "${NAMESPACE}" \
    || die "RBAC apply failed"
  log "RBAC updated"
}

step_update_operator() {
  local url="${GITHUB_BASE}/v${OPERATOR_VERSION}/deploy/operator.yaml"
  log "Step 3/5: Updating operator deployment from ${url}"
  kubectl apply --server-side --force-conflicts -f "${url}" -n "${NAMESPACE}" \
    || die "operator deployment apply failed"
  log "Operator deployment updated"

  log "Waiting for operator rollout..."
  kubectl_ns rollout status deployment/percona-server-mysql-operator --timeout="${ROLLOUT_TIMEOUT}" \
    || die "operator rollout did not complete within ${ROLLOUT_TIMEOUT}"
  log "Operator rollout complete"
}

step_update_cr_version() {
  local current_cr_version
  current_cr_version="$(kubectl_ns get ps "${CLUSTER_NAME}" \
    -o jsonpath='{.spec.crVersion}' 2>/dev/null || echo "")"

  if [[ "${current_cr_version}" == "${OPERATOR_VERSION}" ]]; then
    log "Step 4/5: crVersion already ${OPERATOR_VERSION} — no patch needed"
    return
  fi

  log "Step 4/5: Patching crVersion ${current_cr_version} -> ${OPERATOR_VERSION} on ${CLUSTER_NAME}"
  kubectl_ns patch ps "${CLUSTER_NAME}" --type merge \
    -p "{\"spec\":{\"crVersion\":\"${OPERATOR_VERSION}\"}}" \
    || die "crVersion patch failed"
  log "crVersion patched to ${OPERATOR_VERSION}"
}

step_verify() {
  log "Step 5/5: Verifying upgrade"

  local operator_image
  operator_image="$(kubectl_ns get deploy percona-server-mysql-operator \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "?")"
  log "Operator image: ${operator_image}"

  if [[ "${operator_image}" != *":${OPERATOR_VERSION}" ]]; then
    log "WARNING: operator image does not match target version ${OPERATOR_VERSION}"
  fi

  log "Operator pod status:"
  kubectl_ns get pods -l app.kubernetes.io/name=percona-server-mysql-operator \
    --no-headers 2>/dev/null || true

  log "Operator env vars (checking for required 1.2.0+ vars):"
  local env_vars
  env_vars="$(kubectl_ns get deploy percona-server-mysql-operator \
    -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}{"\n"}{end}' 2>/dev/null || true)"

  local missing=0
  for required_var in POD_NAME POD_NAMESPACE MAX_CONCURRENT_RECONCILES; do
    if echo "${env_vars}" | grep -q "^${required_var}$"; then
      log "  ${required_var}: present"
    else
      log "  ${required_var}: MISSING"
      missing=1
    fi
  done
  if [[ "${missing}" -eq 1 ]]; then
    log "WARNING: some required env vars are missing — operator may crash"
  fi

  log "Cluster CRs after upgrade:"
  kubectl_ns get ps \
    -o custom-columns='NAME:.metadata.name,CR_VERSION:.spec.crVersion,STATUS:.status.state' 2>/dev/null \
    || true

  log "Recent operator logs:"
  kubectl_ns logs deploy/percona-server-mysql-operator --tail=10 2>/dev/null || true
}

main() {
  require_cmd kubectl

  [[ -n "${USER_ID}" ]] || die "USER_ID is required"
  [[ -n "${CLUSTER_UUID}" ]] || die "CLUSTER_UUID is required"
  [[ -n "${REGION}" ]] || die "REGION is required"
  [[ -n "${ENVIRONMENT}" ]] || die "ENVIRONMENT is required"
  [[ -n "${OPERATOR_VERSION}" ]] || die "OPERATOR_VERSION is required"

  log "=== Percona Operator Upgrade ==="
  log "Cluster UUID: ${CLUSTER_UUID}"
  log "Target version: ${OPERATOR_VERSION}"
  log "Namespace: ${NAMESPACE}"

  fetch_kubeconfig

  if [[ -z "${CLUSTER_NAME}" ]]; then
    auto_detect_cluster_name
  fi

  show_current_state

  log ""
  log "=== Starting upgrade to ${OPERATOR_VERSION} ==="

  step_update_crds
  step_update_rbac
  step_update_operator
  step_update_cr_version
  step_verify

  log ""
  log "=== Upgrade complete ==="
  log "Operator: percona/percona-server-mysql-operator:${OPERATOR_VERSION}"
  log "Cluster:  ${CLUSTER_NAME} (crVersion=${OPERATOR_VERSION})"
}

main "$@"
