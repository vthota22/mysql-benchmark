#!/usr/bin/env bash
# Failover benchmark: continuous TPC-C load, trigger failover mid-run, capture RTO metrics.
#
# Runs each configured scenario sequentially (default: mixed read/write, then write_only).
#
# Usage:
#   cp benchmark.conf.example benchmark.conf   # fill in credentials + failover settings
#   ./run_failover_benchmark.sh
#
# Optional:
#   BENCHMARK_CONF=/path/to/benchmark.conf ./run_failover_benchmark.sh
#   FAILOVER_EDITIONS="advanced" ./run_failover_benchmark.sh   # single edition
#   FAILOVER_SCENARIOS="mixed" ./run_failover_benchmark.sh    # skip write_only scenario
#   FAILOVER_THREAD_MATRIX="4 8 16 32" ./run_failover_benchmark.sh  # thread sweep
#
# Run inside tmux/nohup on the benchmark droplet — runtime depends on FAILOVER_*_SEC and scenario count.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${BENCHMARK_CONF:-${SCRIPT_DIR}/benchmark.conf}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULTS_ROOT="${SCRIPT_DIR}/results/failover_${TIMESTAMP}"
FULL_LOG="${RESULTS_ROOT}/full_run.log"

export PATH="${SCRIPT_DIR}/sysbench-1.1/bin:${PATH}"

# shellcheck source=lib/failover_common.sh
source "${SCRIPT_DIR}/lib/failover_common.sh"
load_benchmark_config "${CONFIG}"
failover_defaults

mkdir -p "${RESULTS_ROOT}"
exec > >(tee -a "${FULL_LOG}") 2>&1

_per_scenario_runtime_sec() {
  failover_total_runtime_sec
}

echo "=== MySQL Failover Benchmark (TPC-C under load) ==="
echo "Started:  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "Results:  ${RESULTS_ROOT}"
echo "Config:   ${CONFIG}"
echo "Sysbench: $("${SCRIPT_DIR}/which_sysbench.sh")"
echo ""
echo "Load:     threads=${FAILOVER_THREADS} report-interval=${FAILOVER_REPORT_INTERVAL}s"
if [[ -n "${FAILOVER_THREAD_MATRIX:-}" ]]; then
  echo "Thread matrix:${FAILOVER_THREAD_MATRIX} (delay between=${FAILOVER_THREAD_DELAY_SEC}s)"
fi
echo "Timeline: warmup=${FAILOVER_WARMUP_SEC}s + baseline=${FAILOVER_BASELINE_SEC}s + observe=${FAILOVER_OBSERVE_SEC}s"
echo "          trigger at second $(failover_trigger_second) | total=$(_per_scenario_runtime_sec)s per scenario"
echo "Scenarios:${FAILOVER_SCENARIOS} (delay between=${FAILOVER_SCENARIO_DELAY_SEC}s)"
verify_failover_tpcc_profiles || exit 1
echo "Editions: ${FAILOVER_EDITIONS}"
echo "Reconnect: mysql-ignore-errors=${FAILOVER_MYSQL_IGNORE_ERRORS}"
echo "Monitor:   primary=${FAILOVER_MONITOR_PRIMARY:-1} k8s_events=${FAILOVER_COLLECT_K8S_EVENTS:-1}"
if failover_trigger_enabled; then
  if [[ "${FAILOVER_EDITIONS}" == *advanced* ]]; then
    echo "Trigger:  enabled (method=${FAILOVER_ADVANCED_TRIGGER_METHOD:-pod_delete}, pod delete=${FAILOVER_POD_DELETE})"
  else
    echo "Trigger:  enabled (FAILOVER_TRIGGER_ENABLED=1)"
  fi
else
  echo "Trigger:  DISABLED — load-only control run (FAILOVER_TRIGGER_ENABLED=0)"
fi
echo ""

