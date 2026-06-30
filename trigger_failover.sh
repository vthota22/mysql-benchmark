#!/usr/bin/env bash
# Trigger failover for Standard or Advanced edition during a benchmark run.
#
# Usage:
#   trigger_failover.sh <edition> <results_dir> [action]
#
# Actions (Advanced pod delete; harness uses prepare → refresh → fire):
#   prepare  — fetch kubeconfig, validate kubectl, resolve primary pod (during baseline)
#   refresh  — re-resolve primary pod shortly before trigger second
#   fire     — kubectl delete/kill using kubeconfig + target pod from refresh (no re-resolve)
#   (omit)   — one-shot: prepare + delete immediately (manual / legacy)
#
# Requires benchmark.conf (via BENCHMARK_CONF) and edition-specific settings.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${BENCHMARK_CONF:-${SCRIPT_DIR}/benchmark.conf}"

# shellcheck source=lib/failover_common.sh
source "${SCRIPT_DIR}/lib/failover_common.sh"
load_benchmark_config "${CONFIG}"
failover_defaults

EDITION="${1:?Usage: $0 <standard|advanced> <results_dir> [prepare|refresh|fire]}"
RESULTS_DIR="${2:?Usage: $0 <standard|advanced> <results_dir> [prepare|refresh|fire]}"
ACTION="${3:-}"
mkdir -p "${RESULTS_DIR}"

PREPARED_ENV="${RESULTS_DIR}/failover_trigger_prepared.env"
TRIGGER_LOG="${RESULTS_DIR}/failover_trigger.log"
EVENT_FILE="${RESULTS_DIR}/failover_event.txt"

set_mysql_env_for_edition "${EDITION}"

init_failover_event_stub() {
  : > "${EVENT_FILE}"
  echo "FAILOVER_EDITION=${EDITION}" >> "${EVENT_FILE}"
  echo "FAILOVER_TRIGGER_ENABLED=${FAILOVER_TRIGGER_ENABLED:-1}" >> "${EVENT_FILE}"
  echo "FAILOVER_POD_DELETE=${FAILOVER_POD_DELETE:-${FAILOVER_TRIGGER_ENABLED:-1}}" >> "${EVENT_FILE}"
  echo "FAILOVER_ADVANCED_TRIGGER_METHOD=${FAILOVER_ADVANCED_TRIGGER_METHOD:-pod_delete}" >> "${EVENT_FILE}"
}

record_trigger_skipped() {
  local reason="${1:?reason required}"
  init_failover_event_stub
  echo "FAILOVER_METHOD=skipped" >> "${EVENT_FILE}"
  echo "FAILOVER_TRIGGER_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "${EVENT_FILE}"
  echo "FAILOVER_SKIP_REASON=${reason}" >> "${EVENT_FILE}"
  {
    echo "Failover trigger SKIPPED at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "Reason: ${reason}"
    echo "Load continues through observe window; no pod delete / API trigger."
  } | tee -a "${TRIGGER_LOG}"
}

write_failover_prepared_env() {
  local kubeconfig="${1:?kubeconfig required}"
  local pod="${2:?pod required}"
  local ns="${3:?namespace required}"
  local delete_force="${4:-1}"
  local delete_grace="${5:-0}"

  cat > "${PREPARED_ENV}" <<EOF
FAILOVER_PREPARED_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)
FAILOVER_KUBECONFIG=${kubeconfig}
FAILOVER_K8S_NAMESPACE=${ns}
FAILOVER_K8S_CONTEXT=${ADVANCED_K8S_CONTEXT:-}
FAILOVER_TARGET_POD=${pod}
FAILOVER_POD_DELETE_FORCE=${delete_force}
FAILOVER_POD_DELETE_GRACE_SEC=${delete_grace}
EOF
}

load_failover_prepared_env() {
  [[ -f "${PREPARED_ENV}" ]] || {
    echo "ERROR: missing ${PREPARED_ENV} — run prepare first" >&2
    return 1
  }
  # shellcheck disable=SC1090
  source "${PREPARED_ENV}"
  : "${FAILOVER_KUBECONFIG:?FAILOVER_KUBECONFIG missing in prepared env}"
  : "${FAILOVER_K8S_NAMESPACE:?FAILOVER_K8S_NAMESPACE missing in prepared env}"
  : "${FAILOVER_TARGET_POD:?FAILOVER_TARGET_POD missing in prepared env}"
}

