#!/usr/bin/env bash
# Background Kubernetes monitor for Percona MySQL scaling events.
#
# Supports both:
#   - Percona Server for MySQL (ps) with InnoDB Group Replication
#   - Percona XtraDB Cluster (pxc) with Galera
#
# Auto-detects which CRD is present and uses the right queries.
#
# Polls pod state, CR status, replication state, K8s events, nodes,
# and PVCs at a configurable interval.  Writes structured JSONL output that
# parse_k8s_events.py turns into analysis-ready CSVs.
#
# Usage (standalone):
#   export KUBECONFIG=/path/to/kubeconfig
#   export K8S_NAMESPACE=percona
#   export PXC_CLUSTER_NAME=my-cluster   # optional, auto-detected
#   ./k8s_scaling_monitor.sh /path/to/output_dir [poll_interval_sec]
#
# The script runs until killed (SIGTERM/SIGINT).  run_benchmark.sh starts it
# in the background and stops it after the TPC-C workload completes.
set -euo pipefail

OUTPUT_DIR="${1:?output directory required}"
POLL_INTERVAL="${2:-5}"

KUBECONFIG="${KUBECONFIG:?Set KUBECONFIG to the cluster kubeconfig path}"
export KUBECONFIG

NAMESPACE="${K8S_NAMESPACE:-mysql}"
CLUSTER_NAME="${PXC_CLUSTER_NAME:-}"
MYSQL_ROOT_SECRET="${PXC_MYSQL_ROOT_SECRET:-}"
MYSQL_ROOT_USER="${PXC_MYSQL_ROOT_USER:-root}"

# Auto-detected: "ps" (PerconaServerMySQL) or "pxc" (PerconaXtraDBCluster)
CR_TYPE=""
# Container name: "mysql" for ps, "pxc" for pxc
MYSQL_CONTAINER=""
# Component label: "database" for ps, "pxc" for pxc
MYSQL_COMPONENT_LABEL=""

mkdir -p "${OUTPUT_DIR}"

SNAPSHOT_LOG="${OUTPUT_DIR}/k8s_snapshots.jsonl"
EVENT_LOG="${OUTPUT_DIR}/k8s_events.jsonl"
REPL_LOG="${OUTPUT_DIR}/replication_status.jsonl"
NODE_LOG="${OUTPUT_DIR}/k8s_nodes.jsonl"
PVC_LOG="${OUTPUT_DIR}/k8s_pvcs.jsonl"
MONITOR_LOG="${OUTPUT_DIR}/k8s_monitor.log"
TIMELINE_LOG="${OUTPUT_DIR}/k8s_timeline.jsonl"
METRICS_LOG="${OUTPUT_DIR}/mysqld_exporter_metrics.jsonl"
POD_LOGS_DIR="${OUTPUT_DIR}/pod_logs"

: > "${SNAPSHOT_LOG}"
: > "${EVENT_LOG}"
: > "${REPL_LOG}"
: > "${NODE_LOG}"
: > "${PVC_LOG}"
: > "${MONITOR_LOG}"
: > "${TIMELINE_LOG}"
: > "${METRICS_LOG}"
mkdir -p "${POD_LOGS_DIR}"

LAST_EVENT_TIMESTAMP=""
PREVIOUS_PRIMARY=""
PREVIOUS_POD_STATES=""
PREVIOUS_CLUSTER_SIZE=""
PREVIOUS_NODE_COUNT=""
CACHED_PASSWORD=""
# PIDs of background log-streaming processes
LOG_STREAM_PIDS=()

log() {
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "[${ts}] $*" >> "${MONITOR_LOG}"
  echo "[${ts}] $*" >&2
}

kubectl_ns() {
  kubectl --namespace="${NAMESPACE}" "$@"
}

# ── Auto-detect CRD type and cluster name ───────────────────────────────────
auto_detect_cluster() {
  if [[ -n "${CLUSTER_NAME}" ]]; then
    # Try to detect CR type for a known cluster name
    if kubectl_ns get ps "${CLUSTER_NAME}" >/dev/null 2>&1; then
      CR_TYPE="ps"
    elif kubectl_ns get pxc "${CLUSTER_NAME}" >/dev/null 2>&1; then
      CR_TYPE="pxc"
    else
      log "ERROR: cluster ${CLUSTER_NAME} not found as ps or pxc in namespace ${NAMESPACE}"
      return 1
    fi
  else
    # Try ps first (PerconaServerMySQL), then pxc
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
    ps)
      MYSQL_CONTAINER="mysql"
      MYSQL_COMPONENT_LABEL="database"
      ;;
    pxc)
      MYSQL_CONTAINER="pxc"
      MYSQL_COMPONENT_LABEL="pxc"
      ;;
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