run_failover_scenario() {
  local edition="${1:?edition required}"
  local scenario="${2:?scenario required}"
  local edition_dir="${3:?edition dir required}"
  local scenario_dir="${edition_dir}/${scenario}"
  local trx_profile

  trx_profile="$(failover_scenario_trx_profile "${scenario}")"
  mkdir -p "${scenario_dir}"

  export FAILOVER_SCENARIO="${scenario}"
  export TPCC_TRX_PROFILE="${trx_profile}"

  echo ""
  echo "----------------------------------------"
  echo " Scenario: ${scenario} (trx_profile=${trx_profile})"
  echo "----------------------------------------"
  echo ""

  start_failover_watchers "${scenario_dir}" "${edition}"

  echo "--- Starting continuous TPC-C load (${scenario}) ---"
  run_tpcc_failover_load "${scenario_dir}"

  if ! wait_for_sysbench_start "${scenario_dir}" 180; then
    stop_failover_watchers "${scenario_dir}"
    stop_sysbench_load "${scenario_dir}"
    return 1
  fi

  if [[ "${edition}" == "advanced" ]] && failover_advanced_trigger_active; then
    : > "${scenario_dir}/failover_trigger.log"
    echo "--- Preparing failover trigger (kubeconfig, kubectl, primary pod) ---"
    BENCHMARK_CONF="${CONFIG}" "${SCRIPT_DIR}/trigger_failover.sh" "${edition}" "${scenario_dir}" prepare \
      2>&1 | tee -a "${scenario_dir}/failover_trigger.log"
  fi

  echo "--- Baseline load period, then failover trigger ---"
  if [[ "${edition}" == "advanced" ]] && failover_advanced_trigger_active; then
    sleep_until_failover_trigger_early
  else
    sleep_until_failover_trigger
  fi

  if failover_trigger_enabled; then
    echo "--- Triggering failover (${scenario}) ---"
  else
    echo "--- Failover trigger skipped (FAILOVER_TRIGGER_ENABLED=0) — recording trigger time only ---"
  fi
  if [[ "${edition}" == "advanced" ]] && failover_advanced_trigger_active; then
    BENCHMARK_CONF="${CONFIG}" "${SCRIPT_DIR}/trigger_failover.sh" "${edition}" "${scenario_dir}" refresh \
      2>&1 | tee -a "${scenario_dir}/failover_trigger.log"
    sleep_until_failover_trigger_final_gap
    BENCHMARK_CONF="${CONFIG}" "${SCRIPT_DIR}/trigger_failover.sh" "${edition}" "${scenario_dir}" fire \
      2>&1 | tee -a "${scenario_dir}/failover_trigger.log"
  else
    BENCHMARK_CONF="${CONFIG}" "${SCRIPT_DIR}/trigger_failover.sh" "${edition}" "${scenario_dir}" \
      2>&1 | tee -a "${scenario_dir}/failover_trigger.log"
  fi

  echo "--- Observing recovery for ${FAILOVER_OBSERVE_SEC}s ---"
  sleep "${FAILOVER_OBSERVE_SEC}"

  _failover_snapshot_k8s_events "${scenario_dir}" "post_observe"
  log_failover_do_events "${scenario_dir}" "${edition}" "post_observe"

  echo "--- Stopping load ---"
  stop_sysbench_load "${scenario_dir}"
  stop_failover_watchers "${scenario_dir}"

  run_failover_tpcc_check "${scenario_dir}" || true

  echo "--- Analyzing failover metrics (${scenario}) ---"
  analyze_failover_metrics "${scenario_dir}"

  echo ""
  echo "${edition}/${scenario}: failover benchmark complete"
  echo "  Analysis:         ${scenario_dir}/failover_analysis.txt"
  echo "  KPI CSV:          ${scenario_dir}/failover_kpi.csv"
  echo "  Extended metrics: ${scenario_dir}/failover_extended_metrics.txt"
  echo "  Promotion breakdown: ${scenario_dir}/failover_promotion_breakdown.txt"
  echo "  Metrics CSV:      ${scenario_dir}/failover_metrics.csv"
  echo "  Time series:      ${scenario_dir}/failover_timeseries.csv"
  echo "  Graphs:           ${scenario_dir}/graphs/"
  echo "  HTML report:      ${scenario_dir}/graphs/failover_report.html"
}

