#!/usr/bin/env bash
# Background Kubernetes monitor for Percona MySQL scaling events.
#
# Replication mode is detected dynamically (written to replication_mode.txt):
#   gr      — Group Replication (performance_schema.replication_group_members)
#   async   — classic/async source→replica (SHOW REPLICA STATUS / PFS channels)
#   galera  — PXC / wsrep
#   unknown — single-node or not yet classified (uses read_only role fallback)
# Async-specific SQL only runs when mode is async/unknown; GR clusters unchanged.
#
# Tracks per poll cycle:
#   1. Role: which pod is PRIMARY, which are SECONDARY (GR / async / Galera)
#   2. Pod state: phase, ready, member state (ONLINE/RECOVERING/ERROR[/Synced])
#   3. DOKS node binding: which K8s worker node + slug each pod runs on
#   4. gr_detail: error / lag reason when state is not ONLINE
#   5. read_only / super_read_only per pod (failover detection)
#   6. Replication lag (GR apply queue, or async Seconds_Behind_Source)
#   7. replica_parallel_workers (configured) and active applier workers per pod
#   8. HAProxy/router pod state (phase, ready, backend routing)
#   9. K8s service endpoint changes (when HAProxy detects new primary)
#  10. K8s namespace events (pod kills, probe failures, scheduling)
#
# Outputs:
#   k8s_monitor.tsv        — per-pod time-series (MySQL pods)
#   haproxy_monitor.tsv    — per-pod time-series (HAProxy/router pods)
#   haproxy_conns.tsv      — CurrConns / backend scur per HAProxy pod
#   endpoints_monitor.tsv  — service endpoint changes
#   k8s_events.tsv         — namespace events log
#   pods_watch.log         — live kubectl get pods -o wide -w stream (timestamped)
#   k8s_monitor.log        — key events (failovers, changes)
#   replication_mode.txt   — detected mode: gr | async | galera | unknown
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
# Detected at runtime: gr | async | galera | unknown
REPL_MODE=""

mkdir -p "${OUTPUT_DIR}"

TSV_FILE="${OUTPUT_DIR}/k8s_monitor.tsv"
HAPROXY_TSV="${OUTPUT_DIR}/haproxy_monitor.tsv"
HAPROXY_CONNS_TSV="${OUTPUT_DIR}/haproxy_conns.tsv"
ENDPOINTS_TSV="${OUTPUT_DIR}/endpoints_monitor.tsv"
EVENTS_TSV="${OUTPUT_DIR}/k8s_events.tsv"
MONITOR_LOG="${OUTPUT_DIR}/k8s_monitor.log"
PODS_WATCH_LOG="${OUTPUT_DIR}/pods_watch.log"
PODS_WATCH_PID_FILE="${OUTPUT_DIR}/.pods_watch.pid"
PODS_WATCH_PID=""

: > "${MONITOR_LOG}"
: > "${PODS_WATCH_LOG}"

CACHED_PASSWORD=""
PREVIOUS_PRIMARY=""
PREVIOUS_NODE_MAP=""
PREVIOUS_POD_COUNT=""
PREVIOUS_PVC_SIZES=""
PREVIOUS_ENDPOINTS=""
PREVIOUS_HAPROXY_BACKENDS=""
NODE_CYCLE=0
NODES_LOADED=false
LAST_EVENT_TS=""

# Temporary files for lookups (avoids associative-array + set -u issues)
GR_TMP="${OUTPUT_DIR}/.gr_members.tsv"
GR_STATS_TMP="${OUTPUT_DIR}/.gr_stats.tsv"
READONLY_TMP="${OUTPUT_DIR}/.readonly_status.tsv"
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

# API-server reachability check (short timeout so polls don't hang forever).
cluster_reachable() {
  local timeout="${K8S_MONITOR_CONNECT_TIMEOUT_SEC:-10}"
  kubectl --request-timeout="${timeout}s" get --raw=/readyz >/dev/null 2>&1 \
    || kubectl --request-timeout="${timeout}s" cluster-info >/dev/null 2>&1
}

