#!/usr/bin/env bash
# Failover benchmark helpers: monitoring, trigger coordination, metric analysis
set -euo pipefail

FAILOVER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_ROOT="$(cd "${FAILOVER_LIB_DIR}/.." && pwd)"

# shellcheck source=lib/benchmark_common.sh
source "${FAILOVER_LIB_DIR}/benchmark_common.sh"

# Defaults (override in benchmark.conf)
failover_defaults() {
  : "${FAILOVER_THREADS:=16}"
  : "${FAILOVER_WARMUP_SEC:=300}"
  : "${FAILOVER_BASELINE_SEC:=300}"
  : "${FAILOVER_OBSERVE_SEC:=600}"
  : "${FAILOVER_REPORT_INTERVAL:=1}"
  : "${FAILOVER_RECOVERY_THRESHOLD:=0.90}"
  : "${FAILOVER_RECOVERY_STABLE_SEC:=30}"
  : "${FAILOVER_OUTAGE_TPS_RATIO:=0.05}"
  : "${FAILOVER_EDITIONS:=standard advanced}"
  : "${FAILOVER_STANDARD_TRIGGER_METHOD:=install_update}"
  : "${FAILOVER_TRIGGER_DELAY_SEC:=}"
  : "${FAILOVER_GENERATE_GRAPHS:=1}"
  : "${FAILOVER_MONITOR_HOSTNAME:=0}"
  : "${FAILOVER_MONITOR_PRIMARY:=1}"
  : "${FAILOVER_MONITOR_WRITE_PROBE:=1}"
  : "${FAILOVER_MONITOR_INTERVAL:=1}"
  : "${FAILOVER_MONITOR_CONNECT_TIMEOUT:=1}"
  : "${FAILOVER_MONITOR_OP_TIMEOUT:=1}"
  : "${FAILOVER_COLLECT_K8S_EVENTS:=1}"
  : "${FAILOVER_RUN_TPCC_CHECK:=0}"
  : "${FAILOVER_MYSQL_IGNORE_ERRORS:=1053,2013,1290,3100,1205,1213,2006,2014,2003,2055,1047,1158,1159,1161,3011}"
  : "${FAILOVER_TRIGGER_ENABLED:=1}"
  : "${FAILOVER_POD_DELETE:=${FAILOVER_TRIGGER_ENABLED}}"
  : "${FAILOVER_POD_DELETE_FORCE:=1}"
  : "${FAILOVER_POD_DELETE_GRACE_SEC:=0}"
  # Advanced: fetch kubeconfig early; re-resolve primary pod this many seconds before delete
  : "${FAILOVER_TRIGGER_PREPARE_SEC:=5}"
  : "${FAILOVER_SCENARIOS:=mixed write_only}"
  : "${FAILOVER_SCENARIO_DELAY_SEC:=120}"
  # Space-separated load thread counts; when set, runs each under edition/t<N>/<scenario>/
  : "${FAILOVER_THREAD_MATRIX:=}"
  : "${FAILOVER_THREAD_DELAY_SEC:=120}"
}

failover_scenario_trx_profile() {
  case "${1:-mixed}" in
    write_only) echo "write_only" ;;
    mixed|*) echo "mixed" ;;
  esac
}

failover_cluster_slug() {
  local edition="${1:-}"
  local prefix slug_var
  prefix="$(echo "${edition}" | tr '[:lower:]' '[:upper:]')"
  slug_var="${prefix}_CLUSTER_SIZE_SLUG"
  if [[ -n "${edition}" && -n "${!slug_var:-}" ]]; then
    echo "${!slug_var}"
    return 0
  fi
  if [[ -n "${SLUG_SIZE:-}" ]]; then
    echo "${SLUG_SIZE}"
    return 0
  fi
  if [[ -n "${MYSQL_CLUSTER_PLAN:-}" ]]; then
    echo "${MYSQL_CLUSTER_PLAN}"
    return 0
  fi
  if [[ -n "${CLUSTER_SIZE_SLUG:-}" ]]; then
    echo "${CLUSTER_SIZE_SLUG}"
    return 0
  fi
  echo "N/A"
}

failover_cluster_num_nodes() {
  local edition="${1:-}"
  local prefix nodes_var
  prefix="$(echo "${edition}" | tr '[:lower:]' '[:upper:]')"
  nodes_var="${prefix}_CLUSTER_NUM_NODES"
  if [[ -n "${edition}" && -n "${!nodes_var:-}" ]]; then
    echo "${!nodes_var}"
    return 0
  fi
  if [[ -n "${NUM_NODES:-}" ]]; then
    echo "${NUM_NODES}"
    return 0
  fi
  echo "N/A"
}

tpcc_approx_data_size_label() {
  local tables="${TPCC_TABLES:-10}"
  local scale="${TPCC_SCALE:-100}"
  awk -v t="${tables}" -v s="${scale}" 'BEGIN {
    gb = s * t * 0.1
    if (gb == int(gb)) printf "~%d GB (tables=%d, scale=%d)", gb, t, s
    else printf "~%.1f GB (tables=%d, scale=%d)", gb, t, s
  }'
}

write_failover_benchmark_config() {
  local edition_dir="${1:?edition dir required}"
  local edition="${2:?edition required}"
  local slug num_nodes data_size prep_threads load_threads tables scale

  slug="$(failover_cluster_slug "${edition}")"
  num_nodes="$(failover_cluster_num_nodes "${edition}")"
  data_size="$(tpcc_approx_data_size_label)"
  prep_threads="${PREP_THREADS:-16}"
  load_threads="${FAILOVER_THREADS:-16}"
  tables="${TPCC_TABLES:-10}"
  scale="${TPCC_SCALE:-100}"

  {
    echo "FAILOVER_EDITION=${edition}"
    echo "SLUG_SIZE=${slug}"
    echo "CLUSTER_SLUG=${slug}"
    echo "NUM_NODES=${num_nodes}"
    echo "DATA_SIZE=${data_size}"
    echo "THREADS=${load_threads}"
    echo "FAILOVER_THREADS=${load_threads}"
    echo "TPCC_SCALE=${scale}"
    echo "TPCC_TABLES=${tables}"
    echo "TPCC_THREADS=${prep_threads}"
    echo "PREP_THREADS=${prep_threads}"
    echo "FAILOVER_THREAD_MATRIX=${FAILOVER_THREAD_MATRIX:-}"
    echo "FAILOVER_SCENARIOS=${FAILOVER_SCENARIOS:-mixed write_only}"
  } > "${edition_dir}/benchmark_config.env"
}

verify_failover_tpcc_profiles() {
  local tpcc scenario profile
  tpcc="$(tpcc_dir)"

  if tpcc_supports_trx_profile "${tpcc}"; then
    echo "TPC-C trx_profile: supported (${tpcc})"
    return 0
  fi

  for scenario in ${FAILOVER_SCENARIOS}; do
    profile="$(failover_scenario_trx_profile "${scenario}")"
    if [[ "${profile}" != "mixed" ]]; then
      echo "ERROR: TPC-C at ${tpcc} does not support --trx_profile=${profile}." >&2
      echo "  The benchmark droplet needs updated Lua files from this repo:" >&2
      echo "    TPCC/sysbench-tpcc/tpcc_common.lua   (trx_profile option)" >&2
      echo "    TPCC/sysbench-tpcc/tpcc.lua          (pick_trx function)" >&2
      echo "  On the droplet: cd /root/mysql-benchmark && git pull" >&2
      echo "  Or copy those two files, then verify:" >&2
      echo "    cd TPCC/sysbench-tpcc && sysbench tpcc.lua help | grep trx_profile" >&2
      return 1
    fi
  done

  echo "WARNING: TPC-C lacks --trx_profile; mixed scenario will use default TPC-C mix." >&2
  echo "  Update TPCC/sysbench-tpcc before running write_only." >&2
  return 0
}

failover_trigger_enabled() {
  failover_defaults
  [[ "${FAILOVER_TRIGGER_ENABLED}" == "1" ]]
}

failover_pod_delete_enabled() {
  failover_defaults
  [[ "${FAILOVER_POD_DELETE}" == "1" ]]
}

failover_total_runtime_sec() {
  failover_defaults
  echo $((FAILOVER_WARMUP_SEC + FAILOVER_BASELINE_SEC + FAILOVER_OBSERVE_SEC))
}

# Sysbench --time is the measured run duration *after* warmup (not including warmup).
failover_sysbench_time_sec() {
  failover_defaults
  echo $((FAILOVER_BASELINE_SEC + FAILOVER_OBSERVE_SEC))
}

failover_trigger_second() {
  failover_defaults
  if [[ -n "${FAILOVER_TRIGGER_SECOND:-}" ]]; then
    echo "${FAILOVER_TRIGGER_SECOND}"
    return 0
  fi
  echo $((FAILOVER_WARMUP_SEC + FAILOVER_BASELINE_SEC))
}

_failover_tee_linebuffer() {
  if command -v stdbuf >/dev/null 2>&1; then
    stdbuf -oL -eL tee "$@"
  else
    tee "$@"
  fi
}

_failover_kill_process_tree() {
  local pid="${1:?pid required}"
  local signal="${2:-INT}"
  local child

  for child in $(pgrep -P "${pid}" 2>/dev/null || true); do
    _failover_kill_process_tree "${child}" "${signal}"
  done
  kill "-${signal}" "${pid}" 2>/dev/null || true
}

mysql_cli() {
  mysql -h "${MYSQL_HOST}" -P "${MYSQL_PORT}" -u "${MYSQL_USER}" -p"${MYSQL_PASSWORD}" \
    --ssl-mode=REQUIRED "${MYSQL_DB}" 2>/dev/null "$@"
}

_failover_run_timeout() {
  local secs="${1:?seconds required}"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "${secs}" "$@"
  else
    "$@"
  fi
}

mysql_cli_timed() {
  _failover_run_timeout "${FAILOVER_MONITOR_OP_TIMEOUT}" \
    mysql -h "${MYSQL_HOST}" -P "${MYSQL_PORT}" -u "${MYSQL_USER}" -p"${MYSQL_PASSWORD}" \
    --ssl-mode=REQUIRED --connect-timeout="${FAILOVER_MONITOR_CONNECT_TIMEOUT}" \
    "${MYSQL_DB}" 2>/dev/null "$@"
}

failover_monitor_enabled() {
  [[ "${FAILOVER_MONITOR_PRIMARY:-1}" == "1" || "${FAILOVER_MONITOR_HOSTNAME:-0}" == "1" ]]
}

_failover_ensure_write_probe_table() {
  mysql_cli -e "
    CREATE TABLE IF NOT EXISTS failover_write_probe (
      id INT NOT NULL PRIMARY KEY,
      heartbeat TIMESTAMP(6) NOT NULL
        DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6)
    ) ENGINE=InnoDB;" 2>/dev/null || true
}

_failover_write_probe_ok() {
  [[ "${FAILOVER_MONITOR_WRITE_PROBE:-1}" == "1" ]] || return 1
  mysql_cli -e "
    INSERT INTO failover_write_probe (id, heartbeat) VALUES (1, NOW(6))
    ON DUPLICATE KEY UPDATE heartbeat = NOW(6);" 2>/dev/null
}

