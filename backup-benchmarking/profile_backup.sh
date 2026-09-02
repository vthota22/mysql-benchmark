#!/usr/bin/env bash
# Profile a Percona XtraBackup on a Kubernetes-based MySQL cluster.
# Captures xtrabackup logs, MySQL server metrics, and pod resource usage
# to break down where backup time is spent.
#
# Usage:
#   ./profile_backup.sh --kubeconfig <path> --namespace <ns> [options]
#
# Modes:
#   (default)     Wait for a backup to start, then monitor it
#   --attach      Attach to an already-running backup
#
# Examples:
#   ./profile_backup.sh --kubeconfig ~/.kube/config --namespace mysql-prod
#   ./profile_backup.sh --kubeconfig ~/.kube/config --namespace mysql-prod --pod mysql-0 --attach
#   BENCHMARK_CONF=benchmark.conf ./profile_backup.sh --kubeconfig ~/.kube/config --namespace mysql-prod
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
KUBECONFIG_PATH=""
NAMESPACE=""
POD_NAME=""
ATTACH_MODE=0
TIMEOUT=3600
POLL_INTERVAL=10
RESULTS_BASE="${SCRIPT_DIR}/results"

MYSQL_HOST="${MYSQL_HOST:-}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-}"
MYSQL_CONNECT_VIA=""  # "direct" or "kubectl"

DETECTED_CONTAINER=""
DETECTED_SOURCE=""  # "pod-container", "backup-pod", "process"

# PIDs of background workers — cleaned up on exit
declare -a BG_PIDS=()

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log_ts() {
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "[${ts}] $*"
}

epoch_now() { date +%s; }

epoch_to_utc() {
  local epoch="${1:?}"
  if date -u -r 0 +%Y >/dev/null 2>&1; then
    date -u -r "${epoch}" +%Y-%m-%dT%H:%M:%SZ
  else
    date -u -d "@${epoch}" +%Y-%m-%dT%H:%M:%SZ
  fi
}

kctl() {
  kubectl --kubeconfig="${KUBECONFIG_PATH}" -n "${NAMESPACE}" "$@"
}

cleanup() {
  local pid
  for pid in "${BG_PIDS[@]}"; do
    kill "${pid}" 2>/dev/null || true
    wait "${pid}" 2>/dev/null || true
  done
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
usage() {
  echo "Usage: $0 --kubeconfig <path> --namespace <ns> [options]"
  echo ""
  echo "Required:"
  echo "  --kubeconfig <path>    Path to kubeconfig file"
  echo "  --namespace <ns>       Kubernetes namespace"
  echo ""
  echo "Optional:"
  echo "  --pod <name>           MySQL pod name (default: auto-detect mysql-0)"
  echo "  --attach               Attach to an already-running backup"
  echo "  --timeout <sec>        Max seconds to wait for backup (default: 3600)"
  echo "  --poll-interval <sec>  MySQL/resource poll interval (default: 10)"
  echo "  --mysql-host <host>    MySQL host for direct connection"
  echo "  --mysql-port <port>    MySQL port (default: 3306)"
  echo "  --mysql-user <user>    MySQL user (default: root)"
  echo "  --mysql-password <pw>  MySQL password"
  echo ""
  echo "Config:"
  echo "  BENCHMARK_CONF=benchmark.conf  Load MySQL creds from config file"
  exit 1
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --kubeconfig)   KUBECONFIG_PATH="$2"; shift 2 ;;
      --namespace)    NAMESPACE="$2"; shift 2 ;;
      --pod)          POD_NAME="$2"; shift 2 ;;
      --attach)       ATTACH_MODE=1; shift ;;
      --timeout)      TIMEOUT="$2"; shift 2 ;;
      --poll-interval) POLL_INTERVAL="$2"; shift 2 ;;
      --mysql-host)   MYSQL_HOST="$2"; shift 2 ;;
      --mysql-port)   MYSQL_PORT="$2"; shift 2 ;;
      --mysql-user)   MYSQL_USER="$2"; shift 2 ;;
      --mysql-password) MYSQL_PASSWORD="$2"; shift 2 ;;
      -h|--help)      usage ;;
      *)              echo "Unknown option: $1" >&2; usage ;;
    esac
  done

  if [[ -z "${KUBECONFIG_PATH}" ]]; then
    echo "ERROR: --kubeconfig is required" >&2; usage
  fi
  if [[ ! -f "${KUBECONFIG_PATH}" ]]; then
    echo "ERROR: kubeconfig not found: ${KUBECONFIG_PATH}" >&2; exit 1
  fi
  if [[ -z "${NAMESPACE}" ]]; then
    echo "ERROR: --namespace is required" >&2; usage
  fi
}

load_optional_config() {
  local conf="${BENCHMARK_CONF:-}"
  if [[ -n "${conf}" && -f "${conf}" ]]; then
    log_ts "Loading MySQL config from ${conf}"
    # shellcheck source=/dev/null
    source "${conf}"
  fi
}

# ---------------------------------------------------------------------------
# MySQL connection helpers
# ---------------------------------------------------------------------------
KUBE_MYSQL_PASSWORD=""

setup_mysql_connection() {
  if [[ -n "${MYSQL_HOST}" && -n "${MYSQL_PASSWORD}" ]]; then
    MYSQL_CONNECT_VIA="direct"
    log_ts "MySQL: direct connection to ${MYSQL_HOST}:${MYSQL_PORT}"
  else
    MYSQL_CONNECT_VIA="kubectl"
    log_ts "MySQL: will use kubectl exec into ${POD_NAME}"
    # Resolve root password from K8s secret for kubectl-based queries.
    local secret_name
    secret_name="$(kctl get secrets -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
      | grep -E '^internal-' | head -1)" || true
    if [[ -n "${secret_name}" ]]; then
      KUBE_MYSQL_PASSWORD="$(kctl get secret "${secret_name}" \
        -o jsonpath='{.data.root}' 2>/dev/null | base64 -d 2>/dev/null)" || true
    fi
    if [[ -n "${KUBE_MYSQL_PASSWORD}" ]]; then
      log_ts "MySQL: resolved root password from secret ${secret_name}"
    else
      log_ts "MySQL: WARNING — no root password found; kubectl queries may fail"
    fi
  fi
}