# Block until the Kubernetes API is reachable again.
# Used after transient API outages during node rolls / control-plane blips.
# Never exits the monitor — keeps retrying with exponential backoff.
ensure_cluster_connected() {
  if cluster_reachable; then
    return 0
  fi

  local attempt=0
  local backoff="${K8S_MONITOR_RECONNECT_BACKOFF_SEC:-5}"
  local max_backoff="${K8S_MONITOR_RECONNECT_MAX_BACKOFF_SEC:-60}"

  log "WARN: lost connection to Kubernetes API — entering reconnect loop"
  while true; do
    attempt=$((attempt + 1))
    log "reconnect attempt ${attempt} (next wait ${backoff}s if fail)"
    if cluster_reachable; then
      log "reconnected to Kubernetes API after ${attempt} attempt(s)"
      # Re-resolve CR in case the API was mid-upgrade when we lost contact.
      if ! auto_detect_cluster; then
        log "WARN: reconnected but cluster CR not found yet — will keep polling"
      fi
      return 0
    fi
    sleep "${backoff}"
    if [[ "${backoff}" -lt "${max_backoff}" ]]; then
      backoff=$((backoff * 2))
      [[ "${backoff}" -gt "${max_backoff}" ]] && backoff="${max_backoff}"
    fi
  done
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

list_running_mysql_pods() {
  kubectl_ns get pods \
    -l "app.kubernetes.io/instance=${CLUSTER_NAME},app.kubernetes.io/component=${MYSQL_COMPONENT_LABEL}" \
    -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true
}

# Persist + log replication mode (idempotent when unchanged).
set_replication_mode() {
  local mode="${1:?mode required}"
  local prev="${REPL_MODE}"
  REPL_MODE="${mode}"
  echo "${REPL_MODE}" > "${OUTPUT_DIR}/replication_mode.txt"
  if [[ "${prev}" != "${REPL_MODE}" ]]; then
    log "replication mode: ${REPL_MODE}${prev:+ (was ${prev})}"
  fi
}

# True when we should use async source/replica queries (not GR/Galera).
use_async_repl_queries() {
  [[ "${REPL_MODE}" == "async" || "${REPL_MODE}" == "unknown" ]]
}

# Detect GR vs async vs Galera. Sticky once GR/galera is confirmed so a
# transient empty GR membership during recovery does not flip to async.
detect_replication_mode() {
  if [[ "${REPL_MODE}" == "gr" || "${REPL_MODE}" == "galera" ]]; then
    return 0
  fi

  if [[ "${CR_TYPE}" == "pxc" ]]; then
    set_replication_mode "galera"
    return 0
  fi

  local password
  password="$(get_mysql_password)"
  if [[ -z "${password}" ]]; then
    [[ -z "${REPL_MODE}" ]] && set_replication_mode "unknown"
    return 0
  fi

  local running_pods
  running_pods="$(list_running_mysql_pods)"
  if [[ -z "${running_pods}" ]]; then
    [[ -z "${REPL_MODE}" ]] && set_replication_mode "unknown"
    return 0
  fi

  local saw_gr=0 saw_async=0 pod_count=0
  local pod_name gr_n async_n

  while IFS= read -r pod_name; do
    [[ -z "${pod_name}" ]] && continue
    pod_count=$((pod_count + 1))

    gr_n="$(mysql_in_pod "${pod_name}" "${password}" -e "
      SELECT COUNT(*)
        FROM performance_schema.replication_group_members
       WHERE MEMBER_ID <> ''
         AND MEMBER_STATE NOT IN ('', 'OFFLINE');
    " 2>/dev/null | tr -d '[:space:]')" || gr_n="0"

    if [[ "${gr_n}" =~ ^[1-9][0-9]*$ ]]; then
      saw_gr=1
      break
    fi

    async_n="$(mysql_in_pod "${pod_name}" "${password}" -e "
      SELECT COUNT(*)
        FROM performance_schema.replication_connection_status
       WHERE CHANNEL_NAME NOT LIKE 'group_replication%';
    " 2>/dev/null | tr -d '[:space:]')" || async_n="0"

    if [[ "${async_n}" =~ ^[1-9][0-9]*$ ]]; then
      saw_async=1
    fi
  done <<< "${running_pods}"

  if [[ "${saw_gr}" -eq 1 ]]; then
    set_replication_mode "gr"
  elif [[ "${saw_async}" -eq 1 ]]; then
    set_replication_mode "async"
  elif [[ "${REPL_MODE}" == "async" ]]; then
    # Keep async once observed (replica channel can flap during scale).
    return 0
  elif [[ "${pod_count}" -gt 1 ]]; then
    # Multi-pod PS without GR membership → treat as async topology.
    set_replication_mode "async"
  else
    set_replication_mode "unknown"
  fi
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

# ── Member info (GR / async / Galera) ──────────────────────────────────────
# Writes TSV to GR_TMP: short_hostname \t role \t state \t detail
refresh_gr_info() {
  : > "${GR_TMP}"
  : > "${GR_COUNTS_TMP}"

  local password
  password="$(get_mysql_password)"
  [[ -z "${password}" ]] && return

  if use_async_repl_queries; then
    refresh_async_member_info "${password}"
    return
  fi

  local running_pods
  running_pods="$(list_running_mysql_pods)" || {
    log "WARN: refresh_gr_info: failed to list running pods"
    return 0
  }

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
    # GR path empty — re-detect; may flip multi-pod PS to async next poll.
    if [[ "${REPL_MODE}" == "gr" ]]; then
      log "WARN: could not query GR from any pod"
    else
      log "WARN: could not query replication membership from any pod (mode=${REPL_MODE:-unset})"
    fi
    return
  fi

  local total=0 online=0
  echo "${gr_raw}" | while IFS=$'\t' read -r host role state detail; do
    [[ -z "${host}" ]] && continue
    detail="$(echo "${detail}" | tr '\t\n\r' '___' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -z "${detail}" ]] && detail="-"
    printf '%s\t%s\t%s\t%s\n' "${host}" "${role}" "${state}" "${detail}"
  done > "${GR_TMP}"

  if [[ -s "${GR_TMP}" ]]; then
    total="$(wc -l < "${GR_TMP}" | tr -d ' ')"
    online="$(grep -c '	ONLINE	\|	Synced	' "${GR_TMP}" 2>/dev/null || echo 0)"
  fi
  echo "${total}	${online}" > "${GR_COUNTS_TMP}"
}

# Async / unknown: per-pod role from read_only + SHOW REPLICA STATUS.
# Only used when use_async_repl_queries is true.
refresh_async_member_info() {
  local password="${1:?password required}"
  local running_pods
  running_pods="$(list_running_mysql_pods)" || {
    log "WARN: refresh_async_member_info: failed to list running pods"
    return 0
  }

  local total=0 online=0
  : > "${GR_TMP}"

  while IFS= read -r pod_name; do
    [[ -z "${pod_name}" ]] && continue

    local base_raw
    base_raw="$(mysql_in_pod "${pod_name}" "${password}" -e "
      SELECT SUBSTRING_INDEX(@@hostname, '.', 1), @@read_only, @@super_read_only;
    " 2>/dev/null)" || continue

    local host ro sro
    IFS=$'\t' read -r host ro sro <<< "${base_raw}"
    [[ -z "${host}" ]] && host="${pod_name}"

    local role="SECONDARY" state="ONLINE" detail="-" behind=""
    if [[ "${ro}" == "0" && "${sro}" == "0" ]]; then
      role="PRIMARY"
      state="ONLINE"
      detail="-"
    else
      role="SECONDARY"
      local replica_raw
      # SHOW REPLICA STATUS\G — empty on source; populated on replicas.
      replica_raw="$(mysql_in_pod "${pod_name}" "${password}" -e "SHOW REPLICA STATUS\G" 2>/dev/null)" || replica_raw=""

      if [[ -z "${replica_raw}" ]]; then
        state="RECOVERING"
        detail="no_replica_status"
      else
        local io_running sql_running last_io_err last_sql_err
        io_running="$(echo "${replica_raw}" | awk -F': ' '/^[[:space:]]*Replica_IO_Running:/{print $2; exit}')"
        sql_running="$(echo "${replica_raw}" | awk -F': ' '/^[[:space:]]*Replica_SQL_Running:/{print $2; exit}')"
        behind="$(echo "${replica_raw}" | awk -F': ' '/^[[:space:]]*Seconds_Behind_Source:/{print $2; exit}')"
        last_io_err="$(echo "${replica_raw}" | awk -F': ' '/^[[:space:]]*Last_IO_Error:/{print $2; exit}')"
        last_sql_err="$(echo "${replica_raw}" | awk -F': ' '/^[[:space:]]*Last_SQL_Error:/{print $2; exit}')"

        # Compatibility with older "Slave_*" field names if present.
        [[ -z "${io_running}" ]] && io_running="$(echo "${replica_raw}" | awk -F': ' '/^[[:space:]]*Slave_IO_Running:/{print $2; exit}')"
        [[ -z "${sql_running}" ]] && sql_running="$(echo "${replica_raw}" | awk -F': ' '/^[[:space:]]*Slave_SQL_Running:/{print $2; exit}')"
        [[ -z "${behind}" ]] && behind="$(echo "${replica_raw}" | awk -F': ' '/^[[:space:]]*Seconds_Behind_Master:/{print $2; exit}')"

        behind="${behind//[[:space:]]/}"
        [[ "${behind}" == "NULL" || -z "${behind}" ]] && behind=""

        local err_bits=""
        [[ -n "${last_io_err}" ]] && err_bits="${err_bits} io_err:${last_io_err}"
        [[ -n "${last_sql_err}" ]] && err_bits="${err_bits} sql_err:${last_sql_err}"
        err_bits="$(echo "${err_bits}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr '\t\n\r' '___')"

        if [[ "${io_running}" == "Yes" && "${sql_running}" == "Yes" ]]; then
          state="ONLINE"
          if [[ -n "${behind}" && "${behind}" != "0" ]]; then
            detail="behind=${behind}s"
          else
            detail="-"
          fi
        elif [[ -n "${err_bits}" ]]; then
          state="ERROR"
          detail="${err_bits}"
        elif [[ "${io_running}" == "Connecting" || "${sql_running}" == "Connecting" ]]; then
          state="RECOVERING"
          detail="io=${io_running:-?} sql=${sql_running:-?}"
        else
          state="RECOVERING"
          detail="io=${io_running:-?} sql=${sql_running:-?}${behind:+ behind=${behind}s}"
        fi
      fi
    fi

    detail="$(echo "${detail}" | tr '\t\n\r' '___' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -z "${detail}" ]] && detail="-"
    printf '%s\t%s\t%s\t%s\n' "${host}" "${role}" "${state}" "${detail}" >> "${GR_TMP}"
    total=$((total + 1))
    [[ "${state}" == "ONLINE" ]] && online=$((online + 1))
  done <<< "${running_pods}"

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

# ── Per-pod MySQL session vars (read_only + parallel applier workers) ─────
# Writes TSV to READONLY_TMP:
#   short_hostname \t read_only \t super_read_only \
#   replica_parallel_workers \t replica_parallel_active
#
# replica_parallel_workers = @@GLOBAL.replica_parallel_workers (configured)
# replica_parallel_active  = applier workers currently applying
#   GR: group_replication_applier channel
#   async: non-GR channels only
refresh_readonly_status() {
  : > "${READONLY_TMP}"

  local password
  password="$(get_mysql_password)"
  [[ -z "${password}" ]] && return

  local running_pods
  running_pods="$(list_running_mysql_pods)" || {
    log "WARN: refresh_readonly_status: failed to list running pods"
    return 0
  }

  local active_sql
  if use_async_repl_queries; then
    active_sql="(SELECT COUNT(*)
                FROM performance_schema.replication_applier_status_by_worker
               WHERE CHANNEL_NAME NOT LIKE 'group_replication%'
                 AND APPLYING_TRANSACTION <> '')"
  else
    active_sql="(SELECT COUNT(*)
                FROM performance_schema.replication_applier_status_by_worker
               WHERE CHANNEL_NAME = 'group_replication_applier'
                 AND APPLYING_TRANSACTION <> '')"
  fi

  while IFS= read -r pod_name; do
    [[ -z "${pod_name}" ]] && continue
    local ro_raw
    ro_raw="$(mysql_in_pod "${pod_name}" "${password}" -e "
      SELECT @@hostname,
             @@read_only,
             @@super_read_only,
             @@GLOBAL.replica_parallel_workers,
             ${active_sql};
    " 2>/dev/null)" || continue
    echo "${ro_raw}" | while IFS=$'\t' read -r host ro sro rpw_cfg rpw_active; do
      [[ -z "${host}" ]] && continue
      printf '%s\t%s\t%s\t%s\t%s\n' "${host}" "${ro}" "${sro}" "${rpw_cfg}" "${rpw_active}"
    done >> "${READONLY_TMP}"
  done <<< "${running_pods}"
}

