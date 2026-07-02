#!/usr/bin/env bash
# Background Kubernetes monitor for Percona MySQL scaling events.
#
# Tracks per poll cycle:
#   1. GR role: which pod is PRIMARY, which are SECONDARY
#   2. Pod state: phase, ready, GR member state (ONLINE/RECOVERING/ERROR)
#   3. DOKS node binding: which K8s worker node + slug each pod runs on
#   4. gr_detail: error reason when GR state is not ONLINE
#
# Outputs k8s_monitor.tsv (time-series) and k8s_monitor.log (events).
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
PREVIOUS_POD_COUNT=""
PREVIOUS_PVC_SIZES=""
NODE_CYCLE=0
NODES_LOADED=false

# Temporary files for lookups (avoids associative-array + set -u issues)
GR_TMP="${OUTPUT_DIR}/.gr_members.tsv"
NODE_TMP="${OUTPUT_DIR}/.node_info.tsv"
PVC_TMP="${OUTPUT_DIR}/.pvc_info.tsv"
GR_COUNTS_TMP="${OUTPUT_DIR}/.gr_counts.txt"

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

# ── Node info cache ────────────────────────────────────────────────────────
# Writes TSV to NODE_TMP: node_name \t slug \t cpu \t mem_gib
# Refreshed every 6 cycles (~30s); new nodes trigger an immediate refresh.
refresh_node_info() {
  local nodes_json
  nodes_json="$(kubectl get nodes -o json 2>/dev/null)" || { log "WARN: failed to get nodes"; return; }

  echo "${nodes_json}" | python3 -c "
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
" > "${NODE_TMP}" 2>/dev/null || { log "WARN: node info parsing failed"; return; }
  NODES_LOADED=true
}

maybe_refresh_nodes() {
  NODE_CYCLE=$((NODE_CYCLE + 1))
  if (( NODE_CYCLE >= 6 )) || [[ "${NODES_LOADED}" != "true" ]]; then
    refresh_node_info
    NODE_CYCLE=0
  fi
}

# Lookup from NODE_TMP: given a node name, return "slug \t cpu \t mem_gib"
node_lookup() {
  local node_name="${1}"
  [[ -z "${node_name}" || ! -f "${NODE_TMP}" ]] && { echo "?\t?\t?"; return; }
  local match
  match="$(grep "^${node_name}	" "${NODE_TMP}" 2>/dev/null | head -1)" || true
  if [[ -n "${match}" ]]; then
    echo "${match}" | cut -f2-
  else
    echo "?\t?\t?"
  fi
}

# ── PVC info ───────────────────────────────────────────────────────────────
# Writes TSV to PVC_TMP: pod_name \t requested \t capacity
# PVC names follow: datadir-<cluster>-mysql-N → pod <cluster>-mysql-N
refresh_pvc_info() {
  local pvcs_json
  pvcs_json="$(kubectl_ns get pvc \
    -l "app.kubernetes.io/instance=${CLUSTER_NAME}" \
    -o json 2>/dev/null)" || { log "WARN: failed to get PVCs"; return; }

  echo "${pvcs_json}" | python3 -c "
import json, sys, re
data = json.load(sys.stdin)
for item in data.get('items', []):
    name = item['metadata']['name']
    # Extract pod name: 'datadir-cluster-mysql-0' → 'cluster-mysql-0'
    pod_name = re.sub(r'^datadir-', '', name)
    req = item.get('spec', {}).get('resources', {}).get('requests', {}).get('storage', '?')
    cap = item.get('status', {}).get('capacity', {}).get('storage', '?')
    phase = item.get('status', {}).get('phase', '?')
    print(f'{pod_name}\t{req}\t{cap}\t{phase}')
" > "${PVC_TMP}" 2>/dev/null || { log "WARN: PVC parsing failed"; return; }

  # Detect PVC size changes
  local current_sizes
  current_sizes="$(sort "${PVC_TMP}" 2>/dev/null)"
  if [[ -n "${PREVIOUS_PVC_SIZES}" && "${current_sizes}" != "${PREVIOUS_PVC_SIZES}" ]]; then
    log "PVC CHANGE detected"
  fi
  PREVIOUS_PVC_SIZES="${current_sizes}"
}