run_mysql_query() {
  local query="${1:?query required}"
  if [[ "${MYSQL_CONNECT_VIA}" == "direct" ]]; then
    mysql -h "${MYSQL_HOST}" -P "${MYSQL_PORT}" -u "${MYSQL_USER}" \
      -p"${MYSQL_PASSWORD}" --ssl-mode=REQUIRED -N -e "${query}" 2>/dev/null
  else
    local -a mysql_args=(-u root -N)
    if [[ -n "${KUBE_MYSQL_PASSWORD}" ]]; then
      mysql_args+=(-p"${KUBE_MYSQL_PASSWORD}")
    fi
    kctl exec "${POD_NAME}" -c "${DETECTED_CONTAINER:-mysql}" -- \
      mysql "${mysql_args[@]}" -e "${query}" 2>/dev/null
  fi
}

# ---------------------------------------------------------------------------
# Auto-detection
# ---------------------------------------------------------------------------
detect_mysql_pod() {
  if [[ -n "${POD_NAME}" ]]; then
    log_ts "Using specified pod: ${POD_NAME}"
    return 0
  fi

  log_ts "Auto-detecting MySQL pod in namespace ${NAMESPACE}..."

  local pod
  # Try common StatefulSet patterns
  for pattern in mysql-0 percona-0 pxc-0; do
    if kctl get pod "${pattern}" -o name >/dev/null 2>&1; then
      POD_NAME="${pattern}"
      log_ts "Found MySQL pod: ${POD_NAME}"
      return 0
    fi
  done

  # Broader search: Running pods with "mysql" in the name.
  # Prefer StatefulSet pods (name ends with -N) over operator/deployment pods.
  pod="$(kctl get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\n"}{end}' 2>/dev/null \
    | grep -i mysql | grep Running \
    | grep -v 'operator' \
    | awk '$1 ~ /-[0-9]+$/ {print $1; exit}')" || true
  if [[ -n "${pod}" ]]; then
    POD_NAME="${pod}"
    log_ts "Found MySQL pod: ${POD_NAME}"
    return 0
  fi

  # Last resort: any Running pod with mysql (excluding operator pods)
  pod="$(kctl get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\n"}{end}' 2>/dev/null \
    | grep -i mysql | grep Running \
    | grep -v 'operator' \
    | head -1 | awk '{print $1}')" || true
  if [[ -n "${pod}" ]]; then
    POD_NAME="${pod}"
    log_ts "Found MySQL pod: ${POD_NAME}"
    return 0
  fi

  echo "ERROR: Could not auto-detect a MySQL pod. Use --pod <name>." >&2
  return 1
}

detect_main_container() {
  local containers
  containers="$(kctl get pod "${POD_NAME}" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null)" || true
  for c in ${containers}; do
    case "${c}" in
      mysql|mysqld|percona|pxc)
        DETECTED_CONTAINER="${c}"
        return 0
        ;;
    esac
  done
  # Fall back to first container
  DETECTED_CONTAINER="$(echo "${containers}" | awk '{print $1}')"
}

# Look for a running xtrabackup process inside the MySQL pod.
detect_xtrabackup_process() {
  local result
  result="$(kctl exec "${POD_NAME}" -c "${DETECTED_CONTAINER}" -- \
    sh -c 'pgrep -a xtrabackup 2>/dev/null || true' 2>/dev/null)" || true
  if [[ -n "${result}" ]]; then
    DETECTED_SOURCE="process"
    return 0
  fi
  return 1
}

# Look for standalone backup pods/jobs in the namespace (xb-cron-*, xb-ondemand-*).
detect_backup_pod() {
  local pod
  pod="$(kctl get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\n"}{end}' 2>/dev/null \
    | grep -iE 'backup|xtrabackup|xb-' | grep -i running | head -1 | awk '{print $1}')" || true
  if [[ -n "${pod}" ]]; then
    POD_NAME="${pod}"
    DETECTED_SOURCE="backup-pod"
    local containers
    containers="$(kctl get pod "${pod}" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null)" || true
    DETECTED_CONTAINER="$(echo "${containers}" | awk '{print $1}')"
    log_ts "Found backup pod: ${pod} (container: ${DETECTED_CONTAINER})"
    return 0
  fi
  return 1
}

# Find the xtrabackup sidecar container name in the MySQL pod (for log streaming).
# This does NOT indicate a backup is running — the sidecar is always present.
find_xtrabackup_sidecar() {
  local containers
  containers="$(kctl get pod "${POD_NAME}" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null)" || true
  for c in ${containers}; do
    case "${c}" in
      xtrabackup|backup|xb-*)
        DETECTED_CONTAINER="${c}"
        return 0
        ;;
    esac
  done
  return 1
}

detect_running_backup() {
  # 1. Running backup pod/job is the strongest signal
  detect_backup_pod && return 0
  # 2. xtrabackup process inside the MySQL pod
  detect_xtrabackup_process && return 0
  return 1
}

# ---------------------------------------------------------------------------
# Wait for backup to start
# ---------------------------------------------------------------------------
wait_for_backup() {
  local start_epoch deadline
  start_epoch="$(epoch_now)"
  deadline=$((start_epoch + TIMEOUT))

  log_ts "Waiting for a backup to start (timeout: ${TIMEOUT}s, checking every 5s)..."

  while true; do
    if [[ "$(epoch_now)" -ge "${deadline}" ]]; then
      echo "ERROR: Timed out after ${TIMEOUT}s waiting for a backup to start" >&2
      return 1
    fi

    if detect_running_backup; then
      log_ts "Backup detected (source: ${DETECTED_SOURCE})"
      return 0
    fi

    sleep 5
  done
}