# Lookup from READONLY_TMP: "read_only \t super_read_only"
readonly_lookup() {
  local pod_name="${1}"
  [[ -z "${pod_name}" || ! -f "${READONLY_TMP}" ]] && { echo "?\t?"; return; }
  local match
  match="$(grep "^${pod_name}	" "${READONLY_TMP}" 2>/dev/null | head -1)" || true
  if [[ -n "${match}" ]]; then
    echo "${match}" | cut -f2-3
  else
    echo "?\t?"
  fi
}

# Lookup from READONLY_TMP: "replica_parallel_workers \t replica_parallel_active"
parallel_workers_lookup() {
  local pod_name="${1}"
  [[ -z "${pod_name}" || ! -f "${READONLY_TMP}" ]] && { echo "?\t?"; return; }
  local match
  match="$(grep "^${pod_name}	" "${READONLY_TMP}" 2>/dev/null | head -1)" || true
  if [[ -n "${match}" ]]; then
    echo "${match}" | cut -f4-5
  else
    echo "?\t?"
  fi
}

# ── Replication lag stats ─────────────────────────────────────────────────
# Writes TSV to GR_STATS_TMP: short_hostname \t queue \t applier_queue
#   GR: COUNT_TRANSACTIONS_IN_QUEUE / REMOTE_IN_APPLIER_QUEUE
#   async: Seconds_Behind_Source in queue column; applier_queue unused (0)
refresh_gr_stats() {
  : > "${GR_STATS_TMP}"

  local password
  password="$(get_mysql_password)"
  [[ -z "${password}" ]] && return

  if use_async_repl_queries; then
    refresh_async_lag_stats "${password}"
    return
  fi

  local running_pods
  running_pods="$(list_running_mysql_pods)" || {
    log "WARN: refresh_gr_stats: failed to list running pods"
    return 0
  }

  local stats_raw="" queried_pod=""
  while IFS= read -r pod_name; do
    [[ -z "${pod_name}" ]] && continue
    if [[ "${CR_TYPE}" == "ps" ]]; then
      stats_raw="$(mysql_in_pod "${pod_name}" "${password}" -e "
        SELECT
          SUBSTRING_INDEX(MEMBER_ID, '-', -1) AS member_short,
          MEMBER_ID,
          COUNT_TRANSACTIONS_IN_QUEUE,
          COUNT_TRANSACTIONS_REMOTE_IN_APPLIER_QUEUE,
          COUNT_TRANSACTIONS_REMOTE_APPLIED,
          COUNT_TRANSACTIONS_LOCAL_PROPOSED
        FROM performance_schema.replication_group_member_stats;
      " 2>/dev/null)" && { queried_pod="${pod_name}"; break; }
    fi
  done <<< "${running_pods}"

  [[ -z "${stats_raw}" ]] && return

  # Map MEMBER_ID back to hostname using GR_TMP (which has hostnames)
  # We'll also query the hostname-to-member mapping
  local mapping_raw=""
  if [[ -n "${queried_pod}" ]]; then
    mapping_raw="$(mysql_in_pod "${queried_pod}" "${password}" -e "
      SELECT
        SUBSTRING_INDEX(MEMBER_HOST, '.', 1) AS short_host,
        COUNT_TRANSACTIONS_IN_QUEUE,
        COUNT_TRANSACTIONS_REMOTE_IN_APPLIER_QUEUE
      FROM performance_schema.replication_group_member_stats s
      JOIN performance_schema.replication_group_members m USING (MEMBER_ID);
    " 2>/dev/null)" || true
  fi

  if [[ -n "${mapping_raw}" ]]; then
    echo "${mapping_raw}" | while IFS=$'\t' read -r host queue applier_queue; do
      [[ -z "${host}" ]] && continue
      printf '%s\t%s\t%s\n' "${host}" "${queue}" "${applier_queue}"
    done > "${GR_STATS_TMP}"
  fi
}

