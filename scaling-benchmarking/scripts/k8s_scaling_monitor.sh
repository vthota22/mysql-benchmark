#!/usr/bin/env bash
# Background Kubernetes monitor for Percona MySQL scaling events.
#
# Tracks per poll cycle:
#   1. GR role: which pod is PRIMARY, which are SECONDARY
#   2. Pod state: phase (Running/Pending/etc), ready, GR member state (ONLINE/RECOVERING/ERROR)
#   3. DOKS node binding: which K8s worker node each pod runs on (detects node drain/migration)
#
# Outputs a single TSV file (k8s_monitor.tsv) and a human-readable log (k8s_monitor.log).
#
# Usage (standalone):
#   export KUBECONFIG=/path/to/kubeconfig
#   export K8S_NAMESPACE=percona
#   export PXC_CLUSTER_NAME=my-cluster   # optional, auto-detected
#   ./k8s_scaling_monitor.sh /path/to/output_dir [poll_interval_sec]
set -euo pipefail

OUTPUT_DIR="${1:?output directory required}"
POLL_INTERVAL="${2:-5}"

KUBECONFIG="${KUBECONFIG:?Set KUBECONFIG to the cluster kubeconfig path}"
export KUBECONFIG

NAMESPACE="${K8S_NAMESPACE:-mysql}"
CLUSTER_NAME="${PXC_CLUSTER_NAME:-}"
MYSQL_ROOT_SECRET="${PXC_MYSQL_ROOT_SECRET:-}"
MYSQL_ROOT_USER="${PXC_MYSQL_ROOT_USER:-root}"

CR_TYPE=""
MYSQL_CONTAINER=""
MYSQL_COMPONENT_LABEL=""

mkdir -p "${OUTPUT_DIR}"

TSV_FILE="${OUTPUT_DIR}/k8s_monitor.tsv"
MONITOR_LOG="${OUTPUT_DIR}/k8s_monitor.log"

: > "${MONITOR_LOG}"

CACHED_PASSWORD=""
PREVIOUS_PRIMARY=""
PREVIOUS_NODE_MAP=""

log() {
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "[${ts}] $*" >> "${MONITOR_LOG}"
  echo "[${ts}] $*" >&2
}

kubectl_ns() {
  kubectl --namespace="${NAMESPACE}" "$@"
}

auto_detect_cluster() {
  if [[ -n "${CLUSTER_NAME}" ]]; then
    if kubectl_ns get ps "${CLUSTER_NAME}" >/dev/null 2>&1; then
      CR_TYPE="ps"
    elif kubectl_ns get pxc "${CLUSTER_NAME}" >/dev/null 2>&1; then
      CR_TYPE="pxc"
    else
      log "ERROR: cluster ${CLUSTER_NAME} not found as ps or pxc in namespace ${NAMESPACE}"
      return 1
    fi
  else
    CLUSTER_NAME="$(kubectl_ns get ps -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [[ -n "${CLUSTER_NAME}" ]]; then
      CR_TYPE="ps"
    else
      CLUSTER_NAME="$(kubectl_ns get pxc -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
      if [[ -n "${CLUSTER_NAME}" ]]; then
        CR_TYPE="pxc"
      fi
    fi
  fi

  if [[ -z "${CLUSTER_NAME}" || -z "${CR_TYPE}" ]]; then
    log "ERROR: no Percona MySQL cluster found in namespace ${NAMESPACE}"
    return 1
  fi

  case "${CR_TYPE}" in
    ps)  MYSQL_CONTAINER="mysql";  MYSQL_COMPONENT_LABEL="database" ;;
    pxc) MYSQL_CONTAINER="pxc";    MYSQL_COMPONENT_LABEL="pxc" ;;
  esac

  log "detected CR_TYPE=${CR_TYPE} cluster=${CLUSTER_NAME} container=${MYSQL_CONTAINER}"
}

get_mysql_password() {
  if [[ -n "${CACHED_PASSWORD}" ]]; then
    echo "${CACHED_PASSWORD}"
    return
  fi
  if [[ -n "${PXC_MYSQL_ROOT_PASSWORD:-}" ]]; then
    CACHED_PASSWORD="${PXC_MYSQL_ROOT_PASSWORD}"
    echo "${CACHED_PASSWORD}"
    return
  fi
  local secret_name="${MYSQL_ROOT_SECRET}"
  if [[ -z "${secret_name}" ]]; then
    secret_name="${CLUSTER_NAME}-secrets"
  fi
  CACHED_PASSWORD="$(kubectl_ns get secret "${secret_name}" \
    -o jsonpath='{.data.root}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  echo "${CACHED_PASSWORD}"
}