# Lookup from PVC_TMP: given a pod name, return "requested \t capacity"
pvc_lookup() {
  local pod_name="${1}"
  [[ -z "${pod_name}" || ! -f "${PVC_TMP}" ]] && { echo "?\t?"; return; }
  local match
  match="$(grep "^${pod_name}	" "${PVC_TMP}" 2>/dev/null | head -1)" || true
  if [[ -n "${match}" ]]; then
    echo "${match}" | cut -f2-3
  else
    echo "?\t?"
  fi
}

# ── GR member info via a single query from one reachable pod ───────────────
# Writes TSV to GR_TMP: short_hostname \t role \t state \t detail
# One kubectl-exec instead of N.
refresh_gr_info() {
  : > "${GR_TMP}"

  local password
  password="$(get_mysql_password)"
  [[ -z "${password}" ]] && return

  local running_pods
  running_pods="$(kubectl_ns get pods \
    -l "app.kubernetes.io/instance=${CLUSTER_NAME},app.kubernetes.io/component=${MYSQL_COMPONENT_LABEL}" \
    -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{"\n"}{end}' 2>/dev/null)"

  local gr_raw=""
  local queried_pod=""
  while IFS= read -r pod_name; do
    [[ -z "${pod_name}" ]] && continue

    if [[ "${CR_TYPE}" == "ps" ]]; then
      gr_raw="$(mysql_in_pod "${pod_name}" "${password}" -e "
        SELECT
          SUBSTRING_INDEX(m.MEMBER_HOST, '.', 1) AS short_host,
          m.MEMBER_ROLE,
          m.MEMBER_STATE,
          IFNULL(
            CASE
              WHEN m.MEMBER_STATE = 'RECOVERING' THEN 'catching_up'
              WHEN m.MEMBER_STATE = 'UNREACHABLE' THEN 'connection_lost'
              WHEN m.MEMBER_STATE = 'ERROR' THEN
                IFNULL((SELECT CONCAT('applier:', e.LAST_ERROR_MESSAGE)
                        FROM performance_schema.replication_applier_status_by_worker e
                        WHERE e.LAST_ERROR_MESSAGE != '' LIMIT 1),
                       IFNULL((SELECT CONCAT('connection:', c.LAST_ERROR_MESSAGE)
                               FROM performance_schema.replication_connection_status c
                               WHERE c.LAST_ERROR_MESSAGE != '' LIMIT 1),
                              'unknown_error'))
              ELSE ''
            END, '')
        FROM performance_schema.replication_group_members m;
      " 2>/dev/null)" && { queried_pod="${pod_name}"; break; }
    else
      gr_raw="$(mysql_in_pod "${pod_name}" "${password}" -e "
        SELECT
          @@hostname,
          CASE WHEN @@read_only = 0 THEN 'PRIMARY' ELSE 'SECONDARY' END,
          @@wsrep_local_state_comment,
          CASE
            WHEN @@wsrep_local_state_comment != 'Synced' THEN @@wsrep_local_state_comment
            ELSE ''
          END;
      " 2>/dev/null)" && { queried_pod="${pod_name}"; break; }
    fi
  done <<< "${running_pods}"

  if [[ -z "${gr_raw}" ]]; then
    log "WARN: could not query GR from any pod"
    return
  fi

  local total=0 online=0
  echo "${gr_raw}" | while IFS=$'\t' read -r host role state detail; do
    [[ -z "${host}" ]] && continue
    detail="$(echo "${detail}" | tr '\t\n\r' '___' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -z "${detail}" ]] && detail="-"
    printf '%s\t%s\t%s\t%s\n' "${host}" "${role}" "${state}" "${detail}"
  done > "${GR_TMP}"

  # Count members and online members from GR_TMP
  if [[ -s "${GR_TMP}" ]]; then
    total="$(wc -l < "${GR_TMP}" | tr -d ' ')"
    online="$(grep -c '	ONLINE	\|	Synced	' "${GR_TMP}" 2>/dev/null || echo 0)"
  fi
  echo "${total}	${online}" > "${GR_COUNTS_TMP}"
}

# Lookup from GR_TMP: given a pod name, return "role \t state \t detail"
gr_lookup() {
  local pod_name="${1}"
  [[ -z "${pod_name}" || ! -f "${GR_TMP}" ]] && { echo "?\t?\t"; return; }
  local match
  match="$(grep "^${pod_name}	" "${GR_TMP}" 2>/dev/null | head -1)" || true
  if [[ -n "${match}" ]]; then
    echo "${match}" | cut -f2-
  else
    echo "?\t?\t"
  fi
}