refresh_async_lag_stats() {
  local password="${1:?password required}"
  local running_pods
  running_pods="$(list_running_mysql_pods)" || return 0

  : > "${GR_STATS_TMP}"
  while IFS= read -r pod_name; do
    [[ -z "${pod_name}" ]] && continue

    local host
    host="$(mysql_in_pod "${pod_name}" "${password}" -e "
      SELECT SUBSTRING_INDEX(@@hostname, '.', 1);
    " 2>/dev/null | tr -d '[:space:]')" || continue
    [[ -z "${host}" ]] && host="${pod_name}"

    local replica_raw behind="0"
    replica_raw="$(mysql_in_pod "${pod_name}" "${password}" -e "SHOW REPLICA STATUS\G" 2>/dev/null)" || replica_raw=""
    if [[ -n "${replica_raw}" ]]; then
      behind="$(echo "${replica_raw}" | awk -F': ' '/^[[:space:]]*Seconds_Behind_Source:/{print $2; exit}')"
      [[ -z "${behind}" ]] && behind="$(echo "${replica_raw}" | awk -F': ' '/^[[:space:]]*Seconds_Behind_Master:/{print $2; exit}')"
      behind="${behind//[[:space:]]/}"
      if [[ -z "${behind}" || "${behind}" == "NULL" ]]; then
        behind="0"
      fi
    fi

    # queue = Seconds_Behind_Source; applier_queue unused for async (0)
    printf '%s\t%s\t%s\n' "${host}" "${behind}" "0" >> "${GR_STATS_TMP}"
  done <<< "${running_pods}"
}