emit_timeline() {
  local event_type="${1}" detail="${2}"
  local ts epoch
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  epoch="$(date +%s)"
  printf '{"ts":"%s","epoch":%s,"event":"%s","detail":%s}\n' \
    "${ts}" "${epoch}" "${event_type}" "${detail}" >> "${TIMELINE_LOG}"
}

mysql_in_pod() {
  local pod_name="${1:?pod required}" password="${2:?password required}"
  shift 2
  kubectl_ns exec "${pod_name}" -c "${MYSQL_CONTAINER}" -- \
    mysql -u"${MYSQL_ROOT_USER}" -p"${password}" --skip-column-names "$@" 2>/dev/null
}

# ── Pod state snapshot ──────────────────────────────────────────────────────
collect_pod_snapshot() {
  local ts epoch
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  epoch="$(date +%s)"

  local pods_json
  pods_json="$(kubectl_ns get pods \
    -l "app.kubernetes.io/instance=${CLUSTER_NAME}" \
    -o json 2>/dev/null)" || { log "WARN: failed to get pods"; return; }

  local pod_summary
  pod_summary="$(echo "${pods_json}" | python3 -c "
import json, sys
data = json.load(sys.stdin)
pods = []
for item in data.get('items', []):
    meta = item['metadata']
    spec = item['spec']
    status = item['status']
    containers = status.get('containerStatuses', [])
    main_container = next((c for c in containers if c['name'] in ('pxc', 'mysql')), containers[0] if containers else {})
    ready = all(c.get('ready', False) for c in containers) if containers else False
    pods.append({
        'name': meta['name'],
        'phase': status.get('phase', 'Unknown'),
        'ready': ready,
        'node': spec.get('nodeName', ''),
        'pod_ip': status.get('podIP', ''),
        'restarts': main_container.get('restartCount', 0),
        'labels': {k: v for k, v in meta.get('labels', {}).items()
                   if k in ('app.kubernetes.io/component', 'app.kubernetes.io/name',
                            'controller-revision-hash', 'statefulset.kubernetes.io/pod-name')},
        'conditions': [{'type': c['type'], 'status': c['status']}
                       for c in status.get('conditions', [])],
        'deletion_ts': meta.get('deletionTimestamp', ''),
    })
print(json.dumps(pods))
" 2>/dev/null)" || { log "WARN: pod parsing failed"; return; }

  printf '{"ts":"%s","epoch":%s,"type":"pod_snapshot","pods":%s}\n' \
    "${ts}" "${epoch}" "${pod_summary}" >> "${SNAPSHOT_LOG}"

  detect_pod_changes "${pod_summary}"
}