# ---------------------------------------------------------------------------
# Capture: xtrabackup log stream
# ---------------------------------------------------------------------------
stream_xtrabackup_logs() {
  local log_file="${1:?log file required}"

  case "${DETECTED_SOURCE}" in
    backup-pod)
      log_ts "Streaming logs from backup pod ${POD_NAME}/${DETECTED_CONTAINER}..."
      kctl logs -f "${POD_NAME}" -c "${DETECTED_CONTAINER}" >> "${log_file}" 2>&1 &
      BG_PIDS+=($!)
      ;;
    process)
      # xtrabackup process detected in the MySQL pod. Try streaming from the
      # xtrabackup sidecar first (the operator routes output there), then
      # fall back to tailing process stderr.
      local sidecar_container=""
      if find_xtrabackup_sidecar; then
        sidecar_container="${DETECTED_CONTAINER}"
        log_ts "Streaming xtrabackup sidecar logs from ${POD_NAME}/${sidecar_container}..."
        kctl logs -f "${POD_NAME}" -c "${sidecar_container}" >> "${log_file}" 2>&1 &
        BG_PIDS+=($!)
      else
        log_ts "Capturing xtrabackup output via process monitoring in ${POD_NAME}..."
        (
          while true; do
            local xb_pid
            xb_pid="$(kctl exec "${POD_NAME}" -c "${DETECTED_CONTAINER}" -- \
              sh -c 'pgrep -o xtrabackup 2>/dev/null' 2>/dev/null)" || true
            if [[ -z "${xb_pid}" ]]; then
              sleep 2; continue
            fi
            kctl exec "${POD_NAME}" -c "${DETECTED_CONTAINER}" -- \
              sh -c "tail -f /proc/${xb_pid}/fd/2 2>/dev/null || \
                     tail -f /var/log/xtrabackup.log 2>/dev/null || \
                     echo 'WARNING: cannot tail xtrabackup output'" \
              >> "${log_file}" 2>&1
            break
          done
        ) &
        BG_PIDS+=($!)
      fi
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Capture: MySQL server metrics
# ---------------------------------------------------------------------------
poll_mysql_status() {
  local csv_file="${1:?csv file required}"
  local interval="${2:-10}"

  echo "epoch,timestamp,innodb_os_log_written,innodb_data_read,innodb_data_written,innodb_buffer_pool_pages_dirty,innodb_buffer_pool_read_requests,innodb_buffer_pool_reads,innodb_row_lock_waits,threads_running,checkpoint_age" \
    > "${csv_file}"

  log_ts "Starting MySQL status polling (every ${interval}s) -> ${csv_file}"

  while true; do
    local epoch ts
    epoch="$(epoch_now)"
    ts="$(epoch_to_utc "${epoch}")"

    local status_output checkpoint_age_val="0"

    # Fetch InnoDB global status variables in a single query
    status_output="$(run_mysql_query "
      SELECT VARIABLE_NAME, VARIABLE_VALUE
      FROM performance_schema.global_status
      WHERE VARIABLE_NAME IN (
        'Innodb_os_log_written',
        'Innodb_data_read',
        'Innodb_data_written',
        'Innodb_buffer_pool_pages_dirty',
        'Innodb_buffer_pool_read_requests',
        'Innodb_buffer_pool_reads',
        'Innodb_row_lock_waits',
        'Threads_running'
      )
      ORDER BY VARIABLE_NAME;
    " 2>/dev/null)" || true

    if [[ -z "${status_output}" ]]; then
      # Fallback to SHOW GLOBAL STATUS
      status_output="$(run_mysql_query "
        SHOW GLOBAL STATUS WHERE Variable_name IN (
          'Innodb_os_log_written',
          'Innodb_data_read',
          'Innodb_data_written',
          'Innodb_buffer_pool_pages_dirty',
          'Innodb_buffer_pool_read_requests',
          'Innodb_buffer_pool_reads',
          'Innodb_row_lock_waits',
          'Threads_running'
        );
      " 2>/dev/null)" || true
    fi

    # Try to get checkpoint age from InnoDB status
    local innodb_status
    innodb_status="$(run_mysql_query "SHOW ENGINE INNODB STATUS\G" 2>/dev/null)" || true
    if [[ -n "${innodb_status}" ]]; then
      checkpoint_age_val="$(echo "${innodb_status}" \
        | awk '/Checkpoint age/{print $NF; exit}' 2>/dev/null)" || true
      checkpoint_age_val="${checkpoint_age_val:-0}"
    fi

    # Parse status vars into a map
    local log_written="0" data_read="0" data_written="0" pages_dirty="0"
    local read_requests="0" buf_reads="0" row_lock_waits="0" threads_running="0"

    if [[ -n "${status_output}" ]]; then
      while IFS=$'\t' read -r name val; do
        case "${name}" in
          Innodb_os_log_written|INNODB_OS_LOG_WRITTEN)   log_written="${val}" ;;
          Innodb_data_read|INNODB_DATA_READ)             data_read="${val}" ;;
          Innodb_data_written|INNODB_DATA_WRITTEN)       data_written="${val}" ;;
          Innodb_buffer_pool_pages_dirty|INNODB_BUFFER_POOL_PAGES_DIRTY) pages_dirty="${val}" ;;
          Innodb_buffer_pool_read_requests|INNODB_BUFFER_POOL_READ_REQUESTS) read_requests="${val}" ;;
          Innodb_buffer_pool_reads|INNODB_BUFFER_POOL_READS) buf_reads="${val}" ;;
          Innodb_row_lock_waits|INNODB_ROW_LOCK_WAITS)   row_lock_waits="${val}" ;;
          Threads_running|THREADS_RUNNING)               threads_running="${val}" ;;
        esac
      done <<< "${status_output}"
    fi

    echo "${epoch},${ts},${log_written},${data_read},${data_written},${pages_dirty},${read_requests},${buf_reads},${row_lock_waits},${threads_running},${checkpoint_age_val}" \
      >> "${csv_file}"

    sleep "${interval}"
  done
}