# Lookup from GR_STATS_TMP: given a pod name, return "queue \t applier_queue"
gr_stats_lookup() {
  local pod_name="${1}"
  [[ -z "${pod_name}" || ! -f "${GR_STATS_TMP}" ]] && { echo "?\t?"; return; }
  local match
  match="$(grep "^${pod_name}	" "${GR_STATS_TMP}" 2>/dev/null | head -1)" || true
  if [[ -n "${match}" ]]; then
    echo "${match}" | cut -f2-
  else
    echo "?\t?"
  fi
}

# ── HAProxy / MySQL Router pod monitoring ─────────────────────────────────
# Percona PS operator labels HAProxy pods as:
#   app.kubernetes.io/component=proxy
#   app.kubernetes.io/name=haproxy
poll_haproxy_pods() {
  local ts="${1:?timestamp required}"

  local haproxy_json
  haproxy_json="$(kubectl_ns get pods \
    -l "app.kubernetes.io/instance=${CLUSTER_NAME}" \
    -o json 2>/dev/null)" || return

  local proxy_lines
  proxy_lines="$(echo "${haproxy_json}" | python3 -c "
import json, sys
data = json.load(sys.stdin)
# Percona PS operator labels HAProxy as component=proxy + name=haproxy
# (not component=haproxy). Also accept router/proxysql variants.
PROXY_COMPONENTS = {'haproxy', 'proxy', 'router', 'proxysql', 'mysql-router'}
PROXY_NAMES = {'haproxy', 'router', 'proxysql', 'mysql-router'}
for item in data.get('items', []):
    meta = item['metadata']
    labels = meta.get('labels', {})
    component = labels.get('app.kubernetes.io/component', '')
    app_name = labels.get('app.kubernetes.io/name', '')
    if component not in PROXY_COMPONENTS and app_name not in PROXY_NAMES:
        continue
    # Prefer a stable display label (haproxy/router) over generic 'proxy'
    display = app_name if app_name in PROXY_NAMES else (component or 'proxy')
    spec = item['spec']
    status = item['status']
    cs = status.get('containerStatuses', [])
    ready = all(c.get('ready', False) for c in cs) if cs else False
    restarts = sum(c.get('restartCount', 0) for c in cs)
    # Container state reason
    reason = ''
    for c in cs:
        state_info = c.get('state', {})
        for stype in ('waiting', 'terminated'):
            if stype in state_info:
                reason = state_info[stype].get('reason', '')
                break
        if reason:
            break
    print('\t'.join([
        meta['name'],
        display,
        status.get('phase', 'Unknown'),
        'true' if ready else 'false',
        spec.get('nodeName', ''),
        str(restarts),
        reason or '-',
    ]))
" 2>/dev/null)" || return

  [[ -z "${proxy_lines}" ]] && return

  while IFS=$'\t' read -r pod_name component phase ready node restarts reason; do
    [[ -z "${pod_name}" ]] && continue
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${ts}" "${pod_name}" "${component}" "${phase}" "${ready}" \
      "${node}" "${restarts}" "${reason}" \
      >> "${HAPROXY_TSV}"
  done <<< "${proxy_lines}"
}

