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
  # Legacy fallback when the split intervals below are unset.
  : "${FAILOVER_MONITOR_INTERVAL:=1}"
  # VIP/client-path monitor (primary_monitor.tsv); sub-second default for promote KPI accuracy.
  : "${FAILOVER_PRIMARY_MONITOR_INTERVAL:=}"
  # Shared by GR pod + K8s pod monitors (kubectl); keep >= 1s to avoid exec backlog.
  : "${FAILOVER_CLUSTER_MONITOR_INTERVAL:=}"
  : "${FAILOVER_MONITOR_CONNECT_TIMEOUT:=1}"
  : "${FAILOVER_MONITOR_OP_TIMEOUT:=1}"
  : "${FAILOVER_GR_POD_MONITOR:=1}"
  : "${FAILOVER_K8S_POD_MONITOR:=1}"
  : "${FAILOVER_HAPROXY_STATS_MONITOR:=1}"
  : "${FAILOVER_HAPROXY_STATS_MONITOR_INTERVAL:=0.5}"
  # Block failover trigger until GR is fully healthy (expected members ONLINE, 1 PRIMARY)
  : "${FAILOVER_GR_READINESS_GATE:=1}"
  : "${FAILOVER_GR_READINESS_POLL_SEC:=2}"
  : "${FAILOVER_GR_READINESS_TIMEOUT_SEC:=600}"
  : "${FAILOVER_GR_READINESS_ABORT_ON_TIMEOUT:=1}"
  # Require this many ONLINE GR members (and Ready mysql-* pods). 0 = do not enforce count.
  : "${FAILOVER_GR_EXPECTED_MEMBERS:=3}"
  # Also require all mysql-* pods Ready (phase=Running, ready_num==ready_den, not deleting)
  : "${FAILOVER_GR_REQUIRE_K8S_PODS_READY:=1}"
  # Advanced: ensure replica_parallel_workers on every pod before each iteration / trigger
  : "${FAILOVER_REPLICA_WORKERS_GATE:=1}"
  : "${FAILOVER_REPLICA_PARALLEL_WORKERS:=16}"
  : "${FAILOVER_REPLICA_WORKERS_POLL_SEC:=2}"
  : "${FAILOVER_REPLICA_WORKERS_TIMEOUT_SEC:=600}"
  : "${FAILOVER_REPLICA_WORKERS_ABORT_ON_TIMEOUT:=1}"
  : "${FAILOVER_COLLECT_K8S_EVENTS:=1}"
  : "${FAILOVER_RUN_TPCC_CHECK:=0}"
  : "${FAILOVER_MYSQL_IGNORE_ERRORS:=1053,2013,1290,3100,1205,1213,2006,2014,2003,2055,1047,1158,1159,1161,3011}"
  : "${FAILOVER_TRIGGER_ENABLED:=1}"
  : "${FAILOVER_ADVANCED_TRIGGER_METHOD:=pod_delete}"
  : "${FAILOVER_POD_DELETE:=${FAILOVER_TRIGGER_ENABLED}}"
  : "${FAILOVER_POD_DELETE_FORCE:=1}"
  : "${FAILOVER_POD_DELETE_GRACE_SEC:=0}"
  : "${FAILOVER_MYSQLD_KILL_SIGNAL:=9}"
  # Unplanned: max seconds after trigger to accept connect_ok=0 as detection.
  : "${FAILOVER_DETECT_WINDOW_SEC:=60}"
  # Planned (set_as_primary): max seconds after trigger to accept write/connect outage start.
  : "${FAILOVER_PLANNED_DETECT_WINDOW_SEC:=10}"
  # Optional 2nd arg to group_replication_set_as_primary(member_uuid[, timeout]):
  # seconds to wait for ongoing transactions before forcing the switch (MySQL UDF).
  : "${FAILOVER_SET_AS_PRIMARY_TIMEOUT_SEC:=1}"
  # Pre-trigger band for TTD (seconds). 0 = first connect_ok=0 at/after trigger epoch only.
  : "${FAILOVER_DETECT_GUARD_SEC:=0}"
  : "${ADVANCED_K8S_MYSQL_CONTAINER:=mysql}"
  # Advanced: fetch kubeconfig early; re-resolve primary pod this many seconds before delete
  : "${FAILOVER_TRIGGER_PREPARE_SEC:=5}"
  : "${FAILOVER_SCENARIOS:=mixed write_only}"
  : "${FAILOVER_SCENARIO_DELAY_SEC:=120}"
  # Space-separated load thread counts; when set, runs each under edition/t<N>/<scenario>/
  : "${FAILOVER_THREAD_MATRIX:=}"
  : "${FAILOVER_THREAD_DELAY_SEC:=120}"
  # Space-separated advanced trigger methods; when set, runs each under edition/<method>/...
  # Example: "pod_delete set_as_primary" (unplanned then planned). Empty = use FAILOVER_ADVANCED_TRIGGER_METHOD only.
  : "${FAILOVER_TRIGGER_MATRIX:=}"
  : "${FAILOVER_TRIGGER_MATRIX_DELAY_SEC:=180}"
  # Repeat full failover scenario loop N times (results under edition/iter<N>/); single combined report at end
  : "${FAILOVER_ITERATIONS:=1}"
  : "${FAILOVER_ITERATION_DELAY_SEC:=120}"
  # Advanced HAProxy: check inter N ms (N = interval_sec * 1000); Percona operator script default inter 10000 rise 1 fall 2
  : "${HAPROXY_HEALTH_CHECK_INTERVAL_SEC:=10}"
  : "${HAPROXY_HEALTH_CHECK_RISE:=1}"
  : "${HAPROXY_HEALTH_CHECK_FALL:=2}"
  : "${HAPROXY_APPLY_BEFORE_FAILOVER:=1}"
  : "${HAPROXY_APPLY_WAIT_SEC:=90}"
  : "${ADVANCED_PSMYSQL_CR_NAME:=}"
  # PMM client integration (Advanced): patch secrets + CR once per cluster (skipped if spec.pmm.enabled=true)
  : "${PMM_APPLY_BEFORE_FAILOVER:=0}"
  : "${PMM_REQUIRE_INTEGRATION:=0}"
  : "${PMM_SERVER_HOST:=}"
  : "${PMM_SERVER_TOKEN:=}"
  : "${PMM_CLIENT_IMAGE:=percona/pmm-client:3.7.0}"
  : "${PMM_ROLLOUT_TIMEOUT_SEC:=300}"
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

# Copy mysql_runtime.env fields into per-scenario sysbench_timing.txt (if captured).
_append_mysql_runtime_to_timing() {
  local results_dir="${1:?results dir required}"
  local timing_file="${results_dir}/sysbench_timing.txt"
  local edition_dir="${results_dir}"
  local base name runtime_file key

  while [[ "${edition_dir}" != "/" ]]; do
    base="$(basename "${edition_dir}")"
    if [[ "${base}" == "advanced" || "${base}" == "standard" ]]; then
      runtime_file="${edition_dir}/mysql_runtime.env"
      if [[ -f "${runtime_file}" ]]; then
        for key in BUFFER_POOL_GB REDO_LOG_CAPACITY_GB BUFFER_POOL_HIT_PCT \
          BUFFER_POOL_DATA_RATIO REPLICA_PARALLEL_WORKERS \
          GR_FLOW_CONTROL_CERTIFIER_THRESHOLD GR_FLOW_CONTROL_APPLIER_THRESHOLD; do
          val=$(grep -E "^${key}=" "${runtime_file}" | tail -1 | cut -d= -f2- || true)
          [[ -n "${val}" ]] && echo "${key}=${val}" >> "${timing_file}"
        done
      fi
      if [[ -f "${edition_dir}/haproxy_health.env" ]]; then
        for key in HA_SERVER_OPTIONS HAPROXY_CHECK_INTER_MS \
          HAPROXY_HEALTH_CHECK_INTERVAL_SEC HAPROXY_HEALTH_CHECK_RISE HAPROXY_HEALTH_CHECK_FALL; do
          val=$(grep -E "^${key}=" "${edition_dir}/haproxy_health.env" | tail -1 | cut -d= -f2- || true)
          [[ -n "${val}" ]] && echo "${key}=${val}" >> "${timing_file}"
        done
      fi
      return 0
    fi
    edition_dir="$(dirname "${edition_dir}")"
  done
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
    echo "TPCC_THREADS=${load_threads}"
    echo "PREP_THREADS=${prep_threads}"
    echo "FAILOVER_THREAD_MATRIX=${FAILOVER_THREAD_MATRIX:-}"
    echo "FAILOVER_TRIGGER_MATRIX=${FAILOVER_TRIGGER_MATRIX:-}"
    echo "FAILOVER_ADVANCED_TRIGGER_METHOD=${FAILOVER_ADVANCED_TRIGGER_METHOD:-pod_delete}"
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

failover_advanced_trigger_method() {
  failover_defaults
  echo "${FAILOVER_ADVANCED_TRIGGER_METHOD}"
}

# Valid advanced trigger methods for FAILOVER_TRIGGER_MATRIX / FAILOVER_ADVANCED_TRIGGER_METHOD.
failover_is_advanced_trigger_method() {
  case "${1:-}" in
    pod_delete|mysqld_kill|set_as_primary) return 0 ;;
    *) return 1 ;;
  esac
}

# Resolve the list of advanced trigger methods for one edition run.
# When FAILOVER_TRIGGER_MATRIX is set, that list is used; otherwise a single
# FAILOVER_ADVANCED_TRIGGER_METHOD entry (no extra results subdir).
failover_trigger_matrix_methods() {
  failover_defaults
  local method
  if [[ -n "${FAILOVER_TRIGGER_MATRIX:-}" ]]; then
    for method in ${FAILOVER_TRIGGER_MATRIX}; do
      if ! failover_is_advanced_trigger_method "${method}"; then
        echo "ERROR: Unknown FAILOVER_TRIGGER_MATRIX entry '${method}' (use pod_delete, mysqld_kill, set_as_primary)" >&2
        return 1
      fi
      echo "${method}"
    done
    return 0
  fi
  method="${FAILOVER_ADVANCED_TRIGGER_METHOD:-pod_delete}"
  if ! failover_is_advanced_trigger_method "${method}"; then
    echo "ERROR: Unknown FAILOVER_ADVANCED_TRIGGER_METHOD=${method} (use pod_delete, mysqld_kill, set_as_primary)" >&2
    return 1
  fi
  echo "${method}"
}

# Advanced kubectl-based trigger (pod delete, mysqld kill, or graceful GR switchover).
failover_advanced_trigger_active() {
  failover_defaults
  failover_trigger_enabled || return 1
  case "$(failover_advanced_trigger_method)" in
    pod_delete) failover_pod_delete_enabled ;;
    mysqld_kill) return 0 ;;
    set_as_primary) return 0 ;;
    *)
      echo "ERROR: Unknown FAILOVER_ADVANCED_TRIGGER_METHOD=$(failover_advanced_trigger_method) (use pod_delete, mysqld_kill, or set_as_primary)" >&2
      return 1
      ;;
  esac
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

# Sysbench --report-interval timeline (excludes warmup); used for TPS/QPS graphs and analysis.
failover_trigger_log_second() {
  failover_defaults
  if [[ -n "${FAILOVER_TRIGGER_LOG_SECOND:-}" ]]; then
    echo "${FAILOVER_TRIGGER_LOG_SECOND}"
    return 0
  fi
  echo "${FAILOVER_BASELINE_SEC}"
}