trigger_standard_failover() {
  local method="${FAILOVER_STANDARD_TRIGGER_METHOD:-install_update}"
  echo "FAILOVER_METHOD=${method}" >> "${RESULTS_DIR}/failover_event.txt"
  echo "FAILOVER_TRIGGER_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "${RESULTS_DIR}/failover_event.txt"

  local uuid="${STANDARD_CLUSTER_UUID:-}"
  : "${uuid:?Set STANDARD_CLUSTER_UUID in benchmark.conf}"

  case "${method}" in
    power_off)
      local node_uuid="${STANDARD_PRIMARY_NODE_UUID:-}"
      local token="${DO_DBAAS_API_TOKEN:-}"
      : "${node_uuid:?Set STANDARD_PRIMARY_NODE_UUID for power_off trigger}"
      : "${token:?Set DO_DBAAS_API_TOKEN for power_off trigger}"

      local api_url="${STANDARD_DBAAS_POWER_URL:-https://api.digitalocean.com/v2/dbaas/clusters/${node_uuid}/power}"
      echo "Triggering Standard primary power-off: ${api_url}" | tee -a "${RESULTS_DIR}/failover_trigger.log"

      http_code=$(curl -sS -o "${RESULTS_DIR}/failover_api_response.json" -w '%{http_code}' \
        -X PATCH \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -d '{"powered": false}' \
        "${api_url}")

      echo "HTTP ${http_code}" | tee -a "${RESULTS_DIR}/failover_trigger.log"
      if [[ "${http_code}" -lt 200 || "${http_code}" -ge 300 ]]; then
        echo "ERROR: power-off API failed (HTTP ${http_code})" | tee -a "${RESULTS_DIR}/failover_trigger.log"
        cat "${RESULTS_DIR}/failover_api_response.json" | tee -a "${RESULTS_DIR}/failover_trigger.log"
        return 1
      fi
      ;;

    install_update)
      local token="${DIGITALOCEAN_TOKEN:-${DO_API_TOKEN:-}}"
      : "${token:?Set DIGITALOCEAN_TOKEN or DO_API_TOKEN for install_update trigger}"

      echo "Triggering Standard forced maintenance (install_update): ${uuid}" \
        | tee -a "${RESULTS_DIR}/failover_trigger.log"

      if command -v doctl >/dev/null 2>&1; then
        DIGITALOCEAN_ACCESS_TOKEN="${token}" doctl databases maintenance-window install "${uuid}" \
          2>&1 | tee -a "${RESULTS_DIR}/failover_trigger.log"
      else
        http_code=$(curl -sS -o "${RESULTS_DIR}/failover_api_response.json" -w '%{http_code}' \
          -X PUT \
          -H "Authorization: Bearer ${token}" \
          -H "Content-Type: application/json" \
          "https://api.digitalocean.com/v2/databases/${uuid}/install_update")

        echo "HTTP ${http_code}" | tee -a "${RESULTS_DIR}/failover_trigger.log"
        if [[ "${http_code}" -lt 200 || "${http_code}" -ge 300 ]]; then
          cat "${RESULTS_DIR}/failover_api_response.json" | tee -a "${RESULTS_DIR}/failover_trigger.log"
          return 1
        fi
      fi
      ;;

    storage_resize)
      local token="${DIGITALOCEAN_TOKEN:-${DO_API_TOKEN:-}}"
      local size_slug="${STANDARD_CLUSTER_SIZE_SLUG:-}"
      local storage_mib="${STANDARD_CLUSTER_STORAGE_MIB:-}"
      local num_nodes
      num_nodes="$(failover_cluster_num_nodes standard)"
      : "${token:?Set DIGITALOCEAN_TOKEN for storage_resize}"
      : "${size_slug:?Set STANDARD_CLUSTER_SIZE_SLUG}"
      : "${storage_mib:?Set STANDARD_CLUSTER_STORAGE_MIB (current + increment)}"

      echo "Triggering Standard storage resize: ${uuid}" | tee -a "${RESULTS_DIR}/failover_trigger.log"

      if command -v doctl >/dev/null 2>&1; then
        DIGITALOCEAN_ACCESS_TOKEN="${token}" doctl databases resize "${uuid}" \
          --num-nodes "${num_nodes}" \
          --size "${size_slug}" \
          --storage-size-mib "${storage_mib}" \
          --wait false \
          2>&1 | tee -a "${RESULTS_DIR}/failover_trigger.log"
      else
        curl -sS -X PUT \
          -H "Authorization: Bearer ${token}" \
          -H "Content-Type: application/json" \
          -d "{\"num_nodes\": ${num_nodes}, \"size\": \"${size_slug}\", \"storage_size_mib\": ${storage_mib}}" \
          "https://api.digitalocean.com/v2/databases/${uuid}/resize" \
          | tee -a "${RESULTS_DIR}/failover_trigger.log"
      fi
      ;;

    manual)
      echo "FAILOVER_METHOD=manual" >> "${RESULTS_DIR}/failover_event.txt"
      echo "Manual trigger — perform failover now; waiting ${FAILOVER_MANUAL_WAIT_SEC:-30}s..." \
        | tee -a "${RESULTS_DIR}/failover_trigger.log"
      sleep "${FAILOVER_MANUAL_WAIT_SEC:-30}"
      ;;

    *)
      echo "ERROR: Unknown FAILOVER_STANDARD_TRIGGER_METHOD=${method}" >&2
      echo "Use: power_off | install_update | storage_resize | manual" >&2
      return 1
      ;;
  esac
}