mysql_in_pod() {
  local pod_name="${1:?pod required}" password="${2:?password required}"
  shift 2
  kubectl_ns exec "${pod_name}" -c "${MYSQL_CONTAINER}" -- \
    mysql -u"${MYSQL_ROOT_USER}" -p"${password}" --skip-column-names "$@" 2>/dev/null
}

# ── Build node-name → {slug, cpu, mem_gib} lookup from kubectl get nodes ───
# Populated once per poll cycle; avoids per-pod kubectl calls.
declare -A NODE_SLUG_MAP NODE_CPU_MAP NODE_MEM_MAP

refresh_node_info() {
  NODE_SLUG_MAP=()
  NODE_CPU_MAP=()
  NODE_MEM_MAP=()

  local nodes_json
  nodes_json="$(kubectl get nodes -o json 2>/dev/null)" || { log "WARN: failed to get nodes"; return; }

  local node_lines
  node_lines="$(echo "${nodes_json}" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for n in data.get('items', []):
    name = n['metadata']['name']
    labels = n['metadata'].get('labels', {})
    slug = labels.get('node.kubernetes.io/instance-type', labels.get('beta.kubernetes.io/instance-type', '?'))
    cap = n['status'].get('capacity', {})
    cpu = cap.get('cpu', '?')
    mem_ki = cap.get('memory', '0')
    mem_ki_val = int(''.join(c for c in mem_ki if c.isdigit()) or '0')
    mem_gib = round(mem_ki_val / 1048576, 1)
    print(f'{name}\t{slug}\t{cpu}\t{mem_gib}')
" 2>/dev/null)" || { log "WARN: node info parsing failed"; return; }

  while IFS=$'\t' read -r n_name n_slug n_cpu n_mem; do
    [[ -z "${n_name}" ]] && continue
    NODE_SLUG_MAP["${n_name}"]="${n_slug}"
    NODE_CPU_MAP["${n_name}"]="${n_cpu}"
    NODE_MEM_MAP["${n_name}"]="${n_mem}"
  done <<< "${node_lines}"
}