# ── HAProxy connection count polling (via admin socket) ───────────────────
# Polls CurrConns + per-backend session counts from each HAProxy pod.
# Writes to haproxy_conns.tsv: timestamp, pod, curr_conns, cum_conns,
#   mysql_primary_scur, mysql_replicas_scur, mysql_admin_scur
#
# Label note: Percona PS operator sets component=proxy + name=haproxy
# (not component=haproxy). Prefer name=haproxy scoped to this cluster.
poll_haproxy_conns() {
  local ts="${1:?timestamp required}"

  local haproxy_pods
  haproxy_pods="$(kubectl_ns get pods \
    -l "app.kubernetes.io/instance=${CLUSTER_NAME},app.kubernetes.io/name=haproxy" \
    -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{"\n"}{end}' 2>/dev/null)" || return

  # Fallback: older/alternate label layouts
  if [[ -z "${haproxy_pods}" ]]; then
    haproxy_pods="$(kubectl_ns get pods \
      -l "app.kubernetes.io/instance=${CLUSTER_NAME},app.kubernetes.io/component=proxy" \
      -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{"\n"}{end}' 2>/dev/null)" || return
  fi

  while IFS= read -r pod_name; do
    [[ -z "${pod_name}" ]] && continue

    local raw
    # Use printf so fields are real tabs; sock path matches Percona PS image.
    raw="$(kubectl_ns exec "${pod_name}" -c haproxy -- sh -c '
      SOCK=/etc/haproxy/mysql/haproxy.sock
      info=$(echo "show info" | socat stdio "$SOCK" 2>/dev/null)
      curr=$(echo "$info" | awk -F": " "/^CurrConns:/{print \$2}")
      cum=$(echo "$info" | awk -F": " "/^CumConns:/{print \$2}")
      stat=$(echo "show stat" | socat stdio "$SOCK" 2>/dev/null)
      primary_scur=$(echo "$stat" | awk -F, "/^mysql-primary,BACKEND/{print \$5}")
      replicas_scur=$(echo "$stat" | awk -F, "/^mysql-replicas,BACKEND/{print \$5}")
      admin_scur=$(echo "$stat" | awk -F, "/^mysql-admin,BACKEND/{print \$5}")
      printf "%s\t%s\t%s\t%s\t%s\n" \
        "${curr:-0}" "${cum:-0}" \
        "${primary_scur:-0}" "${replicas_scur:-0}" "${admin_scur:-0}"
    ' 2>/dev/null)" || continue

    [[ -z "${raw}" ]] && continue

    local curr_conns cum_conns primary_scur replicas_scur admin_scur
    IFS=$'\t' read -r curr_conns cum_conns primary_scur replicas_scur admin_scur <<< "${raw}"

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${ts}" "${pod_name}" \
      "${curr_conns:-0}" "${cum_conns:-0}" \
      "${primary_scur:-0}" "${replicas_scur:-0}" "${admin_scur:-0}" \
      >> "${HAPROXY_CONNS_TSV}"
  done <<< "${haproxy_pods}"
}