# ---------------------------------------------------------------------------
# Capture: pod resource metrics (kubectl top)
# ---------------------------------------------------------------------------
poll_pod_resources() {
  local csv_file="${1:?csv file required}"
  local target_pod="${2:?pod name required}"
  local interval="${3:-10}"

  echo "epoch,timestamp,pod,container,cpu_millicores,memory_mib" > "${csv_file}"

  # Pre-check: verify Metrics API is available
  if ! kctl top pod "${target_pod}" --containers --no-headers >/dev/null 2>&1; then
    log_ts "WARNING: kubectl top failed (Metrics API may not be available) — skipping pod resource polling"
    return 0
  fi

  log_ts "Starting pod resource polling (every ${interval}s) -> ${csv_file}"

  while true; do
    local epoch ts
    epoch="$(epoch_now)"
    ts="$(epoch_to_utc "${epoch}")"

    local top_output
    top_output="$(kctl top pod "${target_pod}" --containers --no-headers 2>/dev/null)" || true

    if [[ -n "${top_output}" ]]; then
      while read -r pod container cpu mem; do
        local cpu_m="${cpu%m}"
        local mem_mi="${mem%Mi}"
        if [[ "${cpu}" != *m ]]; then
          cpu_m=$((${cpu:-0} * 1000))
        fi
        if [[ "${mem}" == *Gi ]]; then
          mem_mi=$(( ${mem%Gi} * 1024 ))
        fi
        echo "${epoch},${ts},${pod},${container},${cpu_m},${mem_mi}" >> "${csv_file}"
      done <<< "${top_output}"
    fi

    sleep "${interval}"
  done
}

# ---------------------------------------------------------------------------
# Capture: disk I/O from inside the pod
# ---------------------------------------------------------------------------
poll_disk_io() {
  local csv_file="${1:?csv file required}"
  local interval="${2:-10}"

  echo "epoch,timestamp,device,reads_completed,reads_merged,sectors_read,ms_reading,writes_completed,writes_merged,sectors_written,ms_writing" \
    > "${csv_file}"

  log_ts "Starting disk I/O polling (every ${interval}s) -> ${csv_file}"

  while true; do
    local epoch ts
    epoch="$(epoch_now)"
    ts="$(epoch_to_utc "${epoch}")"

    local diskstats
    diskstats="$(kctl exec "${POD_NAME}" -c "${DETECTED_CONTAINER}" -- \
      sh -c 'cat /proc/diskstats 2>/dev/null' 2>/dev/null)" || true

    if [[ -n "${diskstats}" ]]; then
      # Filter to block devices (sd*, vd*, nvme*), skip loop/ram/dm with 0 activity
      echo "${diskstats}" | awk -v epoch="${epoch}" -v ts="${ts}" '
        $3 ~ /^(sd|vd|nvme|xvd)/ {
          printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n",
            epoch, ts, $3, $4, $5, $6, $7, $8, $9, $10, $11
        }
      ' >> "${csv_file}"
    fi

    sleep "${interval}"
  done
}

# ---------------------------------------------------------------------------
# Monitor: detect when backup finishes
# ---------------------------------------------------------------------------
wait_for_backup_completion() {
  local xb_log="${1:?xb log required}"
  local start_epoch="${2:?start epoch required}"
  local deadline=$(( start_epoch + TIMEOUT ))

  log_ts "Monitoring backup until completion (timeout: ${TIMEOUT}s)..."

  while true; do
    if [[ "$(epoch_now)" -ge "${deadline}" ]]; then
      log_ts "WARNING: Timed out waiting for backup completion after ${TIMEOUT}s"
      return 1
    fi

    # Check if xtrabackup log contains completion marker
    if [[ -f "${xb_log}" ]] && grep -qE 'completed OK!?$' "${xb_log}" 2>/dev/null; then
      log_ts "Backup completed (found 'completed OK!' in xtrabackup log)"
      return 0
    fi

    # Check if the backup process/pod is still running
    case "${DETECTED_SOURCE}" in
      process)
        local still_running
        still_running="$(kctl exec "${POD_NAME}" -c "${DETECTED_CONTAINER}" -- \
          sh -c 'pgrep xtrabackup 2>/dev/null' 2>/dev/null)" || true
        if [[ -z "${still_running}" ]]; then
          log_ts "XtraBackup process no longer running"
          sleep 2  # Let log stream catch up
          return 0
        fi
        ;;
      backup-pod)
        local phase
        phase="$(kctl get pod "${POD_NAME}" -o jsonpath='{.status.phase}' 2>/dev/null)" || true
        if [[ "${phase}" != "Running" ]]; then
          log_ts "Backup pod ${POD_NAME} phase: ${phase}"
          sleep 2
          return 0
        fi
        ;;
    esac

    sleep 5
  done
}

# ---------------------------------------------------------------------------
# Capture: processlist snapshots (detect xtrabackup connections)
# ---------------------------------------------------------------------------
capture_processlist_snapshot() {
  local out_file="${1:?output file required}"
  local epoch ts
  epoch="$(epoch_now)"
  ts="$(epoch_to_utc "${epoch}")"

  local pl
  pl="$(run_mysql_query "SHOW FULL PROCESSLIST;" 2>/dev/null)" || true
  if [[ -n "${pl}" ]]; then
    {
      echo "--- ${ts} (epoch=${epoch}) ---"
      echo "${pl}"
      echo ""
    } >> "${out_file}"
  fi
}

# ---------------------------------------------------------------------------
# Capture backup timing from K8s resources and xtrabackup logs
# ---------------------------------------------------------------------------

# Extract the ps-backup CR name that owns a given backup pod.
find_ps_backup_for_pod() {
  local pod_name="${1:?pod name required}"
  # ps-backup CR name is embedded in the pod name:
  #   xb-cron-<cr-name>-<suffix>  or  xb-ondemand-<cr-name>-<suffix>
  # The CR creates the pod, so we can look up ownerReferences.
  local owner
  owner="$(kctl get pod "${pod_name}" \
    -o jsonpath='{.metadata.labels.job-name}' 2>/dev/null)" || true
  if [[ -z "${owner}" ]]; then
    # Fallback: strip the pod suffix to get the job name, then find the CR
    owner="$(kctl get pod "${pod_name}" \
      -o jsonpath='{.metadata.ownerReferences[0].name}' 2>/dev/null)" || true
  fi
  if [[ -z "${owner}" ]]; then
    return 1
  fi
  # The job's owner is the ps-backup CR
  local cr_name
  cr_name="$(kctl get job "${owner}" \
    -o jsonpath='{.metadata.ownerReferences[0].name}' 2>/dev/null)" || true
  if [[ -n "${cr_name}" ]]; then
    echo "${cr_name}"
    return 0
  fi
  return 1
}