# ── Single poll ────────────────────────────────────────────────────────────
poll_once() {
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  maybe_refresh_nodes
  refresh_gr_info
  refresh_pvc_info

  # GR member counts (total / online)
  local gr_members="?" gr_online="?"
  if [[ -f "${GR_COUNTS_TMP}" ]]; then
    gr_members="$(cut -f1 "${GR_COUNTS_TMP}")"
    gr_online="$(cut -f2 "${GR_COUNTS_TMP}")"
  fi

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
    # Container state reason (e.g. CrashLoopBackOff, ContainerCreating)
    state_info = main.get('state', {})
    reason = ''
    for stype in ('waiting', 'terminated'):
        if stype in state_info:
            reason = state_info[stype].get('reason', '')
            break
    print('\t'.join([
        meta['name'],
        status.get('phase', 'Unknown'),
        'true' if ready else 'false',
        spec.get('nodeName', ''),
        str(main.get('restartCount', 0)),
        deleting,
        reason,
    ]))
" 2>/dev/null)" || { log "WARN: pod parsing failed"; return; }

  local current_node_map=""

  while IFS=$'\t' read -r pod_name phase ready node restarts deleting container_reason; do
    [[ -z "${pod_name}" ]] && continue

    # GR info from cached single-query result
    local gr_info
    gr_info="$(gr_lookup "${pod_name}")"
    local gr_role gr_state gr_detail
    gr_role="$(echo "${gr_info}" | cut -f1)"
    gr_state="$(echo "${gr_info}" | cut -f2)"
    gr_detail="$(echo "${gr_info}" | cut -f3)"

    # If pod is not Running, override gr_detail with container reason
    if [[ "${phase}" != "Running" && -n "${container_reason}" ]]; then
      gr_detail="${container_reason}"
    fi

    # Node info from cached result
    local node_info
    node_info="$(node_lookup "${node}")"
    local node_slug node_cpu node_mem
    node_slug="$(echo "${node_info}" | cut -f1)"
    node_cpu="$(echo "${node_info}" | cut -f2)"
    node_mem="$(echo "${node_info}" | cut -f3)"

    # If node is unknown (new node during scaling), force refresh
    if [[ "${node_slug}" == "?" && -n "${node}" ]]; then
      refresh_node_info
      NODE_CYCLE=0
      node_info="$(node_lookup "${node}")"
      node_slug="$(echo "${node_info}" | cut -f1)"
      node_cpu="$(echo "${node_info}" | cut -f2)"
      node_mem="$(echo "${node_info}" | cut -f3)"
    fi

    # PVC info
    local pvc_info
    pvc_info="$(pvc_lookup "${pod_name}")"
    local pvc_req pvc_cap
    pvc_req="$(echo "${pvc_info}" | cut -f1)"
    pvc_cap="$(echo "${pvc_info}" | cut -f2)"

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${ts}" "${pod_name}" "${phase}" "${ready}" \
      "${gr_role}" "${gr_state}" "${gr_detail}" "${gr_members}" "${gr_online}" \
      "${node}" "${node_slug}" "${node_cpu}" "${node_mem}" \
      "${pvc_req}" "${pvc_cap}" "${restarts}" "${deleting}" \
      >> "${TSV_FILE}"

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

  # Detect pod count change (horizontal scaling)
  local pod_count
  pod_count="$(echo "${pod_lines}" | grep -c '.' || echo 0)"
  if [[ -n "${PREVIOUS_POD_COUNT}" && "${pod_count}" != "${PREVIOUS_POD_COUNT}" ]]; then
    log "POD COUNT CHANGE: ${PREVIOUS_POD_COUNT} -> ${pod_count}"
  fi
  PREVIOUS_POD_COUNT="${pod_count}"

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
  rm -f "${GR_TMP}" "${NODE_TMP}" "${PVC_TMP}" "${GR_COUNTS_TMP}"
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

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "timestamp" "pod" "phase" "ready" \
    "gr_role" "gr_state" "gr_detail" "gr_members" "gr_online" \
    "doks_node" "slug" "vcpus" "mem_gib" \
    "pvc_req" "pvc_cap" "restarts" "deleting" \
    > "${TSV_FILE}"

  log "polling started"

  while true; do
    poll_once
    sleep "${POLL_INTERVAL}"
  done
}

main "$@"