# ── Service endpoints tracking (reveals when HAProxy sees new primary) ────
poll_endpoints() {
  local ts="${1:?timestamp required}"

  # Get endpoints for the cluster's services
  local endpoints_json
  endpoints_json="$(kubectl_ns get endpoints \
    -l "app.kubernetes.io/instance=${CLUSTER_NAME}" \
    -o json 2>/dev/null)" || return

  local ep_lines
  ep_lines="$(echo "${endpoints_json}" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for item in data.get('items', []):
    name = item['metadata']['name']
    subsets = item.get('subsets', [])
    for subset in subsets:
        addrs = subset.get('addresses', [])
        not_ready = subset.get('notReadyAddresses', [])
        ports = subset.get('ports', [])
        port_str = ','.join(f\"{p.get('name','')}/{p.get('port','')}\" for p in ports)
        for a in addrs:
            target = a.get('targetRef', {})
            pod = target.get('name', a.get('ip', '?'))
            print(f\"{name}\tready\t{pod}\t{a.get('ip','')}\t{port_str}\")
        for a in not_ready:
            target = a.get('targetRef', {})
            pod = target.get('name', a.get('ip', '?'))
            print(f\"{name}\tnot_ready\t{pod}\t{a.get('ip','')}\t{port_str}\")
" 2>/dev/null)" || return

  local current_endpoints=""
  while IFS=$'\t' read -r svc_name ep_state pod_name ip ports; do
    [[ -z "${svc_name}" ]] && continue
    current_endpoints="${current_endpoints}${svc_name}:${ep_state}:${pod_name} "
  done <<< "${ep_lines}"

  # Only record when endpoints change (plus initial baseline on first poll)
  if [[ -z "${PREVIOUS_ENDPOINTS}" ]]; then
    while IFS=$'\t' read -r svc_name ep_state pod_name ip ports; do
      [[ -z "${svc_name}" ]] && continue
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "${ts}" "${svc_name}" "${ep_state}" "${pod_name}" "${ip}" "${ports}" \
        >> "${ENDPOINTS_TSV}"
    done <<< "${ep_lines}"
    log "ENDPOINTS baseline: ${current_endpoints}"
  elif [[ "${current_endpoints}" != "${PREVIOUS_ENDPOINTS}" ]]; then
    while IFS=$'\t' read -r svc_name ep_state pod_name ip ports; do
      [[ -z "${svc_name}" ]] && continue
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "${ts}" "${svc_name}" "${ep_state}" "${pod_name}" "${ip}" "${ports}" \
        >> "${ENDPOINTS_TSV}"
    done <<< "${ep_lines}"
    log "ENDPOINT CHANGE detected (HAProxy routing may have shifted)"
    log "  was: ${PREVIOUS_ENDPOINTS}"
    log "  now: ${current_endpoints}"
  fi
  PREVIOUS_ENDPOINTS="${current_endpoints}"
}

# ── K8s events capture (namespace-scoped) ─────────────────────────────────
poll_k8s_events() {
  local ts="${1:?timestamp required}"

  local events_json
  # Get events from the last 60 seconds to avoid duplicates across polls
  events_json="$(kubectl_ns get events \
    --sort-by='.lastTimestamp' \
    -o json 2>/dev/null)" || return

  echo "${events_json}" | python3 -c "
import json, sys, os

last_ts_file = os.environ.get('LAST_EVENT_TS_FILE', '')
last_seen = ''
if last_ts_file and os.path.isfile(last_ts_file):
    with open(last_ts_file) as f:
        last_seen = f.read().strip()

data = json.load(sys.stdin)
events = data.get('items', [])

new_last = last_seen
output_lines = []
for e in events:
    event_ts = e.get('lastTimestamp', '') or e.get('metadata', {}).get('creationTimestamp', '')
    if last_seen and event_ts <= last_seen:
        continue
    kind = e.get('involvedObject', {}).get('kind', '?')
    obj_name = e.get('involvedObject', {}).get('name', '?')
    reason = e.get('reason', '?')
    msg = e.get('message', '').replace('\t', ' ').replace('\n', ' ')[:200]
    etype = e.get('type', 'Normal')
    count = e.get('count', 1)
    output_lines.append(f\"{event_ts}\t{etype}\t{kind}\t{obj_name}\t{reason}\t{count}\t{msg}\")
    if event_ts > new_last:
        new_last = event_ts

for line in output_lines:
    print(line)

if last_ts_file and new_last != last_seen:
    with open(last_ts_file, 'w') as f:
        f.write(new_last)
" 2>/dev/null | while IFS=$'\t' read -r event_ts etype kind obj reason count msg; do
    [[ -z "${event_ts}" ]] && continue
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${ts}" "${event_ts}" "${etype}" "${kind}" "${obj}" "${reason}" "${count}" "${msg}" \
      >> "${EVENTS_TSV}"

    # Log notable events (warnings, errors, pod kills, probe failures)
    if [[ "${etype}" == "Warning" ]] || \
       [[ "${reason}" == "Killing" || "${reason}" == "Unhealthy" || \
          "${reason}" == "FailedScheduling" || "${reason}" == "Evicted" || \
          "${reason}" == "OOMKilling" || "${reason}" == "BackOff" ]]; then
      log "K8S_EVENT [${etype}] ${kind}/${obj}: ${reason} — ${msg}"
    fi
  done
}

# ── Single poll ────────────────────────────────────────────────────────────
poll_once() {
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  maybe_refresh_nodes || true
  # Re-detect until sticky GR/galera; allows unknown→async and async→gr.
  detect_replication_mode || true
  refresh_gr_info || true
  refresh_readonly_status || true
  refresh_gr_stats || true
  refresh_pvc_info || true

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

    # read_only / super_read_only status
    local ro_info
    ro_info="$(readonly_lookup "${pod_name}")"
    local read_only super_read_only
    read_only="$(echo "${ro_info}" | cut -f1)"
    super_read_only="$(echo "${ro_info}" | cut -f2)"

    # GR replication queue stats
    local stats_info
    stats_info="$(gr_stats_lookup "${pod_name}")"
    local gr_queue gr_applier_queue
    gr_queue="$(echo "${stats_info}" | cut -f1)"
    gr_applier_queue="$(echo "${stats_info}" | cut -f2)"

    # replica_parallel_workers (configured vs active/busy)
    local rpw_info
    rpw_info="$(parallel_workers_lookup "${pod_name}")"
    local replica_parallel_workers replica_parallel_active
    replica_parallel_workers="$(echo "${rpw_info}" | cut -f1)"
    replica_parallel_active="$(echo "${rpw_info}" | cut -f2)"

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${ts}" "${pod_name}" "${phase}" "${ready}" \
      "${gr_role}" "${gr_state}" "${gr_detail}" "${gr_members}" "${gr_online}" \
      "${node}" "${node_slug}" "${node_cpu}" "${node_mem}" \
      "${pvc_req}" "${pvc_cap}" "${restarts}" "${deleting}" \
      "${read_only}" "${super_read_only}" "${gr_queue}" "${gr_applier_queue}" \
      "${replica_parallel_workers}" "${replica_parallel_active}" \
      >> "${TSV_FILE}"

    # Log transitions to/from read_only (key failover indicator)
    if [[ "${read_only}" == "1" && "${gr_role}" == "PRIMARY" ]]; then
      log "READ_ONLY on PRIMARY: ${pod_name} (read_only=${read_only}, super_read_only=${super_read_only}) — failover imminent or in progress"
    fi

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

  # Poll HAProxy/router pods, endpoints, connections, and K8s events.
  # Each step is independent — one failure must not abort the others.
  poll_haproxy_pods "${ts}" || log "WARN: poll_haproxy_pods failed"
  poll_haproxy_conns "${ts}" || log "WARN: poll_haproxy_conns failed"
  poll_endpoints "${ts}" || log "WARN: poll_endpoints failed"
  poll_k8s_events "${ts}" || log "WARN: poll_k8s_events failed"
}

# ── Startup / shutdown ─────────────────────────────────────────────────────

# Continuous kubectl get pods -o wide -w into pods_watch.log (separate from poll TSV).
# Reconnects automatically if the watch stream dies (API blip / timeout).
start_pods_watch() {
  (
    local backoff=5
    while true; do
      {
        echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] === pods watch (re)starting: kubectl get pods -n ${NAMESPACE} -o wide -w ==="
        # Prefix every watch line with UTC timestamp. Stream stderr into the same file.
        kubectl --namespace="${NAMESPACE}" get pods -o wide -w 2>&1 | while IFS= read -r line; do
          echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ${line}"
        done
        echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] === pods watch stream ended — reconnecting in ${backoff}s ==="
      } >> "${PODS_WATCH_LOG}"
      sleep "${backoff}"
      if [[ "${backoff}" -lt 60 ]]; then
        backoff=$((backoff * 2))
        [[ "${backoff}" -gt 60 ]] && backoff=60
      fi
    done
  ) &
  PODS_WATCH_PID=$!
  echo "${PODS_WATCH_PID}" > "${PODS_WATCH_PID_FILE}"
  log "pods watch started (pid=${PODS_WATCH_PID}) -> ${PODS_WATCH_LOG}"
}

stop_pods_watch() {
  local pid="${PODS_WATCH_PID:-}"
  if [[ -z "${pid}" && -f "${PODS_WATCH_PID_FILE}" ]]; then
    pid="$(cat "${PODS_WATCH_PID_FILE}" 2>/dev/null || true)"
  fi
  if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
    log "stopping pods watch (pid=${pid})"
    # Kill kubectl child(ren) first, then the wrapper loop.
    pkill -TERM -P "${pid}" 2>/dev/null || true
    kill -TERM "${pid}" 2>/dev/null || true
    wait "${pid}" 2>/dev/null || true
  fi
  rm -f "${PODS_WATCH_PID_FILE}"
  PODS_WATCH_PID=""
}

capture_baseline() {
  log "capturing baseline"
  kubectl_ns get pods -l "app.kubernetes.io/instance=${CLUSTER_NAME}" -o wide \
    > "${OUTPUT_DIR}/pods_baseline.txt" 2>/dev/null || true
  kubectl get nodes -o wide > "${OUTPUT_DIR}/nodes_baseline.txt" 2>/dev/null || true
  log "baseline saved"
}

shutdown() {
  log "monitor shutting down"
  stop_pods_watch
  kubectl_ns get pods -l "app.kubernetes.io/instance=${CLUSTER_NAME}" -o wide \
    > "${OUTPUT_DIR}/pods_final.txt" 2>/dev/null || true
  kubectl get nodes -o wide > "${OUTPUT_DIR}/nodes_final.txt" 2>/dev/null || true
  # Capture final endpoint state for debugging
  kubectl_ns get endpoints -l "app.kubernetes.io/instance=${CLUSTER_NAME}" -o wide \
    > "${OUTPUT_DIR}/endpoints_final.txt" 2>/dev/null || true
  rm -f "${GR_TMP}" "${GR_STATS_TMP}" "${READONLY_TMP}" "${NODE_TMP}" "${PVC_TMP}" "${GR_COUNTS_TMP}" "${LAST_EVENT_TS_FILE:-}"
  log "final state saved — exiting (replication_mode=${REPL_MODE:-unset})"
  exit 0
}
trap shutdown SIGTERM SIGINT

main() {
  log "k8s_scaling_monitor starting"
  log "KUBECONFIG=${KUBECONFIG}"
  log "NAMESPACE=${NAMESPACE}"
  log "POLL_INTERVAL=${POLL_INTERVAL}s"

  # Wait for initial API connectivity (same reconnect loop as mid-run).
  ensure_cluster_connected

  # Wait until the Percona CR is visible (API can be up before CRs are).
  local detect_attempt=0
  until auto_detect_cluster; do
    detect_attempt=$((detect_attempt + 1))
    log "WARN: cluster CR not found yet (attempt ${detect_attempt}) — retrying in 10s"
    sleep 10
    ensure_cluster_connected
  done
  log "CLUSTER=${CLUSTER_NAME} CR_TYPE=${CR_TYPE} CONTAINER=${MYSQL_CONTAINER}"

  detect_replication_mode || true
  log "REPL_MODE=${REPL_MODE:-unset}"

  capture_baseline

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "timestamp" "pod" "phase" "ready" \
    "gr_role" "gr_state" "gr_detail" "gr_members" "gr_online" \
    "doks_node" "slug" "vcpus" "mem_gib" \
    "pvc_req" "pvc_cap" "restarts" "deleting" \
    "read_only" "super_read_only" "gr_queue" "gr_applier_queue" \
    "replica_parallel_workers" "replica_parallel_active" \
    > "${TSV_FILE}"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "timestamp" "pod" "component" "phase" "ready" "node" "restarts" "reason" \
    > "${HAPROXY_TSV}"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "timestamp" "pod" "curr_conns" "cum_conns" \
    "mysql_primary_scur" "mysql_replicas_scur" "mysql_admin_scur" \
    > "${HAPROXY_CONNS_TSV}"

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "timestamp" "service" "state" "pod" "ip" "ports" \
    > "${ENDPOINTS_TSV}"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "poll_ts" "event_ts" "type" "kind" "object" "reason" "count" "message" \
    > "${EVENTS_TSV}"

  # Track last-seen event timestamp to avoid duplicate event output
  export LAST_EVENT_TS_FILE="${OUTPUT_DIR}/.last_event_ts"
  : > "${LAST_EVENT_TS_FILE}"

  log "polling started"
  start_pods_watch

  local consecutive_failures=0
  while true; do
    # If API is down, block in reconnect loop until it comes back.
    ensure_cluster_connected

    # Never let a single poll failure kill the monitor (set -e).
    if poll_once; then
      consecutive_failures=0
    else
      consecutive_failures=$((consecutive_failures + 1))
      log "WARN: poll_once failed (consecutive=${consecutive_failures}) — retrying after ${POLL_INTERVAL}s"
      # After repeated poll failures, force a connectivity check next iteration.
      if [[ "${consecutive_failures}" -ge 3 ]]; then
        if ! cluster_reachable; then
          log "WARN: ${consecutive_failures} consecutive poll failures and API unreachable"
        fi
      fi
    fi
    sleep "${POLL_INTERVAL}"
  done
}

main "$@"