# Capture backup timing from all available sources and write to profile_timing.env.
capture_backup_timing() {
  local backup_dir="${1:?backup dir required}"
  local backup_pod="${2:-}"
  local xb_log="${backup_dir}/xtrabackup.log"
  local timing_file="${backup_dir}/profile_timing.env"

  # --- Source 1: Backup pod container lifecycle ---
  if [[ -n "${backup_pod}" ]]; then
    local pod_started pod_finished pod_exit_code pod_reason pod_phase
    pod_phase="$(kctl get pod "${backup_pod}" \
      -o jsonpath='{.status.phase}' 2>/dev/null)" || true
    pod_started="$(kctl get pod "${backup_pod}" \
      -o jsonpath='{.status.containerStatuses[0].state.terminated.startedAt}' 2>/dev/null)" || true
    pod_finished="$(kctl get pod "${backup_pod}" \
      -o jsonpath='{.status.containerStatuses[0].state.terminated.finishedAt}' 2>/dev/null)" || true
    pod_exit_code="$(kctl get pod "${backup_pod}" \
      -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null)" || true
    pod_reason="$(kctl get pod "${backup_pod}" \
      -o jsonpath='{.status.containerStatuses[0].state.terminated.reason}' 2>/dev/null)" || true
    # If still running, check running state
    if [[ -z "${pod_started}" ]]; then
      pod_started="$(kctl get pod "${backup_pod}" \
        -o jsonpath='{.status.containerStatuses[0].state.running.startedAt}' 2>/dev/null)" || true
    fi
    {
      echo "BACKUP_POD=${backup_pod}"
      echo "POD_PHASE=${pod_phase}"
      [[ -n "${pod_started}" ]]   && echo "POD_STARTED=${pod_started}"
      [[ -n "${pod_finished}" ]]  && echo "POD_FINISHED=${pod_finished}"
      [[ -n "${pod_exit_code}" ]] && echo "POD_EXIT_CODE=${pod_exit_code}"
      [[ -n "${pod_reason}" ]]    && echo "POD_REASON=${pod_reason}"
    } >> "${timing_file}"
    log_ts "  pod started:   ${pod_started:-?}"
    log_ts "  pod finished:  ${pod_finished:-?}"
    log_ts "  pod exit_code: ${pod_exit_code:-?} reason: ${pod_reason:-?}"

    # Capture pod events (scheduling, image pull errors, OOM kills, etc.)
    local events_file="${backup_dir}/pod_events.log"
    kctl get events \
      --field-selector "involvedObject.name=${backup_pod}" \
      --sort-by='.lastTimestamp' > "${events_file}" 2>/dev/null || true
    if [[ -s "${events_file}" ]]; then
      log_ts "  pod events saved to pod_events.log"
    fi
  fi

  # --- Source 2: ps-backup CR status ---
  if [[ -n "${backup_pod}" ]]; then
    local cr_name
    cr_name="$(find_ps_backup_for_pod "${backup_pod}")" || true
    if [[ -n "${cr_name}" ]]; then
      local cr_created cr_completed cr_state cr_type cr_destination
      cr_created="$(kctl get ps-backup "${cr_name}" \
        -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null)" || true
      cr_completed="$(kctl get ps-backup "${cr_name}" \
        -o jsonpath='{.status.completed}' 2>/dev/null)" || true
      cr_state="$(kctl get ps-backup "${cr_name}" \
        -o jsonpath='{.status.state}' 2>/dev/null)" || true
      cr_type="$(kctl get ps-backup "${cr_name}" \
        -o jsonpath='{.status.type}' 2>/dev/null)" || true
      cr_destination="$(kctl get ps-backup "${cr_name}" \
        -o jsonpath='{.status.destination}' 2>/dev/null)" || true
      {
        echo "CR_NAME=${cr_name}"
        echo "CR_CREATED=${cr_created}"
        echo "CR_COMPLETED=${cr_completed}"
        echo "CR_STATE=${cr_state}"
        echo "CR_TYPE=${cr_type}"
        echo "CR_DESTINATION=${cr_destination}"
      } >> "${timing_file}"
      log_ts "  cr name:      ${cr_name}"
      log_ts "  cr created:   ${cr_created}"
      log_ts "  cr completed: ${cr_completed}"
      log_ts "  cr state:     ${cr_state}"
    fi
  fi

  # --- Source 3: XtraBackup log timestamps, result, and compression stats ---
  if [[ -f "${xb_log}" && -s "${xb_log}" ]]; then
    local xb_first_ts xb_completed_ts xb_result="unknown"
    xb_first_ts="$(grep -m1 -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}' \
      "${xb_log}" 2>/dev/null)" || true
    if grep -q 'completed OK' "${xb_log}" 2>/dev/null; then
      xb_result="OK"
      xb_completed_ts="$(grep 'completed OK' "${xb_log}" 2>/dev/null \
        | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}' \
        | tail -1)" || true
    elif grep -qiE 'FATAL|ERROR|failed' "${xb_log}" 2>/dev/null; then
      xb_result="FAILED"
      local error_lines
      error_lines="$(grep -iE 'FATAL|ERROR|failed' "${xb_log}" 2>/dev/null | tail -10)" || true
      echo "XB_ERRORS<<EOF" >> "${timing_file}"
      echo "${error_lines}" >> "${timing_file}"
      echo "EOF" >> "${timing_file}"
      log_ts "  xb errors:"
      echo "${error_lines}" | while IFS= read -r eline; do
        [[ -n "${eline}" ]] && log_ts "    ${eline}"
      done
    fi
    {
      [[ -n "${xb_first_ts}" ]]     && echo "XB_LOG_FIRST_TS=${xb_first_ts}"
      [[ -n "${xb_completed_ts}" ]] && echo "XB_LOG_COMPLETED_TS=${xb_completed_ts}"
      echo "XB_RESULT=${xb_result}"
    } >> "${timing_file}"
    log_ts "  xb result:    ${xb_result}"
    [[ -n "${xb_first_ts}" ]]     && log_ts "  xb log start: ${xb_first_ts}"
    [[ -n "${xb_completed_ts}" ]] && log_ts "  xb log end:   ${xb_completed_ts}"

    # --- Source 3b: Compression and upload stats from xtrabackup log ---
    local compress_enabled="false"
    if grep -q 'Compressing and streaming' "${xb_log}" 2>/dev/null; then
      compress_enabled="true"

      # Timestamps for compress+stream phase
      local compress_start_ts compress_end_ts
      compress_start_ts="$(grep -m1 'Compressing and streaming' "${xb_log}" 2>/dev/null \
        | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]+' \
        | head -1)" || true
      compress_end_ts="$(grep 'Done: Compressing and streaming' "${xb_log}" 2>/dev/null \
        | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]+' \
        | tail -1)" || true

      # Count files compressed
      local files_compressed
      files_compressed="$(grep -c 'Compressing and streaming' "${xb_log}" 2>/dev/null)" || files_compressed=0

      # Total uploaded size (sum of all chunk sizes from xbcloud lines)
      local total_uploaded_bytes
      total_uploaded_bytes="$(grep 'successfully uploaded chunk' "${xb_log}" 2>/dev/null \
        | awk -F'size: ' '{s += $2+0} END{print s+0}')" || total_uploaded_bytes=0

      # Upload chunk count
      local upload_chunk_count
      upload_chunk_count="$(grep -c 'successfully uploaded chunk' "${xb_log}" 2>/dev/null)" || upload_chunk_count=0

      # Upload phase timestamps
      local upload_first_ts upload_last_ts
      upload_first_ts="$(grep -m1 'successfully uploaded chunk' "${xb_log}" 2>/dev/null \
        | grep -oE '^[0-9]{6} [0-9]{2}:[0-9]{2}:[0-9]{2}')" || true
      upload_last_ts="$(grep 'Upload completed' "${xb_log}" 2>/dev/null \
        | grep -oE '^[0-9]{6} [0-9]{2}:[0-9]{2}:[0-9]{2}')" || true

      # Parallel threads used
      local compress_threads
      compress_threads="$(grep -m1 'Starting .* threads for parallel' "${xb_log}" 2>/dev/null \
        | awk '{for(i=1;i<=NF;i++) if($i~/^[0-9]+$/ && $(i+1)=="threads") {print $i; exit}}')" || true

      local uploaded_mb
      if [[ "${total_uploaded_bytes}" -gt 0 ]]; then
        uploaded_mb="$(awk "BEGIN{printf \"%.2f\", ${total_uploaded_bytes}/1048576}")"
      else
        uploaded_mb="0"
      fi

      {
        echo "COMPRESS_ENABLED=true"
        echo "COMPRESS_THREADS=${compress_threads:-?}"
        echo "COMPRESS_START_TS=${compress_start_ts}"
        echo "COMPRESS_END_TS=${compress_end_ts}"
        echo "FILES_COMPRESSED=${files_compressed}"
        echo "UPLOAD_CHUNKS=${upload_chunk_count}"
        echo "UPLOAD_TOTAL_BYTES=${total_uploaded_bytes}"
        echo "UPLOAD_TOTAL_MB=${uploaded_mb}"
        echo "UPLOAD_FIRST_TS=${upload_first_ts}"
        echo "UPLOAD_LAST_TS=${upload_last_ts}"
      } >> "${timing_file}"
      log_ts "  compress:     enabled (${compress_threads:-?} threads)"
      log_ts "  compress from: ${compress_start_ts:-?} to ${compress_end_ts:-?}"
      log_ts "  files compressed: ${files_compressed}"
      log_ts "  uploaded:     ${uploaded_mb} MB in ${upload_chunk_count} chunks"
    else
      echo "COMPRESS_ENABLED=false" >> "${timing_file}"
      log_ts "  compress:     disabled (no compression in log)"
    fi
  fi
}

