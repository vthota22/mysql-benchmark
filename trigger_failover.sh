#!/usr/bin/env bash
# Trigger failover for Standard or Advanced edition during a benchmark run.
#
# Usage:
#   trigger_failover.sh <edition> <results_dir>
#
# Requires benchmark.conf (via BENCHMARK_CONF) and edition-specific settings.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${BENCHMARK_CONF:-${SCRIPT_DIR}/benchmark.conf}"

# shellcheck source=lib/failover_common.sh
source "${SCRIPT_DIR}/lib/failover_common.sh"
load_benchmark_config "${CONFIG}"
failover_defaults

EDITION="${1:?Usage: $0 <standard|advanced> <results_dir>}"
RESULTS_DIR="${2:?Usage: $0 <standard|advanced> <results_dir>}"
mkdir -p "${RESULTS_DIR}"

set_mysql_env_for_edition "${EDITION}"

: > "${RESULTS_DIR}/failover_event.txt"
echo "FAILOVER_EDITION=${EDITION}" >> "${RESULTS_DIR}/failover_event.txt"
echo "FAILOVER_TRIGGER_ENABLED=${FAILOVER_TRIGGER_ENABLED:-1}" >> "${RESULTS_DIR}/failover_event.txt"
echo "FAILOVER_POD_DELETE=${FAILOVER_POD_DELETE:-${FAILOVER_TRIGGER_ENABLED:-1}}" >> "${RESULTS_DIR}/failover_event.txt"

record_trigger_skipped() {
  local reason="${1:?reason required}"
  echo "FAILOVER_METHOD=skipped" >> "${RESULTS_DIR}/failover_event.txt"
  echo "FAILOVER_TRIGGER_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "${RESULTS_DIR}/failover_event.txt"
  echo "FAILOVER_SKIP_REASON=${reason}" >> "${RESULTS_DIR}/failover_event.txt"
  {
    echo "Failover trigger SKIPPED at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "Reason: ${reason}"
    echo "Load continues through observe window; no pod delete / API trigger."
  } | tee -a "${RESULTS_DIR}/failover_trigger.log"
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
  local log="${RESULTS_DIR}/failover_trigger.log"

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
  local log="${RESULTS_DIR}/failover_trigger.log"
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

trigger_advanced_failover() {
  if ! failover_pod_delete_enabled; then
    record_trigger_skipped "FAILOVER_POD_DELETE=0 (load-only control run)"
    return 0
  fi

  local delete_force="${FAILOVER_POD_DELETE_FORCE:-1}"
  local delete_grace="${FAILOVER_POD_DELETE_GRACE_SEC:-0}"
  local delete_method="kubectl_delete_pod"
  if [[ "${delete_force}" == "1" ]]; then
    delete_method="kubectl_delete_pod_force"
  fi

  echo "FAILOVER_METHOD=${delete_method}" >> "${RESULTS_DIR}/failover_event.txt"
  echo "FAILOVER_POD_DELETE_FORCE=${delete_force}" >> "${RESULTS_DIR}/failover_event.txt"
  echo "FAILOVER_POD_DELETE_GRACE_SEC=${delete_grace}" >> "${RESULTS_DIR}/failover_event.txt"
  echo "FAILOVER_TRIGGER_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "${RESULTS_DIR}/failover_event.txt"
  echo "FAILOVER_POD_DELETE_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "${RESULTS_DIR}/failover_event.txt"

  if ! command -v kubectl >/dev/null 2>&1; then
    echo "ERROR: kubectl not found in PATH" >&2
    return 1
  fi

  local kubeconfig
  kubeconfig=$(fetch_advanced_kubeconfig)

  local ns="${ADVANCED_K8S_NAMESPACE:?Set ADVANCED_K8S_NAMESPACE}"
  local pod
  pod=$(find_advanced_primary_pod "${kubeconfig}")

  echo "FAILOVER_TARGET_POD=${pod}" >> "${RESULTS_DIR}/failover_event.txt"

  local kubectl=(kubectl --kubeconfig="${kubeconfig}")
  if [[ -n "${ADVANCED_K8S_CONTEXT:-}" ]]; then
    kubectl+=(--context="${ADVANCED_K8S_CONTEXT}")
  fi

  local delete_args=(delete pod -n "${ns}" "${pod}" --wait=false)
  if [[ "${delete_force}" == "1" ]]; then
    delete_args+=(--grace-period="${delete_grace}" --force)
    echo "Force-deleting primary pod ${pod} in namespace ${ns} (grace-period=${delete_grace})..." \
      | tee -a "${RESULTS_DIR}/failover_trigger.log"
    echo "Command: kubectl delete pod ${pod} -n ${ns} --grace-period=${delete_grace} --force --wait=false" \
      >> "${RESULTS_DIR}/failover_trigger.log"
  else
    delete_args+=(--grace-period="${delete_grace}")
    echo "Deleting primary pod ${pod} in namespace ${ns} (grace-period=${delete_grace})..." \
      | tee -a "${RESULTS_DIR}/failover_trigger.log"
  fi

  _failover_snapshot_k8s_events "${RESULTS_DIR}" "pre_delete"
  log_failover_do_events "${RESULTS_DIR}" "advanced" "pre_delete"

  "${kubectl[@]}" "${delete_args[@]}" \
    2>&1 | tee -a "${RESULTS_DIR}/failover_trigger.log"

  echo "Pod delete issued at $(date -u +%Y-%m-%dT%H:%M:%SZ)" | tee -a "${RESULTS_DIR}/failover_trigger.log"
  _failover_snapshot_k8s_events "${RESULTS_DIR}" "post_delete"
  log_failover_do_events "${RESULTS_DIR}" "advanced" "post_delete"
}

log_do_events() {
  log_failover_do_events "${RESULTS_DIR}" "${EDITION}" "trigger"
}

case "${EDITION}" in
  standard)
    if failover_trigger_enabled; then
      trigger_standard_failover
      : > "${RESULTS_DIR}/do_events.log"
      log_do_events
    else
      record_trigger_skipped "FAILOVER_TRIGGER_ENABLED=0"
    fi
    ;;
  advanced)
    : > "${RESULTS_DIR}/do_events.log"
    trigger_advanced_failover
    ;;
  *)
    echo "ERROR: Unknown edition '${EDITION}' (use standard or advanced)" >&2
    exit 1
    ;;
esac

echo "Failover trigger complete for ${EDITION}"