detect_pod_changes() {
  local current_states="${1}"

  local states_sig
  states_sig="$(echo "${current_states}" | python3 -c "
import json, sys
pods = json.loads(sys.stdin.read())
for p in sorted(pods, key=lambda x: x['name']):
    print(f\"{p['name']}:{p['phase']}:{p['ready']}:{p['node']}:{p['restarts']}\")
" 2>/dev/null)"

  if [[ "${states_sig}" != "${PREVIOUS_POD_STATES}" && -n "${PREVIOUS_POD_STATES}" ]]; then
    local changes
    changes="$(diff <(echo "${PREVIOUS_POD_STATES}") <(echo "${states_sig}") 2>/dev/null || true)"
    if [[ -n "${changes}" ]]; then
      local detail
      detail="$(echo "${changes}" | python3 -c "
import json, sys
lines = sys.stdin.read().strip().split('\n')
changes = []
for l in lines:
    if l.startswith('< '):
        changes.append({'action': 'removed/changed', 'state': l[2:]})
    elif l.startswith('> '):
        changes.append({'action': 'added/changed', 'state': l[2:]})
print(json.dumps(changes))
" 2>/dev/null)"
      emit_timeline "POD_STATE_CHANGE" "${detail:-\"pod states changed\"}"
    fi
  fi
  PREVIOUS_POD_STATES="${states_sig}"
}

# ── CR status (works for both ps and pxc) ──────────────────────────────────
collect_cr_status() {
  local ts epoch
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  epoch="$(date +%s)"

  local cr_json
  cr_json="$(kubectl_ns get "${CR_TYPE}" "${CLUSTER_NAME}" -o json 2>/dev/null)" \
    || { log "WARN: failed to get ${CR_TYPE} CR"; return; }

  local cr_summary
  cr_summary="$(echo "${cr_json}" | python3 -c "
import json, sys
data = json.load(sys.stdin)
spec = data.get('spec', {})
status = data.get('status', {})
cr_type = '${CR_TYPE}'

if cr_type == 'ps':
    mysql_spec = spec.get('mysql', {})
    mysql_status = status.get('mysql', {})
    resources = mysql_spec.get('resources', {})
    haproxy = status.get('haproxy', {})
    result = {
        'cr_type': 'ps',
        'state': status.get('state', 'unknown'),
        'size': mysql_spec.get('size', 0),
        'mysql_ready': mysql_status.get('ready', 0),
        'mysql_size': mysql_status.get('size', 0),
        'mysql_state': mysql_status.get('state', 'unknown'),
        'mysql_version': mysql_status.get('version', ''),
        'mysql_image': mysql_spec.get('image', ''),
        'haproxy_ready': haproxy.get('ready', 0),
        'haproxy_size': haproxy.get('size', 0),
        'haproxy_state': haproxy.get('state', 'unknown'),
        'host': status.get('host', ''),
        'conditions': [{'type': c.get('type',''), 'status': c.get('status',''),
                         'reason': c.get('reason',''), 'message': c.get('message','')}
                        for c in status.get('conditions', [])],
        'resources_requests_cpu': resources.get('requests', {}).get('cpu', ''),
        'resources_requests_memory': resources.get('requests', {}).get('memory', ''),
        'resources_limits_cpu': resources.get('limits', {}).get('cpu', ''),
        'resources_limits_memory': resources.get('limits', {}).get('memory', ''),
        'annotations': {k: v for k, v in data.get('metadata', {}).get('annotations', {}).items()
                        if 'percona' in k or 'resize' in k},
    }
else:
    pxc_spec = spec.get('pxc', {})
    pxc_status = status.get('pxc', {})
    resources = pxc_spec.get('resources', {})
    result = {
        'cr_type': 'pxc',
        'state': status.get('state', 'unknown'),
        'size': pxc_spec.get('size', 0),
        'mysql_ready': pxc_status.get('ready', 0),
        'mysql_size': pxc_status.get('size', 0),
        'mysql_state': pxc_status.get('status', 'unknown'),
        'mysql_version': pxc_status.get('version', ''),
        'mysql_image': pxc_spec.get('image', ''),
        'haproxy_ready': status.get('haproxy', {}).get('ready', 0),
        'haproxy_size': status.get('haproxy', {}).get('size', 0),
        'haproxy_state': status.get('haproxy', {}).get('status', 'unknown'),
        'host': '',
        'conditions': [{'type': c.get('type',''), 'status': c.get('status',''),
                         'reason': c.get('reason',''), 'message': c.get('message','')}
                        for c in status.get('conditions', [])],
        'resources_requests_cpu': resources.get('requests', {}).get('cpu', ''),
        'resources_requests_memory': resources.get('requests', {}).get('memory', ''),
        'resources_limits_cpu': resources.get('limits', {}).get('cpu', ''),
        'resources_limits_memory': resources.get('limits', {}).get('memory', ''),
        'annotations': {k: v for k, v in data.get('metadata', {}).get('annotations', {}).items()
                        if 'percona' in k or 'resize' in k},
    }
print(json.dumps(result))
" 2>/dev/null)" || { log "WARN: CR parsing failed"; return; }

  printf '{"ts":"%s","epoch":%s,"type":"cr_status","cluster":"%s","status":%s}\n' \
    "${ts}" "${epoch}" "${CLUSTER_NAME}" "${cr_summary}" >> "${SNAPSHOT_LOG}"

  local current_size
  current_size="$(echo "${cr_summary}" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['size'])" 2>/dev/null)"
  if [[ -n "${PREVIOUS_CLUSTER_SIZE}" && "${current_size}" != "${PREVIOUS_CLUSTER_SIZE}" ]]; then
    emit_timeline "CLUSTER_SIZE_CHANGE" \
      "$(printf '{"from":%s,"to":%s}' "${PREVIOUS_CLUSTER_SIZE}" "${current_size}")"
  fi
  PREVIOUS_CLUSTER_SIZE="${current_size}"
}