fetch_advanced_kubeconfig() {
  local kubeconfig="${RESULTS_DIR}/kubeconfig"
  local log="${TRIGGER_LOG}"

  if [[ -n "${ADVANCED_KUBECONFIG_PATH:-}" && -f "${ADVANCED_KUBECONFIG_PATH}" ]]; then
    cp "${ADVANCED_KUBECONFIG_PATH}" "${kubeconfig}"
    echo "Using ADVANCED_KUBECONFIG_PATH: ${ADVANCED_KUBECONFIG_PATH}" >> "${log}"
    echo "${kubeconfig}"
    return 0
  fi

  if [[ -n "${ADVANCED_KUBECONFIG_FETCH_CMD:-}" ]]; then
    echo "Fetching kubeconfig via ADVANCED_KUBECONFIG_FETCH_CMD..." >> "${log}"
    # shellcheck disable=SC2090
    eval "${ADVANCED_KUBECONFIG_FETCH_CMD}" > "${kubeconfig}"
    chmod 600 "${kubeconfig}"
    echo "${kubeconfig}"
    return 0
  fi

  local fetch_url="${ADVANCED_KUBECONFIG_FETCH_URL:-}"
  local token="${ADVANCED_KUBECONFIG_FETCH_TOKEN:-${DO_DBAAS_API_TOKEN:-${DIGITALOCEAN_TOKEN:-}}}"
  if [[ -n "${fetch_url}" ]]; then
    echo "Fetching kubeconfig from ${fetch_url}..." >> "${log}"
    http_code=$(curl -sS -o "${kubeconfig}" -w '%{http_code}' \
      -H "Authorization: Bearer ${token}" \
      "${fetch_url}")
    chmod 600 "${kubeconfig}"
    if [[ "${http_code}" -lt 200 || "${http_code}" -ge 300 ]]; then
      echo "ERROR: kubeconfig fetch failed (HTTP ${http_code})" >> "${log}"
      return 1
    fi
    echo "${kubeconfig}"
    return 0
  fi

  echo "ERROR: Set ADVANCED_KUBECONFIG_PATH, ADVANCED_KUBECONFIG_FETCH_URL, or ADVANCED_KUBECONFIG_FETCH_CMD" >&2
  return 1
}