# Append a row to the consolidated backup_events.csv.
append_backup_event_csv() {
  local csv_file="${1:?csv file required}"
  local backup_dir="${2:?backup dir required}"
  local backup_num="${3:?backup number required}"
  local timing_file="${backup_dir}/profile_timing.env"

  if [[ ! -f "${timing_file}" ]]; then
    return
  fi

  # Create header if file doesn't exist
  if [[ ! -f "${csv_file}" ]]; then
    echo "backup_num,detected_source,cr_name,cr_state,cr_type,xb_result,pod_phase,pod_exit_code,pod_reason,pod_started,pod_finished,xb_log_start,xb_log_end,cr_created,cr_completed,cr_destination,compress_enabled,compress_threads,files_compressed,upload_total_mb,upload_chunks,compress_start,compress_end,profile_start_epoch,profile_end_epoch,profile_duration_sec" \
      > "${csv_file}"
  fi

  # shellcheck source=/dev/null
  local DETECTED_SOURCE="" CR_NAME="" CR_STATE="" CR_TYPE="" CR_DESTINATION=""
  local POD_PHASE="" POD_EXIT_CODE="" POD_REASON=""
  local POD_STARTED="" POD_FINISHED=""
  local XB_LOG_FIRST_TS="" XB_LOG_COMPLETED_TS="" XB_RESULT=""
  local CR_CREATED="" CR_COMPLETED=""
  local COMPRESS_ENABLED="" COMPRESS_THREADS="" FILES_COMPRESSED=""
  local UPLOAD_TOTAL_MB="" UPLOAD_CHUNKS="" COMPRESS_START_TS="" COMPRESS_END_TS=""
  local BACKUP_PROFILE_START_EPOCH="" BACKUP_PROFILE_END_EPOCH="" BACKUP_PROFILE_DURATION_SEC=""
  source "${timing_file}"

  echo "${backup_num},${DETECTED_SOURCE},${CR_NAME},${CR_STATE},${CR_TYPE},${XB_RESULT},${POD_PHASE},${POD_EXIT_CODE},${POD_REASON},${POD_STARTED},${POD_FINISHED},${XB_LOG_FIRST_TS},${XB_LOG_COMPLETED_TS},${CR_CREATED},${CR_COMPLETED},${CR_DESTINATION},${COMPRESS_ENABLED},${COMPRESS_THREADS},${FILES_COMPRESSED},${UPLOAD_TOTAL_MB},${UPLOAD_CHUNKS},${COMPRESS_START_TS},${COMPRESS_END_TS},${BACKUP_PROFILE_START_EPOCH},${BACKUP_PROFILE_END_EPOCH},${BACKUP_PROFILE_DURATION_SEC}" \
    >> "${csv_file}"
}