run_failover_edition() {
  local edition="${1:?edition required}"
  local edition_dir="${RESULTS_ROOT}/${edition}"
  mkdir -p "${edition_dir}"

  echo ""
  echo "========================================"
  echo " Failover test: ${edition}"
  echo "========================================"
  echo ""

  export FAILOVER_EDITION="${edition}"
  set_mysql_env_for_edition "${edition}"

  export TPCC_TABLES="${TPCC_TABLES:-10}"
  export TPCC_SCALE="${TPCC_SCALE:-100}"
  export TPCC_FORCE_PK="${TPCC_FORCE_PK:-1}"
  export TPCC_TRX_LEVEL="${TPCC_TRX_LEVEL:-RR}"

  echo "Host: ${MYSQL_HOST}:${MYSQL_PORT}  DB: ${MYSQL_DB}"
  echo "Trigger: $(
    if [[ "${edition}" == "standard" ]]; then
      echo "${FAILOVER_STANDARD_TRIGGER_METHOD:-install_update}"
    else
      case "${FAILOVER_ADVANCED_TRIGGER_METHOD:-pod_delete}" in
        mysqld_kill)
          echo "kubectl_kill_mysqld (signal=${FAILOVER_MYSQLD_KILL_SIGNAL:-9}, container=${ADVANCED_K8S_MYSQL_CONTAINER:-mysql})"
          ;;
        pod_delete)
          if [[ "${FAILOVER_POD_DELETE_FORCE:-1}" == "1" ]]; then
            echo "kubectl_delete_pod_force (grace-period=${FAILOVER_POD_DELETE_GRACE_SEC:-0})"
          else
            echo "kubectl_delete_pod (grace-period=${FAILOVER_POD_DELETE_GRACE_SEC:-30})"
          fi
          ;;
        *)
          echo "${FAILOVER_ADVANCED_TRIGGER_METHOD:-pod_delete}"
          ;;
      esac
    fi
  )"
  echo ""

  mysql_connectivity_check "${edition}" "${edition_dir}/mysql_info.txt" \
    || { echo "Aborting ${edition}: cannot connect"; return 1; }
  echo ""

  write_failover_benchmark_config "${edition_dir}" "${edition}"

  if [[ "${SKIP_PREPARE:-0}" != "1" ]]; then
    echo "--- Prepare TPC-C data (threads=${PREP_THREADS:-16}) ---"
    export TPCC_THREADS="${PREP_THREADS:-16}"
    run_tpcc_command cleanup 2>&1 | tee "${edition_dir}/cleanup_before.log" || true
    run_tpcc_command prepare 2>&1 | tee "${edition_dir}/prepare.log"
    echo ""
  else
    echo "--- Skipping prepare (SKIP_PREPARE=1) ---"
    echo ""
  fi

  local scenario_index=0
  local thread_index=0

  _run_scenarios_for_base_dir() {
    local base_dir="${1:?base dir required}"
    scenario_index=0
    for scenario in ${FAILOVER_SCENARIOS}; do
      scenario_index=$((scenario_index + 1))
      if [[ "${scenario_index}" -gt 1 && "${FAILOVER_SCENARIO_DELAY_SEC:-0}" -gt 0 ]]; then
        echo "--- Waiting ${FAILOVER_SCENARIO_DELAY_SEC}s for cluster stability before scenario ${scenario} ---"
        sleep "${FAILOVER_SCENARIO_DELAY_SEC}"
      fi
      if ! run_failover_scenario "${edition}" "${scenario}" "${base_dir}"; then
        return 1
      fi
    done
    return 0
  }

  if [[ -n "${FAILOVER_THREAD_MATRIX:-}" ]]; then
    for threads in ${FAILOVER_THREAD_MATRIX}; do
      thread_index=$((thread_index + 1))
      if [[ "${thread_index}" -gt 1 && "${FAILOVER_THREAD_DELAY_SEC:-0}" -gt 0 ]]; then
        echo "--- Waiting ${FAILOVER_THREAD_DELAY_SEC}s before thread count ${threads} ---"
        sleep "${FAILOVER_THREAD_DELAY_SEC}"
      fi
      export FAILOVER_THREADS="${threads}"
      local thread_dir="${edition_dir}/t${threads}"
      mkdir -p "${thread_dir}"
      echo ""
      echo "======== Thread count: ${threads} (results under ${thread_dir}/) ========"
      if ! _run_scenarios_for_base_dir "${thread_dir}"; then
        return 1
      fi
    done
  else
    if ! _run_scenarios_for_base_dir "${edition_dir}"; then
      return 1
    fi
  fi
}

FAILED=0
for edition in ${FAILOVER_EDITIONS}; do
  if ! run_failover_edition "${edition}"; then
    FAILED=$((FAILED + 1))
  fi
done

echo ""
echo "--- Failover comparison report ---"
write_failover_comparison "${RESULTS_ROOT}"
generate_failover_graphs "${RESULTS_ROOT}"

echo "${RESULTS_ROOT}" > "${SCRIPT_DIR}/results/LATEST_FAILOVER.txt"

echo ""
echo "=== Failover benchmark complete ==="
echo "Results:   ${RESULTS_ROOT}"
echo "Summary:   ${RESULTS_ROOT}/failover_comparison.txt"
echo "KPI CSV:   ${RESULTS_ROOT}/failover_kpi.csv"
echo "HTML report (thread toggle): ${RESULTS_ROOT}/advanced/graphs/failover_report.html"
echo "Full log:  ${FULL_LOG}"

if [[ "${FAILED}" -gt 0 ]]; then
  echo ""
  echo "WARNING: ${FAILED} edition(s) failed"
  exit 1
fi