find_advanced_primary_pod() {
  local kubeconfig="${1:?kubeconfig required}"
  local ns="${ADVANCED_K8S_NAMESPACE:-}"
  local log="${TRIGGER_LOG}"
  : "${ns:?Set ADVANCED_K8S_NAMESPACE in benchmark.conf}"

  local kubectl=(kubectl --kubeconfig="${kubeconfig}")
  if [[ -n "${ADVANCED_K8S_CONTEXT:-}" ]]; then
    kubectl+=(--context="${ADVANCED_K8S_CONTEXT}")
  fi

  local pod=""

  if [[ -n "${ADVANCED_K8S_PRIMARY_POD_NAME:-}" ]]; then
    pod="${ADVANCED_K8S_PRIMARY_POD_NAME}"
    echo "Using configured primary pod: ${pod}" >> "${log}"
    echo "${pod}"
    return 0
  fi

  if [[ -n "${ADVANCED_K8S_POD_LABEL_SELECTOR:-}" ]]; then
    pod=$("${kubectl[@]}" get pods -n "${ns}" -l "${ADVANCED_K8S_POD_LABEL_SELECTOR}" \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [[ -n "${pod}" ]]; then
      echo "Primary pod from label selector: ${pod}" >> "${log}"
      echo "${pod}"
      return 0
    fi
  fi

  local hostname
  hostname=$(mysql_cli -N -e "SELECT @@hostname;" 2>/dev/null || true)
  echo "MySQL @@hostname=${hostname}" >> "${log}"

  if [[ -n "${hostname}" ]]; then
    pod=$("${kubectl[@]}" get pods -n "${ns}" --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null \
      | grep -F "${hostname}" | head -1 || true)
    if [[ -n "${pod}" ]]; then
      echo "Primary pod matched by hostname: ${pod}" >> "${log}"
      echo "${pod}"
      return 0
    fi
  fi

  pod=$("${kubectl[@]}" get pods -n "${ns}" \
    -l "${ADVANCED_K8S_CLUSTER_LABEL:-app.kubernetes.io/instance=mysql},${ADVANCED_K8S_PRIMARY_ROLE_LABEL:-role=primary}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

  if [[ -z "${pod}" ]]; then
    pod=$("${kubectl[@]}" get pods -n "${ns}" --no-headers 2>/dev/null \
      | awk '/mysql/ && !/proxy/ {print $1; exit}' || true)
  fi

  if [[ -z "${pod}" ]]; then
    echo "ERROR: Could not identify Advanced primary pod." >> "${log}"
    "${kubectl[@]}" get pods -n "${ns}" >> "${log}" 2>&1 || true
    return 1
  fi

  echo "Primary pod: ${pod}" >> "${log}"
  echo "${pod}"
}

_advanced_failover_delete_pod() {
  local kubeconfig="${1:?kubeconfig required}"
  local pod="${2:?pod required}"
  local ns="${3:?namespace required}"
  local delete_force="${4:-1}"
  local delete_grace="${5:-0}"

  local delete_method="kubectl_delete_pod"
  if [[ "${delete_force}" == "1" ]]; then
    delete_method="kubectl_delete_pod_force"
  fi

  echo "FAILOVER_METHOD=${delete_method}" >> "${EVENT_FILE}"
  echo "FAILOVER_POD_DELETE_FORCE=${delete_force}" >> "${EVENT_FILE}"
  echo "FAILOVER_POD_DELETE_GRACE_SEC=${delete_grace}" >> "${EVENT_FILE}"
  echo "FAILOVER_TARGET_POD=${pod}" >> "${EVENT_FILE}"

  local kubectl=(kubectl --kubeconfig="${kubeconfig}")
  if [[ -n "${ADVANCED_K8S_CONTEXT:-}" ]]; then
    kubectl+=(--context="${ADVANCED_K8S_CONTEXT}")
  fi

  local delete_args=(delete pod -n "${ns}" "${pod}" --wait=false)
  if [[ "${delete_force}" == "1" ]]; then
    delete_args+=(--grace-period="${delete_grace}" --force)
    echo "Force-deleting primary pod ${pod} in namespace ${ns} (grace-period=${delete_grace})..." \
      | tee -a "${TRIGGER_LOG}"
    echo "Command: kubectl delete pod ${pod} -n ${ns} --grace-period=${delete_grace} --force --wait=false" \
      >> "${TRIGGER_LOG}"
  else
    delete_args+=(--grace-period="${delete_grace}")
    echo "Deleting primary pod ${pod} in namespace ${ns} (grace-period=${delete_grace})..." \
      | tee -a "${TRIGGER_LOG}"
  fi

  echo "FAILOVER_TRIGGER_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "${EVENT_FILE}"
  echo "FAILOVER_POD_DELETE_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "${EVENT_FILE}"

  "${kubectl[@]}" "${delete_args[@]}" \
    2>&1 | tee -a "${TRIGGER_LOG}"

  echo "Pod delete issued at $(date -u +%Y-%m-%dT%H:%M:%SZ)" | tee -a "${TRIGGER_LOG}"
  _failover_snapshot_k8s_events "${RESULTS_DIR}" "post_delete"
  log_failover_do_events "${RESULTS_DIR}" "advanced" "post_delete"
}

_advanced_failover_kill_mysqld() {
  local kubeconfig="${1:?kubeconfig required}"
  local pod="${2:?pod required}"
  local ns="${3:?namespace required}"
  local container="${ADVANCED_K8S_MYSQL_CONTAINER:-mysql}"
  local signal="${FAILOVER_MYSQLD_KILL_SIGNAL:-9}"

  echo "FAILOVER_METHOD=kubectl_kill_mysqld" >> "${EVENT_FILE}"
  echo "FAILOVER_MYSQLD_KILL_SIGNAL=${signal}" >> "${EVENT_FILE}"
  echo "FAILOVER_MYSQLD_KILL_CONTAINER=${container}" >> "${EVENT_FILE}"
  echo "FAILOVER_TARGET_POD=${pod}" >> "${EVENT_FILE}"

  local kubectl=(kubectl --kubeconfig="${kubeconfig}")
  if [[ -n "${ADVANCED_K8S_CONTEXT:-}" ]]; then
    kubectl+=(--context="${ADVANCED_K8S_CONTEXT}")
  fi

  echo "Killing mysqld in primary pod ${pod} (namespace=${ns}, container=${container}, signal=${signal})..." \
    | tee -a "${TRIGGER_LOG}"
  echo "Command: kubectl exec -n ${ns} ${pod} -c ${container} -- kill -${signal} \$(pidof mysqld)" \
    >> "${TRIGGER_LOG}"

  echo "FAILOVER_TRIGGER_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "${EVENT_FILE}"
  echo "FAILOVER_MYSQLD_KILL_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "${EVENT_FILE}"

  "${kubectl[@]}" exec -n "${ns}" "${pod}" -c "${container}" -- \
    sh -c "kill -${signal} \$(pidof mysqld) 2>/dev/null || kill -${signal} 1" \
    2>&1 | tee -a "${TRIGGER_LOG}"

  echo "mysqld kill issued at $(date -u +%Y-%m-%dT%H:%M:%SZ)" | tee -a "${TRIGGER_LOG}"
  _failover_snapshot_k8s_events "${RESULTS_DIR}" "post_mysqld_kill"
  log_failover_do_events "${RESULTS_DIR}" "advanced" "post_mysqld_kill"
}

prepare_advanced_failover_trigger() {
  if ! failover_advanced_trigger_active; then
    if ! failover_trigger_enabled; then
      record_trigger_skipped "FAILOVER_TRIGGER_ENABLED=0"
    else
      record_trigger_skipped "FAILOVER_POD_DELETE=0 (load-only control run)"
    fi
    return 0
  fi

  if ! command -v kubectl >/dev/null 2>&1; then
    echo "ERROR: kubectl not found in PATH" >&2
    return 1
  fi

  init_failover_event_stub

  local delete_force="${FAILOVER_POD_DELETE_FORCE:-1}"
  local delete_grace="${FAILOVER_POD_DELETE_GRACE_SEC:-0}"
  local kubeconfig pod ns

  ns="${ADVANCED_K8S_NAMESPACE:?Set ADVANCED_K8S_NAMESPACE}"
  echo "Preparing Advanced failover trigger at $(date -u +%Y-%m-%dT%H:%M:%SZ)..." | tee -a "${TRIGGER_LOG}"
  kubeconfig=$(fetch_advanced_kubeconfig)
  pod=$(find_advanced_primary_pod "${kubeconfig}")

  write_failover_prepared_env "${kubeconfig}" "${pod}" "${ns}" "${delete_force}" "${delete_grace}"
  echo "Prepared: kubeconfig=${kubeconfig} target_pod=${pod} namespace=${ns}" | tee -a "${TRIGGER_LOG}"
}

refresh_advanced_failover_trigger() {
  load_failover_prepared_env

  if ! command -v kubectl >/dev/null 2>&1; then
    echo "ERROR: kubectl not found in PATH" >&2
    return 1
  fi

  local pod
  pod=$(find_advanced_primary_pod "${FAILOVER_KUBECONFIG}")
  write_failover_prepared_env "${FAILOVER_KUBECONFIG}" "${pod}" "${FAILOVER_K8S_NAMESPACE}" \
    "${FAILOVER_POD_DELETE_FORCE:-1}" "${FAILOVER_POD_DELETE_GRACE_SEC:-0}"
  echo "Refreshed primary pod for trigger: ${pod} at $(date -u +%Y-%m-%dT%H:%M:%SZ)" | tee -a "${TRIGGER_LOG}"
}

fire_advanced_failover_trigger() {
  if ! failover_advanced_trigger_active; then
    if ! failover_trigger_enabled; then
      record_trigger_skipped "FAILOVER_TRIGGER_ENABLED=0"
    else
      record_trigger_skipped "FAILOVER_POD_DELETE=0 (load-only control run)"
    fi
    return 0
  fi

  load_failover_prepared_env

  local pod="${FAILOVER_TARGET_POD}" method
  echo "Using primary pod from refresh: ${pod} at $(date -u +%Y-%m-%dT%H:%M:%SZ)" | tee -a "${TRIGGER_LOG}"

  method="$(failover_advanced_trigger_method)"
  case "${method}" in
    pod_delete)
      _advanced_failover_delete_pod "${FAILOVER_KUBECONFIG}" "${pod}" "${FAILOVER_K8S_NAMESPACE}" \
        "${FAILOVER_POD_DELETE_FORCE:-1}" "${FAILOVER_POD_DELETE_GRACE_SEC:-0}"
      ;;
    mysqld_kill)
      _advanced_failover_kill_mysqld "${FAILOVER_KUBECONFIG}" "${pod}" "${FAILOVER_K8S_NAMESPACE}"
      ;;
    *)
      echo "ERROR: Unknown FAILOVER_ADVANCED_TRIGGER_METHOD=${method}" >&2
      return 1
      ;;
  esac
}