# ── MySQL replication status (Group Replication or Galera via kubectl exec) ─
collect_replication_status() {
  local ts epoch
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  epoch="$(date +%s)"

  local password
  password="$(get_mysql_password)"
  if [[ -z "${password}" ]]; then
    log "WARN: cannot get MySQL password for replication status"
    return
  fi

  local pods_list
  pods_list="$(kubectl_ns get pods \
    -l "app.kubernetes.io/instance=${CLUSTER_NAME},app.kubernetes.io/component=${MYSQL_COMPONENT_LABEL}" \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.phase}{"\n"}{end}' 2>/dev/null)"

  while IFS=' ' read -r pod_name pod_phase; do
    [[ -z "${pod_name}" ]] && continue
    [[ "${pod_phase}" != "Running" ]] && continue

    local repl_json=""

    if [[ "${CR_TYPE}" == "ps" ]]; then
      # InnoDB Group Replication query
      repl_json="$(mysql_in_pod "${pod_name}" "${password}" -e "
        SELECT JSON_OBJECT(
          'repl_type', 'group_replication',
          'hostname', @@hostname,
          'server_id', @@server_id,
          'read_only', @@read_only,
          'super_read_only', @@super_read_only,
          'group_replication_single_primary_mode', @@group_replication_single_primary_mode,
          'member_count', (SELECT COUNT(*) FROM performance_schema.replication_group_members),
          'online_count', (SELECT COUNT(*) FROM performance_schema.replication_group_members WHERE MEMBER_STATE='ONLINE'),
          'primary_host', (SELECT MEMBER_HOST FROM performance_schema.replication_group_members WHERE MEMBER_ROLE='PRIMARY' LIMIT 1),
          'my_role', (SELECT MEMBER_ROLE FROM performance_schema.replication_group_members WHERE MEMBER_HOST LIKE CONCAT(@@hostname, '%') LIMIT 1),
          'my_state', (SELECT MEMBER_STATE FROM performance_schema.replication_group_members WHERE MEMBER_HOST LIKE CONCAT(@@hostname, '%') LIMIT 1),
          'members', (SELECT JSON_ARRAYAGG(JSON_OBJECT('host', MEMBER_HOST, 'state', MEMBER_STATE, 'role', MEMBER_ROLE)) FROM performance_schema.replication_group_members)
        );
      ")" || { log "WARN: GR query failed on ${pod_name}"; continue; }
    else
      # Galera/wsrep query
      repl_json="$(mysql_in_pod "${pod_name}" "${password}" -e "
        SELECT JSON_OBJECT(
          'repl_type', 'galera',
          'hostname', @@hostname,
          'server_id', @@server_id,
          'read_only', @@read_only,
          'super_read_only', @@super_read_only,
          'member_count', @@wsrep_cluster_size,
          'online_count', @@wsrep_cluster_size,
          'cluster_status', @@wsrep_cluster_status,
          'local_state', @@wsrep_local_state_comment,
          'local_state_num', @@wsrep_local_state,
          'wsrep_ready', @@wsrep_ready,
          'wsrep_connected', @@wsrep_connected,
          'incoming_addresses', @@wsrep_incoming_addresses,
          'flow_control_paused', @@wsrep_flow_control_paused,
          'flow_control_sent', @@wsrep_flow_control_sent,
          'cert_deps_distance', @@wsrep_cert_deps_distance
        );
      ")" || { log "WARN: Galera query failed on ${pod_name}"; continue; }
    fi

    repl_json="$(echo "${repl_json}" | tr -d '\n\r')"
    [[ -z "${repl_json}" ]] && continue

    printf '{"ts":"%s","epoch":%s,"pod":"%s","replication":%s}\n' \
      "${ts}" "${epoch}" "${pod_name}" "${repl_json}" >> "${REPL_LOG}"

    # Detect primary: for GR check my_role=PRIMARY, for Galera check read_only=0
    local is_primary
    is_primary="$(echo "${repl_json}" | python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
if data.get('repl_type') == 'group_replication':
    print('1' if data.get('my_role') == 'PRIMARY' else '0')
else:
    ro = str(data.get('read_only', '1'))
    print('1' if ro in ('0', 'OFF', 'Off', 'off') else '0')
" 2>/dev/null)"

    if [[ "${is_primary}" == "1" && "${pod_name}" != "${PREVIOUS_PRIMARY}" ]]; then
      if [[ -n "${PREVIOUS_PRIMARY}" ]]; then
        emit_timeline "PRIMARY_FAILOVER" \
          "$(printf '{"from":"%s","to":"%s"}' "${PREVIOUS_PRIMARY}" "${pod_name}")"
        log "PRIMARY FAILOVER: ${PREVIOUS_PRIMARY} -> ${pod_name}"
      else
        emit_timeline "PRIMARY_DETECTED" \
          "$(printf '{"primary":"%s"}' "${pod_name}")"
        log "Initial primary: ${pod_name}"
      fi
      PREVIOUS_PRIMARY="${pod_name}"
    fi

  done <<< "${pods_list}"
}