# One mysql session per grid tick: write INSERT (optional) + topology SELECT.
# Sets monitor_connect_ok, monitor_write_ok, monitor_row, monitor_err.
_failover_monitor_poll_once() {
  local tmp_out line
  lines=()

  monitor_connect_ok=0
  monitor_write_ok=0
  monitor_row=""
  monitor_err="timeout_or_connect_failed"

  tmp_out=$(mktemp "${TMPDIR:-/tmp}/failover_monitor.XXXXXX")
  if [[ "${FAILOVER_MONITOR_WRITE_PROBE:-1}" == "1" ]]; then
    mysql_cli_timed -f -N -B > "${tmp_out}" 2>/dev/null <<'SQL' || true
INSERT INTO failover_write_probe (id, heartbeat) VALUES (1, NOW(6))
ON DUPLICATE KEY UPDATE heartbeat = NOW(6);
SELECT ROW_COUNT();
SELECT @@hostname,
       @@global.read_only,
       @@global.super_read_only,
       IFNULL((
         SELECT MEMBER_STATE
           FROM performance_schema.replication_group_members
          WHERE MEMBER_ID = @@server_uuid
          LIMIT 1
       ), 'N/A'),
       IFNULL((
         SELECT MEMBER_ROLE
           FROM performance_schema.replication_group_members
          WHERE MEMBER_ID = @@server_uuid
          LIMIT 1
       ), 'N/A');
SQL
  else
    mysql_cli_timed -N -B > "${tmp_out}" 2>/dev/null <<'SQL' || true
SELECT @@hostname,
       @@global.read_only,
       @@global.super_read_only,
       IFNULL((
         SELECT MEMBER_STATE
           FROM performance_schema.replication_group_members
          WHERE MEMBER_ID = @@server_uuid
          LIMIT 1
       ), 'N/A'),
       IFNULL((
         SELECT MEMBER_ROLE
           FROM performance_schema.replication_group_members
          WHERE MEMBER_ID = @@server_uuid
          LIMIT 1
       ), 'N/A');
SQL
  fi

  while IFS= read -r line || [[ -n "${line}" ]]; do
    lines+=("${line}")
  done < "${tmp_out}"
  rm -f "${tmp_out}"

  if [[ "${FAILOVER_MONITOR_WRITE_PROBE:-1}" == "1" ]]; then
    if ((${#lines[@]} >= 2)) && [[ "${lines[1]}" == *$'\t'* ]]; then
      monitor_row="${lines[1]}"
      monitor_connect_ok=1
      monitor_err=""
      if [[ "${lines[0]}" =~ ^-?[0-9]+$ ]] && ((lines[0] >= 0)); then
        monitor_write_ok=1
      fi
    elif ((${#lines[@]} >= 1)) && [[ "${lines[0]}" == *$'\t'* ]]; then
      monitor_row="${lines[0]}"
      monitor_connect_ok=1
      monitor_write_ok=0
      monitor_err=""
    fi
  elif ((${#lines[@]} >= 1)) && [[ "${lines[0]}" == *$'\t'* ]]; then
    monitor_row="${lines[0]}"
    monitor_connect_ok=1
    monitor_write_ok=0
    monitor_err=""
  fi
}

_failover_monitor_sleep_until() {
  local target_epoch="${1:?target epoch required}"
  python3 -c "
import time
target = float('${target_epoch}')
delay = target - time.time()
if delay > 0:
    time.sleep(delay)
"
}

_failover_monitor_append_row() {
  local out_file="${1:?out file required}"
  local ts="${2:?timestamp required}"
  local elapsed="${3:?elapsed required}"
  local connect_ok="${4:?connect ok required}"
  local row="${5:-}"
  local write_ok="${6:-0}"
  local err="${7:-}"

  if [[ "${connect_ok}" == "1" && "${row}" == *$'\t'* && "${row}" != *"ERROR"* ]]; then
    echo -e "${ts}\t${elapsed}\t1\t${row}\t${write_ok}\t${err}" >> "${out_file}"
  else
    err=${err:-${row//$'\t'/ }}
    err=${err//$'\n'/ }
    echo -e "${ts}\t${elapsed}\t0\tERROR\tERROR\tERROR\tERROR\tERROR\t${write_ok}\t${err}" >> "${out_file}"
  fi
}

_failover_monitor_emit_missed_tick() {
  local out_file="${1:?out file required}"
  local start_epoch="${2:?start epoch required}"
  local tick="${3:?tick required}"
  local interval="${4:?interval required}"
  local target_epoch elapsed ts

  target_epoch=$(python3 -c "print(float('${start_epoch}') + int('${tick}') * float('${interval}'))")
  elapsed=$(python3 -c "print('%.3f' % (float('${target_epoch}') - float('${start_epoch}')))")
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  _failover_monitor_append_row "${out_file}" "${ts}" "${elapsed}" 0 "" 0 "missed_tick"
}

start_primary_monitor() {
  local results_dir="${1:?results dir required}"
  local edition="${2:-unknown}"
  local pid_file="${results_dir}/primary_monitor.pid"
  local out_file="${results_dir}/primary_monitor.tsv"
  local meta_file="${results_dir}/primary_monitor_meta.txt"
  local interval="${FAILOVER_MONITOR_INTERVAL}"
  local connect_timeout="${FAILOVER_MONITOR_CONNECT_TIMEOUT}"
  local op_timeout="${FAILOVER_MONITOR_OP_TIMEOUT}"
  local start_epoch
  start_epoch=$(python3 -c "import time; print('%.3f' % time.time())")

  : > "${out_file}"
  echo -e "timestamp_utc\telapsed_sec\tconnect_ok\thostname\tread_only\tsuper_read_only\tgr_member_state\tgr_member_role\twrite_ok\tconnect_error" >> "${out_file}"
  {
    echo "MONITOR_START_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "MONITOR_START_EPOCH=${start_epoch}"
    echo "MONITOR_INTERVAL_SEC=${interval}"
    echo "MONITOR_SCHEDULE=fixed_interval"
    echo "MONITOR_SESSION=single_connection"
    echo "MONITOR_CONNECT_TIMEOUT_SEC=${connect_timeout}"
    echo "MONITOR_OP_TIMEOUT_SEC=${op_timeout}"
    echo "MONITOR_EDITION=${edition}"
  } > "${meta_file}"

  _failover_ensure_write_probe_table

  (
    local tick=0 target_epoch elapsed ts due_tick
    while true; do
      due_tick=$(python3 -c "
import math, time
start = float('${start_epoch}')
interval = float('${interval}')
print(int(math.floor((time.time() - start) / interval)))
")
      while (( tick < due_tick )); do
        _failover_monitor_emit_missed_tick "${out_file}" "${start_epoch}" "${tick}" "${interval}"
        tick=$((tick + 1))
      done

      target_epoch=$(python3 -c "print(float('${start_epoch}') + ${tick} * float('${interval}'))")
      _failover_monitor_sleep_until "${target_epoch}"

      elapsed=$(python3 -c "print('%.3f' % (float('${target_epoch}') - float('${start_epoch}')))")
      ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

      _failover_monitor_poll_once
      _failover_monitor_append_row "${out_file}" "${ts}" "${elapsed}" \
        "${monitor_connect_ok}" "${monitor_row}" "${monitor_write_ok}" "${monitor_err}"

      tick=$((tick + 1))
    done
  ) &

  echo $! > "${pid_file}"
  echo "Primary monitor started (pid=$(cat "${pid_file}"), fixed ${interval}s grid, single mysql session/tick, connect_timeout=${connect_timeout}s, op_timeout=${op_timeout}s)"
}

stop_primary_monitor() {
  local results_dir="${1:?results dir required}"
  local pid_file="${results_dir}/primary_monitor.pid"

  if [[ -f "${pid_file}" ]]; then
    local pid
    pid=$(cat "${pid_file}")
    if kill -0 "${pid}" 2>/dev/null; then
      kill "${pid}" 2>/dev/null || true
      wait "${pid}" 2>/dev/null || true
    fi
    rm -f "${pid_file}"
  fi
  if [[ -f "${results_dir}/primary_monitor_meta.txt" ]]; then
    echo "MONITOR_END_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "${results_dir}/primary_monitor_meta.txt"
  fi
}

_failover_snapshot_k8s_events() {
  local results_dir="${1:?results dir required}"
  local label="${2:?label required}"

  [[ "${FAILOVER_COLLECT_K8S_EVENTS:-1}" == "1" ]] || return 0
  command -v kubectl >/dev/null 2>&1 || return 0

  local kubeconfig="${results_dir}/kubeconfig"
  if [[ ! -f "${kubeconfig}" && -n "${ADVANCED_KUBECONFIG_PATH:-}" && -f "${ADVANCED_KUBECONFIG_PATH}" ]]; then
    kubeconfig="${ADVANCED_KUBECONFIG_PATH}"
  fi
  [[ -f "${kubeconfig}" ]] || return 0

  local ns="${ADVANCED_K8S_NAMESPACE:-percona}"
  local out_file="${results_dir}/k8s_events.log"
  local kubectl=(kubectl --kubeconfig="${kubeconfig}")
  [[ -n "${ADVANCED_K8S_CONTEXT:-}" ]] && kubectl+=(--context="${ADVANCED_K8S_CONTEXT}")

  {
    echo "=== K8s events snapshot: ${label} @ $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
    "${kubectl[@]}" get events -n "${ns}" --sort-by=.lastTimestamp 2>&1 || true
    echo ""
  } >> "${out_file}"
}

start_k8s_event_collector() {
  : # snapshots taken at trigger and post-observe via _failover_snapshot_k8s_events
}

stop_k8s_event_collector() {
  :
}

start_failover_watchers() {
  local results_dir="${1:?results dir required}"
  local edition="${2:?edition required}"

  if failover_monitor_enabled; then
    echo "--- Starting primary / topology monitor ---"
    start_primary_monitor "${results_dir}" "${edition}"
  fi
  if [[ "${edition}" == "advanced" ]]; then
    : > "${results_dir}/k8s_events.log"
  fi
}

stop_failover_watchers() {
  local results_dir="${1:?results dir required}"

  stop_k8s_event_collector "${results_dir}"
  if failover_monitor_enabled; then
    stop_primary_monitor "${results_dir}"
  fi
}

log_failover_do_events() {
  local results_dir="${1:?results dir required}"
  local edition="${2:?edition required}"
  local label="${3:-snapshot}"
  local uuid=""
  local token="${DIGITALOCEAN_TOKEN:-${DO_API_TOKEN:-}}"
  local out_file="${results_dir}/do_events.log"

  case "${edition}" in
    standard) uuid="${STANDARD_CLUSTER_UUID:-}" ;;
    advanced) uuid="${ADVANCED_CLUSTER_UUID:-}" ;;
  esac

  [[ -n "${uuid}" && -n "${token}" ]] || return 0

  {
    echo "=== DO database events: ${label} @ $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
    if command -v doctl >/dev/null 2>&1; then
      DIGITALOCEAN_ACCESS_TOKEN="${token}" doctl databases events list "${uuid}" 2>&1 || true
    else
      curl -sS -H "Authorization: Bearer ${token}" \
        "https://api.digitalocean.com/v2/databases/${uuid}/events" 2>&1 || true
    fi
    echo ""
  } >> "${out_file}"
}

run_tpcc_failover_load() {
  local results_dir="${1:?results dir required}"
  local log_file="${results_dir}/sysbench_run.log"
  local pid_file="${results_dir}/sysbench.pid"

  failover_defaults
  build_mysql_base_opts

  local tpcc total_time sysbench_time ignore_errors trx_profile scenario
  tpcc="$(tpcc_dir)"
  total_time=$(failover_total_runtime_sec)
  sysbench_time=$(failover_sysbench_time_sec)
  ignore_errors="${FAILOVER_MYSQL_IGNORE_ERRORS}"
  scenario="${FAILOVER_SCENARIO:-mixed}"
  trx_profile="${TPCC_TRX_PROFILE:-$(failover_scenario_trx_profile "${scenario}")}"

  export TPCC_THREADS="${FAILOVER_THREADS}"
  export TPCC_TIME="${sysbench_time}"
  export TPCC_WARMUP="${FAILOVER_WARMUP_SEC}"
  export TPCC_REPORT_INTERVAL="${FAILOVER_REPORT_INTERVAL}"

  echo "SYSBENCH_START_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${results_dir}/sysbench_timing.txt"
  echo "FAILOVER_EDITION=${FAILOVER_EDITION:-advanced}" >> "${results_dir}/sysbench_timing.txt"
  echo "FAILOVER_SCENARIO=${scenario}" >> "${results_dir}/sysbench_timing.txt"
  echo "TPCC_TRX_PROFILE=${trx_profile}" >> "${results_dir}/sysbench_timing.txt"
  echo "FAILOVER_TRIGGER_SECOND=$(failover_trigger_second)" >> "${results_dir}/sysbench_timing.txt"
  echo "FAILOVER_TOTAL_SEC=${total_time}" >> "${results_dir}/sysbench_timing.txt"
  echo "FAILOVER_MYSQL_IGNORE_ERRORS=${ignore_errors}" >> "${results_dir}/sysbench_timing.txt"
  echo "CLUSTER_SLUG=$(failover_cluster_slug "${FAILOVER_EDITION:-unknown}")" >> "${results_dir}/sysbench_timing.txt"
  echo "SLUG_SIZE=$(failover_cluster_slug "${FAILOVER_EDITION:-unknown}")" >> "${results_dir}/sysbench_timing.txt"
  echo "NUM_NODES=$(failover_cluster_num_nodes "${FAILOVER_EDITION:-unknown}")" >> "${results_dir}/sysbench_timing.txt"
  echo "DATA_SIZE=$(tpcc_approx_data_size_label)" >> "${results_dir}/sysbench_timing.txt"
  echo "THREADS=${FAILOVER_THREADS}" >> "${results_dir}/sysbench_timing.txt"
  echo "FAILOVER_THREADS=${FAILOVER_THREADS}" >> "${results_dir}/sysbench_timing.txt"
  echo "TPCC_SCALE=${TPCC_SCALE:-100}" >> "${results_dir}/sysbench_timing.txt"
  echo "TPCC_TABLES=${TPCC_TABLES:-10}" >> "${results_dir}/sysbench_timing.txt"
  echo "TPCC_THREADS=${PREP_THREADS:-16}" >> "${results_dir}/sysbench_timing.txt"
  echo "PREP_THREADS=${PREP_THREADS:-16}" >> "${results_dir}/sysbench_timing.txt"

  : > "${log_file}"

  local tables="${TPCC_TABLES:-10}"
  local scale="${TPCC_SCALE:-100}"
  local opts=(
    "${MYSQL_BASE_OPTS[@]}"
    "${MYSQL_SSL_OPTS[@]}"
    --tables="${tables}"
    --scale="${scale}"
    --threads="${FAILOVER_THREADS}"
    --trx_level="${TPCC_TRX_LEVEL:-RR}"
    --force_pk="${TPCC_FORCE_PK:-1}"
  )

  if tpcc_supports_trx_profile "${tpcc}"; then
    opts+=(--trx_profile="${trx_profile}")
  elif [[ "${trx_profile}" != "mixed" ]]; then
    echo "ERROR: --trx_profile=${trx_profile} not supported by ${tpcc}/tpcc.lua — update TPCC/sysbench-tpcc on this host" >&2
    return 1
  else
    echo "NOTE: omitting --trx_profile (not in tpcc.lua); using default TPC-C mixed workload"
  fi

  opts+=(
    --mysql-ignore-errors="${ignore_errors}"
    --db-ps-mode=disable
    --time="${sysbench_time}"
    --warmup-time="${FAILOVER_WARMUP_SEC}"
    --report-interval="${FAILOVER_REPORT_INTERVAL}"
  )

  echo "Sysbench failover opts: scenario=${scenario} trx_profile=${trx_profile} mysql-ignore-errors=${ignore_errors} db-ps-mode=disable"

  # Foreground load job (not a wrapper subshell) so $! is the sysbench driver process.
  export SYSBENCH_LINE_BUFFER=1
  run_sysbench_tpcc "${tpcc}" "${opts[@]}" run > >(_failover_tee_linebuffer "${log_file}") 2>&1 &
  local load_pid=$!
  unset SYSBENCH_LINE_BUFFER

  echo "${load_pid}" > "${pid_file}"
  echo "Sysbench TPC-C started (pid=${load_pid}, warmup=${FAILOVER_WARMUP_SEC}s time=${sysbench_time}s wall=${total_time}s, report-interval=${FAILOVER_REPORT_INTERVAL}s)"
}

stop_sysbench_load() {
  local results_dir="${1:?results dir required}"
  local pid_file="${results_dir}/sysbench.pid"

  if [[ -f "${pid_file}" ]]; then
    local pid
    pid=$(cat "${pid_file}")
    if kill -0 "${pid}" 2>/dev/null; then
      _failover_kill_process_tree "${pid}" INT
      local i
      for i in $(seq 1 30); do
        kill -0 "${pid}" 2>/dev/null || break
        sleep 1
      done
      _failover_kill_process_tree "${pid}" KILL
      wait "${pid}" 2>/dev/null || true
    fi
    rm -f "${pid_file}"
  fi
  echo "SYSBENCH_END_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "${results_dir}/sysbench_timing.txt"
}

wait_for_sysbench_start() {
  local results_dir="${1:?results dir required}"
  local log_file="${results_dir}/sysbench_run.log"
  local pid_file="${results_dir}/sysbench.pid"
  local timeout="${2:-120}"
  local i

  for i in $(seq 1 "${timeout}"); do
    if [[ -f "${pid_file}" ]]; then
      local pid
      pid=$(cat "${pid_file}")
      if ! kill -0 "${pid}" 2>/dev/null; then
        echo "ERROR: sysbench process (pid=${pid}) exited before load started — see ${log_file}" >&2
        return 1
      fi
    fi
    if [[ -f "${log_file}" ]] && grep -qE 'Threads started!|^\[[[:space:]]*[0-9]+s \]' "${log_file}"; then
      {
        echo "SYSBENCH_READY_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "SYSBENCH_READY_EPOCH=$(python3 -c "import time; print('%.3f' % time.time())")"
      } >> "${results_dir}/sysbench_timing.txt"
      return 0
    fi
    sleep 1
  done
  echo "ERROR: sysbench did not reach running state within ${timeout}s — see ${log_file}" >&2
  return 1
}

sleep_until_failover_trigger() {
  failover_defaults
  local delay="${FAILOVER_TRIGGER_DELAY_SEC:-$(failover_trigger_second)}"
  echo "Waiting ${delay}s before failover trigger (warmup=${FAILOVER_WARMUP_SEC}s + baseline=${FAILOVER_BASELINE_SEC}s)..."
  sleep "${delay}"
}

# Sleep until FAILOVER_TRIGGER_PREPARE_SEC before trigger second (kubeconfig already prepared).
sleep_until_failover_trigger_early() {
  failover_defaults
  local delay="${FAILOVER_TRIGGER_DELAY_SEC:-$(failover_trigger_second)}"
  local prep_sec="${FAILOVER_TRIGGER_PREPARE_SEC:-5}"
  local early=$((delay - prep_sec))
  (( early < 0 )) && early=0
  echo "Waiting ${early}s until final primary resolution (${prep_sec}s before pod delete at second ${delay})..."
  sleep "${early}"
}

# Short final wait after refresh; delete runs immediately when this returns.
sleep_until_failover_trigger_final_gap() {
  failover_defaults
  local prep_sec="${FAILOVER_TRIGGER_PREPARE_SEC:-5}"
  echo "Final ${prep_sec}s before instant pod delete (trigger second)..."
  sleep "${prep_sec}"
}

analyze_primary_change() {
  local monitor_file="${1:?monitor tsv required}"
  local trigger_utc="${2:-}"

  if [[ ! -f "${monitor_file}" ]]; then
    echo "PRIMARY_CHANGED=unknown"
    echo "PRIMARY_BEFORE=N/A"
    echo "PRIMARY_AFTER=N/A"
    return 1
  fi

  awk -F'\t' -v trigger="${trigger_utc}" '
    NR <= 1 { next }
    $3 != "1" { next }
    {
      host = $4
      ro = $5
      if (before == "" && (trigger == "" || $1 < trigger)) {
        before = host
        before_ro = ro
      }
      if (trigger != "" && $1 >= trigger) {
        after = host
        after_ro = ro
        if (trigger_elapsed == "" && $2 != "") trigger_elapsed = $2
      } else if (trigger == "") {
        after = host
        after_ro = ro
      }
      last = host
      last_ro = ro
    }
    END {
      if (before == "") before = "N/A"
      if (after == "") after = last
      changed = (before != "N/A" && after != "N/A" && before != after) ? "yes" : "no"
      printf "PRIMARY_BEFORE=%s\nPRIMARY_AFTER=%s\nPRIMARY_CHANGED=%s\n", before, after, changed
      if (before_ro != "") printf "PRIMARY_BEFORE_READ_ONLY=%s\n", before_ro
      if (after_ro != "") printf "PRIMARY_AFTER_READ_ONLY=%s\n", after_ro
    }
  ' "${monitor_file}"
}

# Export per-second TPS/QPS time series from sysbench log (for graphs and CSV analysis).
export_failover_timeseries() {
  local results_dir="${1:?results dir required}"
  local sysbench_log="${results_dir}/sysbench_run.log"
  local timing_file="${results_dir}/sysbench_timing.txt"
  local event_file="${results_dir}/failover_event.txt"
  local csv_file="${results_dir}/failover_timeseries.csv"
  local meta_file="${results_dir}/failover_timeseries_meta.txt"

  local trigger_second start_utc edition scenario trx_profile
  trigger_second=$(failover_trigger_second)
  start_utc=""
  edition="${FAILOVER_EDITION:-advanced}"
  scenario="mixed"
  trx_profile="mixed"

  if [[ -f "${timing_file}" ]]; then
    # shellcheck disable=SC1090
    source "${timing_file}" 2>/dev/null || true
    trigger_second="${FAILOVER_TRIGGER_SECOND:-${trigger_second}}"
    start_utc="${SYSBENCH_START_UTC:-}"
    edition="${FAILOVER_EDITION:-${edition}}"
    scenario="${FAILOVER_SCENARIO:-mixed}"
    trx_profile="${TPCC_TRX_PROFILE:-mixed}"
  fi
  if [[ -f "${event_file}" ]]; then
    edition=$(grep -E '^FAILOVER_EDITION=' "${event_file}" | tail -1 | cut -d= -f2- || echo "${edition}")
    [[ -z "${edition}" || "${edition}" == "unknown" ]] && edition="${FAILOVER_EDITION:-advanced}"
  fi

  {
    echo "SYSBENCH_START_UTC=${start_utc}"
    echo "FAILOVER_SCENARIO=${scenario:-mixed}"
    echo "TPCC_TRX_PROFILE=${trx_profile:-mixed}"
    echo "FAILOVER_TRIGGER_SECOND=${trigger_second}"
    echo "FAILOVER_EDITION=${edition}"
  } > "${meta_file}"

  if [[ -f "${results_dir}/sysbench_timing.txt" ]]; then
    grep -E '^(SLUG_SIZE|CLUSTER_SLUG|NUM_NODES|DATA_SIZE|THREADS|FAILOVER_THREADS|TPCC_SCALE|TPCC_TABLES|TPCC_THREADS|PREP_THREADS)=' \
      "${results_dir}/sysbench_timing.txt" >> "${meta_file}" 2>/dev/null || true
  elif [[ -f "${results_dir}/../benchmark_config.env" ]]; then
    grep -E '^(SLUG_SIZE|CLUSTER_SLUG|NUM_NODES|DATA_SIZE|THREADS|FAILOVER_THREADS|TPCC_SCALE|TPCC_TABLES|TPCC_THREADS|PREP_THREADS)=' \
      "${results_dir}/../benchmark_config.env" >> "${meta_file}" 2>/dev/null || true
  fi

  awk -v trigger="${trigger_second}" \
      -f - "${sysbench_log}" > "${csv_file}" <<'AWK'
function parse_line(line,    i, n, f, sec, tps, qps, err, reconn, lat95) {
  n = split(line, f, " ")
  if (f[1] !~ /^\[/ || f[2] !~ /^[0-9]+s$/) return 0
  sec = f[2]
  sub(/s$/, "", sec)
  sec += 0
  tps = 0; qps = 0; err = 0; reconn = 0; lat95 = 0
  for (i = 1; i <= n; i++) {
    if (f[i] == "tps:") tps = f[i + 1] + 0
    if (f[i] == "qps:") qps = f[i + 1] + 0
    if (f[i] == "err/s:" || f[i] == "err/s") err = f[i + 1] + 0
    if (f[i] == "reconn/s:") reconn = f[i + 1] + 0
    if (f[i] ~ /^lat/ && f[i + 1] ~ /\(ms,95%\):/) lat95 = f[i + 2] + 0
  }
  tps_arr[sec] = tps
  qps_arr[sec] = qps
  err_arr[sec] = err
  reconn_arr[sec] = reconn
  lat_arr[sec] = lat95
  if (sec > max_sec) max_sec = sec
  return 1
}
BEGIN {
  max_sec = 0
  print "elapsed_sec,seconds_from_trigger,tps,qps,err_per_sec,reconn_per_sec,lat_p95_ms"
}
{
  parse_line($0)
}
END {
  for (sec = 1; sec <= max_sec; sec++) {
    if (!(sec in tps_arr)) continue
    printf "%d,%d,%.2f,%.2f,%.2f,%.2f,%.2f\n", \
      sec, sec - trigger, tps_arr[sec], qps_arr[sec], err_arr[sec], reconn_arr[sec], lat_arr[sec]
  }
}
AWK

  echo "Time series CSV: ${csv_file} ($(tail -n +2 "${csv_file}" | wc -l | tr -d ' ') rows)"
}

generate_failover_graphs() {
  local target="${1:?path required}"
  local py_script="${BENCH_ROOT}/scripts/generate_failover_graphs.py"

  if [[ "${FAILOVER_GENERATE_GRAPHS:-1}" != "1" ]]; then
    echo "Graph generation skipped (FAILOVER_GENERATE_GRAPHS=0)"
    return 0
  fi

  if [[ ! -f "${py_script}" ]]; then
    echo "WARNING: ${py_script} not found — skipping graphs" >&2
    return 0
  fi

  if ! python3 -c "import matplotlib" 2>/dev/null; then
    echo "NOTE: matplotlib not installed — HTML report only (no PNG)." >&2
    echo "  PNG:  sudo apt-get install -y python3-matplotlib  OR  pip3 install matplotlib" >&2
  fi

  python3 "${py_script}" "${target}"
}

# Portable parser for sysbench --report-interval lines (no gawk match() arrays).
_failover_parse_sysbench_intervals() {
  local sysbench_log="${1:?log required}"
  local trigger="${2:?trigger second required}"
  local recovery="${3:-0.90}"
  local stable="${4:-30}"
  local outage_ratio="${5:-0.05}"
  local observe_sec="${6:-600}"

  awk -v trigger="${trigger}" \
      -v recovery="${recovery}" \
      -v stable="${stable}" \
      -v outage_ratio="${outage_ratio}" \
      -v observe_sec="${observe_sec}" \
      -f - "${sysbench_log}" <<'AWK'
function parse_interval_line(line,    i, sec, tps, qps, err, reconn, lat95, n) {
  n = split(line, f, " ")
  if (f[1] !~ /^\[/ || f[2] !~ /^[0-9]+s$/) return 0
  sec = f[2]
  sub(/s$/, "", sec)
  sec += 0
  tps = 0; qps = 0; err = 0; reconn = 0; lat95 = 0
  for (i = 1; i <= n; i++) {
    if (f[i] == "tps:") tps = f[i + 1] + 0
    if (f[i] == "qps:") qps = f[i + 1] + 0
    if (f[i] == "err/s:" || f[i] == "err/s") err = f[i + 1] + 0
    if (f[i] == "reconn/s:") reconn = f[i + 1] + 0
    if (f[i] ~ /^lat/ && f[i + 1] ~ /\(ms,95%\):/) lat95 = f[i + 2] + 0
  }
  tps_arr[sec] = tps
  qps_arr[sec] = qps
  err_arr[sec] = err
  reconn_arr[sec] = reconn
  lat_arr[sec] = lat95
  if (sec < trigger && err == 0 && tps > 0) {
    baseline_tps_sum += tps
    baseline_tps_count++
    baseline_qps_sum += qps
    baseline_qps_count++
    if (lat95 > 0) {
      baseline_lat_sum += lat95
      baseline_lat_count++
    }
  }
  return 1
}
BEGIN {
  baseline_tps_sum = 0
  baseline_tps_count = 0
  baseline_qps_sum = 0
  baseline_qps_count = 0
  baseline_lat_sum = 0
  baseline_lat_count = 0
}
{
  parse_interval_line($0)
}
END {
  if (baseline_tps_count == 0) {
    print "ERROR: no baseline data before trigger second " trigger > "/dev/stderr"
    exit 1
  }
  baseline_tps = baseline_tps_sum / baseline_tps_count
  baseline_qps = (baseline_qps_count > 0) ? baseline_qps_sum / baseline_qps_count : 0
  baseline_lat_p95 = (baseline_lat_count > 0) ? baseline_lat_sum / baseline_lat_count : 0
  post_trigger_end = trigger + observe_sec

  outage_start = -1
  outage_end = -1
  max_err = 0
  max_reconn = 0
  max_lat = 0
  total_errors = 0

  for (sec = trigger; sec <= post_trigger_end; sec++) {
    if (!(sec in tps_arr)) continue
    total_errors += err_arr[sec]
    if (err_arr[sec] > max_err) max_err = err_arr[sec]
    if (reconn_arr[sec] > max_reconn) max_reconn = reconn_arr[sec]
    if (lat_arr[sec] > max_lat) max_lat = lat_arr[sec]
    is_outage = (tps_arr[sec] < baseline_tps * outage_ratio) || (err_arr[sec] > 0)
    if (is_outage && outage_start < 0) outage_start = sec
    if (is_outage) outage_end = sec
  }

  if (outage_start < 0) {
    for (sec = trigger; sec <= post_trigger_end; sec++) {
      if (!(sec in tps_arr)) continue
      if (err_arr[sec] > 0 || reconn_arr[sec] > 0) {
        outage_start = sec
        outage_end = sec
        break
      }
    }
  }
  if (outage_start < 0) {
    outage_start = trigger
    outage_end = trigger
    outage_duration = 0
  } else {
    outage_duration = outage_end - outage_start + 1
  }

  recovery_threshold_tps = baseline_tps * recovery
  rto_sec = -1
  stable_count = 0
  for (sec = trigger; sec <= post_trigger_end; sec++) {
    if (!(sec in tps_arr)) continue
    if (tps_arr[sec] >= recovery_threshold_tps) {
      stable_count++
      if (stable_count >= stable && rto_sec < 0) {
        rto_sec = sec - trigger - stable + 2
        if (rto_sec < 0) rto_sec = 0
      }
    } else {
      stable_count = 0
    }
  }

  printf "BASELINE_TPS=%.2f\n", baseline_tps
  printf "BASELINE_QPS=%.2f\n", baseline_qps
  printf "BASELINE_LAT_P95_MS=%.2f\n", baseline_lat_p95
  printf "OUTAGE_START=%d\n", outage_start
  printf "OUTAGE_END=%d\n", outage_end
  printf "OUTAGE_DURATION=%d\n", outage_duration
  printf "RTO_SEC=%d\n", rto_sec
  printf "PEAK_ERR=%.2f\n", max_err
  printf "PEAK_RECONN=%.2f\n", max_reconn
  printf "PEAK_LAT95=%.2f\n", max_lat
  printf "TOTAL_ERR_SUM=%.0f\n", total_errors
  printf "RECOVERY_THRESHOLD=%.2f\n", recovery_threshold_tps
}
AWK
}

# Parse sysbench interval lines and compute failover metrics.
analyze_failover_metrics() {
  local results_dir="${1:?results dir required}"
  local sysbench_log="${results_dir}/sysbench_run.log"
  local event_file="${results_dir}/failover_event.txt"
  local timing_file="${results_dir}/sysbench_timing.txt"
  local analysis_file="${results_dir}/failover_analysis.txt"
  local csv_file="${results_dir}/failover_metrics.csv"
  local parsed_file="${results_dir}/failover_parsed.env"

  failover_defaults

  local trigger_second scenario trx_profile
  trigger_second=$(failover_trigger_second)
  scenario="mixed"
  trx_profile="mixed"
  if [[ -f "${timing_file}" ]]; then
    # shellcheck disable=SC1090
    source "${timing_file}" 2>/dev/null || true
    trigger_second="${FAILOVER_TRIGGER_SECOND:-${trigger_second}}"
    scenario="${FAILOVER_SCENARIO:-mixed}"
    trx_profile="${TPCC_TRX_PROFILE:-mixed}"
  fi

  local trigger_utc=""
  local edition="unknown"
  local method="unknown"
  if [[ -f "${event_file}" ]]; then
    trigger_utc=$(grep -E '^FAILOVER_TRIGGER_UTC=' "${event_file}" | tail -1 | cut -d= -f2- || true)
    edition=$(grep -E '^FAILOVER_EDITION=' "${event_file}" | tail -1 | cut -d= -f2- || echo "unknown")
    method=$(grep -E '^FAILOVER_METHOD=' "${event_file}" | tail -1 | cut -d= -f2- || echo "unknown")
  fi

  if [[ ! -f "${sysbench_log}" ]]; then
    echo "ERROR: missing sysbench log: ${sysbench_log}" >&2
    return 1
  fi

  _failover_parse_sysbench_intervals "${sysbench_log}" "${trigger_second}" \
    "${FAILOVER_RECOVERY_THRESHOLD}" "${FAILOVER_RECOVERY_STABLE_SEC}" \
    "${FAILOVER_OUTAGE_TPS_RATIO}" "${FAILOVER_OBSERVE_SEC}" > "${parsed_file}"

  # shellcheck disable=SC1090
  source "${parsed_file}"

  export_failover_timeseries "${results_dir}"

  {
    echo "=== Failover Benchmark Analysis ==="
    echo "Edition:              ${edition}"
    echo "Scenario:             ${scenario}"
    echo "TPC-C trx profile:    ${trx_profile}"
    echo "Trigger method:       ${method}"
    echo "Trigger UTC:          ${trigger_utc:-N/A}"
    echo "Trigger second:       ${trigger_second} (from sysbench start)"
    echo ""
    echo "--- Throughput ---"
    printf "Baseline TPS (avg):   %.2f\n" "${BASELINE_TPS}"
    printf "Baseline QPS (avg):   %.2f\n" "${BASELINE_QPS:-0}"
    printf "Baseline p95 lat (avg): %.2f ms\n" "${BASELINE_LAT_P95_MS:-0}"
    printf "Recovery threshold:   %.2f (%.0f%% of baseline)\n" \
      "${RECOVERY_THRESHOLD}" "$(awk "BEGIN {print ${FAILOVER_RECOVERY_THRESHOLD} * 100}")"
    echo ""
    echo "--- Outage ---"
    echo "Outage start (sec):   ${OUTAGE_START}"
    echo "Outage end (sec):     ${OUTAGE_END}"
    echo "Outage duration (s):  ${OUTAGE_DURATION}"
    echo ""
    echo "--- Recovery ---"
    if [[ "${RTO_SEC}" -ge 0 ]]; then
      echo "RTO to $(awk "BEGIN {print ${FAILOVER_RECOVERY_THRESHOLD} * 100}")% baseline (${FAILOVER_RECOVERY_STABLE_SEC}s stable): ${RTO_SEC}s"
    else
      echo "RTO:                  NOT_REACHED (within observe window)"
    fi
    echo ""
    echo "--- Errors & latency ---"
    printf "Total err/s (sum):    %.0f\n" "${TOTAL_ERR_SUM}"
    printf "Peak err/s:           %.2f\n" "${PEAK_ERR}"
    printf "Peak reconn/s:        %.2f\n" "${PEAK_RECONN}"
    printf "Peak lat p95 (ms):    %.2f\n" "${PEAK_LAT95}"
    echo ""
    echo "--- Time series ---"
    echo "Full per-second TPS/QPS CSV: ${results_dir}/failover_timeseries.csv"
    echo "Graphs (if generated):       ${results_dir}/graphs/"
    echo "HTML report:                 ${results_dir}/graphs/failover_report.html"
  } | tee "${analysis_file}"

  local header="edition,scenario,trx_profile,trigger_method,trigger_utc,baseline_tps,outage_start_sec,outage_duration_sec,rto_sec,peak_err_per_sec,peak_reconn_per_sec,peak_lat_p95_ms"
  echo "${header}" > "${csv_file}"
  echo "${edition},${scenario},${trx_profile},${method},${trigger_utc},${BASELINE_TPS},${OUTAGE_START},${OUTAGE_DURATION},${RTO_SEC},${PEAK_ERR},${PEAK_RECONN},${PEAK_LAT95}" \
    >> "${csv_file}"

  generate_failover_graphs "${results_dir}"

  write_failover_extended_metrics "${results_dir}"
  write_failover_kpi "${results_dir}"

  echo "Analysis written: ${analysis_file}"
  echo "Metrics CSV:      ${csv_file}"
  echo "KPI CSV:          ${results_dir}/failover_kpi.csv"
  echo "Extended metrics: ${results_dir}/failover_extended_metrics.txt"
}

# Seven core failover KPIs — absolute seconds from trigger (see benchmark.conf.example).
write_failover_kpi() {
  local results_dir="${1:?results dir required}"
  local kpi_csv="${results_dir}/failover_kpi.csv"
  local timeseries="${results_dir}/failover_timeseries.csv"
  local monitor="${results_dir}/primary_monitor.tsv"
  local event_file="${results_dir}/failover_event.txt"
  local check_result="${results_dir}/tpcc_check_result.env"
  local sysbench_log="${results_dir}/sysbench_run.log"
  local timing_file="${results_dir}/sysbench_timing.txt"

  failover_defaults

  local trigger_second edition trigger_utc scenario trx_profile
  trigger_second=$(failover_trigger_second)
  edition="unknown"
  trigger_utc=""
  scenario="mixed"
  trx_profile="mixed"

  if [[ -f "${timing_file}" ]]; then
    # shellcheck disable=SC1090
    source "${timing_file}" 2>/dev/null || true
    trigger_second="${FAILOVER_TRIGGER_SECOND:-${trigger_second}}"
    scenario="${FAILOVER_SCENARIO:-mixed}"
    trx_profile="${TPCC_TRX_PROFILE:-mixed}"
  fi
  if [[ -f "${event_file}" ]]; then
    edition=$(grep -E '^FAILOVER_EDITION=' "${event_file}" | tail -1 | cut -d= -f2- || echo "unknown")
    trigger_utc=$(grep -E '^FAILOVER_TRIGGER_UTC=' "${event_file}" | tail -1 | cut -d= -f2- || true)
  fi

  local monitor_offset=0
  if [[ -f "${results_dir}/primary_monitor_meta.txt" && -f "${timing_file}" ]]; then
    local monitor_start sysbench_ready
    monitor_start=$(grep -E '^MONITOR_START_EPOCH=' "${results_dir}/primary_monitor_meta.txt" | cut -d= -f2- || true)
    sysbench_ready=$(grep -E '^SYSBENCH_READY_EPOCH=' "${timing_file}" | cut -d= -f2- || true)
    if [[ -n "${monitor_start}" && -n "${sysbench_ready}" ]]; then
      monitor_offset=$(python3 -c "print('%.3f' % (float('${sysbench_ready}') - float('${monitor_start}')))")
    fi
  fi

  local primary_before="N/A"
  if [[ -f "${monitor}" ]]; then
    primary_before=$(analyze_primary_change "${monitor}" "${trigger_utc}" 2>/dev/null \
      | grep '^PRIMARY_BEFORE=' | cut -d= -f2- || echo "N/A")
  fi

  local tpcc_check="SKIPPED"
  [[ -f "${check_result}" ]] && tpcc_check=$(grep TPCC_CHECK_RESULT "${check_result}" | cut -d= -f2-)

  local sysbench_max_lat=""
  if [[ -f "${sysbench_log}" ]]; then
    sysbench_max_lat=$(grep -E '^[[:space:]]+max:' "${sysbench_log}" | tail -1 | awk '{print $2}' || true)
  fi

  if [[ ! -f "${timeseries}" ]]; then
    echo "WARNING: missing ${timeseries} — skipping failover_kpi.csv" >&2
    return 1
  fi

  awk -v trigger="${trigger_second}" \
      -v edition="${edition}" \
      -v scenario="${scenario}" \
      -v trx_profile="${trx_profile}" \
      -v recovery_pct="${FAILOVER_RECOVERY_THRESHOLD}" \
      -v stable="${FAILOVER_RECOVERY_STABLE_SEC}" \
      -v outage_ratio="${FAILOVER_OUTAGE_TPS_RATIO}" \
      -v observe_sec="${FAILOVER_OBSERVE_SEC}" \
      -v monitor="${monitor}" \
      -v monitor_offset="${monitor_offset}" \
      -v primary_before="${primary_before}" \
      -v tpcc_check="${tpcc_check}" \
      -v sysbench_max_lat="${sysbench_max_lat}" \
      -v tsfile="${timeseries}" \
      -f - > "${kpi_csv}" <<'AWK'
function load_timeseries(    line, f, sec) {
  while ((getline line < tsfile) > 0) {
    split(line, f, ",")
    if (f[1] == "elapsed_sec") continue
    sec = f[1] + 0
    tps_arr[sec] = f[3] + 0
    qps_arr[sec] = f[4] + 0
    err_arr[sec] = f[5] + 0
    reconn_arr[sec] = f[6] + 0
    lat_arr[sec] = f[7] + 0
    if (sec > load_end) load_end = sec
    if (sec < trigger && tps_arr[sec] > 0) {
      pre_tps_sum += tps_arr[sec]
      pre_tps_cnt++
    }
    if (sec < trigger && qps_arr[sec] > 0) {
      pre_qps_sum += qps_arr[sec]
      pre_qps_cnt++
    }
    if (sec < trigger) {
      pre_err_sum += err_arr[sec]
      pre_reconn_sum += reconn_arr[sec]
      pre_err_cnt++
    }
  }
  close(tsfile)
  if (pre_tps_cnt > 0) baseline_tps = pre_tps_sum / pre_tps_cnt
  if (pre_qps_cnt > 0) baseline_qps = pre_qps_sum / pre_qps_cnt
  tps_thresh = baseline_tps * recovery_pct
  qps_thresh = baseline_qps * recovery_pct
  outage_tps = baseline_tps * outage_ratio
  outage_qps = baseline_qps * outage_ratio
  observe_end = trigger + observe_sec
  if (load_end > observe_end) observe_end = load_end
}
function detect_connect_failure_ttd(    sysbench_sec) {
  if (monitor == "" || ( (getline _ < monitor) <= 0 )) return -1
  close(monitor)
  while ((getline line < monitor) > 0) {
    split(line, f, "\t")
    if (f[1] == "timestamp_utc") continue
    sysbench_sec = (f[2] + 0) - monitor_offset
    if (sysbench_sec < trigger) continue
    if (f[3] != "1") return sysbench_sec - trigger
  }
  close(monitor)
  return -1
}
function count_write_probe_failures(recovery_rel, election_rel,    sysbench_sec, wo, end_abs, count) {
  count = 0
  end_abs = observe_end
  if (recovery_rel >= 0) end_abs = trigger + recovery_rel
  if (election_rel >= 0 && trigger + election_rel > end_abs)
    end_abs = trigger + election_rel
  if (monitor == "" || ( (getline _ < monitor) <= 0 )) return 0
  close(monitor)
  while ((getline line < monitor) > 0) {
    split(line, f, "\t")
    if (f[1] == "timestamp_utc") continue
    sysbench_sec = (f[2] + 0) - monitor_offset
    if (sysbench_sec < trigger || sysbench_sec > end_abs) continue
    if (f[3] != "1") continue
    wo = monitor_write_ok(f)
    if (wo == 0) count++
  }
  close(monitor)
  return count
}
function monitor_gr_state(f) { return f[7] }
function monitor_gr_role(f) {
  if (length(f) >= 9 && f[8] != "" && f[8] != "ERROR") return f[8]
  return ""
}
function monitor_write_ok(f) {
  if (length(f) >= 10 && f[9] != "" && f[9] != "ERROR") return f[9] + 0
  return -1
}
function monitor_is_new_format(f) {
  role = monitor_gr_role(f)
  return (role == "PRIMARY" || role == "SECONDARY" || role == "ONLINE" || role == "OFFLINE")
}
function is_primary_elected(f,    wo, role, gr) {
  if (f[3] != "1") return 0
  wo = monitor_write_ok(f)
  if (wo != 1) return 0
  role = monitor_gr_role(f)
  gr = monitor_gr_state(f)
  if (edition == "advanced") {
    return (role == "PRIMARY" && (gr == "ONLINE" || gr == "PRIMARY"))
  }
  return 1
}
function detect_primary_election_from_monitor(    sysbench_sec, saw_connect_fail) {
  if (monitor == "" || ( (getline _ < monitor) <= 0 )) return -1
  close(monitor)
  saw_connect_fail = 0
  while ((getline line < monitor) > 0) {
    split(line, f, "\t")
    if (f[1] == "timestamp_utc") continue
    sysbench_sec = (f[2] + 0) - monitor_offset
    if (sysbench_sec < trigger) continue
    if (!saw_connect_fail) {
      if (f[3] != "1") saw_connect_fail = 1
      else continue
    }
    if (is_primary_elected(f))
      return sysbench_sec - trigger
  }
  close(monitor)
  return -1
}
function detect_app_recovery_rto(    sec, stable_count, rto) {
  stable_count = 0
  rto = -1
  for (sec = trigger; sec <= observe_end; sec++) {
    if (!(sec in tps_arr)) continue
    if (baseline_tps > 0 && tps_arr[sec] >= tps_thresh) {
      stable_count++
      if (stable_count >= stable && rto < 0) {
        rto = sec - trigger - stable + 2
        if (rto < 0) rto = 0
      }
    } else {
      stable_count = 0
    }
  }
  return rto
}
function dip_duration(failure_rel, recovery_rel,    sec, start, end, count) {
  count = 0
  start = trigger + (failure_rel >= 0 ? failure_rel : 0)
  end = observe_end
  if (recovery_rel >= 0) end = trigger + recovery_rel - 1
  for (sec = start; sec <= end; sec++) {
    if (!(sec in tps_arr)) continue
    if (baseline_tps > 0 && tps_arr[sec] < tps_thresh) count++
  }
  return count
}
function peak_latency(failure_rel, recovery_rel,    sec, start, end, peak) {
  peak = 0
  start = trigger + (failure_rel >= 0 ? failure_rel : 0)
  end = observe_end
  if (recovery_rel >= 0) {
    end = trigger + recovery_rel + stable
    if (end > observe_end) end = observe_end
  }
  for (sec = start; sec <= end; sec++) {
    if (!(sec in lat_arr)) continue
    if (lat_arr[sec] > peak) peak = lat_arr[sec]
  }
  if (peak > 0) return peak
  if (sysbench_max_lat != "" && sysbench_max_lat + 0 > 0) return sysbench_max_lat + 0
  return -1
}
function failover_errors_in_window(fail_rel, recovery_rel,    sec, start, end, sum, peak, excess_err, excess_reconn, baseline_err, baseline_reconn) {
  baseline_err = 0
  baseline_reconn = 0
  if (pre_err_cnt > 0) {
    baseline_err = pre_err_sum / pre_err_cnt
    baseline_reconn = pre_reconn_sum / pre_err_cnt
  }
  sum = 0
  peak = 0
  start = trigger + (fail_rel >= 0 ? fail_rel : 0)
  end = observe_end
  if (recovery_rel >= 0) end = trigger + recovery_rel
  for (sec = start; sec <= end; sec++) {
    excess_err = 0
    excess_reconn = 0
    if (sec in err_arr) {
      excess_err = err_arr[sec] - baseline_err
      if (excess_err < 0) excess_err = 0
      sum += excess_err
      if (excess_err > peak) peak = excess_err
    }
    if (sec in reconn_arr) {
      excess_reconn = reconn_arr[sec] - baseline_reconn
      if (excess_reconn < 0) excess_reconn = 0
      sum += excess_reconn
    }
  }
  peak_err_window = peak
  return int(sum + 0.5)
}
function fmt_sec(v) {
  if (v < 0) return "NOT_DETECTED"
  if (v < 1) return sprintf("%.3f", v)
  if (v == int(v)) return sprintf("%d", v)
  return sprintf("%.2f", v)
}
function fmt_phase_duration(v) {
  if (v < 0) return "NOT_REACHED"
  if (v < 1) return sprintf("%.3f", v)
  if (v == int(v)) return sprintf("%d", v)
  return sprintf("%.2f", v)
}
function phase_duration(end_rel, start_rel) {
  if (end_rel < 0 || start_rel < 0) return -1
  if (end_rel < start_rel) return -1
  return end_rel - start_rel
}
function fmt_lat(v) {
  if (v < 0) return "N/A"
  return sprintf("%.2f", v)
}
END {
  load_timeseries()
  failure_sec = detect_connect_failure_ttd()
  promote_total_sec = detect_primary_election_from_monitor()
  election_sec = phase_duration(promote_total_sec, failure_sec)
  recovery_sec = detect_app_recovery_rto()
  dip_sec = dip_duration(failure_sec, recovery_sec)
  peak_lat = peak_latency(failure_sec, recovery_sec)
  peak_err_window = 0
  tx_failed = failover_errors_in_window(failure_sec, recovery_sec)
  writes_failed = count_write_probe_failures(recovery_sec, promote_total_sec)

  print "edition,scenario,trx_profile,failure_detection_sec,primary_election_sec,total_failover_sec,app_recovery_sec,tps_dip_duration_sec,peak_latency_failover_ms,transactions_failed_during_failover,writes_failed_during_failover,peak_write_err_per_sec,data_loss"
  printf "%s,%s,%s,%s,%s,%s,%s,%d,%s,%d,%d,%.2f,%s\n", \
    edition, scenario, trx_profile, \
    fmt_sec(failure_sec), fmt_sec(election_sec), fmt_sec(promote_total_sec), fmt_sec(recovery_sec), \
    dip_sec, fmt_lat(peak_lat), tx_failed, writes_failed, peak_err_window, tpcc_check
}
AWK

  echo "KPI CSV: ${kpi_csv}"
}

run_failover_tpcc_check() {
  local results_dir="${1:?results dir required}"
  local check_log="${results_dir}/tpcc_check.log"

  failover_defaults
  [[ "${FAILOVER_RUN_TPCC_CHECK:-0}" == "1" ]] || return 0

  echo "--- Running TPC-C consistency check (FAILOVER_RUN_TPCC_CHECK=1) ---"
  export TPCC_THREADS="${FAILOVER_THREADS}"
  if run_tpcc_command check > "${check_log}" 2>&1; then
    echo "TPCC_CHECK_RESULT=PASSED" > "${results_dir}/tpcc_check_result.env"
    echo "TPC-C check: PASSED"
    return 0
  fi
  echo "TPCC_CHECK_RESULT=FAILED" > "${results_dir}/tpcc_check_result.env"
  echo "TPC-C check: FAILED — see ${check_log}"
  return 1
}

write_failover_extended_metrics() {
  local results_dir="${1:?results dir required}"
  local out_file="${results_dir}/failover_extended_metrics.txt"
  local timeseries="${results_dir}/failover_timeseries.csv"
  local monitor="${results_dir}/primary_monitor.tsv"
  local event_file="${results_dir}/failover_event.txt"
  local parsed_file="${results_dir}/failover_parsed.env"
  local check_result="${results_dir}/tpcc_check_result.env"
  local k8s_log="${results_dir}/k8s_events.log"
  local do_log="${results_dir}/do_events.log"
  local trigger_log="${results_dir}/failover_trigger.log"
  local sysbench_log="${results_dir}/sysbench_run.log"

  failover_defaults

  local trigger_second trigger_utc edition method target_pod scenario trx_profile
  trigger_second=$(failover_trigger_second)
  trigger_utc=""
  edition="unknown"
  method="unknown"
  target_pod=""
  scenario="mixed"
  trx_profile="mixed"

  if [[ -f "${results_dir}/sysbench_timing.txt" ]]; then
    # shellcheck disable=SC1090
    source "${results_dir}/sysbench_timing.txt" 2>/dev/null || true
    trigger_second="${FAILOVER_TRIGGER_SECOND:-${trigger_second}}"
    scenario="${FAILOVER_SCENARIO:-mixed}"
    trx_profile="${TPCC_TRX_PROFILE:-mixed}"
  fi
  if [[ -f "${event_file}" ]]; then
    trigger_utc=$(grep -E '^FAILOVER_TRIGGER_UTC=' "${event_file}" | tail -1 | cut -d= -f2- || true)
    edition=$(grep -E '^FAILOVER_EDITION=' "${event_file}" | tail -1 | cut -d= -f2- || echo "unknown")
    method=$(grep -E '^FAILOVER_METHOD=' "${event_file}" | tail -1 | cut -d= -f2- || echo "unknown")
    target_pod=$(grep -E '^FAILOVER_TARGET_POD=' "${event_file}" | tail -1 | cut -d= -f2- || true)
  fi

  local primary_env="${results_dir}/primary_change.env"
  if [[ -f "${monitor}" ]]; then
    analyze_primary_change "${monitor}" "${trigger_utc}" > "${primary_env}" 2>/dev/null || true
  fi

  local tpcc_check="SKIPPED"
  [[ -f "${check_result}" ]] && tpcc_check=$(grep TPCC_CHECK_RESULT "${check_result}" | cut -d= -f2-)

  local parsed_env=""
  [[ -f "${parsed_file}" ]] && parsed_env="${parsed_file}"

  local generated_utc
  generated_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  local monitor_offset=0
  local primary_before="N/A" primary_after="N/A" primary_changed="unknown"
  if [[ -f "${primary_env}" ]]; then
    # shellcheck disable=SC1090
    source "${primary_env}" 2>/dev/null || true
    primary_before="${PRIMARY_BEFORE:-N/A}"
    primary_after="${PRIMARY_AFTER:-N/A}"
    primary_changed="${PRIMARY_CHANGED:-unknown}"
  fi
  if [[ -f "${results_dir}/primary_monitor_meta.txt" && -f "${results_dir}/sysbench_timing.txt" ]]; then
    local monitor_start sysbench_ready
    monitor_start=$(grep -E '^MONITOR_START_EPOCH=' "${results_dir}/primary_monitor_meta.txt" | cut -d= -f2- || true)
    sysbench_ready=$(grep -E '^SYSBENCH_READY_EPOCH=' "${results_dir}/sysbench_timing.txt" | cut -d= -f2- || true)
    if [[ -n "${monitor_start}" && -n "${sysbench_ready}" ]]; then
      monitor_offset=$(python3 -c "print('%.3f' % (float('${sysbench_ready}') - float('${monitor_start}')))")
    fi
  fi

  awk -v trigger="${trigger_second}" \
      -v trigger_utc="${trigger_utc}" \
      -v edition="${edition}" \
      -v scenario="${scenario}" \
      -v trx_profile="${trx_profile}" \
      -v method="${method}" \
      -v target_pod="${target_pod}" \
      -v tpcc_check="${tpcc_check}" \
      -v recovery_pct="${FAILOVER_RECOVERY_THRESHOLD}" \
      -v stable="${FAILOVER_RECOVERY_STABLE_SEC}" \
      -v outage_ratio="${FAILOVER_OUTAGE_TPS_RATIO}" \
      -v parsed_env="${parsed_env}" \
      -v monitor="${monitor}" \
      -v monitor_offset="${monitor_offset}" \
      -v primary_before="${primary_before}" \
      -v primary_after="${primary_after}" \
      -v primary_changed="${primary_changed}" \
      -v timeseries="${timeseries}" \
      -v k8s_log="${k8s_log}" \
      -v do_log="${do_log}" \
      -v trigger_log="${trigger_log}" \
      -v sysbench_log="${sysbench_log}" \
      -v generated_utc="${generated_utc}" \
      -f - > "${out_file}" <<'AWK'
BEGIN {
  failure_detect = -1
  failure_detect_abs = -1
  promote_sec = -1
  rto = -1
  load_end_sec = 0
  baseline = 0
  baseline_qps = 0
  recovery_threshold = 0
  outage_start = 0
  outage_end = 0
  outage_duration = 0
  min_tps_post = 0
  min_qps_post = 0
  max_lat_post = 0
  peak_err_post = 0
  peak_reconn_post = 0
  below_recovery = 0
  pre_sum = 0
  pre_cnt = 0
  pre_qps_sum = 0
  pre_qps_cnt = 0
  pre_err_sum = 0
  pre_reconn_sum = 0
  pre_err_cnt = 0
  monitor_offset = monitor_offset + 0
  if (parsed_env != "") {
    while ((getline line < parsed_env) > 0) {
      split(line, kv, "=")
      key = kv[1]
      val = substr(line, index(line, "=") + 1)
      if (key == "BASELINE_TPS") baseline = val + 0
      if (key == "OUTAGE_START") outage_start = val + 0
      if (key == "OUTAGE_END") outage_end = val + 0
      if (key == "OUTAGE_DURATION") outage_duration = val + 0
      if (key == "RTO_SEC") rto = val + 0
      if (key == "PEAK_ERR") peak_err = val + 0
      if (key == "PEAK_RECONN") peak_reconn = val + 0
      if (key == "PEAK_LAT95") peak_lat = val + 0
      if (key == "RECOVERY_THRESHOLD") recovery_threshold = val + 0
    }
    close(parsed_env)
  }
  if (recovery_threshold == 0 && baseline > 0) recovery_threshold = baseline * recovery_pct
}
function load_timeseries(    f, sec, tps, qps, err, reconn, lat, max_sec) {
  if (timeseries == "" || ( (getline _ < timeseries) <= 0 )) return
  close(timeseries)
  while ((getline line < timeseries) > 0) {
    split(line, f, ",")
    if (f[1] == "elapsed_sec") continue
    sec = f[1] + 0
    tps = f[3] + 0
    qps = f[4] + 0
    err = f[5] + 0
    reconn = f[6] + 0
    lat = f[7] + 0
    tps_arr[sec] = tps
    qps_arr[sec] = qps
    err_arr[sec] = err
    reconn_arr[sec] = reconn
    if (sec > max_sec) max_sec = sec
    if (sec < trigger && tps > 0) { pre_sum += tps; pre_cnt++ }
    if (sec < trigger && qps > 0) { pre_qps_sum += qps; pre_qps_cnt++ }
    if (sec < trigger) {
      pre_err_sum += err
      pre_reconn_sum += reconn
      pre_err_cnt++
    }
    if (sec >= trigger) {
      if (min_tps_post == 0 || tps < min_tps_post) min_tps_post = tps
      if (min_qps_post == 0 || qps < min_qps_post) min_qps_post = qps
      if (lat > max_lat_post) max_lat_post = lat
      if (baseline > 0 && tps < recovery_threshold) below_recovery++
      if (err > peak_err_post) peak_err_post = err
      if (reconn > peak_reconn_post) peak_reconn_post = reconn
    }
  }
  load_end_sec = max_sec
  close(timeseries)
}
function monitor_gr_state(f) { return f[7] }
function monitor_gr_role(f) {
  if (length(f) >= 9 && f[8] != "" && f[8] != "ERROR") return f[8]
  return ""
}
function monitor_write_ok(f) {
  if (length(f) >= 10 && f[9] != "" && f[9] != "ERROR") return f[9] + 0
  return -1
}
function is_primary_elected(f,    wo, role, gr) {
  if (f[3] != "1") return 0
  wo = monitor_write_ok(f)
  if (wo != 1) return 0
  role = monitor_gr_role(f)
  gr = monitor_gr_state(f)
  if (edition == "advanced") {
    return (role == "PRIMARY" && (gr == "ONLINE" || gr == "PRIMARY"))
  }
  return 1
}
function compute_rto(    sec, stable_count, computed) {
  computed = -1
  stable_count = 0
  for (sec = trigger; sec <= load_end_sec; sec++) {
    if (!(sec in tps_arr)) continue
    if (baseline > 0 && tps_arr[sec] >= recovery_threshold) {
      stable_count++
      if (stable_count >= stable && computed < 0) {
        computed = sec - trigger - stable + 2
        if (computed < 0) computed = 0
      }
    } else {
      stable_count = 0
    }
  }
  return computed
}
function detect_connect_failure_ttd(    sysbench_sec) {
  if (monitor == "" || ( (getline _ < monitor) <= 0 )) return -1
  close(monitor)
  while ((getline line < monitor) > 0) {
    split(line, f, "\t")
    if (f[1] == "timestamp_utc") continue
    sysbench_sec = (f[2] + 0) - monitor_offset
    if (sysbench_sec < trigger) continue
    if (f[3] != "1") return sysbench_sec - trigger
  }
  close(monitor)
  return -1
}
function phase_duration(end_rel, start_rel) {
  if (end_rel < 0 || start_rel < 0) return -1
  if (end_rel < start_rel) return -1
  return end_rel - start_rel
}
function count_write_probe_failures(rto_rel, promote_rel,    sysbench_sec, wo, end_abs, count) {
  count = 0
  end_abs = load_end_sec
  if (rto_rel >= 0) end_abs = trigger + rto_rel
  if (promote_rel >= 0 && trigger + promote_rel > end_abs)
    end_abs = trigger + promote_rel
  if (monitor == "" || ( (getline _ < monitor) <= 0 )) return 0
  close(monitor)
  while ((getline line < monitor) > 0) {
    split(line, f, "\t")
    if (f[1] == "timestamp_utc") continue
    sysbench_sec = (f[2] + 0) - monitor_offset
    if (sysbench_sec < trigger || sysbench_sec > end_abs) continue
    if (f[3] != "1") continue
    wo = monitor_write_ok(f)
    if (wo == 0) count++
  }
  close(monitor)
  return count
}
function failover_tx_failures(fail_rel, rto_rel,    sec, start, end, sum, baseline_err, baseline_reconn, excess_err, excess_reconn) {
  baseline_err = 0
  baseline_reconn = 0
  if (pre_err_cnt > 0) {
    baseline_err = pre_err_sum / pre_err_cnt
    baseline_reconn = pre_reconn_sum / pre_err_cnt
  }
  sum = 0
  start = trigger + (fail_rel >= 0 ? fail_rel : 0)
  end = load_end_sec
  if (rto_rel >= 0) end = trigger + rto_rel
  for (sec = start; sec <= end; sec++) {
    if (sec in err_arr) {
      excess_err = err_arr[sec] - baseline_err
      if (excess_err > 0) sum += excess_err
    }
    if (sec in reconn_arr) {
      excess_reconn = reconn_arr[sec] - baseline_reconn
      if (excess_reconn > 0) sum += excess_reconn
    }
  }
  return int(sum + 0.5)
}
function load_monitor(    f, host, ro, gr, elapsed, sysbench_sec, saw_connect_fail) {
  if (monitor == "" || ( (getline _ < monitor) <= 0 )) return
  close(monitor)
  saw_connect_fail = 0
  while ((getline line < monitor) > 0) {
    split(line, f, "\t")
    if (f[1] == "timestamp_utc") continue
    elapsed = f[2] + 0
    sysbench_sec = elapsed - monitor_offset
    if (f[3] != "1") {
      if (sysbench_sec >= trigger && connect_fail < 0)
        connect_fail = sysbench_sec - trigger
      if (sysbench_sec >= trigger) saw_connect_fail = 1
      continue
    }
    host = f[4]
    ro = f[5] + 0
    gr = monitor_gr_state(f)
    if (primary_before == "N/A" && sysbench_sec < trigger) primary_before = host
    if (sysbench_sec >= trigger) {
      if (!saw_connect_fail) {
        continue
      } else if (promote_sec < 0 && is_primary_elected(f)) {
        promote_sec = sysbench_sec - trigger
      }
      if (primary_after == "N/A" && host != "ERROR") primary_after = host
    }
  }
  close(monitor)
}
function count_fatal(    n) {
  if (sysbench_log == "") return 0
  while ((getline line < sysbench_log) > 0)
    if (line ~ /^FATAL:/) n++
  close(sysbench_log)
  return n
}
function summarize_k8s(    block, in_block) {
  if (k8s_log == "") return
  print "K8s event highlights (see full log for details):"
  while ((getline line < k8s_log) > 0) {
    if (line ~ /^=== K8s events snapshot:/) {
      if (block != "") print block
      block = line
      in_block = 1
    } else if (in_block && line ~ /Killing|Unhealthy|Started|BackOff|Failed|Deleted|Created|Pulling|Pulled/) {
      if (block != "") block = block "\n  " line
      else block = "  " line
    }
  }
  if (block != "") print block
  close(k8s_log)
  print ""
}
END {
  load_timeseries()
  load_monitor()
  fatal_count = count_fatal()
  if (pre_cnt > 0) {
    baseline = pre_sum / pre_cnt
    recovery_threshold = baseline * recovery_pct
  }
  if (pre_qps_cnt > 0) baseline_qps = pre_qps_sum / pre_qps_cnt

  failure_detect = detect_connect_failure_ttd()
  if (failure_detect >= 0) failure_detect_abs = trigger + failure_detect
  promote_after_detect = phase_duration(promote_sec, failure_detect)

  computed_rto = compute_rto()
  if (computed_rto >= 0) rto = computed_rto

  writes_failed = count_write_probe_failures(rto, promote_sec)
  tx_failed = failover_tx_failures(failure_detect, rto)

  print "=== Failover Extended Metrics ==="
  print "Generated:              " generated_utc
  print "Edition:                  " edition
  print "Scenario:                 " scenario
  print "TPC-C profile:            " trx_profile
  print "Trigger method:           " method
  print "Trigger UTC:              " (trigger_utc != "" ? trigger_utc : "N/A")
  print "Trigger second:           " trigger " (from sysbench start)"
  print "Target pod:               " (target_pod != "" ? target_pod : "N/A")
  print ""
  print "--- Timing ---"
  if (failure_detect >= 0)
    printf "Time to detect failure:   %.3f s (%.0f ms · from trigger, first connect failure connect_ok=0)\n", failure_detect, failure_detect * 1000
  else
    print "Time to detect failure:   NOT_DETECTED"
  if (promote_after_detect >= 0)
    printf "Time to promote primary:  %.3f s (%.0f ms · from first connect failure, GR PRIMARY + write probe OK)\n", promote_after_detect, promote_after_detect * 1000
  else
    print "Time to promote primary:  NOT_DETECTED (monitor off or no promotion signal seen)"
  if (promote_sec >= 0)
    printf "Total failover time:      %.3f s (%.0f ms · downtime from trigger to promotion)\n", promote_sec, promote_sec * 1000
  else
    print "Total failover time:      NOT_DETECTED"
  if (rto >= 0)
    printf "Application recovery RTO: %.3f s (%.0f ms · %.0f%% baseline for %ds)\n", rto, rto * 1000, recovery_pct * 100, stable
  else
    print "Application recovery RTO: NOT_REACHED"
  printf "Outage window:            sysbench sec %d-%d (%d s)\n", outage_start, outage_end, outage_duration
  print ""
  print "--- Topology (from monitor) ---"
  print "Primary before:           " primary_before
  print "Primary after:            " primary_after
  print "Primary changed:          " primary_changed
  print ""
  print "--- Throughput / latency impact (post-trigger) ---"
  if (baseline > 0) printf "Baseline TPS (pre-trigger):     %.2f\n", baseline
  if (min_tps_post > 0 || baseline > 0) {
    printf "Min TPS post-trigger:           %.2f\n", min_tps_post
    if (baseline > 0) printf "Max TPS drop:                   %.1f%%\n", (1 - min_tps_post / baseline) * 100
  }
  if (min_qps_post > 0) printf "Min QPS post-trigger:           %.2f\n", min_qps_post
  if (max_lat_post > 0) printf "Peak p95 latency post-trigger:  %.2f ms\n", max_lat_post
  if (peak_err > 0) printf "Peak err/s (full run):          %.2f\n", peak_err
  if (peak_reconn > 0) printf "Peak reconn/s (full run):       %.2f\n", peak_reconn
  if (peak_lat > 0) printf "Peak p95 latency (full run):    %.2f ms\n", peak_lat
  if (peak_err_post > 0) printf "Peak err/s post-trigger:        %.2f\n", peak_err_post
  if (peak_reconn_post > 0) printf "Peak reconn/s post-trigger:     %.2f\n", peak_reconn_post
  if (below_recovery > 0) printf "Seconds below recovery threshold: %d\n", below_recovery
  print ""
  print "--- Failover impact (TTD → RTO) ---"
  printf "Transactions failed (excess err/reconn over pre-trigger baseline): %d\n", tx_failed
  printf "Write probe failures (poll count, connect_ok=1 & write_ok=0; not seconds — see note): %d\n", writes_failed
  print ""
  print "--- Load continuity ---"
  printf "Sysbench data ends at sec:      %d (expect ~%d)\n", load_end_sec, trigger + stable
  if (load_end_sec > 0 && load_end_sec < trigger + 10)
    print "WARNING: Sysbench stopped early — reconnect metrics may be incomplete"
  if (load_end_sec > 0 && load_end_sec < trigger)
    print "WARNING: Load ended BEFORE trigger second — failover metrics invalid"
  if (fatal_count > 0)
    printf "FATAL errors in sysbench log:   %d\n", fatal_count
  else
    print "FATAL errors in sysbench log:   0 (mysql-ignore-errors active)"
  print ""
  print "--- Data loss ---"
  print "TPC-C consistency check:        " tpcc_check
  print "Set FAILOVER_RUN_TPCC_CHECK=1 to validate TPC-C invariants after failover."
  print ""
  print "--- Control plane ---"
  if (trigger_log != "") print "Trigger log:              " trigger_log
  if (do_log != "") print "DO API events log:        " do_log
  if (k8s_log != "") {
    print "K8s events log:           " k8s_log
    summarize_k8s()
  }
  print "--- Related artifacts ---"
  print "Time series CSV:          " timeseries
  print "Primary monitor TSV:      " monitor
}
AWK

  echo "Extended metrics: ${out_file}"
}

write_failover_comparison() {
  local results_root="${1:?results root required}"
  local summary="${results_root}/failover_comparison.txt"
  local combined_csv="${results_root}/failover_comparison.csv"
  local kpi_csv="${results_root}/failover_kpi.csv"

  echo "edition,scenario,trigger_method,trigger_utc,baseline_tps,outage_start_sec,outage_duration_sec,rto_sec,peak_err_per_sec,peak_reconn_per_sec,peak_lat_p95_ms" > "${combined_csv}"
  echo "edition,scenario,trx_profile,failure_detection_sec,primary_election_sec,total_failover_sec,app_recovery_sec,tps_dip_duration_sec,peak_latency_failover_ms,transactions_failed_during_failover,writes_failed_during_failover,peak_write_err_per_sec,data_loss" > "${kpi_csv}"

  {
    echo "=== Failover Benchmark — Standard vs Advanced ==="
    echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo ""
  } > "${summary}"

  _append_failover_scenario_results() {
    local edition="$1"
    local scenario="$2"
    local scenario_dir="$3"
    local metrics="${scenario_dir}/failover_metrics.csv"
    local kpi="${scenario_dir}/failover_kpi.csv"
    local analysis="${scenario_dir}/failover_analysis.txt"

    if [[ -f "${metrics}" ]]; then
      tail -n +2 "${metrics}" >> "${combined_csv}" 2>/dev/null || true
    fi
    if [[ -f "${kpi}" ]]; then
      tail -n +2 "${kpi}" >> "${kpi_csv}"
    fi
    if [[ -f "${analysis}" ]]; then
      {
        echo "========================================"
        echo " Edition: ${edition} | Scenario: ${scenario}"
        echo "========================================"
        cat "${analysis}"
        echo ""
      } >> "${summary}"
    fi
  }

  for edition_dir in "${results_root}"/*/; do
    [[ -d "${edition_dir}" ]] || continue
    local edition
    edition=$(basename "${edition_dir}")
    [[ "${edition}" == "graphs" ]] && continue

    local found_scenario=0
    for sub_dir in "${edition_dir}"/*/; do
      [[ -d "${sub_dir}" ]] || continue
      local sub_name scenario_dir scenario threads_label
      sub_name=$(basename "${sub_dir}")

      if [[ "${sub_name}" =~ ^t[0-9]+$ ]]; then
        threads_label="${sub_name}"
        for scenario_dir in "${sub_dir}"/*/; do
          [[ -d "${scenario_dir}" ]] || continue
          scenario=$(basename "${scenario_dir}")
          [[ -f "${scenario_dir}/failover_kpi.csv" ]] || continue
          found_scenario=1
          _append_failover_scenario_results "${edition}" "${threads_label}/${scenario}" "${scenario_dir}"
        done
        continue
      fi

      scenario_dir="${sub_dir}"
      scenario="${sub_name}"
      [[ -f "${scenario_dir}/failover_kpi.csv" ]] || continue
      found_scenario=1
      _append_failover_scenario_results "${edition}" "${scenario}" "${scenario_dir}"
    done

    if [[ "${found_scenario}" -eq 0 && -f "${edition_dir}/failover_kpi.csv" ]]; then
      _append_failover_scenario_results "${edition}" "default" "${edition_dir%/}"
    fi
  done

  echo "Comparison summary: ${summary}"
  echo "Comparison CSV:     ${combined_csv}"
  echo "KPI CSV:            ${kpi_csv}"
}

# Recompute KPI / extended metrics from saved timeseries + monitor (no sysbench re-run).
reanalyze_failover_scenario() {
  local scenario_dir="${1:?scenario dir required}"
  local sysbench_log="${scenario_dir}/sysbench_run.log"
  local timing_file="${scenario_dir}/sysbench_timing.txt"
  local parsed_file="${scenario_dir}/failover_parsed.env"
  local timeseries="${scenario_dir}/failover_timeseries.csv"

  if [[ ! -f "${timeseries}" ]]; then
    echo "SKIP: missing ${timeseries}" >&2
    return 1
  fi

  failover_defaults

  if [[ -f "${sysbench_log}" ]]; then
    local trigger_second
    trigger_second=$(failover_trigger_second)
    if [[ -f "${timing_file}" ]]; then
      # shellcheck disable=SC1090
      source "${timing_file}" 2>/dev/null || true
      trigger_second="${FAILOVER_TRIGGER_SECOND:-${trigger_second}}"
    fi
    _failover_parse_sysbench_intervals "${sysbench_log}" "${trigger_second}" \
      "${FAILOVER_RECOVERY_THRESHOLD}" "${FAILOVER_RECOVERY_STABLE_SEC}" \
      "${FAILOVER_OUTAGE_TPS_RATIO}" "${FAILOVER_OBSERVE_SEC}" > "${parsed_file}"
  fi

  write_failover_kpi "${scenario_dir}"
  write_failover_extended_metrics "${scenario_dir}"
  return 0
}

reanalyze_failover_results() {
  local results_root="${1:?results root required}"
  local scenario_dir count=0

  if [[ ! -d "${results_root}" ]]; then
    echo "ERROR: not a directory: ${results_root}" >&2
    return 1
  fi

  failover_defaults

  while IFS= read -r scenario_dir; do
    echo ""
    echo "--- Reanalyzing ${scenario_dir} ---"
    if reanalyze_failover_scenario "${scenario_dir}"; then
      count=$((count + 1))
    fi
  done < <(find "${results_root}" -name failover_timeseries.csv -print | sort | while read -r ts; do dirname "${ts}"; done)

  if [[ "${count}" -eq 0 ]]; then
    echo "WARNING: no scenario dirs with failover_timeseries.csv under ${results_root}" >&2
    return 1
  fi

  echo ""
  echo "--- Rollup comparison + graphs ---"
  write_failover_comparison "${results_root}"
  if [[ -f "${BENCH_ROOT}/scripts/generate_failover_graphs.py" ]]; then
    python3 "${BENCH_ROOT}/scripts/generate_failover_graphs.py" --html-only "${results_root}"
  fi

  echo ""
  echo "Reanalyzed ${count} scenario(s) under ${results_root}"
}