# Resolve log-axis trigger from a completed run (backward compatible with pre-warmup runs).
failover_trigger_log_second_from_timing() {
  local timing_file="${1:-}"
  failover_defaults
  if [[ -f "${timing_file}" ]]; then
    local val warmup baseline wall
    val=$(grep -E '^FAILOVER_TRIGGER_LOG_SECOND=' "${timing_file}" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    if [[ -n "${val}" ]]; then
      echo "${val}"
      return 0
    fi
    warmup=$(grep -E '^FAILOVER_WARMUP_SEC=' "${timing_file}" 2>/dev/null | tail -1 | cut -d= -f2- || echo "0")
    baseline=$(grep -E '^FAILOVER_BASELINE_SEC=' "${timing_file}" 2>/dev/null | tail -1 | cut -d= -f2- || echo "${FAILOVER_BASELINE_SEC}")
    wall=$(grep -E '^FAILOVER_TRIGGER_SECOND=' "${timing_file}" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    if [[ "${warmup}" =~ ^[0-9]+$ ]] && (( warmup > 0 )); then
      echo "${baseline}"
      return 0
    fi
    if [[ -n "${wall}" && "${wall}" =~ ^[0-9]+$ && "${baseline}" =~ ^[0-9]+$ ]] && (( wall > baseline )); then
      # Pre-fix runs stored wall second only (warmup + baseline) without LOG/WARMUP keys.
      echo "${baseline}"
      return 0
    fi
    if [[ -n "${wall}" ]]; then
      echo "${wall}"
      return 0
    fi
  fi
  failover_trigger_log_second
}

failover_trigger_wall_second_from_timing() {
  local timing_file="${1:-}"
  if [[ -f "${timing_file}" ]]; then
    local val
    val=$(grep -E '^FAILOVER_TRIGGER_WALL_SECOND=' "${timing_file}" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    if [[ -n "${val}" ]]; then
      echo "${val}"
      return 0
    fi
    val=$(grep -E '^FAILOVER_TRIGGER_SECOND=' "${timing_file}" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    if [[ -n "${val}" ]]; then
      echo "${val}"
      return 0
    fi
  fi
  failover_trigger_second
}

# Sub-second wall trigger, in "seconds since sysbench ready", computed from the
# actual recorded fire epoch (FAILOVER_TRIGGER_EPOCH) rather than the planned
# integer trigger second. This aligns detection/marking to when the trigger truly
# fired. Falls back to the planned integer wall second for older runs that predate
# FAILOVER_TRIGGER_EPOCH / SYSBENCH_READY_EPOCH.
failover_trigger_wall_subsec() {
  local results_dir="${1:?results dir required}"
  local timing_file="${2:?timing file required}"
  local event_file="${results_dir}/failover_event.txt"
  local trig_epoch="" ready_epoch=""
  [[ -f "${event_file}" ]] && trig_epoch=$(grep -E '^FAILOVER_TRIGGER_EPOCH=' "${event_file}" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  [[ -f "${timing_file}" ]] && ready_epoch=$(grep -E '^SYSBENCH_READY_EPOCH=' "${timing_file}" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  if [[ -n "${trig_epoch}" && -n "${ready_epoch}" ]]; then
    local rel
    rel=$(python3 -c "print('%.3f' % (float('${trig_epoch}') - float('${ready_epoch}')))" 2>/dev/null || true)
    # Guard against malformed/negative values (clock skew, missing sysbench start).
    if [[ -n "${rel}" ]] && python3 -c "import sys; sys.exit(0 if float('${rel}') > 0 else 1)" 2>/dev/null; then
      echo "${rel}"
      return 0
    fi
  fi
  failover_trigger_wall_second_from_timing "${timing_file}"
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

# Primary (VIP) poll grid. Defaults to 0.25s when unset; falls back to FAILOVER_MONITOR_INTERVAL.
_failover_primary_monitor_interval() {
  if [[ -n "${FAILOVER_PRIMARY_MONITOR_INTERVAL}" ]]; then
    echo "${FAILOVER_PRIMARY_MONITOR_INTERVAL}"
  else
    echo "${FAILOVER_MONITOR_INTERVAL:-0.25}"
  fi
}

# GR + K8s pod poll grid. Defaults to 1s when unset; falls back to FAILOVER_MONITOR_INTERVAL.
_failover_cluster_monitor_interval() {
  if [[ -n "${FAILOVER_CLUSTER_MONITOR_INTERVAL}" ]]; then
    echo "${FAILOVER_CLUSTER_MONITOR_INTERVAL}"
  else
    echo "${FAILOVER_MONITOR_INTERVAL:-1}"
  fi
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
  local interval
  interval="$(_failover_primary_monitor_interval)"
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
    echo "PRIMARY_MONITOR_INTERVAL_SEC=${interval}"
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

_failover_kubectl_cmd() {
  local kubeconfig="${1:?kubeconfig required}"
  local -a kubectl=(kubectl --kubeconfig="${kubeconfig}")
  [[ -n "${ADVANCED_K8S_CONTEXT:-}" ]] && kubectl+=(--context="${ADVANCED_K8S_CONTEXT}")
  printf '%s\n' "${kubectl[@]}"
}

_failover_list_mysql_pods() {
  local kubeconfig="${1:?kubeconfig required}"
  local ns="${2:?namespace required}"
  local -a kubectl
  mapfile -t kubectl < <(_failover_kubectl_cmd "${kubeconfig}")
  "${kubectl[@]}" get pods -n "${ns}" --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null \
    | grep -E 'mysql-[0-9]+$' | sort || true
}

_failover_poll_gr_pod_once() {
  local kubeconfig="${1:?kubeconfig required}"
  local ns="${2:?namespace required}"
  local pod="${3:?pod required}"
  local -a kubectl
  local exec_timeout="${FAILOVER_MONITOR_OP_TIMEOUT:-2}"
  (( exec_timeout < 5 )) && exec_timeout=5
  mapfile -t kubectl < <(_failover_kubectl_cmd "${kubeconfig}")
  # Percona operator mounts monitor credentials at /etc/mysql/mysql-users-secret/monitor
  _failover_run_timeout "${exec_timeout}" "${kubectl[@]}" exec -n "${ns}" "${pod}" -c mysql -- \
    sh -c 'mysql -umonitor -p"$(tr -d "\n" </etc/mysql/mysql-users-secret/monitor)" -N -B -e "
SELECT @@hostname,
       IFNULL((SELECT MEMBER_ROLE FROM performance_schema.replication_group_members
               WHERE MEMBER_ID = @@server_uuid LIMIT 1), '\''N/A'\''),
       IFNULL((SELECT MEMBER_STATE FROM performance_schema.replication_group_members
               WHERE MEMBER_ID = @@server_uuid LIMIT 1), '\''N/A'\''),
       IFNULL((SELECT COUNT_TRANSACTIONS_IN_QUEUE
                 FROM performance_schema.replication_group_member_stats
                WHERE MEMBER_ID = @@server_uuid LIMIT 1), -1),
       IFNULL((SELECT COUNT_TRANSACTIONS_REMOTE_IN_APPLIER_QUEUE
                 FROM performance_schema.replication_group_member_stats
                WHERE MEMBER_ID = @@server_uuid LIMIT 1), -1),
       IFNULL((SELECT COUNT_TRANSACTIONS_REMOTE_APPLIED
                 FROM performance_schema.replication_group_member_stats
                WHERE MEMBER_ID = @@server_uuid LIMIT 1), -1),
       IFNULL((SELECT COUNT_TRANSACTIONS_CHECKED
                 FROM performance_schema.replication_group_member_stats
                WHERE MEMBER_ID = @@server_uuid LIMIT 1), -1),
       IFNULL((SELECT COUNT_CONFLICTS_DETECTED
                 FROM performance_schema.replication_group_member_stats
                WHERE MEMBER_ID = @@server_uuid LIMIT 1), -1),
       IFNULL(CAST(SUBSTRING_INDEX(SUBSTRING_INDEX(@@GLOBAL.gtid_executed, '\'':'\'', -1), '\''-'\'', -1) AS UNSIGNED), 0),
       IFNULL((SELECT COUNT(*) FROM performance_schema.replication_applier_status_by_worker
               WHERE CHANNEL_NAME = '\''group_replication_applier'\''), 0),
       IFNULL((SELECT SUM(APPLYING_TRANSACTION <> '\'''\'')
                 FROM performance_schema.replication_applier_status_by_worker
                WHERE CHANNEL_NAME = '\''group_replication_applier'\''), 0);"' 2>/dev/null || true
}

_failover_poll_pod_buffer_pool_once() {
  local kubeconfig="${1:?kubeconfig required}"
  local ns="${2:?namespace required}"
  local pod="${3:?pod required}"
  local -a kubectl
  local exec_timeout="${FAILOVER_MONITOR_OP_TIMEOUT:-2}"
  (( exec_timeout < 5 )) && exec_timeout=5
  mapfile -t kubectl < <(_failover_kubectl_cmd "${kubeconfig}")
  _failover_run_timeout "${exec_timeout}" "${kubectl[@]}" exec -n "${ns}" "${pod}" -c mysql -- \
    sh -c 'mysql -umonitor -p"$(tr -d "\n" </etc/mysql/mysql-users-secret/monitor)" -N -B -e "
SELECT @@hostname,
       @@innodb_buffer_pool_size,
       IFNULL((SELECT VARIABLE_VALUE FROM performance_schema.global_status
               WHERE VARIABLE_NAME = '\''Innodb_buffer_pool_bytes_data'\'' LIMIT 1), 0),
       IFNULL((SELECT MEMBER_ROLE FROM performance_schema.replication_group_members
               WHERE MEMBER_ID = @@server_uuid LIMIT 1), '\''N/A'\''),
       @@GLOBAL.replica_parallel_workers,
       IFNULL((SELECT COUNT(*) FROM performance_schema.replication_applier_status_by_worker
               WHERE CHANNEL_NAME = '\''group_replication_applier'\''), 0),
       IFNULL((SELECT SUM(APPLYING_TRANSACTION <> '\'''\'')
                 FROM performance_schema.replication_applier_status_by_worker
                WHERE CHANNEL_NAME = '\''group_replication_applier'\''), 0);"' 2>/dev/null || true
}

# One-shot per-pod buffer pool snapshot (limit + bytes_data + GR role) for report metadata.
capture_mysql_pod_buffer_pool_metadata() {
  local edition_dir="${1:?edition dir required}"
  local kubeconfig=""
  local ns="${ADVANCED_K8S_NAMESPACE:-}"
  local out_tsv="${edition_dir}/mysql_pod_buffer_pool.tsv"
  local captured_utc
  captured_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  [[ -n "${ns}" ]] || {
    echo "MySQL pod buffer pool: skipped (ADVANCED_K8S_NAMESPACE unset)" >&2
    return 0
  }
  if ! kubeconfig="$(_failover_resolve_kubeconfig "${edition_dir}")"; then
    echo "MySQL pod buffer pool: skipped (no kubeconfig — set ADVANCED_KUBECONFIG_PATH)" >&2
    return 0
  fi

  {
    echo "# captured_utc=${captured_utc}"
    echo "# namespace=${ns} kubeconfig=${kubeconfig}"
    echo -e "pod\thostname\tbp_limit_bytes\tbp_data_bytes\tbp_used_pct\tgr_role\treplica_parallel_workers\tworkers_total\tworkers_applying_now"
    local pod line hostname bp_limit bp_data gr_role replica_workers workers_total workers_applying bp_used_pct
    while IFS= read -r pod; do
      [[ -n "${pod}" ]] || continue
      line="$(_failover_poll_pod_buffer_pool_once "${kubeconfig}" "${ns}" "${pod}")"
      [[ -n "${line}" ]] || continue
      IFS=$'\t' read -r hostname bp_limit bp_data gr_role replica_workers workers_total workers_applying <<< "${line}"
      replica_workers="${replica_workers:-N/A}"
      workers_total="${workers_total:-N/A}"
      workers_applying="${workers_applying:-N/A}"
      bp_used_pct="N/A"
      if [[ -n "${bp_limit}" && -n "${bp_data}" && "${bp_limit}" =~ ^[0-9]+$ && "${bp_data}" =~ ^[0-9]+$ && "${bp_limit}" -gt 0 ]]; then
        bp_used_pct="$(awk "BEGIN { printf \"%.1f\", (${bp_data} / ${bp_limit}) * 100 }")"
      fi
      echo -e "${pod}\t${hostname}\t${bp_limit}\t${bp_data}\t${bp_used_pct}\t${gr_role}\t${replica_workers}\t${workers_total}\t${workers_applying}"
    done < <(_failover_list_mysql_pods "${kubeconfig}" "${ns}")
  } > "${out_tsv}"

  if [[ "$(wc -l < "${out_tsv}" | tr -d ' ')" -le 2 ]]; then
    echo "WARNING: MySQL pod buffer pool capture returned no pod rows" >&2
    return 1
  fi

  echo "Captured MySQL pod buffer pool metadata: ${out_tsv}"
  while IFS=$'\t' read -r pod _host _limit _data _pct gr_role replica_workers workers_total workers_applying; do
    [[ "${pod}" == "pod" || -z "${pod}" || "${pod}" =~ ^# ]] && continue
    echo "  ${pod}: replica_parallel_workers=${replica_workers:-N/A} workers_applying=${workers_applying:-N/A}/${workers_total:-N/A} [${gr_role:-N/A}]"
  done < "${out_tsv}"
  return 0
}

# One-shot per-pod GR applier queue snapshot immediately before failover trigger.
capture_gr_pre_failover_applier_snapshot() {
  local results_dir="${1:?results dir required}"
  local kubeconfig=""
  local ns="${ADVANCED_K8S_NAMESPACE:-}"
  local out_tsv="${results_dir}/gr_pre_failover_applier.tsv"
  local out_env="${results_dir}/gr_pre_failover_applier.env"
  local captured_utc
  captured_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  command -v kubectl >/dev/null 2>&1 || {
    echo "GR pre-failover applier: skipped (kubectl not found)" >&2
    return 0
  }
  [[ -n "${ns}" ]] || {
    echo "GR pre-failover applier: skipped (ADVANCED_K8S_NAMESPACE unset)" >&2
    return 0
  }
  if ! kubeconfig="$(_failover_resolve_kubeconfig "${results_dir}")"; then
    echo "GR pre-failover applier: skipped (no kubeconfig)" >&2
    return 0
  fi

  local pod line hostname role state cert_q applier_q
  local -a pod_rows=()
  local lag_leader="" lag_leader_q=-1

  {
    echo "# captured_utc=${captured_utc}"
    echo "# namespace=${ns} kubeconfig=${kubeconfig}"
    echo -e "pod\tconnect_ok\thostname\tgr_role\tgr_member_state\tcert_queue\tapplier_queue"
    while IFS= read -r pod; do
      [[ -n "${pod}" ]] || continue
      line="$(_failover_poll_gr_pod_once "${kubeconfig}" "${ns}" "${pod}")"
      if [[ "${line}" == *$'\t'* ]]; then
        IFS=$'\t' read -r hostname role state cert_q applier_q _rest <<< "${line}"
        cert_q="${cert_q:--1}"
        applier_q="${applier_q:--1}"
        echo -e "${pod}\t1\t${hostname}\t${role}\t${state}\t${cert_q}\t${applier_q}"
        pod_rows+=("${pod}"$'\t'"${applier_q}")
        if [[ "${applier_q}" =~ ^-?[0-9]+$ ]] && (( applier_q >= lag_leader_q )); then
          lag_leader_q="${applier_q}"
          lag_leader="${pod}"
        fi
      else
        echo -e "${pod}\t0\tERROR\tERROR\tERROR\t-1\t-1"
      fi
    done < <(_failover_list_mysql_pods "${kubeconfig}" "${ns}")
  } > "${out_tsv}"

  if [[ "$(wc -l < "${out_tsv}" | tr -d ' ')" -le 2 ]]; then
    echo "WARNING: GR pre-failover applier capture returned no pod rows" >&2
    return 1
  fi

  {
    echo "GR_PRE_FAILOVER_APPLIER_CAPTURED_UTC=${captured_utc}"
    echo "GR_PRE_FAILOVER_APPLIER_NAMESPACE=${ns}"
    echo "GR_PRE_FAILOVER_LAG_LEADER_POD=${lag_leader}"
    while IFS=$'\t' read -r pod applier_q; do
      [[ -n "${pod}" ]] || continue
      echo "GR_PRE_FAILOVER_POD_APPLIER_${pod}=${applier_q}"
    done < <(printf '%s\n' "${pod_rows[@]}")
  } > "${out_env}"

  echo "Captured GR pre-failover applier queues: ${out_tsv}"
  if [[ -n "${lag_leader}" ]]; then
    echo "  Pre-trigger applier lag leader: ${lag_leader} (queue=${lag_leader_q})"
  fi
  return 0
}

_failover_poll_k8s_mysql_pods_once() {
  local kubeconfig="${1:?kubeconfig required}"
  local ns="${2:?namespace required}"
  local target_pod="${3:-}"

  python3 - "${kubeconfig}" "${ns}" "${target_pod}" "${ADVANCED_K8S_CONTEXT:-}" <<'PY'
import json
import re
import subprocess
import sys

kubeconfig, ns, target_pod, context = sys.argv[1:5]
base = ["kubectl", f"--kubeconfig={kubeconfig}"]
if context:
    base.extend(["--context", context])

try:
    raw = subprocess.check_output(
        base + ["get", "pods", "-n", ns, "-o", "json"],
        text=True,
        stderr=subprocess.DEVNULL,
    )
except (subprocess.CalledProcessError, FileNotFoundError):
    sys.exit(0)

doc = json.loads(raw)
mysql_re = re.compile(r"mysql-\d+$")
for item in sorted(doc.get("items") or [], key=lambda x: x.get("metadata", {}).get("name", "")):
    meta = item.get("metadata") or {}
    name = meta.get("name", "")
    if not mysql_re.search(name):
        continue
    status = item.get("status") or {}
    phase = status.get("phase") or "Unknown"
    containers = status.get("containerStatuses") or []
    ready_num = sum(1 for c in containers if c.get("ready"))
    ready_den = len(containers)
    restarts = 0
    if containers:
        restarts = sum(int(c.get("restartCount") or 0) for c in containers)
    deleting = 1 if meta.get("deletionTimestamp") else 0
    is_target = 1 if target_pod and name == target_pod else 0
    try:
        print(
            f"{name}\t{phase}\t{ready_num}\t{ready_den}\t{restarts}\t{deleting}\t{is_target}",
            flush=True,
        )
    except BrokenPipeError:
        sys.exit(0)
PY
}

start_gr_pod_monitor() {
  local results_dir="${1:?results dir required}"
  local pid_file="${results_dir}/gr_pod_monitor.pid"
  local out_file="${results_dir}/gr_pod_monitor.tsv"
  local meta_file="${results_dir}/gr_pod_monitor_meta.txt"
  local kubeconfig=""
  local ns="${ADVANCED_K8S_NAMESPACE:-}"

  command -v kubectl >/dev/null 2>&1 || return 0
  kubeconfig="$(_failover_resolve_kubeconfig "${results_dir}")" || return 0
  [[ -n "${ns}" ]] || return 0

  local interval
  interval="$(_failover_cluster_monitor_interval)"
  local start_epoch
  start_epoch=$(python3 -c "import time; print('%.3f' % time.time())")

  : > "${out_file}"
  echo -e "timestamp_utc\telapsed_sec\tpod\tconnect_ok\thostname\tgr_member_role\tgr_member_state\tcert_queue\tapplier_queue\tremote_applied\ttx_checked\tconflicts\tgtid_seq\tworkers_total\tworkers_applying_now" >> "${out_file}"
  {
    echo "GR_POD_MONITOR_START_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "GR_POD_MONITOR_START_EPOCH=${start_epoch}"
    echo "GR_POD_MONITOR_INTERVAL_SEC=${interval}"
    echo "CLUSTER_MONITOR_INTERVAL_SEC=${interval}"
    echo "GR_POD_MONITOR_NAMESPACE=${ns}"
    echo "GR_POD_MONITOR_KUBECONFIG=${kubeconfig}"
  } > "${meta_file}"

  (
    local tick=0 target_epoch elapsed ts due_tick pod line host role state cert_q applier_q
    local remote_applied tx_checked conflicts gtid_seq workers_total workers_applying
    while true; do
      due_tick=$(python3 -c "
import math, time
start = float('${start_epoch}')
interval = float('${interval}')
print(int(math.floor((time.time() - start) / interval)))
")
      while (( tick < due_tick )); do
        tick=$((tick + 1))
      done

      target_epoch=$(python3 -c "print(float('${start_epoch}') + ${tick} * float('${interval}'))")
      _failover_monitor_sleep_until "${target_epoch}"

      elapsed=$(python3 -c "print('%.3f' % (float('${target_epoch}') - float('${start_epoch}')))")
      ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

      while IFS= read -r pod; do
        [[ -n "${pod}" ]] || continue
        line=$(_failover_poll_gr_pod_once "${kubeconfig}" "${ns}" "${pod}")
        if [[ "${line}" == *$'\t'* ]]; then
          IFS=$'\t' read -r host role state cert_q applier_q remote_applied tx_checked conflicts gtid_seq workers_total workers_applying <<< "${line}"
          remote_applied="${remote_applied:--1}"
          tx_checked="${tx_checked:--1}"
          conflicts="${conflicts:--1}"
          gtid_seq="${gtid_seq:-0}"
          workers_total="${workers_total:--1}"
          workers_applying="${workers_applying:--1}"
          echo -e "${ts}\t${elapsed}\t${pod}\t1\t${host}\t${role}\t${state}\t${cert_q}\t${applier_q}\t${remote_applied}\t${tx_checked}\t${conflicts}\t${gtid_seq}\t${workers_total}\t${workers_applying}" >> "${out_file}"
        else
          echo -e "${ts}\t${elapsed}\t${pod}\t0\tERROR\tERROR\tERROR\t-1\t-1\t-1\t-1\t-1\t0\t-1\t-1" >> "${out_file}"
        fi
      done < <(_failover_list_mysql_pods "${kubeconfig}" "${ns}")

      tick=$((tick + 1))
    done
  ) &

  echo $! > "${pid_file}"
  echo "GR pod monitor started (pid=$(cat "${pid_file}"), ${interval}s grid, direct kubectl exec per mysql pod)"
}

stop_gr_pod_monitor() {
  local results_dir="${1:?results dir required}"
  local pid_file="${results_dir}/gr_pod_monitor.pid"

  if [[ -f "${pid_file}" ]]; then
    local pid
    pid=$(cat "${pid_file}")
    if kill -0 "${pid}" 2>/dev/null; then
      pkill -TERM -P "${pid}" 2>/dev/null || true
      kill "${pid}" 2>/dev/null || true
      wait "${pid}" 2>/dev/null || true
    fi
    rm -f "${pid_file}"
  fi
  if [[ -f "${results_dir}/gr_pod_monitor_meta.txt" ]]; then
    echo "GR_POD_MONITOR_END_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "${results_dir}/gr_pod_monitor_meta.txt"
  fi
}

start_k8s_pods_monitor() {
  local results_dir="${1:?results dir required}"
  local pid_file="${results_dir}/k8s_pods_monitor.pid"
  local out_file="${results_dir}/k8s_pods_monitor.tsv"
  local meta_file="${results_dir}/k8s_pods_monitor_meta.txt"
  local kubeconfig=""
  local ns="${ADVANCED_K8S_NAMESPACE:-}"
  local target_pod=""

  [[ "${FAILOVER_K8S_POD_MONITOR:-1}" == "1" ]] || return 0
  command -v kubectl >/dev/null 2>&1 || return 0
  kubeconfig="$(_failover_resolve_kubeconfig "${results_dir}")" || return 0
  [[ -n "${ns}" ]] || return 0

  if [[ -f "${results_dir}/failover_trigger_prepared.env" ]]; then
    # shellcheck disable=SC1090
    source "${results_dir}/failover_trigger_prepared.env" 2>/dev/null || true
    target_pod="${FAILOVER_TARGET_POD:-}"
  fi

  local interval
  interval="$(_failover_cluster_monitor_interval)"
  local start_epoch
  start_epoch=$(python3 -c "import time; print('%.3f' % time.time())")

  : > "${out_file}"
  echo -e "timestamp_utc\telapsed_sec\tpod\tphase\tready_num\tready_den\trestarts\tdeleting\tis_target" >> "${out_file}"
  {
    echo "K8S_PODS_MONITOR_START_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "K8S_PODS_MONITOR_START_EPOCH=${start_epoch}"
    echo "K8S_PODS_MONITOR_INTERVAL_SEC=${interval}"
    echo "CLUSTER_MONITOR_INTERVAL_SEC=${interval}"
    echo "K8S_PODS_MONITOR_NAMESPACE=${ns}"
    echo "K8S_PODS_MONITOR_KUBECONFIG=${kubeconfig}"
    echo "K8S_PODS_MONITOR_TARGET_POD=${target_pod}"
  } > "${meta_file}"

  (
    local tick=0 target_epoch elapsed ts due_tick pod line phase ready_num ready_den restarts deleting is_target
    while true; do
      due_tick=$(python3 -c "
import math, time
start = float('${start_epoch}')
interval = float('${interval}')
print(int(math.floor((time.time() - start) / interval)))
")
      while (( tick < due_tick )); do
        tick=$((tick + 1))
      done

      target_epoch=$(python3 -c "print(float('${start_epoch}') + ${tick} * float('${interval}'))")
      _failover_monitor_sleep_until "${target_epoch}"

      elapsed=$(python3 -c "print('%.3f' % (float('${target_epoch}') - float('${start_epoch}')))")
      ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

      local current_target="${target_pod}"
      if [[ -f "${results_dir}/failover_event.txt" ]]; then
        current_target=$(grep -E '^FAILOVER_TARGET_POD=' "${results_dir}/failover_event.txt" 2>/dev/null \
          | tail -1 | cut -d= -f2- || echo "${target_pod}")
      fi

      while IFS= read -r line; do
        [[ -n "${line}" ]] || continue
        pod=${line%%$'\t'*}
        rest=${line#*$'\t'}
        phase=${rest%%$'\t'*}
        rest=${rest#*$'\t'}
        ready_num=${rest%%$'\t'*}
        rest=${rest#*$'\t'}
        ready_den=${rest%%$'\t'*}
        rest=${rest#*$'\t'}
        restarts=${rest%%$'\t'*}
        rest=${rest#*$'\t'}
        deleting=${rest%%$'\t'*}
        is_target=${rest#*$'\t'}
        if [[ -n "${current_target}" && "${pod}" == "${current_target}" ]]; then
          is_target=1
        fi
        echo -e "${ts}\t${elapsed}\t${pod}\t${phase}\t${ready_num}\t${ready_den}\t${restarts}\t${deleting}\t${is_target}" \
          >> "${out_file}"
      done < <(_failover_poll_k8s_mysql_pods_once "${kubeconfig}" "${ns}" "${current_target}")

      tick=$((tick + 1))
    done
  ) &

  echo $! > "${pid_file}"
  echo "K8s pods monitor started (pid=$(cat "${pid_file}"), ${interval}s grid, mysql-* pod readiness)"
}

stop_k8s_pods_monitor() {
  local results_dir="${1:?results dir required}"
  local pid_file="${results_dir}/k8s_pods_monitor.pid"

  if [[ -f "${pid_file}" ]]; then
    local pid
    pid=$(cat "${pid_file}")
    if kill -0 "${pid}" 2>/dev/null; then
      pkill -TERM -P "${pid}" 2>/dev/null || true
      kill "${pid}" 2>/dev/null || true
      wait "${pid}" 2>/dev/null || true
    fi
    rm -f "${pid_file}"
  fi
  if [[ -f "${results_dir}/k8s_pods_monitor_meta.txt" ]]; then
    echo "K8S_PODS_MONITOR_END_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "${results_dir}/k8s_pods_monitor_meta.txt"
  fi
}

_failover_haproxy_stats_monitor_interval() {
  if [[ -n "${FAILOVER_HAPROXY_STATS_MONITOR_INTERVAL}" ]]; then
    echo "${FAILOVER_HAPROXY_STATS_MONITOR_INTERVAL}"
  else
    echo "0.5"
  fi
}

_failover_list_haproxy_pods() {
  local kubeconfig="${1:?kubeconfig required}"
  local ns="${2:?namespace required}"
  local -a kubectl
  mapfile -t kubectl < <(_failover_kubectl_cmd "${kubeconfig}")
  "${kubectl[@]}" get pods -n "${ns}" --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null \
    | grep -E 'haproxy-[0-9]+$' | sort || true
}

_failover_poll_haproxy_stats_once() {
  local kubeconfig="${1:?kubeconfig required}"
  local ns="${2:?namespace required}"
  local haproxy_pod="${3:?haproxy pod required}"
  local -a kubectl
  local exec_timeout="${FAILOVER_MONITOR_OP_TIMEOUT:-2}"
  (( exec_timeout < 5 )) && exec_timeout=5
  mapfile -t kubectl < <(_failover_kubectl_cmd "${kubeconfig}")
  _failover_run_timeout "${exec_timeout}" "${kubectl[@]}" exec -n "${ns}" "${haproxy_pod}" -c haproxy -- \
    sh -c 'echo show stat | socat stdio /etc/haproxy/mysql/haproxy.sock 2>/dev/null' 2>/dev/null \
    | python3 -c '
import sys
for raw in sys.stdin:
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    parts = line.split(",")
    if len(parts) < 20:
        continue
    px, sv = parts[0], parts[1]
    if px != "mysql-primary" or sv in ("FRONTEND", "BACKEND"):
        continue
    status = parts[17]
    act = parts[19] if len(parts) > 19 else ""
    bck = parts[20] if len(parts) > 20 else ""
    lastchg = parts[24] if len(parts) > 24 else ""
    check_status = parts[36] if len(parts) > 36 else ""
    print(f"{sv}\t{status}\t{check_status}\t{lastchg}\t{act}\t{bck}")
'
}

start_haproxy_stats_monitor() {
  local results_dir="${1:?results dir required}"
  local pid_file="${results_dir}/haproxy_stats_monitor.pid"
  local out_file="${results_dir}/haproxy_stats_monitor.tsv"
  local meta_file="${results_dir}/haproxy_stats_monitor_meta.txt"
  local kubeconfig=""
  local ns="${ADVANCED_K8S_NAMESPACE:-}"

  command -v kubectl >/dev/null 2>&1 || return 0
  kubeconfig="$(_failover_resolve_kubeconfig "${results_dir}")" || return 0
  [[ -n "${ns}" ]] || return 0

  local interval
  interval="$(_failover_haproxy_stats_monitor_interval)"
  local start_epoch
  start_epoch=$(python3 -c "import time; print('%.3f' % time.time())")

  : > "${out_file}"
  echo -e "timestamp_utc\telapsed_sec\thaproxy_pod\tpoll_ok\tserver\tstatus\tcheck_status\tlastchg_sec\tact\tbck" >> "${out_file}"
  {
    echo "HAPROXY_STATS_MONITOR_START_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "HAPROXY_STATS_MONITOR_START_EPOCH=${start_epoch}"
    echo "HAPROXY_STATS_MONITOR_INTERVAL_SEC=${interval}"
    echo "HAPROXY_STATS_MONITOR_NAMESPACE=${ns}"
    echo "HAPROXY_STATS_MONITOR_KUBECONFIG=${kubeconfig}"
    echo "HAPROXY_STATS_SOCKET=/etc/haproxy/mysql/haproxy.sock"
    echo "HAPROXY_STATS_BACKEND=mysql-primary"
  } > "${meta_file}"

  (
    local tick=0 target_epoch elapsed ts haproxy_pod line poll_ok
    local server status check_status lastchg act bck
    while true; do
      due_tick=$(python3 -c "
import math, time
start = float('${start_epoch}')
interval = float('${interval}')
print(int(math.floor((time.time() - start) / interval)))
")
      while (( tick < due_tick )); do
        tick=$((tick + 1))
      done

      target_epoch=$(python3 -c "print(float('${start_epoch}') + ${tick} * float('${interval}'))")
      _failover_monitor_sleep_until "${target_epoch}"

      elapsed=$(python3 -c "print('%.3f' % (float('${target_epoch}') - float('${start_epoch}')))")
      ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

      while IFS= read -r haproxy_pod; do
        [[ -n "${haproxy_pod}" ]] || continue
        poll_ok=0
        while IFS= read -r line; do
          [[ -n "${line}" ]] || continue
          poll_ok=1
          IFS=$'\t' read -r server status check_status lastchg act bck <<< "${line}"
          echo -e "${ts}\t${elapsed}\t${haproxy_pod}\t1\t${server}\t${status}\t${check_status}\t${lastchg}\t${act}\t${bck}" >> "${out_file}"
        done < <(_failover_poll_haproxy_stats_once "${kubeconfig}" "${ns}" "${haproxy_pod}")
        if [[ "${poll_ok}" -eq 0 ]]; then
          echo -e "${ts}\t${elapsed}\t${haproxy_pod}\t0\tERROR\tERROR\tERROR\t-1\t0\t0" >> "${out_file}"
        fi
      done < <(_failover_list_haproxy_pods "${kubeconfig}" "${ns}")

      tick=$((tick + 1))
    done
  ) &

  echo $! > "${pid_file}"
  echo "HAProxy stats monitor started (pid=$(cat "${pid_file}"), ${interval}s grid, show stat on mysql-primary pool)"
}

stop_haproxy_stats_monitor() {
  local results_dir="${1:?results dir required}"
  local pid_file="${results_dir}/haproxy_stats_monitor.pid"

  if [[ -f "${pid_file}" ]]; then
    local pid
    pid=$(cat "${pid_file}")
    if kill -0 "${pid}" 2>/dev/null; then
      pkill -TERM -P "${pid}" 2>/dev/null || true
      kill "${pid}" 2>/dev/null || true
      wait "${pid}" 2>/dev/null || true
    fi
    rm -f "${pid_file}"
  fi
  if [[ -f "${results_dir}/haproxy_stats_monitor_meta.txt" ]]; then
    echo "HAPROXY_STATS_MONITOR_END_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "${results_dir}/haproxy_stats_monitor_meta.txt"
  fi
}

_failover_haproxy_stat_server_for_pod() {
  local kubeconfig="${1:?kubeconfig required}"
  local ns="${2:?namespace required}"
  local pod="${3:?pod required}"
  local -a kubectl ip

  mapfile -t kubectl < <(_failover_kubectl_cmd "${kubeconfig}")
  ip=$("${kubectl[@]}" get pod -n "${ns}" "${pod}" -o jsonpath='{.status.podIP}' 2>/dev/null || true)
  [[ -n "${ip}" ]] || return 1
  echo "${ip//./-}"
}

_failover_parse_haproxy_stats_primary_up() {
  local results_dir="${1:?results dir required}"
  local elected_pod="${2:-}"
  local out_env="${results_dir}/haproxy_primary_up.env"
  local stats_file="${results_dir}/haproxy_stats_monitor.tsv"
  local meta_file="${results_dir}/haproxy_stats_monitor_meta.txt"
  local timing_file="${results_dir}/sysbench_timing.txt"

  [[ -f "${stats_file}" ]] || return 1

  local kubeconfig="" ns="" monitor_offset=0 wall_trigger=0
  if [[ -f "${meta_file}" ]]; then
    # shellcheck disable=SC1090
    source "${meta_file}" 2>/dev/null || true
    kubeconfig="${HAPROXY_STATS_MONITOR_KUBECONFIG:-}"
    ns="${HAPROXY_STATS_MONITOR_NAMESPACE:-}"
    local monitor_start="" sysbench_ready=""
    monitor_start=$(grep -E '^HAPROXY_STATS_MONITOR_START_EPOCH=' "${meta_file}" | cut -d= -f2- || true)
    if [[ -f "${timing_file}" ]]; then
      sysbench_ready=$(grep -E '^SYSBENCH_READY_EPOCH=' "${timing_file}" | cut -d= -f2- || true)
    fi
    if [[ -n "${monitor_start}" && -n "${sysbench_ready}" ]]; then
      monitor_offset=$(python3 -c "print('%.3f' % (float('${sysbench_ready}') - float('${monitor_start}')))")
    fi
  fi
  wall_trigger=$(failover_trigger_wall_subsec "${results_dir}" "${timing_file}")

  if [[ -z "${elected_pod}" && -f "${results_dir}/gr_election_internal.env" ]]; then
    # shellcheck disable=SC1090
    source "${results_dir}/gr_election_internal.env" 2>/dev/null || true
    elected_pod="${GR_ELECTION_POD:-}"
  fi
  if [[ -z "${elected_pod}" && -f "${results_dir}/primary_change.env" ]]; then
    elected_pod=$(grep -E '^PRIMARY_AFTER=' "${results_dir}/primary_change.env" | cut -d= -f2- || true)
  fi

  local target_server=""
  if [[ -n "${elected_pod}" && -n "${kubeconfig}" && -n "${ns}" ]]; then
    target_server="$(_failover_haproxy_stat_server_for_pod "${kubeconfig}" "${ns}" "${elected_pod}" 2>/dev/null || true)"
  fi

  local min_after_rel="0"
  if [[ -f "${results_dir}/gr_election_internal.env" ]]; then
    # shellcheck disable=SC1090
    source "${results_dir}/gr_election_internal.env" 2>/dev/null || true
    if [[ -n "${GR_ELECTION_FROM_TRIGGER_SEC:-}" ]]; then
      min_after_rel="${GR_ELECTION_FROM_TRIGGER_SEC}"
    fi
  fi

  python3 - "${stats_file}" "${out_env}" "${monitor_offset}" "${wall_trigger}" "${target_server}" "${elected_pod}" "${min_after_rel}" <<'PY'
import sys
from pathlib import Path

stats_path = Path(sys.argv[1])
out_env = Path(sys.argv[2])
monitor_offset = float(sys.argv[3])
wall_trigger = float(sys.argv[4])
target_server = sys.argv[5].strip()
elected_pod = sys.argv[6].strip()
min_after = float(sys.argv[7]) if sys.argv[7] else 0.0

last_status: dict[str, str] = {}
best_transition = None
best_up = None

for line in stats_path.read_text(encoding="utf-8", errors="replace").splitlines():
    if not line or line.startswith("timestamp_utc"):
        continue
    parts = line.split("\t")
    if len(parts) < 7:
        continue
    _ts, elapsed_s, haproxy_pod, poll_ok, server, status = parts[:6]
    if poll_ok != "1" or server in ("", "ERROR"):
        continue
    prev = last_status.get(server)
    last_status[server] = status
    if status != "UP":
        continue
    if target_server and server != target_server:
        continue
    try:
        elapsed = float(elapsed_s) - monitor_offset
    except ValueError:
        continue
    rel = elapsed - wall_trigger
    if rel < min_after:
        continue
    key = (rel, haproxy_pod, server)
    if prev is not None and prev != "UP":
        if best_transition is None or key < best_transition[0]:
            best_transition = (key, haproxy_pod, server, "down_to_up")
    if best_up is None or key < best_up[0]:
        best_up = (key, haproxy_pod, server, "up")

pick = best_transition or best_up
if pick is None:
    sys.exit(1)

rel, haproxy_pod, server, mode = pick[0][0], pick[0][1], pick[0][2], pick[3]
lines = [
    f"HAPROXY_PRIMARY_UP_FROM_TRIGGER_SEC={rel:.3f}",
    f"HAPROXY_PRIMARY_UP_FROM_TRIGGER_MS={int(round(rel * 1000))}",
    f"HAPROXY_PRIMARY_UP_SERVER={server}",
    f"HAPROXY_PRIMARY_UP_POD={haproxy_pod}",
    "HAPROXY_PRIMARY_UP_SOURCE=haproxy_stats_monitor",
    f"HAPROXY_PRIMARY_UP_MODE={mode}",
]
if elected_pod:
    lines.append(f"HAPROXY_PRIMARY_UP_ELECTED_POD={elected_pod}")
out_env.write_text("\n".join(lines) + "\n", encoding="utf-8")
print(f"Parsed HAProxy primary UP: {rel:.3f}s on {server} ({haproxy_pod}, {mode})")
PY
}

# Restart GR + K8s pod monitors after kubeconfig is available (Advanced prepare step).
failover_start_advanced_cluster_monitors() {
  local results_dir="${1:?results dir required}"
  local kubeconfig=""

  command -v kubectl >/dev/null 2>&1 || return 0
  kubeconfig="$(_failover_resolve_kubeconfig "${results_dir}")" || {
    echo "Advanced cluster monitors: skipped (no kubeconfig yet)" >&2
    return 0
  }

  if [[ "${kubeconfig}" != "${results_dir}/kubeconfig" ]]; then
    cp "${kubeconfig}" "${results_dir}/kubeconfig"
    chmod 600 "${results_dir}/kubeconfig"
    kubeconfig="${results_dir}/kubeconfig"
  fi

  echo "--- Starting Advanced cluster monitors (GR pod + K8s readiness + HAProxy stats) ---"
  stop_gr_pod_monitor "${results_dir}"
  stop_k8s_pods_monitor "${results_dir}"
  stop_haproxy_stats_monitor "${results_dir}"
  if [[ "${FAILOVER_GR_POD_MONITOR:-1}" == "1" ]]; then
    start_gr_pod_monitor "${results_dir}"
  fi
  if [[ "${FAILOVER_K8S_POD_MONITOR:-1}" == "1" ]]; then
    start_k8s_pods_monitor "${results_dir}"
  fi
  if [[ "${FAILOVER_HAPROXY_STATS_MONITOR:-1}" == "1" ]]; then
    start_haproxy_stats_monitor "${results_dir}"
  fi
}

_failover_resolve_kubeconfig() {
  local results_dir="${1:-}"
  local path=""

  if [[ -n "${results_dir}" && -f "${results_dir}/kubeconfig" ]]; then
    echo "${results_dir}/kubeconfig"
    return 0
  fi
  if [[ -n "${ADVANCED_KUBECONFIG_PATH:-}" ]]; then
    path="${ADVANCED_KUBECONFIG_PATH}"
    [[ "${path}" != /* ]] && path="${BENCH_ROOT}/${path#./}"
    if [[ -f "${path}" ]]; then
      echo "${path}"
      return 0
    fi
  fi
  return 1
}

# Read live HA_SERVER_OPTIONS from the PerconaServerMySQL CR into edition_dir/haproxy_health.env.
# Always safe to call (read-only); used for HTML run-metadata even when apply is disabled.
capture_haproxy_health_metadata() {
  local edition_dir="${1:-}"
  local ns="${ADVANCED_K8S_NAMESPACE:-}"
  local cr="${ADVANCED_PSMYSQL_CR_NAME:-}"
  local kubeconfig=""
  local server_options=""
  local inter_ms="" interval_sec="" rise="" fall=""

  if [[ -z "${cr}" || -z "${ns}" ]]; then
    echo "HAProxy health metadata: skipped (set ADVANCED_PSMYSQL_CR_NAME and ADVANCED_K8S_NAMESPACE)" >&2
    return 0
  fi

  if ! kubeconfig="$(_failover_resolve_kubeconfig "${edition_dir}")"; then
    echo "HAProxy health metadata: skipped (no kubeconfig)" >&2
    return 0
  fi

  command -v kubectl >/dev/null 2>&1 || {
    echo "HAProxy health metadata: skipped (kubectl not found)" >&2
    return 0
  }

  local -a kubectl=()
  mapfile -t kubectl < <(_failover_kubectl_cmd "${kubeconfig}")

  server_options="$("${kubectl[@]}" get "perconaservermysql" "${cr}" -n "${ns}" \
    -o jsonpath='{.spec.proxy.haproxy.env[?(@.name=="HA_SERVER_OPTIONS")].value}' 2>/dev/null || true)"
  server_options="$(echo "${server_options}" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

  if [[ -z "${server_options}" ]]; then
    echo "HAProxy health metadata: HA_SERVER_OPTIONS not set on ${cr}" >&2
    return 0
  fi

  if [[ "${server_options}" =~ inter[[:space:]]+([0-9]+) ]]; then
    inter_ms="${BASH_REMATCH[1]}"
    interval_sec=$((inter_ms / 1000))
  fi
  if [[ "${server_options}" =~ rise[[:space:]]+([0-9]+) ]]; then
    rise="${BASH_REMATCH[1]}"
  fi
  if [[ "${server_options}" =~ fall[[:space:]]+([0-9]+) ]]; then
    fall="${BASH_REMATCH[1]}"
  fi

  if [[ -n "${edition_dir}" ]]; then
    mkdir -p "${edition_dir}"
    {
      echo "HA_SERVER_OPTIONS=${server_options}"
      [[ -n "${inter_ms}" ]] && echo "HAPROXY_CHECK_INTER_MS=${inter_ms}"
      [[ -n "${interval_sec}" ]] && echo "HAPROXY_HEALTH_CHECK_INTERVAL_SEC=${interval_sec}"
      [[ -n "${rise}" ]] && echo "HAPROXY_HEALTH_CHECK_RISE=${rise}"
      [[ -n "${fall}" ]] && echo "HAPROXY_HEALTH_CHECK_FALL=${fall}"
      echo "ADVANCED_PSMYSQL_CR_NAME=${cr}"
      echo "ADVANCED_K8S_NAMESPACE=${ns}"
      echo "HAPROXY_HEALTH_CAPTURE_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      echo "HAPROXY_HEALTH_CAPTURE_SOURCE=perconaservermysql_cr"
    } > "${edition_dir}/haproxy_health.env"
  fi

  echo "HAProxy health metadata: ${server_options}"
  echo "  wrote ${edition_dir}/haproxy_health.env"
  return 0
}

# Patch PerconaServerMySQL HA_SERVER_OPTIONS (HAProxy backend check inter/rise/fall).
# Requires ADVANCED_K8S_NAMESPACE, ADVANCED_PSMYSQL_CR_NAME, and a kubeconfig on the droplet.
apply_haproxy_health_check() {
  local edition_dir="${1:-}"

  [[ "${HAPROXY_APPLY_BEFORE_FAILOVER:-1}" == "1" ]] || return 0

  local interval_sec="${HAPROXY_HEALTH_CHECK_INTERVAL_SEC:-2}"
  local rise="${HAPROXY_HEALTH_CHECK_RISE:-1}"
  local fall="${HAPROXY_HEALTH_CHECK_FALL:-1}"
  local ns="${ADVANCED_K8S_NAMESPACE:-}"
  local cr="${ADVANCED_PSMYSQL_CR_NAME:-}"
  local wait_sec="${HAPROXY_APPLY_WAIT_SEC:-90}"
  local kubeconfig=""

  if [[ -z "${cr}" || -z "${ns}" ]]; then
    echo "HAProxy health check: skipped (set ADVANCED_PSMYSQL_CR_NAME and ADVANCED_K8S_NAMESPACE)" >&2
    return 0
  fi

  if ! kubeconfig="$(_failover_resolve_kubeconfig "${edition_dir}")"; then
    echo "HAProxy health check: skipped (no kubeconfig — set ADVANCED_KUBECONFIG_PATH on droplet)" >&2
    return 0
  fi

  if ! [[ "${interval_sec}" =~ ^[0-9]+$ ]] || (( interval_sec < 2 || interval_sec > 10 )); then
    echo "ERROR: HAPROXY_HEALTH_CHECK_INTERVAL_SEC must be an integer 2–10 (seconds)" >&2
    return 1
  fi

  command -v kubectl >/dev/null 2>&1 || {
    echo "ERROR: kubectl not found — cannot apply HAProxy health check" >&2
    return 1
  }

  local inter_ms=$((interval_sec * 1000))
  local server_options="check inter ${inter_ms} rise ${rise} fall ${fall} weight 1"
  local -a kubectl=()
  mapfile -t kubectl < <(_failover_kubectl_cmd "${kubeconfig}")

  echo "--- HAProxy health check: inter=${interval_sec}s (${inter_ms}ms) rise=${rise} fall=${fall} ---"
  echo "    CR: ${cr}  namespace: ${ns}"
  echo "    HA_SERVER_OPTIONS=${server_options}"

  if ! python3 - "${cr}" "${ns}" "${server_options}" "${kubeconfig}" "${ADVANCED_K8S_CONTEXT:-}" <<'PY'
import json
import subprocess
import sys

cr, ns, server_options, kubeconfig, context = sys.argv[1:6]
base = ["kubectl", f"--kubeconfig={kubeconfig}"]
if context:
    base.extend(["--context", context])

def run(cmd):
    subprocess.run(cmd, check=True, capture_output=True, text=True)

get_cmd = base + ["get", "perconaservermysql", cr, "-n", ns, "-o", "json"]
doc = json.loads(subprocess.check_output(get_cmd, text=True))
proxy = doc.setdefault("spec", {}).setdefault("proxy", {}).setdefault("haproxy", {})
env = proxy.get("env") or []
updated = False
for item in env:
    if item.get("name") == "HA_SERVER_OPTIONS":
        item["value"] = server_options
        updated = True
        break
if not updated:
    env.append({"name": "HA_SERVER_OPTIONS", "value": server_options})
proxy["env"] = env

apply_cmd = base + ["apply", "-f", "-"]
subprocess.run(apply_cmd, input=json.dumps(doc), check=True, text=True)
PY
  then
    echo "ERROR: failed to patch PerconaServerMySQL ${cr}" >&2
    return 1
  fi

  if [[ -n "${edition_dir}" ]]; then
    mkdir -p "${edition_dir}"
    {
      echo "HAPROXY_HEALTH_CHECK_INTERVAL_SEC=${interval_sec}"
      echo "HAPROXY_CHECK_INTER_MS=${inter_ms}"
      echo "HA_SERVER_OPTIONS=${server_options}"
      echo "ADVANCED_PSMYSQL_CR_NAME=${cr}"
      echo "ADVANCED_K8S_NAMESPACE=${ns}"
      echo "HAPROXY_APPLY_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "${edition_dir}/haproxy_health.env"
  fi

  if (( wait_sec > 0 )); then
    echo "Waiting up to ${wait_sec}s for HAProxy to reconcile..."
    local deadline=$((SECONDS + wait_sec)) state=""
    while (( SECONDS < deadline )); do
      state="$("${kubectl[@]}" get "perconaservermysql" "${cr}" -n "${ns}" \
        -o jsonpath='{.status.haproxy.state}' 2>/dev/null || true)"
      if [[ "${state}" == "ready" ]]; then
        echo "HAProxy state: ready"
        return 0
      fi
      sleep 5
    done
    echo "WARNING: HAProxy not ready after ${wait_sec}s (state=${state:-unknown}) — continuing" >&2
  fi

  return 0
}

_failover_kubectl_resource_exists() {
  local kubeconfig="${1:?kubeconfig required}"
  local resource="${2:?resource required}"
  local name="${3:?name required}"
  local ns="${4:?namespace required}"
  local -a kubectl=()
  mapfile -t kubectl < <(_failover_kubectl_cmd "${kubeconfig}")
  "${kubectl[@]}" get "${resource}" "${name}" -n "${ns}" >/dev/null 2>&1
}

_failover_pmm_cr_spec() {
  # Prints: enabled serverHost (e.g. "true 10.0.0.5" or "false ")
  local kubeconfig="${1:?kubeconfig required}"
  local cr="${2:?cr required}"
  local ns="${3:?namespace required}"
  local -a kubectl=()
  mapfile -t kubectl < <(_failover_kubectl_cmd "${kubeconfig}")
  "${kubectl[@]}" get perconaservermysql "${cr}" -n "${ns}" \
    -o jsonpath='{.spec.pmm.enabled}{" "}{.spec.pmm.serverHost}' 2>/dev/null || true
}

_failover_pmm_enabled_on_cr() {
  local spec
  spec="$(_failover_pmm_cr_spec "$@")"
  [[ "${spec%% *}" == "true" ]]
}

# Enable PMM on Advanced cluster (secrets + PerconaServerMySQL spec). Idempotent: skips when
# spec.pmm.enabled is already true. Requires ADVANCED_PSMYSQL_CR_NAME, ADVANCED_K8S_NAMESPACE,
# PMM_SERVER_HOST, PMM_SERVER_TOKEN when applying.
ensure_pmm_integration() {
  local edition_dir="${1:-}"
  local ns="${ADVANCED_K8S_NAMESPACE:-}"
  local cr="${ADVANCED_PSMYSQL_CR_NAME:-}"
  local kubeconfig=""
  local apply="${PMM_APPLY_BEFORE_FAILOVER:-0}"
  local require="${PMM_REQUIRE_INTEGRATION:-0}"
  local token="${PMM_SERVER_TOKEN:-}"
  local server_host="${PMM_SERVER_HOST:-}"
  local client_image="${PMM_CLIENT_IMAGE:-percona/pmm-client:3.7.0}"
  local rollout_timeout="${PMM_ROLLOUT_TIMEOUT_SEC:-300}"
  local -a kubectl=()

  if [[ -z "${cr}" || -z "${ns}" ]]; then
    if [[ "${require}" == "1" ]]; then
      echo "ERROR: PMM_REQUIRE_INTEGRATION=1 but ADVANCED_PSMYSQL_CR_NAME or ADVANCED_K8S_NAMESPACE is unset" >&2
      return 1
    fi
    echo "PMM integration: skipped (set ADVANCED_PSMYSQL_CR_NAME and ADVANCED_K8S_NAMESPACE)" >&2
    return 0
  fi

  if ! kubeconfig="$(_failover_resolve_kubeconfig "${edition_dir}")"; then
    if [[ "${require}" == "1" || "${apply}" == "1" ]]; then
      echo "ERROR: PMM check/apply requires kubeconfig (set ADVANCED_KUBECONFIG_PATH on droplet)" >&2
      return 1
    fi
    echo "PMM integration: skipped (no kubeconfig)" >&2
    return 0
  fi

  command -v kubectl >/dev/null 2>&1 || {
    echo "ERROR: kubectl not found — cannot check or apply PMM integration" >&2
    return 1
  }

  mapfile -t kubectl < <(_failover_kubectl_cmd "${kubeconfig}")

  if _failover_pmm_enabled_on_cr "${kubeconfig}" "${cr}" "${ns}"; then
    local current_host=""
    current_host="$(_failover_pmm_cr_spec "${kubeconfig}" "${cr}" "${ns}")"
    current_host="${current_host#* }"
    echo "--- PMM integration: already enabled on CR ${cr} (serverHost=${current_host:-unknown}) — skipping ---"
    return 0
  fi

  if [[ "${apply}" != "1" ]]; then
    if [[ "${require}" == "1" ]]; then
      echo "ERROR: PMM is not enabled on cluster ${cr} and PMM_APPLY_BEFORE_FAILOVER=0." >&2
      echo "       Set PMM_APPLY_BEFORE_FAILOVER=1 with PMM_SERVER_HOST + PMM_SERVER_TOKEN," >&2
      echo "       or integrate PMM manually, or set PMM_REQUIRE_INTEGRATION=0 to continue." >&2
      return 1
    fi
    echo "--- PMM integration: not enabled on CR ${cr} (PMM_APPLY_BEFORE_FAILOVER=0) — continuing ---"
    return 0
  fi

  if [[ -z "${server_host}" ]]; then
    echo "ERROR: PMM_APPLY_BEFORE_FAILOVER=1 requires PMM_SERVER_HOST" >&2
    return 1
  fi
  if [[ -z "${token}" ]]; then
    echo "ERROR: PMM_APPLY_BEFORE_FAILOVER=1 requires PMM_SERVER_TOKEN" >&2
    return 1
  fi
  if ! [[ "${rollout_timeout}" =~ ^[0-9]+$ ]] || (( rollout_timeout < 1 )); then
    echo "ERROR: PMM_ROLLOUT_TIMEOUT_SEC must be a positive integer" >&2
    return 1
  fi

  echo "--- PMM integration: enabling on CR ${cr} (namespace ${ns}) ---"
  echo "    PMM serverHost: ${server_host}"
  echo "    PMM client image: ${client_image}"

  local cluster_secret="${cr}-secrets"
  local internal_secret="internal-${cr}"

  if ! _failover_kubectl_resource_exists "${kubeconfig}" secret "${cluster_secret}" "${ns}"; then
    echo "ERROR: secret ${cluster_secret} not found in namespace ${ns}" >&2
    return 1
  fi

  echo "Patching secret ${cluster_secret} (pmmservertoken)..."
  if ! python3 - "${cluster_secret}" "${ns}" "${token}" "${kubeconfig}" "${ADVANCED_K8S_CONTEXT:-}" <<'PY'
import json
import subprocess
import sys

name, ns, token, kubeconfig, context = sys.argv[1:6]
base = ["kubectl", f"--kubeconfig={kubeconfig}"]
if context:
    base.extend(["--context", context])
patch = json.dumps({"stringData": {"pmmservertoken": token}})
subprocess.run(
    base + ["patch", "secret", name, "-n", ns, "--type", "merge", "-p", patch],
    check=True,
    text=True,
)
PY
  then
    echo "ERROR: failed to patch secret ${cluster_secret}" >&2
    return 1
  fi

  if _failover_kubectl_resource_exists "${kubeconfig}" secret "${internal_secret}" "${ns}"; then
    echo "Patching secret ${internal_secret} (pmmservertoken)..."
    if ! python3 - "${internal_secret}" "${ns}" "${token}" "${kubeconfig}" "${ADVANCED_K8S_CONTEXT:-}" <<'PY'
import json
import subprocess
import sys

name, ns, token, kubeconfig, context = sys.argv[1:6]
base = ["kubectl", f"--kubeconfig={kubeconfig}"]
if context:
    base.extend(["--context", context])
patch = json.dumps({"stringData": {"pmmservertoken": token}})
subprocess.run(
    base + ["patch", "secret", name, "-n", ns, "--type", "merge", "-p", patch],
    check=True,
    text=True,
)
PY
    then
      echo "ERROR: failed to patch secret ${internal_secret}" >&2
      return 1
    fi
  else
    echo "WARNING: secret ${internal_secret} not found — skipping internal secret patch" >&2
  fi

  echo "Patching PerconaServerMySQL ${cr} (spec.pmm.enabled=true)..."
  if ! python3 - "${cr}" "${ns}" "${server_host}" "${client_image}" "${kubeconfig}" "${ADVANCED_K8S_CONTEXT:-}" <<'PY'
import json
import subprocess
import sys

cr, ns, server_host, client_image, kubeconfig, context = sys.argv[1:7]
base = ["kubectl", f"--kubeconfig={kubeconfig}"]
if context:
    base.extend(["--context", context])
patch = {
    "spec": {
        "pmm": {
            "enabled": True,
            "image": client_image,
            "serverHost": server_host,
        }
    }
}
subprocess.run(
    base
    + [
        "patch",
        "perconaservermysql",
        cr,
        "-n",
        ns,
        "--type",
        "merge",
        "-p",
        json.dumps(patch),
    ],
    check=True,
    text=True,
)
PY
  then
    echo "ERROR: failed to patch PerconaServerMySQL ${cr}" >&2
    return 1
  fi

  local sts="${cr}-mysql"
  echo "Waiting for MySQL StatefulSet rollout (${sts}, timeout=${rollout_timeout}s)..."
  if ! "${kubectl[@]}" rollout status "statefulset/${sts}" -n "${ns}" --timeout="${rollout_timeout}s"; then
    echo "ERROR: rollout of statefulset/${sts} did not complete within ${rollout_timeout}s" >&2
    return 1
  fi

  if ! _failover_pmm_enabled_on_cr "${kubeconfig}" "${cr}" "${ns}"; then
    echo "ERROR: PMM still not reported as enabled on CR after rollout" >&2
    return 1
  fi

  echo "PMM integration: complete (CR ${cr}, serverHost=${server_host})"

  if [[ -n "${edition_dir}" ]]; then
    mkdir -p "${edition_dir}"
    {
      echo "PMM_APPLY_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      echo "ADVANCED_PSMYSQL_CR_NAME=${cr}"
      echo "ADVANCED_K8S_NAMESPACE=${ns}"
      echo "PMM_SERVER_HOST=${server_host}"
      echo "PMM_CLIENT_IMAGE=${client_image}"
      echo "PMM_CLUSTER_SECRET=${cluster_secret}"
      echo "PMM_INTERNAL_SECRET=${internal_secret}"
    } > "${edition_dir}/pmm_integration.env"
  fi

  return 0
}

_failover_snapshot_operator_logs() {
  local results_dir="${1:?results dir required}"
  local since_utc="${2:-}"

  [[ "${FAILOVER_COLLECT_OPERATOR_LOGS:-1}" == "1" ]] || return 0
  [[ -n "${since_utc}" ]] || return 0
  command -v kubectl >/dev/null 2>&1 || return 0

  local kubeconfig="${results_dir}/kubeconfig"
  if [[ ! -f "${kubeconfig}" && -n "${ADVANCED_KUBECONFIG_PATH:-}" && -f "${ADVANCED_KUBECONFIG_PATH}" ]]; then
    kubeconfig="${ADVANCED_KUBECONFIG_PATH}"
  fi
  [[ -f "${kubeconfig}" ]] || return 0

  local ns="${ADVANCED_K8S_NAMESPACE:-percona}"
  local out_file="${results_dir}/operator_failover.log"
  local -a kubectl=()
  mapfile -t kubectl < <(_failover_kubectl_cmd "${kubeconfig}")
  local label="app.kubernetes.io/name=percona-server-mysql-operator"
  local -a operator_pods=()

  while IFS= read -r pod; do
    [[ -n "${pod}" ]] && operator_pods+=("${pod}")
  done < <("${kubectl[@]}" get pods -n "${ns}" -l "${label}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)

  {
    echo "=== Operator logs since ${since_utc} @ $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
    if ((${#operator_pods[@]} > 0)); then
      local pod
      for pod in "${operator_pods[@]}"; do
        echo "=== pod/${pod} ==="
        "${kubectl[@]}" logs -n "${ns}" "${pod}" \
          --since-time="${since_utc}" --timestamps 2>&1 || true
        echo ""
      done
    else
      "${kubectl[@]}" logs -n "${ns}" -l "${label}" \
        --since-time="${since_utc}" --timestamps 2>&1 || true
    fi
    echo ""
  } > "${out_file}"

  if ! grep -qiE 'groupReplicationStatus|Assigning primary label' "${out_file}" 2>/dev/null; then
    {
      echo "=== Operator logs (all namespaces) since ${since_utc} ==="
      "${kubectl[@]}" logs -A -l "${label}" \
        --since-time="${since_utc}" --timestamps --max-log-requests=10 2>&1 || true
      echo ""
    } >> "${out_file}"
  fi
}

_failover_snapshot_mysql_gr_logs() {
  local results_dir="${1:?results dir required}"
  local since_utc="${2:-}"

  [[ -n "${since_utc}" ]] || return 0
  command -v kubectl >/dev/null 2>&1 || return 0

  local kubeconfig="${results_dir}/kubeconfig"
  if [[ ! -f "${kubeconfig}" && -n "${ADVANCED_KUBECONFIG_PATH:-}" && -f "${ADVANCED_KUBECONFIG_PATH}" ]]; then
    kubeconfig="${ADVANCED_KUBECONFIG_PATH}"
  fi
  [[ -f "${kubeconfig}" ]] || return 0

  local ns="${ADVANCED_K8S_NAMESPACE:-percona}"
  local -a kubectl pod
  mapfile -t kubectl < <(_failover_kubectl_cmd "${kubeconfig}")

  while IFS= read -r pod; do
    [[ -n "${pod}" ]] || continue
    {
      echo "=== MySQL GR logs: ${pod} since ${since_utc} @ $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
      "${kubectl[@]}" logs -n "${ns}" "${pod}" -c mysql \
        --since-time="${since_utc}" --timestamps 2>&1 || true
      echo ""
    } > "${results_dir}/mysql_gr_election_${pod}.log"
  done < <(_failover_list_mysql_pods "${kubeconfig}" "${ns}")
}

_failover_parse_gr_election_from_mysql_logs() {
  local results_dir="${1:?results dir required}"
  local out_env="${results_dir}/gr_election_internal.env"
  local event_file="${results_dir}/failover_event.txt"
  local trigger_epoch=""

  if [[ -f "${event_file}" ]]; then
    trigger_epoch=$(grep -E '^FAILOVER_TRIGGER_EPOCH=' "${event_file}" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  fi
  if [[ -z "${trigger_epoch}" ]]; then
    local trigger_utc=""
    trigger_utc=$(grep -E '^FAILOVER_TRIGGER_UTC=' "${event_file}" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    [[ -n "${trigger_utc}" ]] || return 1
    trigger_epoch=$(python3 -c "
from datetime import datetime
print(datetime.fromisoformat('${trigger_utc}'.replace('Z', '+00:00')).timestamp())
" 2>/dev/null || true)
    [[ -n "${trigger_epoch}" ]] || return 1
  fi

  python3 - "${trigger_epoch}" "${results_dir}" "${out_env}" <<'PY'
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

trigger_epoch = float(sys.argv[1])
results_dir = Path(sys.argv[2])
out_env = Path(sys.argv[3])

ts_re = re.compile(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+Z)")
writable_re = re.compile(r"This server is working as primary member", re.I)
elected_re = re.compile(r"A new primary with address (\S+) was elected", re.I)


def pod_hint_from_path(log_path: Path) -> str:
    hint = log_path.name.replace("mysql_gr_election_", "").replace(".log", "")
    return "" if hint == "mysql_gr_election" else hint


def pod_matches(hint: str, target: str) -> bool:
    if not hint or not target:
        return False
    return hint in target or target in hint


election_ts = None
election_pod = ""
writable_ts = None

for log_path in sorted(results_dir.glob("mysql_gr_election*.log")):
    hint = pod_hint_from_path(log_path)
    with log_path.open(encoding="utf-8", errors="replace") as handle:
        for line in handle:
            match = ts_re.match(line)
            if not match:
                continue
            ts = datetime.fromisoformat(match.group(1).replace("Z", "+00:00"))
            if ts.timestamp() < trigger_epoch:
                continue
            elected = elected_re.search(line)
            if elected:
                pod = elected.group(1).split(".")[0]
                if election_ts is None or ts < election_ts:
                    election_ts = ts
                    election_pod = pod

if election_ts is None:
    sys.exit(1)

for log_path in sorted(results_dir.glob("mysql_gr_election*.log")):
    hint = pod_hint_from_path(log_path)
    if election_pod and hint and not pod_matches(hint, election_pod):
        continue
    with log_path.open(encoding="utf-8", errors="replace") as handle:
        for line in handle:
            if not writable_re.search(line):
                continue
            match = ts_re.match(line)
            if not match:
                continue
            ts = datetime.fromisoformat(match.group(1).replace("Z", "+00:00"))
            if ts.timestamp() < trigger_epoch:
                continue
            if writable_ts is None or ts < writable_ts:
                writable_ts = ts

election_rel = election_ts.timestamp() - trigger_epoch
election_ms = int(round(election_rel * 1000))
election_utc = election_ts.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.") + (
    f"{election_ts.microsecond // 1000:03d}Z"
)

lines = [
    f"GR_ELECTION_FROM_TRIGGER_SEC={election_rel:.3f}",
    f"GR_ELECTION_FROM_TRIGGER_MS={election_ms}",
    f"GR_ELECTION_UTC={election_utc}",
    f"GR_ELECTION_POD={election_pod}",
    "GR_ELECTION_SOURCE=mysql_pod_logs",
]
if writable_ts is not None:
    writable_rel = writable_ts.timestamp() - trigger_epoch
    writable_ms = int(round(writable_rel * 1000))
    writable_utc = writable_ts.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.") + (
        f"{writable_ts.microsecond // 1000:03d}Z"
    )
    lines.extend(
        [
            f"GR_WRITABLE_FROM_TRIGGER_SEC={writable_rel:.3f}",
            f"GR_WRITABLE_FROM_TRIGGER_MS={writable_ms}",
            f"GR_WRITABLE_UTC={writable_utc}",
            "GR_WRITABLE_SOURCE=mysql_pod_logs",
        ]
    )

out_env.write_text("\n".join(lines) + "\n", encoding="utf-8")
print(
    f"Parsed GR election: {election_rel:.3f}s ({election_ms} ms) on {election_pod or 'unknown'}"
)
if writable_ts is not None:
    print(f"Parsed GR writable primary: {writable_rel:.3f}s ({writable_ms} ms)")
PY
}

_failover_backfill_observability_artifacts() {
  local results_dir="${1:?results dir required}"
  local event_file="${results_dir}/failover_event.txt"
  local trigger_utc=""

  [[ -f "${event_file}" ]] || return 0
  trigger_utc=$(grep -E '^FAILOVER_TRIGGER_UTC=' "${event_file}" | tail -1 | cut -d= -f2- || true)
  [[ -n "${trigger_utc}" ]] || return 0

  local operator_log="${results_dir}/operator_failover.log"
  if [[ ! -s "${operator_log}" ]] \
    || ! grep -qiE 'groupReplicationStatus|Assigning primary label' "${operator_log}" 2>/dev/null; then
    echo "--- Backfilling operator_failover.log since ${trigger_utc} ---"
    _failover_snapshot_operator_logs "${results_dir}" "${trigger_utc}"
  fi

  local have_mysql_logs=0
  for _f in "${results_dir}"/mysql_gr_election*.log; do
    [[ -f "${_f}" ]] && have_mysql_logs=1 && break
  done
  if [[ "${have_mysql_logs}" -eq 0 ]]; then
    echo "--- Backfilling mysql GR pod logs since ${trigger_utc} ---"
    _failover_snapshot_mysql_gr_logs "${results_dir}" "${trigger_utc}"
  fi
  if _failover_parse_gr_election_from_mysql_logs "${results_dir}"; then
    :
  else
    echo "WARNING: could not parse GR election from mysql pod logs" >&2
  fi
}

_failover_collect_gr_timing_artifacts() {
  local results_dir="${1:?results dir required}"
  local trigger_utc="${2:-}"

  [[ -n "${trigger_utc}" ]] || return 0
  _failover_snapshot_mysql_gr_logs "${results_dir}" "${trigger_utc}" || true
  _failover_parse_gr_election_from_mysql_logs "${results_dir}" \
    || echo "WARNING: GR election timing not parsed from mysql pod logs" >&2
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
    # GR/K8s pod monitors need scenario kubeconfig; when Advanced trigger prepare runs,
    # they start once in failover_start_advanced_cluster_monitors (avoid stop/restart race).
    if ! failover_advanced_trigger_active; then
      if [[ "${FAILOVER_GR_POD_MONITOR:-1}" == "1" ]]; then
        start_gr_pod_monitor "${results_dir}"
      fi
      if [[ "${FAILOVER_K8S_POD_MONITOR:-1}" == "1" ]]; then
        start_k8s_pods_monitor "${results_dir}"
      fi
      if [[ "${FAILOVER_HAPROXY_STATS_MONITOR:-1}" == "1" ]]; then
        start_haproxy_stats_monitor "${results_dir}"
      fi
    fi
  fi
}

stop_failover_watchers() {
  local results_dir="${1:?results dir required}"

  stop_k8s_event_collector "${results_dir}"
  stop_gr_pod_monitor "${results_dir}"
  stop_k8s_pods_monitor "${results_dir}"
  stop_haproxy_stats_monitor "${results_dir}"
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
  echo "FAILOVER_WARMUP_SEC=${FAILOVER_WARMUP_SEC}" >> "${results_dir}/sysbench_timing.txt"
  echo "FAILOVER_BASELINE_SEC=${FAILOVER_BASELINE_SEC}" >> "${results_dir}/sysbench_timing.txt"
  echo "FAILOVER_OBSERVE_SEC=${FAILOVER_OBSERVE_SEC}" >> "${results_dir}/sysbench_timing.txt"
  echo "FAILOVER_TRIGGER_WALL_SECOND=$(failover_trigger_second)" >> "${results_dir}/sysbench_timing.txt"
  echo "FAILOVER_TRIGGER_LOG_SECOND=$(failover_trigger_log_second)" >> "${results_dir}/sysbench_timing.txt"
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
  echo "TPCC_THREADS=${FAILOVER_THREADS}" >> "${results_dir}/sysbench_timing.txt"
  echo "PREP_THREADS=${PREP_THREADS:-16}" >> "${results_dir}/sysbench_timing.txt"
  _append_mysql_runtime_to_timing "${results_dir}"

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

failover_gr_readiness_gate_enabled() {
  [[ "${FAILOVER_GR_READINESS_GATE:-1}" == "1" ]]
}

_failover_query_gr_members() {
  mysql_cli_timed -N -B -e "
    SELECT MEMBER_HOST, MEMBER_STATE, MEMBER_ROLE
      FROM performance_schema.replication_group_members
     ORDER BY MEMBER_HOST;"
}

# Evaluate GR topology for pre-failover gate.
# Sets GR_READY_SUMMARY. Returns 0=ready, 1=not ready, 2=query empty/failed.
_failover_eval_gr_cluster_readiness() {
  local tsv="${1:?tsv required}"
  local host state role
  local total=0 online=0 recovering=0 primary=0
  local expected="${FAILOVER_GR_EXPECTED_MEMBERS:-3}"
  local -a bad=()

  GR_READY_SUMMARY=""
  while IFS=$'\t' read -r host state role || [[ -n "${host}" ]]; do
    [[ -z "${host}" ]] && continue
    total=$((total + 1))
    state="${state^^}"
    role="${role^^}"
    if [[ "${state}" == "ONLINE" ]]; then
      online=$((online + 1))
    fi
    if [[ "${state}" == "RECOVERING" ]]; then
      recovering=$((recovering + 1))
    fi
    if [[ "${role}" == "PRIMARY" ]]; then
      primary=$((primary + 1))
    fi
    if [[ "${state}" != "ONLINE" ]]; then
      bad+=("${host}:${state}/${role}")
    fi
  done <<< "${tsv}"

  if (( total == 0 )); then
    GR_READY_SUMMARY="no GR members returned"
    return 2
  fi
  if (( recovering > 0 )); then
    GR_READY_SUMMARY="${recovering} member(s) RECOVERING"
    return 1
  fi
  if (( online != total )); then
    GR_READY_SUMMARY="only ${online}/${total} ONLINE (${bad[*]})"
    return 1
  fi
  if (( primary != 1 )); then
    GR_READY_SUMMARY="expected 1 PRIMARY, found ${primary}"
    return 1
  fi
  if [[ "${expected}" =~ ^[0-9]+$ ]] && (( expected > 0 )) && (( online != expected )); then
    GR_READY_SUMMARY="expected ${expected} ONLINE members, found ${online}"
    return 1
  fi
  if [[ "${expected}" =~ ^[0-9]+$ ]] && (( expected > 0 )); then
    GR_READY_SUMMARY="all ${online}/${expected} members ONLINE, 1 PRIMARY"
  else
    GR_READY_SUMMARY="all ${total} members ONLINE, 1 PRIMARY"
  fi
  return 0
}

# Evaluate mysql-* pod readiness for pre-failover gate.
# Sets K8S_READY_SUMMARY. Returns 0=ready, 1=not ready, 2=no pods / query failed.
_failover_eval_k8s_mysql_pods_readiness() {
  local tsv="${1:?tsv required}"
  local expected="${FAILOVER_GR_EXPECTED_MEMBERS:-3}"
  local name phase ready_num ready_den restarts deleting is_target
  local total=0 ready=0
  local -a bad=()

  K8S_READY_SUMMARY=""
  while IFS=$'\t' read -r name phase ready_num ready_den restarts deleting is_target || [[ -n "${name}" ]]; do
    [[ -z "${name}" ]] && continue
    total=$((total + 1))
    phase="${phase:-Unknown}"
    ready_num="${ready_num:-0}"
    ready_den="${ready_den:-0}"
    deleting="${deleting:-0}"
    if [[ "${phase}" == "Running" && "${deleting}" == "0" \
      && "${ready_num}" =~ ^[0-9]+$ && "${ready_den}" =~ ^[0-9]+$ ]] \
      && (( ready_den > 0 )) && (( ready_num == ready_den )); then
      ready=$((ready + 1))
    else
      bad+=("${name}:${phase} ${ready_num}/${ready_den} deleting=${deleting}")
    fi
  done <<< "${tsv}"

  if (( total == 0 )); then
    K8S_READY_SUMMARY="no mysql-* pods returned"
    return 2
  fi
  if (( ready != total )); then
    K8S_READY_SUMMARY="only ${ready}/${total} mysql pods Ready (${bad[*]})"
    return 1
  fi
  if [[ "${expected}" =~ ^[0-9]+$ ]] && (( expected > 0 )) && (( ready != expected )); then
    K8S_READY_SUMMARY="expected ${expected} Ready mysql pods, found ${ready}"
    return 1
  fi
  if [[ "${expected}" =~ ^[0-9]+$ ]] && (( expected > 0 )); then
    K8S_READY_SUMMARY="all ${ready}/${expected} mysql pods Ready"
  else
    K8S_READY_SUMMARY="all ${ready} mysql pods Ready"
  fi
  return 0
}

# Wait until GR (+ optional k8s pods) is stable before firing failover.
wait_for_gr_readiness_before_failover() {
  local results_dir="${1:?results dir required}"
  local log_file="${results_dir}/failover_gr_readiness.log"
  local poll_sec="${FAILOVER_GR_READINESS_POLL_SEC:-2}"
  local timeout_sec="${FAILOVER_GR_READINESS_TIMEOUT_SEC:-600}"
  local abort="${FAILOVER_GR_READINESS_ABORT_ON_TIMEOUT:-1}"
  local expected="${FAILOVER_GR_EXPECTED_MEMBERS:-3}"
  local require_k8s="${FAILOVER_GR_REQUIRE_K8S_PODS_READY:-1}"
  local waited=0 poll_num=0 tsv rc k8s_tsv k8s_rc kubeconfig ns
  local summary=""

  if ! failover_gr_readiness_gate_enabled; then
    return 0
  fi

  echo "=== GR readiness gate (expected ONLINE=${expected}, k8s_pods_ready=${require_k8s}) ===" | tee "${log_file}"
  echo "Poll interval=${poll_sec}s timeout=${timeout_sec}s" | tee -a "${log_file}"

  ns="${ADVANCED_K8S_NAMESPACE:-}"
  kubeconfig=""
  if [[ "${require_k8s}" == "1" ]]; then
    kubeconfig="$(_failover_resolve_kubeconfig "${results_dir}" 2>/dev/null || true)"
  fi

  while (( waited <= timeout_sec )); do
    poll_num=$((poll_num + 1))
    tsv="$(_failover_query_gr_members 2>/dev/null || true)"
    rc=2
    if [[ -n "${tsv}" ]]; then
      _failover_eval_gr_cluster_readiness "${tsv}"
      rc=$?
    else
      GR_READY_SUMMARY="mysql GR query failed"
    fi

    k8s_rc=0
    K8S_READY_SUMMARY="skipped"
    k8s_tsv=""
    if [[ "${require_k8s}" == "1" ]]; then
      k8s_rc=2
      if [[ -z "${ns}" ]]; then
        K8S_READY_SUMMARY="ADVANCED_K8S_NAMESPACE unset"
      elif [[ -z "${kubeconfig}" ]]; then
        K8S_READY_SUMMARY="no kubeconfig (set ADVANCED_KUBECONFIG_PATH)"
      elif ! command -v kubectl >/dev/null 2>&1; then
        K8S_READY_SUMMARY="kubectl not found"
      else
        k8s_tsv="$(_failover_poll_k8s_mysql_pods_once "${kubeconfig}" "${ns}" "" 2>/dev/null || true)"
        if [[ -n "${k8s_tsv}" ]]; then
          _failover_eval_k8s_mysql_pods_readiness "${k8s_tsv}"
          k8s_rc=$?
        else
          K8S_READY_SUMMARY="kubectl mysql pod query failed"
        fi
      fi
    fi

    if (( rc == 0 && k8s_rc == 0 )); then
      summary="${GR_READY_SUMMARY}; ${K8S_READY_SUMMARY}"
    elif (( rc == 0 )); then
      summary="GR ok (${GR_READY_SUMMARY}); k8s not ready (${K8S_READY_SUMMARY})"
    elif (( k8s_rc == 0 )); then
      summary="GR not ready (${GR_READY_SUMMARY}); k8s ok (${K8S_READY_SUMMARY})"
    else
      summary="GR not ready (${GR_READY_SUMMARY}); k8s not ready (${K8S_READY_SUMMARY})"
    fi
    GR_READY_SUMMARY="${summary}"

    {
      local ready_flag=0
      (( rc == 0 && k8s_rc == 0 )) && ready_flag=1
      echo "poll=${poll_num} waited=${waited}s utc=$(date -u +%Y-%m-%dT%H:%M:%SZ) ready=${ready_flag} summary=${GR_READY_SUMMARY}"
      if [[ -n "${tsv}" ]]; then
        while IFS=$'\t' read -r host state role; do
          [[ -z "${host}" ]] && continue
          echo "  GR  ${host}  ${state}  ${role}"
        done <<< "${tsv}"
      fi
      if [[ -n "${k8s_tsv}" ]]; then
        while IFS=$'\t' read -r name phase ready_num ready_den restarts deleting is_target; do
          [[ -z "${name}" ]] && continue
          echo "  K8S ${name}  ${phase}  ${ready_num}/${ready_den}  restarts=${restarts}  deleting=${deleting}"
        done <<< "${k8s_tsv}"
      fi
    } | tee -a "${log_file}"

    if (( rc == 0 && k8s_rc == 0 )); then
      echo "GR readiness gate PASSED after ${waited}s: ${GR_READY_SUMMARY}" | tee -a "${log_file}"
      {
        echo "FAILOVER_GR_READINESS_GATE=passed"
        echo "FAILOVER_GR_READINESS_WAIT_SEC=${waited}"
        echo "FAILOVER_GR_READINESS_SUMMARY=${GR_READY_SUMMARY}"
        echo "FAILOVER_GR_READINESS_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "FAILOVER_GR_EXPECTED_MEMBERS=${expected}"
      } >> "${results_dir}/failover_event.txt"
      return 0
    fi

    if (( waited >= timeout_sec )); then
      break
    fi
    echo "GR not ready (${GR_READY_SUMMARY}); retry in ${poll_sec}s..." | tee -a "${log_file}"
    sleep "${poll_sec}"
    waited=$((waited + poll_sec))
  done

  echo "ERROR: GR readiness gate TIMEOUT after ${timeout_sec}s: ${GR_READY_SUMMARY}" | tee -a "${log_file}"
  {
    echo "FAILOVER_GR_READINESS_GATE=timeout"
    echo "FAILOVER_GR_READINESS_WAIT_SEC=${timeout_sec}"
    echo "FAILOVER_GR_READINESS_SUMMARY=${GR_READY_SUMMARY}"
    echo "FAILOVER_GR_READINESS_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "FAILOVER_GR_EXPECTED_MEMBERS=${expected}"
  } >> "${results_dir}/failover_event.txt"

  if [[ "${abort}" == "1" ]]; then
    return 1
  fi
  echo "WARNING: proceeding despite GR not ready (FAILOVER_GR_READINESS_ABORT_ON_TIMEOUT=0)" \
    | tee -a "${log_file}"
  return 0
}

failover_replica_workers_gate_enabled() {
  [[ "${FAILOVER_REPLICA_WORKERS_GATE:-1}" == "1" ]]
}

_failover_target_replica_parallel_workers() {
  echo "${FAILOVER_REPLICA_PARALLEL_WORKERS:-16}"
}

_failover_replica_workers_gate_prereqs() {
  local results_dir="${1:-}"
  REPLICA_WORKERS_GATE_KUBECONFIG=""
  REPLICA_WORKERS_GATE_NS="${ADVANCED_K8S_NAMESPACE:-}"

  command -v kubectl >/dev/null 2>&1 || {
    REPLICA_WORKERS_GATE_SKIP_REASON="kubectl not found"
    return 1
  }
  [[ -n "${REPLICA_WORKERS_GATE_NS}" ]] || {
    REPLICA_WORKERS_GATE_SKIP_REASON="ADVANCED_K8S_NAMESPACE unset"
    return 1
  }
  if ! REPLICA_WORKERS_GATE_KUBECONFIG="$(_failover_resolve_kubeconfig "${results_dir}")"; then
    REPLICA_WORKERS_GATE_SKIP_REASON="no kubeconfig (set ADVANCED_KUBECONFIG_PATH)"
    return 1
  fi
  return 0
}

_failover_poll_pod_replica_workers_role() {
  local kubeconfig="${1:?kubeconfig required}"
  local ns="${2:?namespace required}"
  local pod="${3:?pod required}"
  local line hostname bp_limit bp_data gr_role replica_workers

  line="$(_failover_poll_pod_buffer_pool_once "${kubeconfig}" "${ns}" "${pod}")"
  [[ -n "${line}" ]] || return 1
  IFS=$'\t' read -r hostname bp_limit bp_data gr_role replica_workers _rest <<< "${line}"
  gr_role="${gr_role^^}"
  printf '%s\t%s\n' "${gr_role}" "${replica_workers}"
}

_failover_mysql_root_exec() {
  local kubeconfig="${1:?kubeconfig required}"
  local ns="${2:?namespace required}"
  local pod="${3:?pod required}"
  local sql="${4:?sql required}"
  local exec_timeout="${5:-90}"
  local -a kubectl
  local container="${ADVANCED_K8S_MYSQL_CONTAINER:-mysql}"

  mapfile -t kubectl < <(_failover_kubectl_cmd "${kubeconfig}")
  _failover_run_timeout "${exec_timeout}" "${kubectl[@]}" exec -n "${ns}" "${pod}" -c "${container}" -- \
    sh -ce 'mysql -uroot -p"$(tr -d "\n" </etc/mysql/mysql-users-secret/root)" -e "$1"' _ "${sql}"
}

_failover_get_pod_server_uuid() {
  local kubeconfig="${1:?kubeconfig required}"
  local ns="${2:?namespace required}"
  local pod="${3:?pod required}"

  # mysql -e prints a header row (e.g. "@@server_uuid"); keep only a UUID-shaped value.
  _failover_mysql_root_exec "${kubeconfig}" "${ns}" "${pod}" "SELECT @@server_uuid;" 30 \
    | awk 'NF && $0 ~ /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/ { print; exit }'
}

_failover_wait_gr_cluster_online() {
  local log_file="${1:-/dev/stderr}"
  local poll_sec="${FAILOVER_REPLICA_WORKERS_POLL_SEC:-2}"
  local timeout_sec="${FAILOVER_REPLICA_WORKERS_TIMEOUT_SEC:-600}"
  local waited=0 poll_num=0 tsv rc

  while (( waited <= timeout_sec )); do
    poll_num=$((poll_num + 1))
    tsv="$(_failover_query_gr_members 2>/dev/null || true)"
    rc=2
    if [[ -n "${tsv}" ]]; then
      _failover_eval_gr_cluster_readiness "${tsv}"
      rc=$?
    else
      GR_READY_SUMMARY="mysql GR query failed"
    fi
    echo "  gr_wait poll=${poll_num} waited=${waited}s summary=${GR_READY_SUMMARY}" >> "${log_file}"
    if (( rc == 0 )); then
      return 0
    fi
    if (( waited >= timeout_sec )); then
      break
    fi
    sleep "${poll_sec}"
    waited=$((waited + poll_sec))
  done
  echo "ERROR: GR not ONLINE after replica_parallel_workers change (${GR_READY_SUMMARY})" >> "${log_file}"
  return 1
}

_failover_capture_replica_workers_snapshot() {
  local kubeconfig="${1:?kubeconfig required}"
  local ns="${2:?namespace required}"
  local out_tsv="${3:?out tsv required}"
  local pod role workers captured_utc

  captured_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  {
    echo "# captured_utc=${captured_utc}"
    echo "# namespace=${ns} kubeconfig=${kubeconfig}"
    echo -e "pod\tgr_role\treplica_parallel_workers"
    while IFS= read -r pod; do
      [[ -n "${pod}" ]] || continue
      if IFS=$'\t' read -r role workers < <(_failover_poll_pod_replica_workers_role "${kubeconfig}" "${ns}" "${pod}"); then
        echo -e "${pod}\t${role}\t${workers}"
      else
        echo -e "${pod}\tERROR\tERROR"
      fi
    done < <(_failover_list_mysql_pods "${kubeconfig}" "${ns}")
  } > "${out_tsv}"
}

_failover_collect_replica_workers_state() {
  local kubeconfig="${1:?kubeconfig required}"
  local ns="${2:?namespace required}"
  local target="${3:?target required}"
  local pod role workers

  REPLICA_WORKERS_PRIMARY_POD=""
  REPLICA_WORKERS_MISMATCH_PODS=()
  REPLICA_WORKERS_READY_PODS=()

  while IFS= read -r pod; do
    [[ -n "${pod}" ]] || continue
    if ! IFS=$'\t' read -r role workers < <(_failover_poll_pod_replica_workers_role "${kubeconfig}" "${ns}" "${pod}"); then
      REPLICA_WORKERS_MISMATCH_PODS+=("${pod}:query_failed")
      continue
    fi
    # Mis-parsed poll (e.g. pod still starting): GR role column holds a numeric workers value.
    if [[ "${role}" =~ ^[0-9]+$ ]]; then
      workers="${role}"
      role="INVALID"
    fi
    if [[ "${role}" != "PRIMARY" && "${role}" != "SECONDARY" ]]; then
      REPLICA_WORKERS_MISMATCH_PODS+=("${pod}:invalid_gr_role(${role:-empty})")
      continue
    fi
    if [[ "${role}" == "PRIMARY" ]]; then
      REPLICA_WORKERS_PRIMARY_POD="${pod}"
    fi
    if [[ "${workers}" =~ ^[0-9]+$ && "${workers}" == "${target}" ]]; then
      REPLICA_WORKERS_READY_PODS+=("${pod}")
    else
      REPLICA_WORKERS_MISMATCH_PODS+=("${pod}:${workers:-?}")
    fi
  done < <(_failover_list_mysql_pods "${kubeconfig}" "${ns}")
}

_failover_wait_mysql_pods_ready_for_workers_gate() {
  local kubeconfig="${1:?kubeconfig required}"
  local ns="${2:?namespace required}"
  local log_file="${3:?log file required}"
  local poll_sec="${FAILOVER_REPLICA_WORKERS_POLL_SEC:-2}"
  local timeout_sec="${FAILOVER_REPLICA_WORKERS_TIMEOUT_SEC:-600}"
  local waited=0 poll_num=0
  local -a kubectl pending=()
  local pod ready_col n_ready n_total

  mapfile -t kubectl < <(_failover_kubectl_cmd "${kubeconfig}")

  while (( waited <= timeout_sec )); do
    poll_num=$((poll_num + 1))
    pending=()
    while IFS= read -r pod; do
      [[ -n "${pod}" ]] || continue
      ready_col="$("${kubectl[@]}" get pod "${pod}" -n "${ns}" --no-headers 2>/dev/null | awk '{print $2}')"
      if [[ "${ready_col}" =~ ^([0-9]+)/([0-9]+)$ ]]; then
        n_ready="${BASH_REMATCH[1]}"
        n_total="${BASH_REMATCH[2]}"
        if (( n_ready < n_total || n_total == 0 )); then
          pending+=("${pod}:${ready_col}")
        fi
      else
        pending+=("${pod}:${ready_col:-unknown}")
      fi
    done < <(_failover_list_mysql_pods "${kubeconfig}" "${ns}")

    if ((${#pending[@]} == 0)); then
      echo "  all MySQL pods container-ready after ${waited}s" | tee -a "${log_file}"
      return 0
    fi
    echo "  wait_mysql_pods_ready poll=${poll_num} waited=${waited}s pending: ${pending[*]}" | tee -a "${log_file}"
    if (( waited >= timeout_sec )); then
      break
    fi
    sleep "${poll_sec}"
    waited=$((waited + poll_sec))
  done

  echo "ERROR: MySQL pods not fully ready after ${timeout_sec}s: ${pending[*]}" | tee -a "${log_file}"
  return 1
}

_failover_apply_replica_workers_on_pod() {
  local kubeconfig="${1:?kubeconfig required}"
  local ns="${2:?namespace required}"
  local pod="${3:?pod required}"
  local target="${4:?target required}"
  local log_file="${5:?log file required}"
  local role workers

  if ! IFS=$'\t' read -r role workers < <(_failover_poll_pod_replica_workers_role "${kubeconfig}" "${ns}" "${pod}"); then
    echo "ERROR: could not read replica_parallel_workers on ${pod}" | tee -a "${log_file}"
    return 1
  fi
  if [[ "${workers}" == "${target}" ]]; then
    echo "  ${pod}: already replica_parallel_workers=${target} [${role}]" | tee -a "${log_file}"
    return 0
  fi

  echo "  ${pod}: SET PERSIST replica_parallel_workers=${target} (was ${workers:-?}, role=${role})" | tee -a "${log_file}"
  if ! _failover_mysql_root_exec "${kubeconfig}" "${ns}" "${pod}" \
    "SET PERSIST replica_parallel_workers = ${target};" 90 | tee -a "${log_file}"; then
    echo "ERROR: SET PERSIST failed on ${pod}" | tee -a "${log_file}"
    return 1
  fi
  echo "  ${pod}: restarting group replication applier" | tee -a "${log_file}"
  if ! _failover_mysql_root_exec "${kubeconfig}" "${ns}" "${pod}" \
    "STOP GROUP_REPLICATION; START GROUP_REPLICATION;" 120 | tee -a "${log_file}"; then
    echo "ERROR: group replication restart failed on ${pod}" | tee -a "${log_file}"
    return 1
  fi
  if ! _failover_wait_gr_cluster_online "${log_file}"; then
    return 1
  fi
  return 0
}

_failover_promote_mysql_pod_to_primary() {
  local kubeconfig="${1:?kubeconfig required}"
  local ns="${2:?namespace required}"
  local pod="${3:?pod required}"
  local log_file="${4:?log file required}"
  local member_id exec_pod

  member_id="$(_failover_get_pod_server_uuid "${kubeconfig}" "${ns}" "${pod}")"
  [[ -n "${member_id}" ]] || {
    echo "ERROR: could not read server_uuid on ${pod}" | tee -a "${log_file}"
    return 1
  }
  exec_pod="${REPLICA_WORKERS_PRIMARY_POD:-${pod}}"
  local udf_timeout="${FAILOVER_SET_AS_PRIMARY_TIMEOUT_SEC:-1}"
  echo "  promoting ${pod} (${member_id}) via ${exec_pod} (udf_timeout=${udf_timeout}s)" | tee -a "${log_file}"
  if ! _failover_mysql_root_exec "${kubeconfig}" "${ns}" "${exec_pod}" \
    "SELECT group_replication_set_as_primary('${member_id}', ${udf_timeout});" 60 | tee -a "${log_file}"; then
    echo "ERROR: group_replication_set_as_primary failed for ${pod}" | tee -a "${log_file}"
    return 1
  fi
  if ! _failover_wait_gr_cluster_online "${log_file}"; then
    return 1
  fi
  return 0
}

_failover_ensure_replica_workers_topology() {
  local kubeconfig="${1:?kubeconfig required}"
  local ns="${2:?namespace required}"
  local target="${3:?target required}"
  local log_file="${4:?log file required}"
  local pod primary_pod candidate

  _failover_collect_replica_workers_state "${kubeconfig}" "${ns}" "${target}"
  if ((${#REPLICA_WORKERS_MISMATCH_PODS[@]} == 0)); then
    return 0
  fi

  echo "Pods needing replica_parallel_workers=${target}: ${REPLICA_WORKERS_MISMATCH_PODS[*]}" | tee -a "${log_file}"

  while IFS= read -r pod; do
    [[ -n "${pod}" ]] || continue
    if ! IFS=$'\t' read -r role workers < <(_failover_poll_pod_replica_workers_role "${kubeconfig}" "${ns}" "${pod}"); then
      return 1
    fi
    [[ "${role}" == "PRIMARY" ]] && continue
    [[ "${workers}" == "${target}" ]] && continue
    if ! _failover_apply_replica_workers_on_pod "${kubeconfig}" "${ns}" "${pod}" "${target}" "${log_file}"; then
      return 1
    fi
  done < <(_failover_list_mysql_pods "${kubeconfig}" "${ns}")

  _failover_collect_replica_workers_state "${kubeconfig}" "${ns}" "${target}"
  primary_pod="${REPLICA_WORKERS_PRIMARY_POD}"
  if [[ -n "${primary_pod}" ]]; then
    if ! IFS=$'\t' read -r role workers < <(_failover_poll_pod_replica_workers_role "${kubeconfig}" "${ns}" "${primary_pod}"); then
      return 1
    fi
    if [[ "${workers}" != "${target}" ]]; then
      candidate=""
      for pod in "${REPLICA_WORKERS_READY_PODS[@]}"; do
        [[ "${pod}" == "${primary_pod}" ]] && continue
        candidate="${pod}"
        break
      done
      if [[ -z "${candidate}" ]]; then
        echo "ERROR: primary ${primary_pod} needs replica_parallel_workers=${target} but no updated secondary is available to promote" \
          | tee -a "${log_file}"
        return 1
      fi
      if ! _failover_promote_mysql_pod_to_primary "${kubeconfig}" "${ns}" "${candidate}" "${log_file}"; then
        return 1
      fi
      if ! _failover_apply_replica_workers_on_pod "${kubeconfig}" "${ns}" "${primary_pod}" "${target}" "${log_file}"; then
        return 1
      fi
    fi
  fi

  _failover_collect_replica_workers_state "${kubeconfig}" "${ns}" "${target}"
  if ((${#REPLICA_WORKERS_MISMATCH_PODS[@]} > 0)); then
    echo "ERROR: replica_parallel_workers still mismatched: ${REPLICA_WORKERS_MISMATCH_PODS[*]}" | tee -a "${log_file}"
    return 1
  fi
  return 0
}

# Ensure every MySQL pod has replica_parallel_workers at target before iteration / trigger.
# Optional second arg: phase label for logs (e.g. "pre-trigger").
ensure_replica_parallel_workers_before_failover() {
  local results_dir="${1:?results dir required}"
  local phase="${2:-}"
  local log_file="${results_dir}/failover_replica_workers_gate.log"
  local snap_tsv="${results_dir}/replica_parallel_workers_gate.tsv"
  local target kubeconfig ns
  local phase_label=""

  if [[ -n "${phase}" ]]; then
    phase_label=" [${phase}]"
  fi

  if ! failover_replica_workers_gate_enabled; then
    return 0
  fi
  if ! _failover_replica_workers_gate_prereqs "${results_dir}"; then
    echo "Replica workers gate${phase_label}: skipped (${REPLICA_WORKERS_GATE_SKIP_REASON})" | tee "${log_file}"
    return 0
  fi

  kubeconfig="${REPLICA_WORKERS_GATE_KUBECONFIG}"
  ns="${REPLICA_WORKERS_GATE_NS}"
  target="$(_failover_target_replica_parallel_workers)"
  if ! [[ "${target}" =~ ^[0-9]+$ ]] || (( target < 1 )); then
    echo "ERROR: FAILOVER_REPLICA_PARALLEL_WORKERS must be a positive integer (got ${target})" | tee "${log_file}"
    return 1
  fi

  echo "=== Replica parallel workers gate (target=${target})${phase_label} ===" | tee -a "${log_file}"
  echo "namespace=${ns} kubeconfig=${kubeconfig}" | tee -a "${log_file}"

  if ! _failover_wait_mysql_pods_ready_for_workers_gate "${kubeconfig}" "${ns}" "${log_file}"; then
    echo "ERROR: replica workers gate FAILED (pods not ready)${phase_label}" | tee -a "${log_file}"
    return 1
  fi

  _failover_capture_replica_workers_snapshot "${kubeconfig}" "${ns}" "${snap_tsv}"
  cat "${snap_tsv}" | tee -a "${log_file}"

  if _failover_ensure_replica_workers_topology "${kubeconfig}" "${ns}" "${target}" "${log_file}"; then
    _failover_capture_replica_workers_snapshot "${kubeconfig}" "${ns}" "${snap_tsv}"
    echo "Replica workers gate PASSED: all pods at replica_parallel_workers=${target}${phase_label}" | tee -a "${log_file}"
    if [[ "${phase}" == "pre-trigger" ]]; then
      {
        echo "FAILOVER_REPLICA_WORKERS_PRETRIGGER=passed"
        echo "FAILOVER_REPLICA_PARALLEL_WORKERS=${target}"
        echo "FAILOVER_REPLICA_WORKERS_PRETRIGGER_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      } >> "${results_dir}/failover_event.txt"
    else
      {
        echo "FAILOVER_REPLICA_WORKERS_GATE=passed"
        echo "FAILOVER_REPLICA_PARALLEL_WORKERS=${target}"
        echo "FAILOVER_REPLICA_WORKERS_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      } >> "${results_dir}/failover_replica_workers_gate.env"
    fi
    return 0
  fi

  echo "ERROR: replica workers gate FAILED${phase_label}" | tee -a "${log_file}"
  if [[ "${phase}" == "pre-trigger" ]]; then
    {
      echo "FAILOVER_REPLICA_WORKERS_PRETRIGGER=failed"
      echo "FAILOVER_REPLICA_PARALLEL_WORKERS=${target}"
      echo "FAILOVER_REPLICA_WORKERS_MISMATCH=${REPLICA_WORKERS_MISMATCH_PODS[*]}"
      echo "FAILOVER_REPLICA_WORKERS_PRETRIGGER_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } >> "${results_dir}/failover_event.txt"
  else
    {
      echo "FAILOVER_REPLICA_WORKERS_GATE=failed"
      echo "FAILOVER_REPLICA_PARALLEL_WORKERS=${target}"
      echo "FAILOVER_REPLICA_WORKERS_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } >> "${results_dir}/failover_replica_workers_gate.env"
  fi
  if [[ "${FAILOVER_REPLICA_WORKERS_ABORT_ON_TIMEOUT:-1}" == "1" ]]; then
    return 1
  fi
  echo "WARNING: proceeding despite replica_parallel_workers gate failure (FAILOVER_REPLICA_WORKERS_ABORT_ON_TIMEOUT=0)" \
    | tee -a "${log_file}"
  return 0
}

# Deprecated alias: pre-trigger now applies fixes via ensure (kept for compatibility).
validate_replica_parallel_workers_before_failover() {
  ensure_replica_parallel_workers_before_failover "${1:?results dir required}" "pre-trigger"
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
  echo "Waiting ${early}s until final primary resolution (${prep_sec}s before failover trigger at second ${delay})..."
  sleep "${early}"
}

# Short final wait after refresh; delete runs immediately when this returns.
sleep_until_failover_trigger_final_gap() {
  failover_defaults
  local prep_sec="${FAILOVER_TRIGGER_PREPARE_SEC:-5}"
  echo "Final ${prep_sec}s before instant failover trigger (trigger second)..."
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

  local trigger_log trigger_wall start_utc edition scenario trx_profile
  trigger_wall=$(failover_trigger_wall_second_from_timing "${timing_file}")
  trigger_log=$(failover_trigger_log_second_from_timing "${timing_file}")
  start_utc=""
  edition="${FAILOVER_EDITION:-advanced}"
  scenario="mixed"
  trx_profile="mixed"

  if [[ -f "${timing_file}" ]]; then
    # shellcheck disable=SC1090
    source "${timing_file}" 2>/dev/null || true
    trigger_wall=$(failover_trigger_wall_second_from_timing "${timing_file}")
    trigger_log=$(failover_trigger_log_second_from_timing "${timing_file}")
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
    echo "FAILOVER_TRIGGER_WALL_SECOND=${trigger_wall}"
    echo "FAILOVER_TRIGGER_LOG_SECOND=${trigger_log}"
    echo "FAILOVER_TRIGGER_SECOND=${trigger_wall}"
    echo "FAILOVER_EDITION=${edition}"
  } > "${meta_file}"

  if [[ -f "${results_dir}/sysbench_timing.txt" ]]; then
    grep -E '^(SLUG_SIZE|CLUSTER_SLUG|NUM_NODES|DATA_SIZE|THREADS|FAILOVER_THREADS|TPCC_SCALE|TPCC_TABLES|TPCC_THREADS|PREP_THREADS)=' \
      "${results_dir}/sysbench_timing.txt" >> "${meta_file}" 2>/dev/null || true
  elif [[ -f "${results_dir}/../benchmark_config.env" ]]; then
    grep -E '^(SLUG_SIZE|CLUSTER_SLUG|NUM_NODES|DATA_SIZE|THREADS|FAILOVER_THREADS|TPCC_SCALE|TPCC_TABLES|TPCC_THREADS|PREP_THREADS)=' \
      "${results_dir}/../benchmark_config.env" >> "${meta_file}" 2>/dev/null || true
  fi

  awk -v trigger="${trigger_log}" \
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

  local trigger_log trigger_wall scenario trx_profile
  trigger_wall=$(failover_trigger_wall_second_from_timing "${timing_file}")
  trigger_log=$(failover_trigger_log_second_from_timing "${timing_file}")
  scenario="mixed"
  trx_profile="mixed"
  if [[ -f "${timing_file}" ]]; then
    # shellcheck disable=SC1090
    source "${timing_file}" 2>/dev/null || true
    trigger_wall=$(failover_trigger_wall_second_from_timing "${timing_file}")
    trigger_log=$(failover_trigger_log_second_from_timing "${timing_file}")
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

  _failover_parse_sysbench_intervals "${sysbench_log}" "${trigger_log}" \
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
    if [[ "${trigger_wall}" != "${trigger_log}" ]]; then
      echo "Trigger second (wall):  ${trigger_wall} (warmup + baseline, harness sleep)"
      echo "Trigger second (log):   ${trigger_log} (sysbench report timeline / graphs)"
    else
      echo "Trigger second:       ${trigger_log} (from sysbench start)"
    fi
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
  write_failover_promotion_breakdown "${results_dir}"

  if [[ -f "${BENCH_ROOT}/scripts/generate_failover_graphs.py" ]]; then
    python3 "${BENCH_ROOT}/scripts/generate_failover_graphs.py" --gr-pre-failover "${results_dir}" \
      2>/dev/null || true
  fi

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

  local trigger_log trigger_wall edition trigger_utc scenario trx_profile
  trigger_wall=$(failover_trigger_wall_second_from_timing "${timing_file}")
  trigger_log=$(failover_trigger_log_second_from_timing "${timing_file}")
  edition="unknown"
  trigger_utc=""
  scenario="mixed"
  trx_profile="mixed"

  if [[ -f "${timing_file}" ]]; then
    # shellcheck disable=SC1090
    source "${timing_file}" 2>/dev/null || true
    trigger_wall=$(failover_trigger_wall_second_from_timing "${timing_file}")
    trigger_log=$(failover_trigger_log_second_from_timing "${timing_file}")
    scenario="${FAILOVER_SCENARIO:-mixed}"
    trx_profile="${TPCC_TRX_PROFILE:-mixed}"
  fi
  local trigger_method=""
  if [[ -f "${event_file}" ]]; then
    edition=$(grep -E '^FAILOVER_EDITION=' "${event_file}" | tail -1 | cut -d= -f2- || echo "unknown")
    trigger_utc=$(grep -E '^FAILOVER_TRIGGER_UTC=' "${event_file}" | tail -1 | cut -d= -f2- || true)
    trigger_method=$(grep -E '^FAILOVER_ADVANCED_TRIGGER_METHOD=' "${event_file}" | tail -1 | cut -d= -f2- || true)
    if [[ -z "${trigger_method}" ]]; then
      trigger_method=$(grep -E '^FAILOVER_METHOD=' "${event_file}" | tail -1 | cut -d= -f2- || true)
    fi
  fi
  : "${trigger_method:=${FAILOVER_ADVANCED_TRIGGER_METHOD:-pod_delete}}"

  local monitor_offset=0
  if [[ -f "${results_dir}/primary_monitor_meta.txt" && -f "${timing_file}" ]]; then
    local monitor_start sysbench_ready
    monitor_start=$(grep -E '^MONITOR_START_EPOCH=' "${results_dir}/primary_monitor_meta.txt" | cut -d= -f2- || true)
    sysbench_ready=$(grep -E '^SYSBENCH_READY_EPOCH=' "${timing_file}" | cut -d= -f2- || true)
    if [[ -n "${monitor_start}" && -n "${sysbench_ready}" ]]; then
      monitor_offset=$(python3 -c "print('%.3f' % (float('${sysbench_ready}') - float('${monitor_start}')))")
    fi
  fi

  # Prefer the actual sub-second fire epoch over the planned integer trigger second.
  trigger_wall=$(failover_trigger_wall_subsec "${results_dir}" "${timing_file}")

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

  # TTD = first connect_ok=0 at/after trigger epoch (no pre-trigger guard).
  # Pre-trigger VIP flakes must not clamp failure_detection_sec to 0.
  local detect_guard_sec="${FAILOVER_DETECT_GUARD_SEC:-0}"

  awk -v log_trigger="${trigger_log}" \
      -v wall_trigger="${trigger_wall}" \
      -v edition="${edition}" \
      -v scenario="${scenario}" \
      -v trx_profile="${trx_profile}" \
      -v recovery_pct="${FAILOVER_RECOVERY_THRESHOLD}" \
      -v stable="${FAILOVER_RECOVERY_STABLE_SEC}" \
      -v outage_ratio="${FAILOVER_OUTAGE_TPS_RATIO}" \
      -v observe_sec="${FAILOVER_OBSERVE_SEC}" \
      -v monitor="${monitor}" \
      -v monitor_offset="${monitor_offset}" \
      -v detect_guard="${detect_guard_sec}" \
      -v detect_window="${FAILOVER_DETECT_WINDOW_SEC:-60}" \
      -v planned_window="${FAILOVER_PLANNED_DETECT_WINDOW_SEC:-10}" \
      -v trigger_method="${trigger_method}" \
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
    if (sec < log_trigger && tps_arr[sec] > 0) {
      pre_tps_sum += tps_arr[sec]
      pre_tps_cnt++
    }
    if (sec < log_trigger && qps_arr[sec] > 0) {
      pre_qps_sum += qps_arr[sec]
      pre_qps_cnt++
    }
    if (sec < log_trigger) {
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
  observe_end = log_trigger + observe_sec
  if (load_end > observe_end) observe_end = load_end
}
function detect_connect_failure_ttd(    sysbench_sec, rel, guard, window) {
  if (monitor == "" || ( (getline _ < monitor) <= 0 )) return -1
  close(monitor)
  # Default guard=0: first connect_ok=0 at/after trigger epoch only.
  # Optional FAILOVER_DETECT_GUARD_SEC allows a small pre-trigger band if needed.
  guard = (detect_guard == "" ? 0 : detect_guard + 0)
  window = (detect_window == "" ? 0 : detect_window + 0)
  while ((getline line < monitor) > 0) {
    split(line, f, "\t")
    if (f[1] == "timestamp_utc") continue
    sysbench_sec = (f[2] + 0) - monitor_offset
    rel = sysbench_sec - wall_trigger
    if (rel < -guard) continue
    # Stop once past the plausible detection window so an unrelated late
    # connection blip cannot masquerade as the failover detection.
    if (window > 0 && rel > window) break
    if (f[3] != "1") return (rel < 0 ? 0 : rel)
  }
  close(monitor)
  return -1
}
function count_write_probe_failures(recovery_rel, election_rel,    sysbench_sec, wo, end_abs, count) {
  count = 0
  end_abs = observe_end
  if (recovery_rel >= 0) end_abs = log_trigger + recovery_rel
  if (election_rel >= 0 && log_trigger + election_rel > end_abs)
    end_abs = log_trigger + election_rel
  if (monitor == "" || ( (getline _ < monitor) <= 0 )) return 0
  close(monitor)
  while ((getline line < monitor) > 0) {
    split(line, f, "\t")
    if (f[1] == "timestamp_utc") continue
    sysbench_sec = (f[2] + 0) - monitor_offset
    if (sysbench_sec < wall_trigger || sysbench_sec > end_abs) continue
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
function is_planned_mode() {
  return (trigger_method == "set_as_primary" || trigger_method == "group_replication_set_as_primary")
}
function host_changed(f,    host) {
  host = f[4]
  if (primary_before == "" || primary_before == "N/A") return 1
  if (host == "" || host == "ERROR") return 0
  return (host != primary_before)
}
function is_primary_elected(f,    wo, role, gr) {
  if (f[3] != "1") return 0
  wo = monitor_write_ok(f)
  if (wo != 1) return 0
  role = monitor_gr_role(f)
  gr = monitor_gr_state(f)
  if (edition == "advanced") {
    if (!(role == "PRIMARY" && (gr == "ONLINE" || gr == "PRIMARY"))) return 0
  }
  # Require VIP hostname to move to a different primary pod.
  if (!host_changed(f)) return 0
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
    if (sysbench_sec < wall_trigger) continue
    if (!saw_connect_fail) {
      if (f[3] != "1") saw_connect_fail = 1
      else continue
    }
    if (is_primary_elected(f))
      return sysbench_sec - wall_trigger
  }
  close(monitor)
  return -1
}
# Planned: first write_ok=0 or connect_ok=0 after trigger (short window).
function detect_planned_outage_start(    sysbench_sec, rel, guard, window, wo) {
  if (monitor == "" || ( (getline _ < monitor) <= 0 )) return -1
  close(monitor)
  guard = (detect_guard == "" ? 0 : detect_guard + 0)
  window = (planned_window == "" ? 10 : planned_window + 0)
  while ((getline line < monitor) > 0) {
    split(line, f, "\t")
    if (f[1] == "timestamp_utc") continue
    sysbench_sec = (f[2] + 0) - monitor_offset
    rel = sysbench_sec - wall_trigger
    if (rel < -guard) continue
    if (window > 0 && rel > window) break
    wo = monitor_write_ok(f)
    if (f[3] != "1" || wo == 0)
      return (rel < 0 ? 0 : rel)
  }
  close(monitor)
  return -1
}
# Planned: first new-PRIMARY+write_ok after outage_start_rel (trigger-relative).
function detect_planned_recover_from(outage_start_rel,    sysbench_sec, rel) {
  if (monitor == "" || ( (getline _ < monitor) <= 0 )) return -1
  close(monitor)
  while ((getline line < monitor) > 0) {
    split(line, f, "\t")
    if (f[1] == "timestamp_utc") continue
    sysbench_sec = (f[2] + 0) - monitor_offset
    rel = sysbench_sec - wall_trigger
    if (rel < outage_start_rel) continue
    if (is_primary_elected(f))
      return rel
  }
  close(monitor)
  return -1
}
# Planned zero-downtime: new PRIMARY+write_ok after trigger with no prior outage sample.
function detect_planned_zero_downtime_promote(    sysbench_sec, rel, window) {
  if (monitor == "" || ( (getline _ < monitor) <= 0 )) return -1
  close(monitor)
  window = (planned_window == "" ? 10 : planned_window + 0)
  while ((getline line < monitor) > 0) {
    split(line, f, "\t")
    if (f[1] == "timestamp_utc") continue
    sysbench_sec = (f[2] + 0) - monitor_offset
    rel = sysbench_sec - wall_trigger
    if (rel < 0) continue
    if (window > 0 && rel > window) break
    if (is_primary_elected(f))
      return rel
  }
  close(monitor)
  return -1
}
function detect_app_recovery_rto(    sec, stable_count, rto) {
  stable_count = 0
  rto = -1
  for (sec = log_trigger; sec <= observe_end; sec++) {
    if (!(sec in tps_arr)) continue
    if (baseline_tps > 0 && tps_arr[sec] >= tps_thresh) {
      stable_count++
      if (stable_count >= stable && rto < 0) {
        rto = sec - log_trigger - stable + 2
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
  start = log_trigger + (failure_rel >= 0 ? failure_rel : 0)
  end = observe_end
  if (recovery_rel >= 0) end = log_trigger + recovery_rel - 1
  for (sec = start; sec <= end; sec++) {
    if (!(sec in tps_arr)) continue
    if (baseline_tps > 0 && tps_arr[sec] < tps_thresh) count++
  }
  return count
}
function peak_latency(failure_rel, recovery_rel,    sec, start, end, peak) {
  peak = 0
  start = log_trigger + (failure_rel >= 0 ? failure_rel : 0)
  end = observe_end
  if (recovery_rel >= 0) {
    end = log_trigger + recovery_rel + stable
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
  start = log_trigger + (fail_rel >= 0 ? fail_rel : 0)
  end = observe_end
  if (recovery_rel >= 0) end = log_trigger + recovery_rel
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
function fmt_detect(v) {
  if (is_planned_mode()) return "N/A"
  return fmt_sec(v)
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
  outage_start_rel = -1
  if (is_planned_mode()) {
    # Planned: detect N/A; total = write-path downtime (first bad → new PRIMARY).
    failure_sec = -1
    outage_start_rel = detect_planned_outage_start()
    if (outage_start_rel < 0) {
      if (detect_planned_zero_downtime_promote() >= 0) {
        promote_total_sec = 0
        election_sec = 0
      } else {
        promote_total_sec = -1
        election_sec = -1
      }
    } else {
      recover_rel = detect_planned_recover_from(outage_start_rel)
      if (recover_rel >= 0) {
        promote_total_sec = recover_rel - outage_start_rel
        election_sec = promote_total_sec
      } else {
        promote_total_sec = -1
        election_sec = -1
      }
    }
    window_start = (outage_start_rel >= 0 ? outage_start_rel : 0)
  } else {
    # Unplanned: connect_ok=0 detect; total = trigger → new PRIMARY (hostname change).
    failure_sec = detect_connect_failure_ttd()
    promote_total_sec = detect_primary_election_from_monitor()
    election_sec = phase_duration(promote_total_sec, failure_sec)
    window_start = failure_sec
  }
  recovery_sec = detect_app_recovery_rto()
  dip_sec = dip_duration(window_start, recovery_sec)
  peak_lat = peak_latency(window_start, recovery_sec)
  peak_err_window = 0
  tx_failed = failover_errors_in_window(window_start, recovery_sec)
  # For planned, count write failures over trigger → recover (duration mapped via abs end).
  if (is_planned_mode() && outage_start_rel >= 0 && promote_total_sec >= 0)
    writes_failed = count_write_probe_failures(recovery_sec, outage_start_rel + promote_total_sec)
  else
    writes_failed = count_write_probe_failures(recovery_sec, promote_total_sec)

  print "edition,scenario,trx_profile,failure_detection_sec,primary_election_sec,total_failover_sec,app_recovery_sec,tps_dip_duration_sec,peak_latency_failover_ms,transactions_failed_during_failover,writes_failed_during_failover,peak_write_err_per_sec,data_loss"
  printf "%s,%s,%s,%s,%s,%s,%s,%d,%s,%d,%d,%.2f,%s\n", \
    edition, scenario, trx_profile, \
    fmt_detect(failure_sec), fmt_sec(election_sec), fmt_sec(promote_total_sec), fmt_sec(recovery_sec), \
    dip_sec, fmt_lat(peak_lat), tx_failed, writes_failed, peak_err_window, tpcc_check
}
AWK

  echo "KPI CSV: ${kpi_csv}"
}

# Decompose primary_election_sec (TTD → GR PRIMARY + write on client VIP) into sub-phases.
# Writes failover_promotion_breakdown.txt and failover_promotion_breakdown.csv
write_failover_promotion_breakdown() {
  local results_dir="${1:?results dir required}"
  local monitor="${results_dir}/primary_monitor.tsv"
  local gr_monitor="${results_dir}/gr_pod_monitor.tsv"
  local timing_file="${results_dir}/sysbench_timing.txt"
  local event_file="${results_dir}/failover_event.txt"
  local txt_out="${results_dir}/failover_promotion_breakdown.txt"
  local csv_out="${results_dir}/failover_promotion_breakdown.csv"

  failover_defaults

  [[ -f "${monitor}" ]] || return 0

  local trigger_wall edition trigger_method
  trigger_wall=$(failover_trigger_wall_second_from_timing "${timing_file}")
  edition="unknown"
  trigger_method=""
  if [[ -f "${timing_file}" ]]; then
    # shellcheck disable=SC1090
    source "${timing_file}" 2>/dev/null || true
    trigger_wall=$(failover_trigger_wall_second_from_timing "${timing_file}")
  fi
  if [[ -f "${event_file}" ]]; then
    edition=$(grep -E '^FAILOVER_EDITION=' "${event_file}" | tail -1 | cut -d= -f2- || echo "unknown")
    trigger_method=$(grep -E '^FAILOVER_ADVANCED_TRIGGER_METHOD=' "${event_file}" | tail -1 | cut -d= -f2- || true)
    if [[ -z "${trigger_method}" ]]; then
      trigger_method=$(grep -E '^FAILOVER_METHOD=' "${event_file}" | tail -1 | cut -d= -f2- || true)
    fi
  fi
  : "${trigger_method:=${FAILOVER_ADVANCED_TRIGGER_METHOD:-pod_delete}}"

  local monitor_offset=0
  if [[ -f "${results_dir}/primary_monitor_meta.txt" && -f "${timing_file}" ]]; then
    local monitor_start sysbench_ready
    monitor_start=$(grep -E '^MONITOR_START_EPOCH=' "${results_dir}/primary_monitor_meta.txt" | cut -d= -f2- || true)
    sysbench_ready=$(grep -E '^SYSBENCH_READY_EPOCH=' "${timing_file}" | cut -d= -f2- || true)
    if [[ -n "${monitor_start}" && -n "${sysbench_ready}" ]]; then
      monitor_offset=$(python3 -c "print('%.3f' % (float('${sysbench_ready}') - float('${monitor_start}')))")
    fi
  fi

  # Prefer the actual sub-second fire epoch over the planned integer trigger second.
  trigger_wall=$(failover_trigger_wall_subsec "${results_dir}" "${timing_file}")

  local primary_before="N/A"
  primary_before=$(analyze_primary_change "${monitor}" "" 2>/dev/null \
    | grep '^PRIMARY_BEFORE=' | cut -d= -f2- || echo "N/A")

  local gr_election_override="-1"
  local gr_election_override_pod=""
  local gr_election_source=""
  local gr_writable_override="-1"
  local gr_writable_source=""
  if [[ -f "${results_dir}/gr_election_internal.env" ]]; then
    # shellcheck disable=SC1090
    source "${results_dir}/gr_election_internal.env" 2>/dev/null || true
    gr_election_override="${GR_ELECTION_FROM_TRIGGER_SEC:--1}"
    gr_election_override_pod="${GR_ELECTION_POD:-}"
    gr_election_source="${GR_ELECTION_SOURCE:-mysql_pod_logs}"
    gr_writable_override="${GR_WRITABLE_FROM_TRIGGER_SEC:--1}"
    gr_writable_source="${GR_WRITABLE_SOURCE:-}"
  fi

  _failover_parse_gr_election_from_mysql_logs "${results_dir}" 2>/dev/null || true
  if [[ -f "${results_dir}/gr_election_internal.env" ]]; then
    # shellcheck disable=SC1090
    source "${results_dir}/gr_election_internal.env" 2>/dev/null || true
    gr_election_override="${GR_ELECTION_FROM_TRIGGER_SEC:--1}"
    gr_election_override_pod="${GR_ELECTION_POD:-}"
    gr_election_source="${GR_ELECTION_SOURCE:-mysql_pod_logs}"
    gr_writable_override="${GR_WRITABLE_FROM_TRIGGER_SEC:--1}"
    gr_writable_source="${GR_WRITABLE_SOURCE:-}"
  fi

  _failover_parse_haproxy_stats_primary_up "${results_dir}" "${gr_election_override_pod}" 2>/dev/null || true
  local ha_stats_up_override="-1"
  local ha_stats_up_server=""
  local ha_stats_up_pod=""
  local ha_stats_up_source=""
  if [[ -f "${results_dir}/haproxy_primary_up.env" ]]; then
    # shellcheck disable=SC1090
    source "${results_dir}/haproxy_primary_up.env" 2>/dev/null || true
    ha_stats_up_override="${HAPROXY_PRIMARY_UP_FROM_TRIGGER_SEC:--1}"
    ha_stats_up_server="${HAPROXY_PRIMARY_UP_SERVER:-}"
    ha_stats_up_pod="${HAPROXY_PRIMARY_UP_POD:-}"
    ha_stats_up_source="${HAPROXY_PRIMARY_UP_SOURCE:-haproxy_stats_monitor}"
    if [[ "${ha_stats_up_override}" != "-1" && "${gr_election_override}" != "-1" ]]; then
      if ! python3 -c "import sys; sys.exit(0 if float('${ha_stats_up_override}') >= float('${gr_election_override}') - 0.001 else 1)" 2>/dev/null; then
        echo "WARNING: HAProxy stats UP (${ha_stats_up_override}s) precedes GR election (${gr_election_override}s); using VIP fallback for HA phase" >&2
        ha_stats_up_override="-1"
        ha_stats_up_server=""
        ha_stats_up_pod=""
        ha_stats_up_source=""
      fi
    fi
  fi

  awk -v wall_trigger="${trigger_wall}" \
      -v edition="${edition}" \
      -v trigger_method="${trigger_method}" \
      -v monitor="${monitor}" \
      -v gr_monitor="${gr_monitor}" \
      -v monitor_offset="${monitor_offset}" \
      -v primary_before="${primary_before}" \
      -v gr_election_override="${gr_election_override}" \
      -v gr_election_override_pod="${gr_election_override_pod}" \
      -v gr_election_source="${gr_election_source}" \
      -v gr_writable_override="${gr_writable_override}" \
      -v gr_writable_source="${gr_writable_source}" \
      -v ha_stats_up_override="${ha_stats_up_override}" \
      -v ha_stats_up_server="${ha_stats_up_server}" \
      -v ha_stats_up_pod="${ha_stats_up_pod}" \
      -v ha_stats_up_source="${ha_stats_up_source}" \
      -v txt_out="${txt_out}" \
      -v csv_out="${csv_out}" \
      -f - <<'AWK'
function monitor_gr_state(f) { return f[7] }
function monitor_gr_role(f) {
  if (length(f) >= 9 && f[8] != "" && f[8] != "ERROR") return f[8]
  return ""
}
function monitor_write_ok(f) {
  if (length(f) >= 10 && f[9] != "" && f[9] != "ERROR") return f[9] + 0
  return -1
}
function is_gr_primary_visible(f,    role, gr) {
  if (f[3] != "1") return 0
  role = monitor_gr_role(f)
  gr = monitor_gr_state(f)
  if (edition == "advanced") {
    return (role == "PRIMARY" && (gr == "ONLINE" || gr == "PRIMARY"))
  }
  return 0
}
function phase_start_after(gr_rel, ttd_rel) {
  if (ttd_rel < 0) return -1
  if (gr_rel < 0) return ttd_rel
  return (gr_rel > ttd_rel) ? gr_rel : ttd_rel
}
function host_changed(f,    host) {
  host = f[4]
  if (primary_before == "" || primary_before == "N/A") return 1
  if (host == "" || host == "ERROR") return 0
  return (host != primary_before)
}
function is_primary_elected(f,    wo, role, gr) {
  if (f[3] != "1") return 0
  wo = monitor_write_ok(f)
  if (wo != 1) return 0
  role = monitor_gr_role(f)
  gr = monitor_gr_state(f)
  if (edition == "advanced") {
    if (!(role == "PRIMARY" && (gr == "ONLINE" || gr == "PRIMARY"))) return 0
  }
  if (!host_changed(f)) return 0
  return 1
}
function fmt_sec(v) {
  if (v < 0) return "NOT_DETECTED"
  if (v < 1) return sprintf("%.3f", v)
  if (v == int(v)) return sprintf("%d", v)
  return sprintf("%.2f", v)
}
function fmt_phase(v) {
  if (v < 0) return "NOT_REACHED"
  return fmt_sec(v)
}
function phase_duration(end_rel, start_rel) {
  if (end_rel < 0 || start_rel < 0) return -1
  if (end_rel < start_rel) return -1
  return end_rel - start_rel
}
function scan_ha_monitor(    line, f, sysbench_sec, host, wo, rel) {
  if (monitor == "" || ( (getline _ < monitor) <= 0 )) return
  close(monitor)
  while ((getline line < monitor) > 0) {
    split(line, f, "\t")
    if (f[1] == "timestamp_utc") continue
    sysbench_sec = (f[2] + 0) - monitor_offset
    host = f[4]
    wo = monitor_write_ok(f)
    rel = sysbench_sec - wall_trigger
    if (primary_before == "N/A" && sysbench_sec < wall_trigger && f[3] == "1" && host != "ERROR")
      primary_before = host
    if (sysbench_sec < wall_trigger) continue
    if (stale_ha_end < 0 && f[3] == "1" && host == primary_before && wo == 1)
      stale_ha_end = rel
    # Unplanned: TTD = first connect_ok=0. Planned: first write_ok=0 or connect_ok=0.
    if (ttd < 0) {
      if (trigger_method == "set_as_primary" || trigger_method == "group_replication_set_as_primary") {
        if (f[3] != "1" || wo == 0) ttd = (rel < 0 ? 0 : rel)
      } else if (f[3] != "1") {
        ttd = (rel < 0 ? 0 : rel)
      }
      if (ttd >= 0 && f[3] != "1") continue
    }
    if (ttd < 0) continue
    if (vip_connect < 0 && f[3] == "1") {
      vip_connect = rel
      if (wo != 1) vip_connect_only = vip_connect
    }
    if (vip_connect_only < 0 && f[3] == "1" && wo != 1)
      vip_connect_only = rel
    if (new_host < 0 && f[3] == "1" && host != "ERROR" && primary_before != "N/A" && host != primary_before)
      new_host = rel
    if (gr_on_vip < 0 && is_gr_primary_visible(f))
      gr_on_vip = rel
    if (write_ok < 0 && is_primary_elected(f))
      write_ok = rel
  }
  close(monitor)
}
function scan_gr_pods(    line, f, sysbench_sec, rel, pod, role, state) {
  if (gr_monitor == "" || ( (getline _ < gr_monitor) <= 0 )) return
  close(gr_monitor)
  while ((getline line < gr_monitor) > 0) {
    split(line, f, "\t")
    if (f[1] == "timestamp_utc") continue
    if (f[4] != "1") continue
    sysbench_sec = (f[2] + 0) - monitor_offset
    if (sysbench_sec < wall_trigger) continue
    role = f[6]
    state = f[7]
    pod = f[3]
    if (role == "PRIMARY" && (state == "ONLINE" || state == "PRIMARY")) {
      rel = sysbench_sec - wall_trigger
      if (gr_pod_primary < 0 || rel < gr_pod_primary) {
        gr_pod_primary = rel
        gr_pod_primary_name = pod
      }
    }
  }
  close(gr_monitor)
}
function apply_gr_election_override() {
  if (gr_election_override < 0) return
  gr_pod_primary = gr_election_override + 0
  if (gr_election_override_pod != "")
    gr_pod_primary_name = gr_election_override_pod
}
function max_rel(a, b) {
  if (a < 0) return b
  if (b < 0) return a
  return (a > b) ? a : b
}
function emit_csv_row(phase, anchor, time_abs, dur_ttd, desc) {
  printf "%s,%s,%s,%s,\"%s\"\n", phase, anchor, fmt_sec(time_abs), fmt_phase(dur_ttd), desc >> csv_out
}
BEGIN {
  ttd = -1
  stale_ha_end = -1
  vip_connect = -1
  vip_connect_only = -1
  new_host = -1
  gr_on_vip = -1
  write_ok = -1
  gr_pod_primary = -1
  gr_pod_primary_name = ""

  scan_ha_monitor()
  scan_gr_pods()
  apply_gr_election_override()

  gr_elect = gr_pod_primary
  if (gr_election_override >= 0) gr_elect = gr_election_override + 0

  ha_end = new_host
  if (ha_stats_up_override >= 0) ha_end = ha_stats_up_override + 0
  else if (ha_end < 0 && gr_on_vip >= 0) ha_end = gr_on_vip
  else if (ha_end < 0 && vip_connect >= 0) ha_end = vip_connect

  ha_stats_up = (ha_stats_up_override >= 0) ? ha_stats_up_override + 0 : -1
  ha_start_check = phase_start_after(gr_elect, ttd)
  if (ha_stats_up >= 0 && ha_start_check >= 0 && ha_stats_up < ha_start_check) {
    ha_stats_up = -1
    if (new_host >= 0 && new_host > ha_start_check) ha_end = new_host
    else if (gr_on_vip >= 0 && gr_on_vip > ha_start_check) ha_end = gr_on_vip
    else if (vip_connect >= 0 && vip_connect > ha_start_check) ha_end = vip_connect
    else ha_end = new_host
  }

  gr_writable = -1
  if (gr_writable_override >= 0) gr_writable = gr_writable_override + 0

  promote_total = phase_duration(write_ok, ttd)
  vip_outage = phase_duration(vip_connect, ttd)
  host_switch = phase_duration(new_host, vip_connect)
  gr_on_vip_lag = phase_duration(gr_on_vip, (new_host >= 0 ? new_host : vip_connect))
  write_lag = phase_duration(write_ok, gr_on_vip)
  gr_election = gr_elect
  ha_after_gr = phase_duration(vip_connect, gr_elect)
  apply_lag_internal = -1
  if (gr_elect >= 0 && gr_writable >= 0 && gr_writable > gr_elect)
    apply_lag_internal = gr_writable - gr_elect

  promote_gr_wait = -1
  promote_ha_route = -1
  promote_client_restore = -1
  if (ttd >= 0 && write_ok >= 0) {
    if (gr_elect >= 0) {
      promote_gr_wait = (gr_elect > ttd) ? gr_elect - ttd : 0
      ha_start = phase_start_after(gr_elect, ttd)
      if (ha_start >= 0 && ha_end >= 0 && ha_end > ha_start)
        promote_ha_route = ha_end - ha_start
      client_start = ha_start
      if (ha_end >= 0 && ha_end > client_start) client_start = ha_end
      if (client_start >= 0 && write_ok > client_start)
        promote_client_restore = write_ok - client_start
    }
  }

  print "phase,anchor,time_from_trigger_sec,duration_from_ttd_sec,description" > csv_out
  emit_csv_row("stale_ha_routing", "trigger", stale_ha_end, -1,
    "VIP still routed to old primary with writes OK (after trigger, before sustained outage)")
  emit_csv_row("failure_detection_ttd", "trigger", ttd, 0,
    "First connect failure on client VIP (connect_ok=0)")
  emit_csv_row("gr_election_internal", "trigger", gr_elect, phase_duration(gr_elect, ttd),
    (gr_election_source != "" ? "GR PRIMARY elected (" gr_election_source ")" : "First GR PRIMARY+ONLINE on any mysql pod (direct kubectl exec, bypasses VIP)"))
  emit_csv_row("gr_writable_internal", "trigger", gr_writable, phase_duration(gr_writable, ttd),
    (gr_writable_source != "" ? "Primary writable / applier caught up (" gr_writable_source ")" : "mysqld working-as-primary log not collected"))
  emit_csv_row("haproxy_primary_up_internal", "trigger", ha_stats_up, phase_duration(ha_stats_up, ttd),
    (ha_stats_up_source != "" ? "mysql-primary backend UP on elected server (" ha_stats_up_source ")" : "haproxy_stats_monitor.tsv not collected"))
  emit_csv_row("promote_gr_election_after_ttd", "ttd", gr_elect, promote_gr_wait,
    "GR election after TTD (mysqld elected log preferred; 0 if elected before client detected failure)")
  ha_route_desc = "HAProxy routable after TTD (applier/read_only wait + health check)"
  if (ha_stats_up_source != "" && ha_stats_up >= 0)
    ha_route_desc = ha_route_desc " via stats socket: mysql-primary UP"
  else
    ha_route_desc = ha_route_desc " via VIP hostname fallback"
  if (ha_stats_up_server != "")
    ha_route_desc = ha_route_desc " on " ha_stats_up_server
  ha_route_desc = ha_route_desc " (GR elected -> backend UP)"
  emit_csv_row("promote_ha_routing_after_ttd", "ttd", ha_end, promote_ha_route, ha_route_desc)
  client_desc = "Client path restore: HA backend UP -> write probe OK on client VIP"
  if (ha_stats_up >= 0)
    client_desc = client_desc " (stats UP -> write_ok)"
  else
    client_desc = client_desc " (VIP new host -> write_ok)"
  emit_csv_row("promote_client_path_restore_after_ttd", "ttd", write_ok, promote_client_restore, client_desc)
  emit_csv_row("promote_replication_lag_after_ttd", "ttd", write_ok, promote_client_restore,
    "Legacy alias of promote_client_path_restore_after_ttd")
  emit_csv_row("promote_ha_routing_to_primary", "ttd", write_ok, promote_ha_route,
    "Legacy alias of promote_ha_routing_after_ttd")
  emit_csv_row("vip_outage", "ttd", vip_connect, vip_outage,
    "Client VIP blackout (connect_ok=0 on HA endpoint)")
  emit_csv_row("vip_connect_restored", "ttd", vip_connect, vip_outage,
    "First TCP/MySQL connect succeeds on client VIP")
  emit_csv_row("ha_routes_new_host", "ttd", new_host, phase_duration(new_host, ttd),
    "VIP session lands on new mysql pod (hostname changed)")
  emit_csv_row("gr_primary_on_vip", "ttd", gr_on_vip, phase_duration(gr_on_vip, ttd),
    "GR PRIMARY+ONLINE visible through client VIP")
  emit_csv_row("write_probe_ok", "ttd", write_ok, promote_total,
    "Write probe INSERT succeeds on client VIP (end of promote metric)")
  emit_csv_row("operator_ha_lag_after_gr", "ttd", vip_connect, ha_after_gr,
    "VIP connect restored after internal GR election (operator + HAProxy lag)")
  emit_csv_row("host_switch_after_connect", "ttd", new_host, host_switch,
    "Delay from first VIP connect to routing to new pod")
  emit_csv_row("write_accept_after_gr", "ttd", write_ok, write_lag,
    "Delay from GR PRIMARY on VIP to write probe OK")
  emit_csv_row("promote_total", "ttd", write_ok, promote_total,
    "Total time to promote (same as primary_election_sec KPI)")

  print "=== Failover Promotion Breakdown ===" > txt_out
  print "Reference: seconds from failover trigger (monitor/sysbench wall second " wall_trigger ")" >> txt_out
  print "Primary before failover: " primary_before >> txt_out
  if (gr_pod_primary_name != "") print "GR PRIMARY pod (internal): " gr_pod_primary_name >> txt_out
  print "" >> txt_out
  print "--- Phases (time to promote = TTD -> write probe OK) ---" >> txt_out
  if (stale_ha_end >= 0)
    printf "Stale HA routing (old primary still writable):  %s from trigger\n", fmt_sec(stale_ha_end) >> txt_out
  else
    print "Stale HA routing (old primary still writable):  none detected" >> txt_out
  printf "TTD (first VIP connect failure):               %s\n", fmt_sec(ttd) >> txt_out
  print "" >> txt_out
  print "--- Promote = GR election + HAProxy routable + client path restore (sum = time to promote) ---" >> txt_out
  if (gr_elect >= 0 && promote_gr_wait >= 0 && promote_ha_route >= 0 && promote_client_restore >= 0) {
    printf "  GR election after TTD:                       %s\n", fmt_phase(promote_gr_wait) >> txt_out
    if (ha_stats_up >= 0) {
      printf "  HAProxy routable (stats socket UP):          %s\n", fmt_phase(promote_ha_route) >> txt_out
      if (ha_stats_up_server != "")
        printf "    (mysql-primary %s UP at %s from trigger", ha_stats_up_server, fmt_sec(ha_stats_up) >> txt_out
      else
        printf "    (mysql-primary UP at %s from trigger", fmt_sec(ha_stats_up) >> txt_out
      if (ha_stats_up_pod != "") printf " via %s", ha_stats_up_pod >> txt_out
      print ")" >> txt_out
    } else {
      printf "  HAProxy routable (VIP hostname fallback):    %s\n", fmt_phase(promote_ha_route) >> txt_out
      print "    (fallback: haproxy_stats_monitor.tsv not available)" >> txt_out
    }
    printf "  Client path restore (VIP write OK):          %s\n", fmt_phase(promote_client_restore) >> txt_out
    printf "  (GR elected at %s from trigger", fmt_sec(gr_elect) >> txt_out
    if (gr_pod_primary_name != "") printf " on %s", gr_pod_primary_name >> txt_out
    print ")" >> txt_out
    if (gr_writable >= 0)
      printf "  (GR writable log at %s from trigger; internal apply %s)\n", fmt_sec(gr_writable), fmt_phase(apply_lag_internal) >> txt_out
  } else if (promote_total >= 0) {
    print "  Three-phase split: NOT_COLLECTED (need primary_monitor + GR timing)" >> txt_out
    printf "  VIP-only promote window:                     %s\n", fmt_phase(promote_total) >> txt_out
  }
  print "" >> txt_out
  print "Sub-phases after TTD (detail):" >> txt_out
  if (gr_elect >= 0)
    printf "  GR election (internal):                      %s  (+%s from TTD)\n", fmt_sec(gr_elect), fmt_phase(promote_gr_wait) >> txt_out
  else
    print "  GR election (internal):                      NOT_COLLECTED (enable mysql GR log snapshot)" >> txt_out
  if (ha_after_gr >= 0)
    printf "  Operator + HAProxy lag (GR -> VIP connect):  %s\n", fmt_phase(ha_after_gr) >> txt_out
  else if (gr_pod_primary >= 0 && vip_connect < 0)
    print "  Operator + HAProxy lag (GR -> VIP connect):  NOT_REACHED (VIP never restored)" >> txt_out
  printf "  VIP outage (connect_ok=0):                   %s\n", fmt_phase(vip_outage) >> txt_out
  if (host_switch >= 0)
    printf "  HA route to new host (after connect):        %s\n", fmt_phase(host_switch) >> txt_out
  else if (new_host >= 0)
    print "  HA route to new host (after connect):        0 (same tick as connect)" >> txt_out
  if (write_lag >= 0)
    printf "  Write accept after GR PRIMARY on VIP:        %s\n", fmt_phase(write_lag) >> txt_out
  else if (write_ok >= 0)
    print "  Write accept after GR PRIMARY on VIP:        0 (same tick as GR PRIMARY)" >> txt_out
  print "" >> txt_out
  printf "Time to promote new primary (total):           %s from TTD\n", fmt_phase(promote_total) >> txt_out
  print "" >> txt_out
  print "CSV: " csv_out >> txt_out
  print "Note: 1s monitor grid + 1s connect timeout quantize timings by up to ~2s." >> txt_out
}
AWK

  echo "Promotion breakdown: ${txt_out}"
  echo "Promotion breakdown CSV: ${csv_out}"
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
  local trigger_log_file="${results_dir}/failover_trigger.log"
  local sysbench_log="${results_dir}/sysbench_run.log"
  local timing_file="${results_dir}/sysbench_timing.txt"

  failover_defaults

  local trigger_log trigger_wall trigger_utc edition method target_pod scenario trx_profile
  trigger_wall=$(failover_trigger_wall_second_from_timing "${timing_file}")
  trigger_log=$(failover_trigger_log_second_from_timing "${timing_file}")
  trigger_utc=""
  edition="unknown"
  method="unknown"
  target_pod=""
  scenario="mixed"
  trx_profile="mixed"

  if [[ -f "${timing_file}" ]]; then
    # shellcheck disable=SC1090
    source "${timing_file}" 2>/dev/null || true
    trigger_wall=$(failover_trigger_wall_second_from_timing "${timing_file}")
    trigger_log=$(failover_trigger_log_second_from_timing "${timing_file}")
    scenario="${FAILOVER_SCENARIO:-mixed}"
    trx_profile="${TPCC_TRX_PROFILE:-mixed}"
  fi
  local trigger_method=""
  if [[ -f "${event_file}" ]]; then
    trigger_utc=$(grep -E '^FAILOVER_TRIGGER_UTC=' "${event_file}" | tail -1 | cut -d= -f2- || true)
    edition=$(grep -E '^FAILOVER_EDITION=' "${event_file}" | tail -1 | cut -d= -f2- || echo "unknown")
    method=$(grep -E '^FAILOVER_METHOD=' "${event_file}" | tail -1 | cut -d= -f2- || echo "unknown")
    target_pod=$(grep -E '^FAILOVER_TARGET_POD=' "${event_file}" | tail -1 | cut -d= -f2- || true)
    trigger_method=$(grep -E '^FAILOVER_ADVANCED_TRIGGER_METHOD=' "${event_file}" | tail -1 | cut -d= -f2- || true)
    if [[ -z "${trigger_method}" ]]; then
      trigger_method="${method}"
    fi
  fi
  : "${trigger_method:=${FAILOVER_ADVANCED_TRIGGER_METHOD:-pod_delete}}"

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

  # Prefer the actual sub-second fire epoch over the planned integer trigger second.
  trigger_wall=$(failover_trigger_wall_subsec "${results_dir}" "${timing_file}")

  local detect_guard_sec="${FAILOVER_DETECT_GUARD_SEC:-0}"

  awk -v log_trigger="${trigger_log}" \
      -v wall_trigger="${trigger_wall}" \
      -v trigger_utc="${trigger_utc}" \
      -v edition="${edition}" \
      -v scenario="${scenario}" \
      -v trx_profile="${trx_profile}" \
      -v method="${method}" \
      -v trigger_method="${trigger_method}" \
      -v target_pod="${target_pod}" \
      -v tpcc_check="${tpcc_check}" \
      -v recovery_pct="${FAILOVER_RECOVERY_THRESHOLD}" \
      -v stable="${FAILOVER_RECOVERY_STABLE_SEC}" \
      -v outage_ratio="${FAILOVER_OUTAGE_TPS_RATIO}" \
      -v parsed_env="${parsed_env}" \
      -v monitor="${monitor}" \
      -v monitor_offset="${monitor_offset}" \
      -v detect_guard="${detect_guard_sec}" \
      -v detect_window="${FAILOVER_DETECT_WINDOW_SEC:-60}" \
      -v planned_window="${FAILOVER_PLANNED_DETECT_WINDOW_SEC:-10}" \
      -v primary_before="${primary_before}" \
      -v primary_after="${primary_after}" \
      -v primary_changed="${primary_changed}" \
      -v timeseries="${timeseries}" \
      -v k8s_log="${k8s_log}" \
      -v do_log="${do_log}" \
      -v trigger_log_file="${trigger_log_file}" \
      -v sysbench_log="${sysbench_log}" \
      -v generated_utc="${generated_utc}" \
      -f - > "${out_file}" <<'AWK'
BEGIN {
  failure_detect = -1
  failure_detect_abs = -1
  promote_sec = -1
  planned_outage_start = -1
  planned_downtime = -1
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
  connect_fail = -1
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
    if (sec < log_trigger && tps > 0) { pre_sum += tps; pre_cnt++ }
    if (sec < log_trigger && qps > 0) { pre_qps_sum += qps; pre_qps_cnt++ }
    if (sec < log_trigger) {
      pre_err_sum += err
      pre_reconn_sum += reconn
      pre_err_cnt++
    }
    if (sec >= log_trigger) {
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
function is_planned_mode() {
  return (trigger_method == "set_as_primary" || trigger_method == "group_replication_set_as_primary")
}
function host_changed(f,    host) {
  host = f[4]
  if (primary_before == "" || primary_before == "N/A") return 1
  if (host == "" || host == "ERROR") return 0
  return (host != primary_before)
}
function is_primary_elected(f,    wo, role, gr) {
  if (f[3] != "1") return 0
  wo = monitor_write_ok(f)
  if (wo != 1) return 0
  role = monitor_gr_role(f)
  gr = monitor_gr_state(f)
  if (edition == "advanced") {
    if (!(role == "PRIMARY" && (gr == "ONLINE" || gr == "PRIMARY"))) return 0
  }
  if (!host_changed(f)) return 0
  return 1
}
function compute_rto(    sec, stable_count, computed) {
  computed = -1
  stable_count = 0
  for (sec = log_trigger; sec <= load_end_sec; sec++) {
    if (!(sec in tps_arr)) continue
    if (baseline > 0 && tps_arr[sec] >= recovery_threshold) {
      stable_count++
      if (stable_count >= stable && computed < 0) {
        computed = sec - log_trigger - stable + 2
        if (computed < 0) computed = 0
      }
    } else {
      stable_count = 0
    }
  }
  return computed
}
function detect_connect_failure_ttd(    sysbench_sec, rel, guard, window) {
  if (monitor == "" || ( (getline _ < monitor) <= 0 )) return -1
  close(monitor)
  # Default guard=0: first connect_ok=0 at/after trigger epoch only.
  guard = (detect_guard == "" ? 0 : detect_guard + 0)
  window = (detect_window == "" ? 0 : detect_window + 0)
  while ((getline line < monitor) > 0) {
    split(line, f, "\t")
    if (f[1] == "timestamp_utc") continue
    sysbench_sec = (f[2] + 0) - monitor_offset
    rel = sysbench_sec - wall_trigger
    if (rel < -guard) continue
    # Stop once past the plausible detection window so an unrelated late
    # connection blip cannot masquerade as the failover detection.
    if (window > 0 && rel > window) break
    if (f[3] != "1") return (rel < 0 ? 0 : rel)
  }
  close(monitor)
  return -1
}
function detect_planned_outage_start(    sysbench_sec, rel, guard, window, wo) {
  if (monitor == "" || ( (getline _ < monitor) <= 0 )) return -1
  close(monitor)
  guard = (detect_guard == "" ? 0 : detect_guard + 0)
  window = (planned_window == "" ? 10 : planned_window + 0)
  while ((getline line < monitor) > 0) {
    split(line, f, "\t")
    if (f[1] == "timestamp_utc") continue
    sysbench_sec = (f[2] + 0) - monitor_offset
    rel = sysbench_sec - wall_trigger
    if (rel < -guard) continue
    if (window > 0 && rel > window) break
    wo = monitor_write_ok(f)
    if (f[3] != "1" || wo == 0)
      return (rel < 0 ? 0 : rel)
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
  if (rto_rel >= 0) end_abs = log_trigger + rto_rel
  if (promote_rel >= 0 && log_trigger + promote_rel > end_abs)
    end_abs = log_trigger + promote_rel
  if (monitor == "" || ( (getline _ < monitor) <= 0 )) return 0
  close(monitor)
  while ((getline line < monitor) > 0) {
    split(line, f, "\t")
    if (f[1] == "timestamp_utc") continue
    sysbench_sec = (f[2] + 0) - monitor_offset
    if (sysbench_sec < wall_trigger || sysbench_sec > end_abs) continue
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
  start = log_trigger + (fail_rel >= 0 ? fail_rel : 0)
  end = load_end_sec
  if (rto_rel >= 0) end = log_trigger + rto_rel
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
function load_monitor(    f, host, ro, gr, elapsed, sysbench_sec, saw_outage, wo, rel, pwindow) {
  if (monitor == "" || ( (getline _ < monitor) <= 0 )) return
  close(monitor)
  saw_outage = 0
  planned_outage_start = -1
  pwindow = (planned_window == "" ? 10 : planned_window + 0)
  while ((getline line < monitor) > 0) {
    split(line, f, "\t")
    if (f[1] == "timestamp_utc") continue
    elapsed = f[2] + 0
    sysbench_sec = elapsed - monitor_offset
    rel = sysbench_sec - wall_trigger
    wo = monitor_write_ok(f)
    if (primary_before == "N/A" && sysbench_sec < wall_trigger && f[3] == "1" && f[4] != "ERROR")
      primary_before = f[4]
    if (sysbench_sec < wall_trigger) continue
    if (is_planned_mode()) {
      if (!saw_outage) {
        if ((f[3] != "1" || wo == 0) && (pwindow <= 0 || rel <= pwindow)) {
          saw_outage = 1
          planned_outage_start = (rel < 0 ? 0 : rel)
          if (f[3] != "1" && connect_fail < 0) connect_fail = planned_outage_start
        } else if (is_primary_elected(f) && promote_sec < 0) {
          # Zero-downtime planned switch: mark promote at first new PRIMARY.
          promote_sec = rel
          planned_outage_start = -2
        }
      } else if (promote_sec < 0 && is_primary_elected(f)) {
        promote_sec = rel
      }
    } else {
      if (f[3] != "1") {
        if (connect_fail < 0) connect_fail = rel
        saw_outage = 1
        continue
      }
      if (saw_outage && promote_sec < 0 && is_primary_elected(f))
        promote_sec = rel
    }
    host = f[4]
    if (primary_after == "N/A" && host != "ERROR" && is_primary_elected(f))
      primary_after = host
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

  planned_downtime = -1
  if (is_planned_mode()) {
    failure_detect = -1
    if (planned_outage_start == -2 && promote_sec >= 0) {
      # Zero-downtime planned switchover.
      planned_downtime = 0
      promote_after_detect = 0
    } else if (planned_outage_start >= 0 && promote_sec >= 0) {
      planned_downtime = promote_sec - planned_outage_start
      if (planned_downtime < 0) planned_downtime = -1
      promote_after_detect = planned_downtime
    } else {
      promote_after_detect = -1
    }
  } else {
    failure_detect = detect_connect_failure_ttd()
    if (failure_detect >= 0) failure_detect_abs = wall_trigger + failure_detect
    promote_after_detect = phase_duration(promote_sec, failure_detect)
  }

  computed_rto = compute_rto()
  if (computed_rto >= 0) rto = computed_rto

  writes_failed = count_write_probe_failures(rto, promote_sec)
  tx_window_start = failure_detect
  if (is_planned_mode() && planned_outage_start >= 0) tx_window_start = planned_outage_start
  tx_failed = failover_tx_failures(tx_window_start, rto)

  print "=== Failover Extended Metrics ==="
  print "Generated:              " generated_utc
  print "Edition:                  " edition
  print "Scenario:                 " scenario
  print "TPC-C profile:            " trx_profile
  print "Trigger method:           " method
  print "Trigger UTC:              " (trigger_utc != "" ? trigger_utc : "N/A")
  if (log_trigger != wall_trigger) {
    print "Trigger second (wall):    " wall_trigger " (warmup + baseline, monitor alignment)"
    print "Trigger second (log):     " log_trigger " (sysbench report timeline / graphs)"
  } else {
    print "Trigger second:           " log_trigger " (from sysbench start)"
  }
  print "Target pod:               " (target_pod != "" ? target_pod : "N/A")
  print ""
  print "--- Timing ---"
  if (is_planned_mode()) {
    print "Time to detect failure:   N/A (planned switchover; connect detect not used)"
    if (promote_after_detect >= 0)
      printf "Time to promote primary:  %.3f s (%.0f ms · first write/connect failure → new PRIMARY + write_ok)\n", promote_after_detect, promote_after_detect * 1000
    else
      print "Time to promote primary:  NOT_DETECTED (monitor off or no promotion signal seen)"
    if (planned_downtime >= 0)
      printf "Total failover time:      %.3f s (%.0f ms · planned write-path downtime)\n", planned_downtime, planned_downtime * 1000
    else
      print "Total failover time:      NOT_DETECTED"
  } else if (failure_detect >= 0)
    printf "Time to detect failure:   %.3f s (%.0f ms · from trigger, first connect failure connect_ok=0)\n", failure_detect, failure_detect * 1000
  else
    print "Time to detect failure:   NOT_DETECTED"
  if (!is_planned_mode()) {
    if (promote_after_detect >= 0)
      printf "Time to promote primary:  %.3f s (%.0f ms · from first connect failure, new PRIMARY hostname + write_ok)\n", promote_after_detect, promote_after_detect * 1000
    else
      print "Time to promote primary:  NOT_DETECTED (monitor off or no promotion signal seen)"
    if (promote_sec >= 0)
      printf "Total failover time:      %.3f s (%.0f ms · downtime from trigger to promotion)\n", promote_sec, promote_sec * 1000
    else
      print "Total failover time:      NOT_DETECTED"
  }
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
  printf "Sysbench data ends at sec:      %d (expect ~%d)\n", load_end_sec, log_trigger + stable
  if (load_end_sec > 0 && load_end_sec < log_trigger + 10)
    print "WARNING: Sysbench stopped early — reconnect metrics may be incomplete"
  if (load_end_sec > 0 && load_end_sec < log_trigger)
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
  if (trigger_log_file != "") print "Trigger log:              " trigger_log_file
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

  # Walk edition/<iterN>/<trigger_method>/<tN>/<scenario>/ (any subset of nesting).
  _walk_failover_result_dirs() {
    local edition="$1"
    local parent_dir="$2"
    local label_prefix="$3"
    local child_dir child_name label scenario_dir

    for child_dir in "${parent_dir}"/*/; do
      [[ -d "${child_dir}" ]] || continue
      child_name=$(basename "${child_dir}")
      [[ "${child_name}" == "graphs" ]] && continue

      if [[ "${child_name}" =~ ^t[0-9]+$ ]] \
        || [[ "${child_name}" =~ ^iter[0-9]+$ ]] \
        || failover_is_advanced_trigger_method "${child_name}"; then
        if [[ -n "${label_prefix}" ]]; then
          label="${label_prefix}/${child_name}"
        else
          label="${child_name}"
        fi
        _walk_failover_result_dirs "${edition}" "${child_dir}" "${label}"
        continue
      fi

      scenario_dir="${child_dir}"
      [[ -f "${scenario_dir}/failover_kpi.csv" ]] || continue
      found_scenario=1
      if [[ -n "${label_prefix}" ]]; then
        label="${label_prefix}/${child_name}"
      else
        label="${child_name}"
      fi
      _append_failover_scenario_results "${edition}" "${label}" "${scenario_dir}"
    done
  }

  for edition_dir in "${results_root}"/*/; do
    [[ -d "${edition_dir}" ]] || continue
    local edition
    edition=$(basename "${edition_dir}")
    [[ "${edition}" == "graphs" ]] && continue

    local found_scenario=0
    _walk_failover_result_dirs "${edition}" "${edition_dir}" ""

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
    local trigger_log
    trigger_log=$(failover_trigger_log_second_from_timing "${timing_file}")
    if [[ -f "${timing_file}" ]]; then
      # shellcheck disable=SC1090
      source "${timing_file}" 2>/dev/null || true
      trigger_log=$(failover_trigger_log_second_from_timing "${timing_file}")
    fi
    _failover_parse_sysbench_intervals "${sysbench_log}" "${trigger_log}" \
      "${FAILOVER_RECOVERY_THRESHOLD}" "${FAILOVER_RECOVERY_STABLE_SEC}" \
      "${FAILOVER_OUTAGE_TPS_RATIO}" "${FAILOVER_OBSERVE_SEC}" > "${parsed_file}"
  fi

  export_failover_timeseries "${scenario_dir}" 2>/dev/null || true

  _failover_backfill_observability_artifacts "${scenario_dir}"

  write_failover_kpi "${scenario_dir}"
  write_failover_extended_metrics "${scenario_dir}"
  write_failover_promotion_breakdown "${scenario_dir}"
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