# ── Kubernetes events ───────────────────────────────────────────────────────
collect_k8s_events() {
  local ts epoch
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  epoch="$(date +%s)"

  local events_json
  events_json="$(kubectl_ns get events \
    --sort-by='.lastTimestamp' \
    -o json 2>/dev/null)" || { log "WARN: failed to get events"; return; }

  echo "${events_json}" | python3 -c "
import json, sys
data = json.load(sys.stdin)
last_seen = '${LAST_EVENT_TIMESTAMP}'
new_last = last_seen
for item in data.get('items', []):
    evt_ts = item.get('lastTimestamp', '') or item.get('eventTime', '')
    if not evt_ts:
        continue
    if last_seen and evt_ts <= last_seen:
        continue
    if evt_ts > new_last:
        new_last = evt_ts
    obj = item.get('involvedObject', {})
    record = {
        'ts': evt_ts,
        'type': item.get('type', ''),
        'reason': item.get('reason', ''),
        'message': item.get('message', ''),
        'object_kind': obj.get('kind', ''),
        'object_name': obj.get('name', ''),
        'source': item.get('source', {}).get('component', ''),
        'count': item.get('count', 1),
    }
    print(json.dumps(record))
print(f'__LAST_TS__={new_last}', file=sys.stderr)
" >> "${EVENT_LOG}" 2>"${OUTPUT_DIR}/.last_event_ts"

  LAST_EVENT_TIMESTAMP="$(grep '__LAST_TS__=' "${OUTPUT_DIR}/.last_event_ts" 2>/dev/null | head -1 | cut -d= -f2-)"
}

# ── Node state ──────────────────────────────────────────────────────────────
collect_node_snapshot() {
  local ts epoch
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  epoch="$(date +%s)"

  local nodes_json
  nodes_json="$(kubectl get nodes -o json 2>/dev/null)" \
    || { log "WARN: failed to get nodes"; return; }

  local node_summary
  node_summary="$(echo "${nodes_json}" | python3 -c "
import json, sys
data = json.load(sys.stdin)
nodes = []
for item in data.get('items', []):
    meta = item['metadata']
    status = item['status']
    conditions = {c['type']: c['status'] for c in status.get('conditions', [])}
    cap = status.get('capacity', {})
    alloc = status.get('allocatable', {})
    nodes.append({
        'name': meta['name'],
        'ready': conditions.get('Ready', 'Unknown'),
        'unschedulable': item['spec'].get('unschedulable', False),
        'creation_ts': meta.get('creationTimestamp', ''),
        'capacity_cpu': cap.get('cpu', ''),
        'capacity_memory': cap.get('memory', ''),
        'allocatable_cpu': alloc.get('cpu', ''),
        'allocatable_memory': alloc.get('memory', ''),
        'labels': {k: v for k, v in meta.get('labels', {}).items()
                   if any(x in k for x in ('instance-type', 'node.kubernetes.io', 'topology', 'doks.digitalocean.com'))},
    })
print(json.dumps(nodes))
" 2>/dev/null)" || { log "WARN: node parsing failed"; return; }

  printf '{"ts":"%s","epoch":%s,"type":"node_snapshot","nodes":%s}\n' \
    "${ts}" "${epoch}" "${node_summary}" >> "${NODE_LOG}"

  local current_count
  current_count="$(echo "${node_summary}" | python3 -c "import json,sys; print(len(json.loads(sys.stdin.read())))" 2>/dev/null)"
  if [[ -n "${PREVIOUS_NODE_COUNT}" && "${current_count}" != "${PREVIOUS_NODE_COUNT}" ]]; then
    emit_timeline "NODE_COUNT_CHANGE" \
      "$(printf '{"from":%s,"to":%s}' "${PREVIOUS_NODE_COUNT}" "${current_count}")"
    log "Node count changed: ${PREVIOUS_NODE_COUNT} -> ${current_count}"
  fi
  PREVIOUS_NODE_COUNT="${current_count}"
}