# ── Single poll: collect pod state + GR role + DOKS node for each mysql pod ─
poll_once() {
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local password
  password="$(get_mysql_password)"

  refresh_node_info

  local pods_json
  pods_json="$(kubectl_ns get pods \
    -l "app.kubernetes.io/instance=${CLUSTER_NAME},app.kubernetes.io/component=${MYSQL_COMPONENT_LABEL}" \
    -o json 2>/dev/null)" || { log "WARN: failed to get pods"; return; }

  local pod_lines
  pod_lines="$(echo "${pods_json}" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for item in data.get('items', []):
    meta = item['metadata']
    spec = item['spec']
    status = item['status']
    cs = status.get('containerStatuses', [])
    main = next((c for c in cs if c['name'] in ('pxc', 'mysql')), cs[0] if cs else {})
    ready = all(c.get('ready', False) for c in cs) if cs else False
    deleting = 'yes' if meta.get('deletionTimestamp') else 'no'
    print('\t'.join([
        meta['name'],
        status.get('phase', 'Unknown'),
        'true' if ready else 'false',
        spec.get('nodeName', ''),
        str(main.get('restartCount', 0)),
        deleting,
    ]))
" 2>/dev/null)" || { log "WARN: pod parsing failed"; return; }

  local current_node_map=""

  while IFS=$'\t' read -r pod_name phase ready node restarts deleting; do
    [[ -z "${pod_name}" ]] && continue

    local gr_role="?" gr_state="?"

    if [[ "${phase}" == "Running" && -n "${password}" ]]; then
      local gr_line
      if [[ "${CR_TYPE}" == "ps" ]]; then
        gr_line="$(mysql_in_pod "${pod_name}" "${password}" -e "
          SELECT
            IFNULL((SELECT MEMBER_ROLE FROM performance_schema.replication_group_members
                    WHERE MEMBER_HOST LIKE CONCAT(@@hostname, '%') LIMIT 1), 'UNKNOWN'),
            IFNULL((SELECT MEMBER_STATE FROM performance_schema.replication_group_members
                    WHERE MEMBER_HOST LIKE CONCAT(@@hostname, '%') LIMIT 1), 'UNKNOWN');
        ")" || gr_line=""
      else
        gr_line="$(mysql_in_pod "${pod_name}" "${password}" -e "
          SELECT
            CASE WHEN @@read_only = 0 THEN 'PRIMARY' ELSE 'SECONDARY' END,
            @@wsrep_local_state_comment;
        ")" || gr_line=""
      fi

      if [[ -n "${gr_line}" ]]; then
        gr_role="$(echo "${gr_line}" | awk '{print $1}')"
        gr_state="$(echo "${gr_line}" | awk '{print $2}')"
      fi
    fi

    local node_slug="${NODE_SLUG_MAP[${node}]:-?}"
    local node_cpu="${NODE_CPU_MAP[${node}]:-?}"
    local node_mem="${NODE_MEM_MAP[${node}]:-?}"

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${ts}" "${pod_name}" "${phase}" "${ready}" "${gr_role}" "${gr_state}" \
      "${node}" "${node_slug}" "${node_cpu}" "${node_mem}" "${restarts}" "${deleting}" \
      >> "${TSV_FILE}"

    # Detect primary change
    if [[ "${gr_role}" == "PRIMARY" && "${pod_name}" != "${PREVIOUS_PRIMARY}" ]]; then
      if [[ -n "${PREVIOUS_PRIMARY}" ]]; then
        log "PRIMARY FAILOVER: ${PREVIOUS_PRIMARY} -> ${pod_name}"
      else
        log "Initial primary: ${pod_name}"
      fi
      PREVIOUS_PRIMARY="${pod_name}"
    fi

    current_node_map="${current_node_map}${pod_name}=${node} "

  done <<< "${pod_lines}"

  # Detect node migration (pod moved to a different DOKS worker)
  if [[ -n "${PREVIOUS_NODE_MAP}" && "${current_node_map}" != "${PREVIOUS_NODE_MAP}" ]]; then
    log "NODE CHANGE detected: was [${PREVIOUS_NODE_MAP}] now [${current_node_map}]"
  fi
  PREVIOUS_NODE_MAP="${current_node_map}"
}

# ── Startup / shutdown ─────────────────────────────────────────────────────
capture_baseline() {
  log "capturing baseline"
  kubectl_ns get pods -l "app.kubernetes.io/instance=${CLUSTER_NAME}" -o wide \
    > "${OUTPUT_DIR}/pods_baseline.txt" 2>/dev/null || true
  kubectl get nodes -o wide > "${OUTPUT_DIR}/nodes_baseline.txt" 2>/dev/null || true
  log "baseline saved"
}

shutdown() {
  log "monitor shutting down"
  kubectl_ns get pods -l "app.kubernetes.io/instance=${CLUSTER_NAME}" -o wide \
    > "${OUTPUT_DIR}/pods_final.txt" 2>/dev/null || true
  kubectl get nodes -o wide > "${OUTPUT_DIR}/nodes_final.txt" 2>/dev/null || true
  log "final state saved — exiting"
  exit 0
}
trap shutdown SIGTERM SIGINT

main() {
  log "k8s_scaling_monitor starting"
  log "KUBECONFIG=${KUBECONFIG}"
  log "NAMESPACE=${NAMESPACE}"
  log "POLL_INTERVAL=${POLL_INTERVAL}s"

  if ! kubectl cluster-info >/dev/null 2>&1; then
    log "ERROR: cannot connect to Kubernetes cluster"
    exit 1
  fi

  auto_detect_cluster
  log "CLUSTER=${CLUSTER_NAME} CR_TYPE=${CR_TYPE} CONTAINER=${MYSQL_CONTAINER}"

  capture_baseline

  # Write TSV header
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "timestamp" "pod" "phase" "ready" "gr_role" "gr_state" \
    "doks_node" "slug" "vcpus" "mem_gib" "restarts" "deleting" \
    > "${TSV_FILE}"

  log "polling started"

  while true; do
    poll_once
    sleep "${POLL_INTERVAL}"
  done
}

main "$@"