trigger_advanced_failover() {
  prepare_advanced_failover_trigger
  fire_advanced_failover_trigger
}

log_do_events() {
  log_failover_do_events "${RESULTS_DIR}" "${EDITION}" "trigger"
}

case "${EDITION}" in
  standard)
    if failover_trigger_enabled; then
      init_failover_event_stub
      trigger_standard_failover
      : > "${RESULTS_DIR}/do_events.log"
      log_do_events
    else
      record_trigger_skipped "FAILOVER_TRIGGER_ENABLED=0"
    fi
    ;;
  advanced)
    : > "${RESULTS_DIR}/do_events.log"
    case "${ACTION}" in
      prepare) prepare_advanced_failover_trigger ;;
      refresh) refresh_advanced_failover_trigger ;;
      fire) fire_advanced_failover_trigger ;;
      "")
        if failover_trigger_enabled; then
          trigger_advanced_failover
        else
          record_trigger_skipped "FAILOVER_TRIGGER_ENABLED=0"
        fi
        ;;
      *)
        echo "ERROR: Unknown action '${ACTION}' (use prepare, refresh, fire, or omit)" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    echo "ERROR: Unknown edition '${EDITION}' (use standard or advanced)" >&2
    exit 1
    ;;
esac

echo "Failover trigger complete for ${EDITION}"