# ── PVC state ───────────────────────────────────────────────────────────────
collect_pvc_snapshot() {
  local ts epoch
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  epoch="$(date +%s)"

  local pvcs_json
  pvcs_json="$(kubectl_ns get pvc \
    -l "app.kubernetes.io/instance=${CLUSTER_NAME}" \
    -o json 2>/dev/null)" || { log "WARN: failed to get PVCs"; return; }

  local pvc_summary
  pvc_summary="$(echo "${pvcs_json}" | python3 -c "
import json, sys
data = json.load(sys.stdin)
pvcs = []
for item in data.get('items', []):
    meta = item['metadata']
    spec = item['spec']
    status = item['status']
    pvcs.append({
        'name': meta['name'],
        'phase': status.get('phase', 'Unknown'),
        'storage_requested': spec.get('resources', {}).get('requests', {}).get('storage', ''),
        'storage_capacity': status.get('capacity', {}).get('storage', ''),
        'access_modes': spec.get('accessModes', []),
        'storage_class': spec.get('storageClassName', ''),
        'volume_name': spec.get('volumeName', ''),
        'conditions': [{'type': c.get('type',''), 'status': c.get('status',''),
                         'message': c.get('message','')}
                        for c in status.get('conditions', [])],
    })
print(json.dumps(pvcs))
" 2>/dev/null)" || { log "WARN: pvc parsing failed"; return; }

  printf '{"ts":"%s","epoch":%s,"type":"pvc_snapshot","pvcs":%s}\n' \
    "${ts}" "${epoch}" "${pvc_summary}" >> "${PVC_LOG}"
}

# ── mysqld-exporter metrics (scraped via kubectl exec wget) ────────────────
collect_mysqld_metrics() {
  local ts epoch
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  epoch="$(date +%s)"

  local pods_list
  pods_list="$(kubectl_ns get pods \
    -l "app.kubernetes.io/instance=${CLUSTER_NAME},app.kubernetes.io/component=${MYSQL_COMPONENT_LABEL}" \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.phase}{"\n"}{end}' 2>/dev/null)"

  while IFS=' ' read -r pod_name pod_phase; do
    [[ -z "${pod_name}" ]] && continue
    [[ "${pod_phase}" != "Running" ]] && continue

    local raw_metrics
    raw_metrics="$(kubectl_ns exec "${pod_name}" -c mysqld-exporter -- \
      wget -qO- http://localhost:9104/metrics 2>/dev/null)" || { continue; }

    local metrics_json
    metrics_json="$(echo "${raw_metrics}" | python3 -c "
import sys, json
metrics = {}
for line in sys.stdin:
    line = line.strip()
    if not line or line.startswith('#'):
        continue
    parts = line.split(None, 1)
    if len(parts) != 2:
        continue
    name, val = parts
    try:
        val = float(val)
    except ValueError:
        continue
    # Only collect key metrics to keep output manageable
    keep = (
        'mysql_global_status_threads_running',
        'mysql_global_status_threads_connected',
        'mysql_global_status_queries',
        'mysql_global_status_questions',
        'mysql_global_status_com_select',
        'mysql_global_status_com_insert',
        'mysql_global_status_com_update',
        'mysql_global_status_com_delete',
        'mysql_global_status_com_commit',
        'mysql_global_status_com_rollback',
        'mysql_global_status_connections',
        'mysql_global_status_aborted_connects',
        'mysql_global_status_aborted_clients',
        'mysql_global_status_innodb_buffer_pool_bytes_data',
        'mysql_global_status_innodb_buffer_pool_bytes_dirty',
        'mysql_global_status_innodb_buffer_pool_read_requests',
        'mysql_global_status_innodb_buffer_pool_reads',
        'mysql_global_status_innodb_buffer_pool_wait_free',
        'mysql_global_status_innodb_buffer_pool_write_requests',
        'mysql_global_status_innodb_row_lock_waits',
        'mysql_global_status_innodb_row_lock_time',
        'mysql_global_status_innodb_rows_read',
        'mysql_global_status_innodb_rows_inserted',
        'mysql_global_status_innodb_rows_updated',
        'mysql_global_status_innodb_rows_deleted',
        'mysql_global_status_innodb_data_reads',
        'mysql_global_status_innodb_data_writes',
        'mysql_global_status_innodb_os_log_written',
        'mysql_global_status_slow_queries',
        'mysql_global_status_table_locks_waited',
        'mysql_global_status_open_tables',
        'mysql_global_status_max_used_connections',
        'mysql_global_variables_innodb_buffer_pool_size',
        'mysql_global_variables_max_connections',
    )
    if name in keep:
        metrics[name] = val
print(json.dumps(metrics))
" 2>/dev/null)" || { continue; }

    [[ -z "${metrics_json}" || "${metrics_json}" == "{}" ]] && continue

    printf '{"ts":"%s","epoch":%s,"pod":"%s","metrics":%s}\n' \
      "${ts}" "${epoch}" "${pod_name}" "${metrics_json}" >> "${METRICS_LOG}"

  done <<< "${pods_list}"
}