# ---------------------------------------------------------------------------
# Kill a list of PIDs and remove them from BG_PIDS
# ---------------------------------------------------------------------------
kill_pids() {
  local pid
  for pid in "$@"; do
    kill "${pid}" 2>/dev/null || true
    wait "${pid}" 2>/dev/null || true
  done
}

# ---------------------------------------------------------------------------
# Post-process a single backup's data
# ---------------------------------------------------------------------------
postprocess_backup() {
  local backup_dir="${1:?backup dir required}"
  local xb_log="${backup_dir}/xtrabackup.log"
  local mysql_csv="${backup_dir}/mysql_status.csv"
  local resources_csv="${backup_dir}/pod_resources.csv"
  local disk_io_csv="${backup_dir}/disk_io.csv"

  local parser="${SCRIPT_DIR}/scripts/parse_backup_profile.py"
  if [[ -f "${parser}" ]]; then
    python3 "${parser}" \
      --xb-log "${xb_log}" \
      --mysql-status-csv "${mysql_csv}" \
      --pod-resources-csv "${resources_csv}" \
      --disk-io-csv "${disk_io_csv}" \
      --profile-timing "${backup_dir}/profile_timing.env" \
      --output-dir "${backup_dir}" 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"
  load_optional_config

  # Preflight
  if ! command -v kubectl >/dev/null 2>&1; then
    echo "ERROR: kubectl not found in PATH" >&2
    exit 1
  fi

  if ! kctl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
    echo "ERROR: Cannot access namespace '${NAMESPACE}' with provided kubeconfig" >&2
    exit 1
  fi

  # Detect MySQL pod
  detect_mysql_pod
  detect_main_container

  local original_pod="${POD_NAME}"
  local original_container="${DETECTED_CONTAINER}"

  # Set up results directory
  local timestamp
  timestamp="$(date +%Y%m%d_%H%M%S)"
  local run_dir="${RESULTS_BASE}/backup_profile_${timestamp}"
  mkdir -p "${run_dir}"

  local mysql_csv="${run_dir}/mysql_status.csv"
  local resources_csv="${run_dir}/pod_resources.csv"
  local disk_io_csv="${run_dir}/disk_io.csv"
  local processlist_log="${run_dir}/processlist.log"
  local profile_log="${run_dir}/profile.log"

  # Tee all script output to profile.log
  exec > >(tee -a "${profile_log}") 2>&1

  echo "=== Backup Profiler ==="
  echo "Namespace:  ${NAMESPACE}"
  echo "MySQL pod:  ${POD_NAME}"
  echo "Container:  ${DETECTED_CONTAINER}"
  echo "Results:    ${run_dir}"
  echo "Timeout:    ${TIMEOUT}s"
  echo "Mode:       $([ "${ATTACH_MODE}" -eq 1 ] && echo 'attach' || echo 'wait-loop')"
  echo ""

  setup_mysql_connection

  local profiler_start_epoch deadline
  profiler_start_epoch="$(epoch_now)"
  deadline=$((profiler_start_epoch + TIMEOUT))
  echo "PROFILER_START_EPOCH=${profiler_start_epoch}" > "${run_dir}/profiler_timing.env"

  # ------------------------------------------------------------------
  # Start continuous pollers (run for entire profiler lifetime)
  # ------------------------------------------------------------------
  local -a continuous_pids=()

  poll_mysql_status "${mysql_csv}" "${POLL_INTERVAL}" &
  continuous_pids+=($!)
  BG_PIDS+=($!)

  poll_pod_resources "${resources_csv}" "${original_pod}" "${POLL_INTERVAL}" &
  continuous_pids+=($!)
  BG_PIDS+=($!)

  poll_disk_io "${disk_io_csv}" "${POLL_INTERVAL}" &
  continuous_pids+=($!)
  BG_PIDS+=($!)

  (
    while true; do
      capture_processlist_snapshot "${processlist_log}"
      sleep 30
    done
  ) &
  continuous_pids+=($!)
  BG_PIDS+=($!)

  # ------------------------------------------------------------------
  # Backup detection loop — capture every backup until timeout
  # ------------------------------------------------------------------
  local backup_count=0

  while true; do
    local now
    now="$(epoch_now)"
    local remaining=$(( deadline - now ))
    if [[ "${remaining}" -le 0 ]]; then
      log_ts "Timeout reached — stopping profiler"
      break
    fi

    # Reset detection state to the original MySQL pod
    POD_NAME="${original_pod}"
    DETECTED_CONTAINER="${original_container}"
    DETECTED_SOURCE=""

    # Attach mode: only the first iteration tries to attach
    if [[ "${ATTACH_MODE}" -eq 1 && "${backup_count}" -eq 0 ]]; then
      log_ts "Attach mode: looking for running backup..."
      if ! detect_running_backup; then
        echo "ERROR: No running backup found. Remove --attach to wait for one." >&2
        break
      fi
      log_ts "Attached to backup (source: ${DETECTED_SOURCE})"
    else
      if [[ "${backup_count}" -eq 0 ]]; then
        log_ts "Waiting for backups (${remaining}s remaining)..."
      else
        log_ts "Waiting for next backup (${remaining}s remaining)..."
      fi

      # Poll until a backup appears or timeout
      local found=0
      while [[ "$(epoch_now)" -lt "${deadline}" ]]; do
        if detect_running_backup; then
          found=1
          break
        fi
        sleep 5
      done
      if [[ "${found}" -eq 0 ]]; then
        log_ts "No more backups detected before timeout"
        break
      fi
      log_ts "Backup detected (source: ${DETECTED_SOURCE})"
    fi

    # ------------------------------------------------------------------
    # Profile this backup
    # ------------------------------------------------------------------
    backup_count=$((backup_count + 1))
    local backup_dir="${run_dir}/backup_${backup_count}"
    mkdir -p "${backup_dir}"

    local xb_log="${backup_dir}/xtrabackup.log"
    : > "${xb_log}"

    # Remember the backup pod name (if detected via backup-pod source)
    local detected_backup_pod=""
    if [[ "${DETECTED_SOURCE}" == "backup-pod" ]]; then
      detected_backup_pod="${POD_NAME}"
    fi

    local backup_start_epoch
    backup_start_epoch="$(epoch_now)"
    log_ts "=== Backup #${backup_count} started (source=${DETECTED_SOURCE}) ==="
    echo "BACKUP_PROFILE_START_EPOCH=${backup_start_epoch}" > "${backup_dir}/profile_timing.env"
    echo "DETECTED_SOURCE=${DETECTED_SOURCE}" >> "${backup_dir}/profile_timing.env"

    # Symlink continuous poller CSVs so per-backup post-processing can find them
    ln -sf "${mysql_csv}" "${backup_dir}/mysql_status.csv" 2>/dev/null || true
    ln -sf "${resources_csv}" "${backup_dir}/pod_resources.csv" 2>/dev/null || true
    ln -sf "${disk_io_csv}" "${backup_dir}/disk_io.csv" 2>/dev/null || true

    # Stream xtrabackup logs for this backup
    local -a log_stream_pids=()
    stream_xtrabackup_logs "${xb_log}"
    # Capture pids added by stream_xtrabackup_logs (they append to BG_PIDS)
    local bg_count_after=${#BG_PIDS[@]}
    local stream_start_idx=$(( bg_count_after - 1 ))
    if [[ "${stream_start_idx}" -ge 0 ]]; then
      log_stream_pids+=("${BG_PIDS[${stream_start_idx}]}")
    fi

    # Wait for this backup to complete
    wait_for_backup_completion "${xb_log}" "${backup_start_epoch}"

    local backup_end_epoch
    backup_end_epoch="$(epoch_now)"
    local duration=$(( backup_end_epoch - backup_start_epoch ))
    log_ts "=== Backup #${backup_count} finished (duration=${duration}s) ==="
    {
      echo "BACKUP_PROFILE_END_EPOCH=${backup_end_epoch}"
      echo "BACKUP_PROFILE_DURATION_SEC=${duration}"
    } >> "${backup_dir}/profile_timing.env"

    # Stop the log stream for this backup (continuous pollers keep running)
    kill_pids "${log_stream_pids[@]}"
    sleep 1

    # Capture timing from pod lifecycle, ps-backup CR, and xtrabackup log
    log_ts "Capturing backup timing for backup #${backup_count}..."
    capture_backup_timing "${backup_dir}" "${detected_backup_pod}"
    append_backup_event_csv "${run_dir}/backup_events.csv" "${backup_dir}" "${backup_count}"

    # Post-process this backup
    postprocess_backup "${backup_dir}"

    if [[ "${ATTACH_MODE}" -eq 1 ]]; then
      # Attach mode: only profile the one backup we attached to
      break
    fi
  done

  # ------------------------------------------------------------------
  # Finalize
  # ------------------------------------------------------------------
  local profiler_end_epoch
  profiler_end_epoch="$(epoch_now)"
  local total_duration=$(( profiler_end_epoch - profiler_start_epoch ))
  {
    echo "PROFILER_END_EPOCH=${profiler_end_epoch}"
    echo "PROFILER_DURATION_SEC=${total_duration}"
    echo "BACKUPS_CAPTURED=${backup_count}"
  } >> "${run_dir}/profiler_timing.env"

  # Stop all background workers
  cleanup
  BG_PIDS=()
  sleep 2

  echo ""
  echo "=== Profiling Complete ==="
  echo "Total duration:  $(( total_duration / 60 ))m $(( total_duration % 60 ))s"
  echo "Backups captured: ${backup_count}"
  echo "Results dir:     ${run_dir}"
  echo ""
  echo "Continuous data:"
  echo "  mysql_status.csv     MySQL server metrics (every ${POLL_INTERVAL}s)"
  echo "  pod_resources.csv    Pod CPU/memory (every ${POLL_INTERVAL}s)"
  echo "  disk_io.csv          Disk I/O stats (every ${POLL_INTERVAL}s)"
  echo "  processlist.log      MySQL processlist snapshots"
  [[ -f "${run_dir}/backup_events.csv" ]] && \
    echo "  backup_events.csv    Consolidated backup start/end times"
  if [[ "${backup_count}" -gt 0 ]]; then
    echo ""
    echo "Per-backup data:"
    local i
    for i in $(seq 1 "${backup_count}"); do
      local bdir="${run_dir}/backup_${i}"
      if [[ -d "${bdir}" ]]; then
        local bdur="?"
        if [[ -f "${bdir}/profile_timing.env" ]]; then
          bdur="$(grep BACKUP_PROFILE_DURATION_SEC "${bdir}/profile_timing.env" 2>/dev/null \
            | cut -d= -f2)" || true
        fi
        echo "  backup_${i}/  (${bdur}s)"
        echo "    xtrabackup.log       XtraBackup log"
        echo "    profile_timing.env   Start/end timestamps"
        [[ -f "${bdir}/phase_timing.csv" ]] && echo "    phase_timing.csv     Phase-level timing"
        [[ -f "${bdir}/profile_summary.txt" ]] && echo "    profile_summary.txt  Summary"
      fi
    done
  fi
}

main "$@"