# ── Pod log streaming (background kubectl logs -f) ─────────────────────────
start_log_streams() {
  local pods_list
  pods_list="$(kubectl_ns get pods \
    -l "app.kubernetes.io/instance=${CLUSTER_NAME},app.kubernetes.io/component=${MYSQL_COMPONENT_LABEL}" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)"

  while IFS= read -r pod_name; do
    [[ -z "${pod_name}" ]] && continue

    # Stream MySQL container logs (errors, warnings, failover messages)
    local log_file="${POD_LOGS_DIR}/${pod_name}_mysql.log"
    kubectl_ns logs "${pod_name}" -c "${MYSQL_CONTAINER}" -f --timestamps \
      > "${log_file}" 2>/dev/null &
    LOG_STREAM_PIDS+=($!)
    log "started log stream for ${pod_name}/${MYSQL_CONTAINER} (pid=$!)"
  done <<< "${pods_list}"

  # Stream operator logs
  local operator_pod
  operator_pod="$(kubectl_ns get pods \
    -l "app.kubernetes.io/name=percona-server-mysql-operator" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || \
    kubectl_ns get pods \
    -l "app.kubernetes.io/name=percona-xtradb-cluster-operator" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"

  if [[ -n "${operator_pod}" ]]; then
    local op_log_file="${POD_LOGS_DIR}/${operator_pod}.log"
    kubectl_ns logs "${operator_pod}" -f --timestamps \
      > "${op_log_file}" 2>/dev/null &
    LOG_STREAM_PIDS+=($!)
    log "started log stream for operator ${operator_pod} (pid=$!)"
  fi
}

stop_log_streams() {
  for pid in "${LOG_STREAM_PIDS[@]}"; do
    kill "${pid}" 2>/dev/null || true
  done
  wait 2>/dev/null || true
  LOG_STREAM_PIDS=()
}

# Capture recent logs on shutdown (in case streaming missed anything)
capture_final_logs() {
  local pods_list
  pods_list="$(kubectl_ns get pods \
    -l "app.kubernetes.io/instance=${CLUSTER_NAME},app.kubernetes.io/component=${MYSQL_COMPONENT_LABEL}" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)"

  while IFS= read -r pod_name; do
    [[ -z "${pod_name}" ]] && continue
    # Grab the last 500 lines as a safety net
    kubectl_ns logs "${pod_name}" -c "${MYSQL_CONTAINER}" --tail=500 --timestamps \
      > "${POD_LOGS_DIR}/${pod_name}_mysql_final.log" 2>/dev/null || true
  done <<< "${pods_list}"
}

# ── One-time baseline capture ──────────────────────────────────────────────
capture_baseline() {
  log "capturing baseline state"

  kubectl_ns get "${CR_TYPE}" "${CLUSTER_NAME}" -o yaml > "${OUTPUT_DIR}/cr_baseline.yaml" 2>/dev/null || true
  kubectl_ns get pods -l "app.kubernetes.io/instance=${CLUSTER_NAME}" -o wide \
    > "${OUTPUT_DIR}/pods_baseline.txt" 2>/dev/null || true
  kubectl_ns get pvc -l "app.kubernetes.io/instance=${CLUSTER_NAME}" -o wide \
    > "${OUTPUT_DIR}/pvcs_baseline.txt" 2>/dev/null || true
  kubectl get nodes -o wide > "${OUTPUT_DIR}/nodes_baseline.txt" 2>/dev/null || true
  kubectl_ns describe "${CR_TYPE}" "${CLUSTER_NAME}" > "${OUTPUT_DIR}/cr_describe_baseline.txt" 2>/dev/null || true

  local password
  password="$(get_mysql_password)"
  if [[ -n "${password}" ]]; then
    local pods_list
    pods_list="$(kubectl_ns get pods \
      -l "app.kubernetes.io/instance=${CLUSTER_NAME},app.kubernetes.io/component=${MYSQL_COMPONENT_LABEL}" \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)"
    while IFS= read -r pod_name; do
      [[ -z "${pod_name}" ]] && continue
      if [[ "${CR_TYPE}" == "ps" ]]; then
        mysql_in_pod "${pod_name}" "${password}" -e "
          SHOW GLOBAL VARIABLES LIKE 'innodb_buffer_pool_size';
          SHOW GLOBAL VARIABLES LIKE 'max_connections';
          SELECT MEMBER_HOST, MEMBER_PORT, MEMBER_STATE, MEMBER_ROLE FROM performance_schema.replication_group_members;
          SHOW GLOBAL STATUS LIKE 'group_replication_%';
        " > "${OUTPUT_DIR}/mysql_baseline_${pod_name}.txt" 2>/dev/null || true
      else
        mysql_in_pod "${pod_name}" "${password}" -e "
          SHOW GLOBAL VARIABLES LIKE 'innodb_buffer_pool_size';
          SHOW GLOBAL VARIABLES LIKE 'max_connections';
          SHOW GLOBAL VARIABLES LIKE 'wsrep_%';
          SHOW GLOBAL STATUS LIKE 'wsrep_%';
        " > "${OUTPUT_DIR}/mysql_baseline_${pod_name}.txt" 2>/dev/null || true
      fi
    done <<< "${pods_list}"
  fi

  # Start background log streams for all MySQL pods + operator
  start_log_streams

  emit_timeline "MONITOR_START" "$(printf '\"baseline captured (cr_type=%s, cluster=%s)\"' "${CR_TYPE}" "${CLUSTER_NAME}")"
  log "baseline capture complete"
}

# ── Main loop ───────────────────────────────────────────────────────────────
shutdown() {
  log "monitor shutting down (signal received)"
  emit_timeline "MONITOR_STOP" '"received shutdown signal"'

  stop_log_streams
  capture_final_logs

  kubectl_ns get pods -l "app.kubernetes.io/instance=${CLUSTER_NAME}" -o wide \
    > "${OUTPUT_DIR}/pods_final.txt" 2>/dev/null || true
  kubectl_ns describe "${CR_TYPE}" "${CLUSTER_NAME}" > "${OUTPUT_DIR}/cr_describe_final.txt" 2>/dev/null || true
  kubectl get nodes -o wide > "${OUTPUT_DIR}/nodes_final.txt" 2>/dev/null || true

  log "final state captured — exiting"
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

  local cycle=0
  while true; do
    cycle=$((cycle + 1))

    collect_pod_snapshot
    collect_cr_status
    collect_pvc_snapshot

    # Replication queries are heavier; run every other cycle
    if (( cycle % 2 == 0 )); then
      collect_replication_status
    fi

    # mysqld-exporter metrics every other cycle (offset from replication)
    if (( cycle % 2 == 1 )); then
      collect_mysqld_metrics
    fi

    # Events and nodes every 3 cycles
    if (( cycle % 3 == 0 )); then
      collect_k8s_events
      collect_node_snapshot
    fi

    sleep "${POLL_INTERVAL}"
  done
}

main "$@"
