#!/usr/bin/env bash
# Shared helpers for scaling-benchmarking
set -euo pipefail

scaling_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd
}

bench_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd
}

log_phase() {
  local phase="${1:?phase required}"
  local message="${2:-}"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "[${ts}] PHASE=${phase} ${message}"
}

epoch_to_utc() {
  local epoch="${1:?epoch required}"
  if date -u -r 0 +%Y >/dev/null 2>&1; then
    date -u -r "${epoch}" +%Y-%m-%dT%H:%M:%SZ
  else
    date -u -d "@${epoch}" +%Y-%m-%dT%H:%M:%SZ
  fi
}

# Prefix sysbench report-interval lines with wall-clock UTC. Set by run_benchmark.sh:
#   TPCC_RUN_START_EPOCH, TPCC_SYSBENCH_OFFSET_SEC
prefix_tpcc_line_timestamp() {
  # Empty lines are valid (sysbench prints blank lines before report-interval output).
  local line="${1-}"
  if [[ "${line}" =~ ^\[[[:space:]]*([0-9]+)s[[:space:]]*\] ]]; then
    local elapsed="${BASH_REMATCH[1]}"
    local run_start="${TPCC_RUN_START_EPOCH:-0}"
    local offset="${TPCC_SYSBENCH_OFFSET_SEC:-0}"
    if [[ "${run_start}" -gt 0 ]]; then
      local ts
      ts="$(epoch_to_utc $((run_start + offset + elapsed)))"
      printf '[%s] %s\n' "${ts}" "${line}"
      return 0
    fi
  fi
  printf '%s\n' "${line}"
}

load_config() {
  local config_file="${1:?config file required}"
  if [[ ! -f "${config_file}" ]]; then
    echo "ERROR: Config not found: ${config_file}" >&2
    echo "Copy benchmark.conf.example to benchmark.conf and edit credentials." >&2
    exit 1
  fi
  # shellcheck source=/dev/null
  source "${config_file}"
}

scaling_enabled() {
  [[ "${SKIP_SCALING:-0}" != "1" ]]
}

k8s_monitor_enabled() {
  [[ -n "${K8S_KUBECONFIG:-}" && -f "${K8S_KUBECONFIG:-/nonexistent}" ]]
}

gib_to_mib() {
  local gib="${1:?GiB value required}"
  echo $(( gib * 1024 ))
}

# Extract vCPU count from a DO slug (e.g. "gd-8vcpu-32gb" -> 8).
slug_vcpu() {
  local slug="${1:-}" match
  match="$(echo "${slug}" | grep -oE '[0-9]+vcpu' | grep -oE '[0-9]+')" || true
  echo "${match:-0}"
}

# Extract memory GB from a DO slug (e.g. "gd-8vcpu-32gb" -> 32).
slug_mem_gb() {
  local slug="${1:-}" match
  match="$(echo "${slug}" | grep -oE '[0-9]+gb' | grep -oE '[0-9]+')" || true
  echo "${match:-0}"
}

# Compare initial vs target state and print a human-readable scaling description.
# Output: one or more lines like "vertical_scale_up (4vcpu/16gb -> 8vcpu/32gb)"
# Sets SCALE_TYPES (comma-separated) for programmatic use.
determine_scale_type() {
  SCALE_TYPES=""
  SCALE_DESCRIPTION=""

  if ! scaling_enabled; then
    SCALE_TYPES="none"
    SCALE_DESCRIPTION="scaling disabled"
    return
  fi

  local parts=()

  # Vertical: compare slugs
  if [[ -n "${INITIAL_SIZE:-}" && -n "${SCALE_TARGET_SIZE:-}" ]]; then
    if [[ "${INITIAL_SIZE}" != "${SCALE_TARGET_SIZE}" ]]; then
      local init_cpu init_mem target_cpu target_mem
      init_cpu="$(slug_vcpu "${INITIAL_SIZE}")"
      init_mem="$(slug_mem_gb "${INITIAL_SIZE}")"
      target_cpu="$(slug_vcpu "${SCALE_TARGET_SIZE}")"
      target_mem="$(slug_mem_gb "${SCALE_TARGET_SIZE}")"

      if (( target_cpu > init_cpu || target_mem > init_mem )); then
        parts+=("vertical_scale_up (${INITIAL_SIZE} -> ${SCALE_TARGET_SIZE})")
      elif (( target_cpu < init_cpu || target_mem < init_mem )); then
        parts+=("vertical_scale_down (${INITIAL_SIZE} -> ${SCALE_TARGET_SIZE})")
      else
        parts+=("vertical_change (${INITIAL_SIZE} -> ${SCALE_TARGET_SIZE})")
      fi
    fi
  fi

  # Horizontal: compare node counts
  if [[ -n "${INITIAL_NUM_NODES:-}" && -n "${SCALE_NUM_NODES:-}" ]]; then
    if (( SCALE_NUM_NODES > INITIAL_NUM_NODES )); then
      parts+=("horizontal_scale_up (${INITIAL_NUM_NODES} -> ${SCALE_NUM_NODES} nodes)")
    elif (( SCALE_NUM_NODES < INITIAL_NUM_NODES )); then
      parts+=("horizontal_scale_down (${INITIAL_NUM_NODES} -> ${SCALE_NUM_NODES} nodes)")
    fi
  fi

  # Storage: compare storage GiB
  if [[ -n "${INITIAL_STORAGE_SIZE_GIB:-}" && -n "${SCALE_STORAGE_SIZE_GIB:-}" ]]; then
    if (( SCALE_STORAGE_SIZE_GIB > INITIAL_STORAGE_SIZE_GIB )); then
      parts+=("storage_scale_up (${INITIAL_STORAGE_SIZE_GIB} -> ${SCALE_STORAGE_SIZE_GIB} GiB)")
    elif (( SCALE_STORAGE_SIZE_GIB < INITIAL_STORAGE_SIZE_GIB )); then
      parts+=("storage_scale_down (${INITIAL_STORAGE_SIZE_GIB} -> ${SCALE_STORAGE_SIZE_GIB} GiB)")
    fi
  fi

  if [[ ${#parts[@]} -eq 0 ]]; then
    SCALE_TYPES="unknown"
    SCALE_DESCRIPTION="scaling target matches initial state or initial state unknown"
    return
  fi

  # Build comma-separated type list and multi-line description
  local types=()
  local t
  for p in "${parts[@]}"; do
    t="${p%% \(*}"
    types+=("${t}")
  done
  SCALE_TYPES="$(IFS=,; echo "${types[*]}")"
  SCALE_DESCRIPTION="$(printf '%s\n' "${parts[@]}")"
}

# Update a KEY="value" line in a config file. Only replaces the value portion;
# preserves comments and surrounding lines.
_update_conf_value() {
  local file="${1}" key="${2}" value="${3}"
  if grep -q "^${key}=" "${file}" 2>/dev/null; then
    local escaped_value
    escaped_value="$(printf '%s' "${value}" | sed 's/[&/\]/\\&/g')"
    sed -i.bak "s|^${key}=.*|${key}=\"${escaped_value}\"|" "${file}"
    rm -f "${file}.bak"
  fi
}

# Write auto-fetched values back into the benchmark.conf file so it becomes
# self-documenting with the actual values used for this cluster.
_save_fetched_to_conf() {
  local config_file="${1:?config file required}"
  shift
  local -a updated_keys=("$@")

  if [[ ${#updated_keys[@]} -eq 0 ]]; then
    return 0
  fi

  for key in "${updated_keys[@]}"; do
    local val=""
    case "${key}" in
      MYSQL_HOST)               val="${MYSQL_HOST:-}" ;;
      MYSQL_PORT)               val="${MYSQL_PORT:-}" ;;
      MYSQL_USER)               val="${MYSQL_USER:-}" ;;
      MYSQL_PASSWORD)           val="${MYSQL_PASSWORD:-}" ;;
      INITIAL_SIZE)             val="${INITIAL_SIZE:-}" ;;
      INITIAL_NUM_NODES)        val="${INITIAL_NUM_NODES:-}" ;;
      INITIAL_STORAGE_SIZE_GIB) val="${INITIAL_STORAGE_SIZE_GIB:-}" ;;
    esac
    if [[ -n "${val}" ]]; then
      _update_conf_value "${config_file}" "${key}" "${val}"
    fi
  done

  log_phase "0_FETCH" "saved fetched values to ${config_file}"
}

# Fetch cluster details and connection info from doctl.
# Always fetches when CLUSTER_ID + DO_API_TOKEN are set, overwriting stale values
# so the config always reflects the live cluster state.
# Pass the config file path as $1 to write fetched values back; omit to skip.
fetch_cluster_details() {
  local config_file="${1:-}"

  if [[ -z "${CLUSTER_ID:-}" || -z "${DO_API_TOKEN:-}" ]]; then
    return 1
  fi
  if ! command -v doctl >/dev/null 2>&1; then
    return 1
  fi

  log_phase "0_FETCH" "fetching cluster details from doctl (cluster=${CLUSTER_ID})"

  local -a updated_keys=()

  # Fetch cluster info: slug, node count, storage
  local cluster_info
  cluster_info="$(run_doctl databases get "${CLUSTER_ID}" \
    --format Size,NumNodes,StorageMib --no-header 2>/dev/null)" || {
    log_phase "0_FETCH" "WARNING: failed to fetch cluster info from doctl"
    return 1
  }
  local fetched_size fetched_nodes fetched_storage_mib
  read -r fetched_size fetched_nodes fetched_storage_mib <<< "${cluster_info}"

  if [[ -n "${fetched_size}" ]]; then
    INITIAL_SIZE="${fetched_size}"
    updated_keys+=("INITIAL_SIZE")
    log_phase "0_FETCH" "INITIAL_SIZE=${INITIAL_SIZE}"
  fi
  if [[ -n "${fetched_nodes}" ]]; then
    INITIAL_NUM_NODES="${fetched_nodes}"
    updated_keys+=("INITIAL_NUM_NODES")
    log_phase "0_FETCH" "INITIAL_NUM_NODES=${INITIAL_NUM_NODES}"
  fi
  if [[ -n "${fetched_storage_mib}" ]]; then
    INITIAL_STORAGE_SIZE_GIB=$(( fetched_storage_mib / 1024 ))
    updated_keys+=("INITIAL_STORAGE_SIZE_GIB")
    log_phase "0_FETCH" "INITIAL_STORAGE_SIZE_GIB=${INITIAL_STORAGE_SIZE_GIB} (${fetched_storage_mib} MiB)"
  fi

  # Fetch connection info: host, port, user, password
  local conn_info
  conn_info="$(run_doctl databases connection "${CLUSTER_ID}" \
    --format Host,Port,User,Password --no-header 2>/dev/null)" || {
    log_phase "0_FETCH" "WARNING: failed to fetch connection info from doctl"
    return 1
  }
  local fetched_host fetched_port fetched_user fetched_pass
  read -r fetched_host fetched_port fetched_user fetched_pass <<< "${conn_info}"

  if [[ -n "${fetched_host}" ]]; then
    MYSQL_HOST="${fetched_host}"
    updated_keys+=("MYSQL_HOST")
    log_phase "0_FETCH" "MYSQL_HOST=${MYSQL_HOST}"
  fi
  if [[ -n "${fetched_port}" ]]; then
    MYSQL_PORT="${fetched_port}"
    updated_keys+=("MYSQL_PORT")
    log_phase "0_FETCH" "MYSQL_PORT=${MYSQL_PORT}"
  fi
  if [[ -n "${fetched_user}" ]]; then
    MYSQL_USER="${fetched_user}"
    updated_keys+=("MYSQL_USER")
    log_phase "0_FETCH" "MYSQL_USER=${MYSQL_USER}"
  fi
  if [[ -n "${fetched_pass}" ]]; then
    MYSQL_PASSWORD="${fetched_pass}"
    updated_keys+=("MYSQL_PASSWORD")
    log_phase "0_FETCH" "MYSQL_PASSWORD=******"
  fi

  # Write fetched values back to config file
  if [[ -n "${config_file}" && -f "${config_file}" && ${#updated_keys[@]} -gt 0 ]]; then
    _save_fetched_to_conf "${config_file}" "${updated_keys[@]}"
  fi
}

require_config() {
  : "${ENGINE:?Set ENGINE in benchmark.conf (standard or advanced)}"
  case "${ENGINE}" in
    standard|advanced) ;;
    *)
      echo "ERROR: ENGINE must be 'standard' or 'advanced' (got: ${ENGINE})" >&2
      exit 1
      ;;
  esac
  : "${CLUSTER_ID:?Set CLUSTER_ID in benchmark.conf}"
  : "${MYSQL_DB:?Set MYSQL_DB in benchmark.conf}"

  # Convert GIB -> MIB for storage (used by doctl resize API)
  if [[ -n "${SCALE_STORAGE_SIZE_GIB:-}" ]]; then
    SCALE_STORAGE_SIZE_MIB="$(gib_to_mib "${SCALE_STORAGE_SIZE_GIB}")"
  fi

  # Auto-fetch connection + initial state from doctl when not manually set.
  # Pass config file path so fetched values are written back to benchmark.conf.
  if [[ -n "${DO_API_TOKEN:-}" ]]; then
    fetch_cluster_details "${BENCHMARK_CONF_FILE:-}"
  fi

  : "${MYSQL_HOST:?Set MYSQL_HOST in benchmark.conf or provide DO_API_TOKEN to auto-fetch}"
  : "${MYSQL_PORT:?Set MYSQL_PORT in benchmark.conf or provide DO_API_TOKEN to auto-fetch}"
  : "${MYSQL_USER:?Set MYSQL_USER in benchmark.conf or provide DO_API_TOKEN to auto-fetch}"
  : "${MYSQL_PASSWORD:?Set MYSQL_PASSWORD in benchmark.conf or provide DO_API_TOKEN to auto-fetch}"

  if ! scaling_enabled; then
    return 0
  fi

  : "${SCALE_TRIGGER_DELAY:?Set SCALE_TRIGGER_DELAY in benchmark.conf}"
  : "${SCALE_TARGET_SIZE:?Set SCALE_TARGET_SIZE in benchmark.conf}"
  : "${DO_API_TOKEN:?Set DO_API_TOKEN in benchmark.conf}"
}

# ── K8s pod monitoring (observation only — scaling still uses doctl) ─────────

k8s_monitor_pid_file() {
  echo "${RUN_DIR:-.}/.k8s_monitor.pid"
}

start_k8s_monitor() {
  local output_dir="${1:?output directory required}"
  local poll_sec="${K8S_MONITOR_POLL_SEC:-5}"

  export KUBECONFIG="${K8S_KUBECONFIG}"
  export K8S_NAMESPACE="${K8S_NAMESPACE:-mysql}"
  export PXC_CLUSTER_NAME="${PXC_CLUSTER_NAME:-}"
  export PXC_MYSQL_ROOT_USER="${PXC_MYSQL_ROOT_USER:-root}"
  export PXC_MYSQL_ROOT_PASSWORD="${PXC_MYSQL_ROOT_PASSWORD:-}"
  export PXC_MYSQL_ROOT_SECRET="${PXC_MYSQL_ROOT_SECRET:-}"

  local monitor_script="${SCRIPT_DIR:-$(scaling_root)}/scripts/k8s_scaling_monitor.sh"
  if [[ ! -x "${monitor_script}" ]]; then
    log_phase "K8S_MONITOR" "ERROR: monitor script not found: ${monitor_script}"
    return 1
  fi

  log_phase "K8S_MONITOR" "starting background monitor (poll=${poll_sec}s)"
  bash "${monitor_script}" "${output_dir}" "${poll_sec}" &
  local pid=$!
  echo "${pid}" > "$(k8s_monitor_pid_file)"
  log_phase "K8S_MONITOR" "started (pid=${pid})"
}

stop_k8s_monitor() {
  local pid_file
  pid_file="$(k8s_monitor_pid_file)"
  if [[ ! -f "${pid_file}" ]]; then
    return 0
  fi
  local pid
  pid="$(cat "${pid_file}")"
  if kill -0 "${pid}" 2>/dev/null; then
    log_phase "K8S_MONITOR" "stopping monitor (pid=${pid})"
    kill -TERM "${pid}" 2>/dev/null || true
    wait "${pid}" 2>/dev/null || true
    log_phase "K8S_MONITOR" "monitor stopped"
  fi
  rm -f "${pid_file}"
}

parse_k8s_monitor_data() {
  local monitor_dir="${1:?monitor output directory required}"
  local parse_script="${SCRIPT_DIR:-$(scaling_root)}/scripts/parse_k8s_events.py"

  if [[ ! -f "${parse_script}" ]]; then
    log_phase "K8S_PARSE" "ERROR: parse script not found: ${parse_script}"
    return 1
  fi

  log_phase "K8S_PARSE" "parsing k8s monitor data"
  python3 "${parse_script}" "${monitor_dir}"
  log_phase "K8S_PARSE" "parse complete"
}

setup_paths() {
  local root
  root="$(scaling_root)"
  export BENCH_ROOT="$(bench_root)"
  export SCALING_ROOT="${root}"
  if [[ ! -f "${BENCH_ROOT}/sysbench_mysql_opts.sh" ]]; then
    echo "ERROR: benchmark repo root not found at BENCH_ROOT=${BENCH_ROOT}" >&2
    echo "Missing: ${BENCH_ROOT}/sysbench_mysql_opts.sh" >&2
    echo "Clone the full mysql-benchmark repo (not just scaling-benchmarking/) and run:" >&2
    echo "  cd ${BENCH_ROOT} && ./setup_benchmark.sh" >&2
    exit 1
  fi
  export PATH="${BENCH_ROOT}/sysbench-1.1/bin:${PATH}"
  # shellcheck source=/dev/null
  source "${BENCH_ROOT}/sysbench_mysql_opts.sh"
}

preflight_checks() {
  local sysbench tpcc
  sysbench="$("${BENCH_ROOT}/which_sysbench.sh")"
  if [[ ! -x "${sysbench}" ]]; then
    echo "ERROR: sysbench not executable: ${sysbench}" >&2
    echo "Run from repo root: ./setup_benchmark.sh" >&2
    exit 1
  fi

  tpcc="$(tpcc_dir)"
  if [[ ! -f "${tpcc}/tpcc.lua" ]]; then
    echo "ERROR: Missing ${tpcc}/tpcc.lua" >&2
    echo "Run from repo root: ./setup_benchmark.sh" >&2
    exit 1
  fi

  if ! command -v mysql >/dev/null 2>&1; then
    echo "ERROR: mysql client not found in PATH" >&2
    echo "Install with: apt-get install -y mysql-client" >&2
    exit 1
  fi

  if scaling_enabled && ! command -v doctl >/dev/null 2>&1; then
    echo "ERROR: doctl not found in PATH (required when scaling is enabled)" >&2
    echo "Run from repo root: ./setup_benchmark.sh" >&2
    exit 1
  fi
}

mysql_admin() {
  mysql -h "${MYSQL_HOST}" -P "${MYSQL_PORT}" -u "${MYSQL_USER}" -p"${MYSQL_PASSWORD}" \
    --ssl-mode=REQUIRED "$@"
}

mysql_connectivity_check() {
  log_phase "0_CONNECT" "checking MySQL connectivity (${MYSQL_HOST}:${MYSQL_PORT})"
  if mysql_admin -e "SELECT VERSION() AS version, @@hostname AS hostname, @@sql_require_primary_key AS require_pk;"; then
    log_phase "0_CONNECT" "connection OK"
    return 0
  fi
  log_phase "0_CONNECT" "connection FAILED"
  return 1
}

ensure_database_exists() {
  mysql_admin -e "CREATE DATABASE IF NOT EXISTS \`${MYSQL_DB}\`;"
}

tpcc_tables_exist() {
  local tables="${TPCC_TABLES:-10}"
  local expected=$((tables * 9))
  local found
  found="$(mysql_admin -N -e "
    SELECT COUNT(*)
    FROM information_schema.tables
    WHERE table_schema = '${MYSQL_DB}'
      AND table_name REGEXP '^(warehouse|district|customer|orders|new_orders|order_line|stock|item|history)[0-9]+\$'
  ")"
  if [[ "${found}" -ge "${expected}" ]]; then
    return 0
  fi
  log_phase "1_INIT" "found ${found}/${expected} TPC-C tables in ${MYSQL_DB}"
  return 1
}

verify_tpcc_tables() {
  if [[ "${SKIP_TPCC_CHECK:-0}" == "1" ]]; then
    log_phase "1_INIT" "SKIP_TPCC_CHECK=1 — verifying TPC-C table names only (no consistency check)"
    tpcc_tables_exist
    return $?
  fi

  log_phase "1_INIT" "running sysbench tpcc check (threads=${TPCC_CHECK_THREADS})"
  run_tpcc check
}

tpcc_tables_ready() {
  if [[ "${SKIP_TPCC_CHECK:-0}" == "1" ]]; then
    tpcc_tables_exist
    return $?
  fi
  if run_tpcc check >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

tpcc_dir() {
  echo "${TPCC_DIR:-${BENCH_ROOT}/TPCC/sysbench-tpcc}"
}

ensure_tpcc_failover_patch() {
  local tpcc patch_script
  tpcc="$(tpcc_dir)"
  patch_script="${BENCH_ROOT}/scripts/patch_tpcc_failover.sh"
  if [[ ! -f "${patch_script}" ]]; then
    echo "WARNING: missing ${patch_script} — tpcc failover patch skipped" >&2
    return 0
  fi
  bash "${patch_script}" "${tpcc}"
}

ensure_tpcc_prepare_commit_patch() {
  local tpcc patch_script
  tpcc="$(tpcc_dir)"
  patch_script="${BENCH_ROOT}/scripts/patch_tpcc_prepare_commit.sh"
  if [[ ! -f "${patch_script}" ]]; then
    echo "WARNING: missing ${patch_script} — tpcc prepare commit patch skipped" >&2
    return 0
  fi
  bash "${patch_script}" "${tpcc}"
}

run_tpcc() {
  local subcommand="${1:?prepare|run|cleanup}"
  shift

  build_mysql_base_opts

  local tpcc tables scale threads force_pk trx_level
  tpcc="$(tpcc_dir)"
  if [[ ! -f "${tpcc}/tpcc.lua" ]]; then
    echo "ERROR: Missing ${tpcc}/tpcc.lua — run ../setup_benchmark.sh first" >&2
    exit 1
  fi

  if [[ "${subcommand}" == "run" ]]; then
    ensure_tpcc_failover_patch
  elif [[ "${subcommand}" == "prepare" ]]; then
    ensure_tpcc_prepare_commit_patch
  fi

  tables="${TPCC_TABLES:-10}"
  scale="${TPCC_SCALE:-10}"
  force_pk="${TPCC_FORCE_PK:-1}"
  trx_level="${TPCC_TRX_LEVEL:-RR}"

  case "${subcommand}" in
    check)
      threads="${TPCC_CHECK_THREADS:-${TPCC_PREP_THREADS:-16}}"
      ;;
    prepare|cleanup)
      threads="${TPCC_PREP_THREADS:-16}"
      ;;
    *)
      threads="${TPCC_THREADS:-16}"
      ;;
  esac

  local opts=(
    "${MYSQL_BASE_OPTS[@]}"
    "${MYSQL_SSL_OPTS[@]}"
    --tables="${tables}"
    --scale="${scale}"
    --threads="${threads}"
    --trx_level="${trx_level}"
    --force_pk="${force_pk}"
  )

  case "${subcommand}" in
    prepare|cleanup|check)
      run_sysbench_tpcc "${tpcc}" "${opts[@]}" "${subcommand}"
      ;;
    run)
      local run_time="${TPCC_MAX_TIME:-${TPCC_TOTAL_TIME:-3600}}"
      # Failover/resize: 1290,1836,1053,2013,2006,2055,2011,3100
      # TPC-C contention (sysbench defaults): 1205,1213,1020
      local ignore_errors="${TPCC_IGNORE_ERRORS:-1290,1836,1053,2013,2006,2055,2011,3100,1205,1213,1020}"
      run_sysbench_tpcc "${tpcc}" "${opts[@]}" \
        --time="${run_time}" \
        --warmup-time="${TPCC_WARMUP_SEC:-0}" \
        --report-interval="${TPCC_REPORT_INTERVAL:-1}" \
        --percentile="${TPCC_PERCENTILE:-99}" \
        --mysql-ignore-errors="${ignore_errors}" \
        --db-ps-mode=disable \
        run
      ;;
    *)
      echo "Unknown tpcc subcommand: ${subcommand}" >&2
      exit 1
      ;;
  esac
}

do_api_token() {
  echo "${DO_API_TOKEN:-${DIGITALOCEAN_ACCESS_TOKEN:-}}"
}

do_api_url() {
  echo "${DO_API_URL:-https://api.digitalocean.com}"
}

doctl_common_args() {
  echo "-u"
  echo "$(do_api_url)"
  local token
  token="$(do_api_token)"
  if [[ -n "${token}" ]]; then
    echo "-t"
    echo "${token}"
  fi
}

run_doctl() {
  if ! command -v doctl >/dev/null 2>&1; then
    echo "ERROR: doctl is required but not found in PATH" >&2
    return 1
  fi
  local -a args=()
  while IFS= read -r line; do
    [[ -n "${line}" ]] && args+=("${line}")
  done < <(doctl_common_args)
  doctl "${args[@]}" "$@"
}

# Verify DO_API_TOKEN works against production (api.digitalocean.com), not stage2.
do_api_auth_check() {
  local api_url
  api_url="$(do_api_url)"

  if [[ "${api_url}" == *internal.digitalocean.com* ]]; then
    log_phase "0_DO_API" "ERROR: DO_API_URL is stage2/internal (${api_url})"
    log_phase "0_DO_API" "Set DO_API_URL=https://api.digitalocean.com for production clusters"
    return 1
  fi

  log_phase "0_DO_API" "checking production API (${api_url})"
  if ! run_doctl account get --format Email --no-header >/dev/null 2>&1; then
    log_phase "0_DO_API" "ERROR: production API token rejected"
    log_phase "0_DO_API" "Create a token at https://cloud.digitalocean.com/account/api/tokens"
    log_phase "0_DO_API" "Stage2 tokens and doctl auth init do not work here — set DO_API_TOKEN in benchmark.conf"
    return 1
  fi

  log_phase "0_DO_API" "checking cluster ${CLUSTER_ID}"
  if ! run_doctl databases get "${CLUSTER_ID}" --format Name --no-header >/dev/null 2>&1; then
    log_phase "0_DO_API" "ERROR: cannot read cluster ${CLUSTER_ID} on production API"
    log_phase "0_DO_API" "Verify CLUSTER_ID and that the token owns this database"
    return 1
  fi

  log_phase "0_DO_API" "production API auth OK"
}

scale_num_nodes_requested() {
  [[ -n "${SCALE_NUM_NODES:-}" ]]
}

scale_storage_size_requested() {
  [[ -n "${SCALE_STORAGE_SIZE_MIB:-}" ]]
}

get_cluster_num_nodes() {
  local cluster_id="${1:?cluster id required}"
  run_doctl databases get "${cluster_id}" \
    --format NumNodes --no-header 2>/dev/null
}

scale_resize_command_description() {
  local api_url num_nodes storage_part="" num_nodes_part=""
  api_url="$(do_api_url)"
  if scale_num_nodes_requested; then
    num_nodes="${SCALE_NUM_NODES}"
    num_nodes_part=" --num-nodes ${num_nodes}"
  elif num_nodes="$(get_cluster_num_nodes "${CLUSTER_ID}")"; then
    num_nodes_part=" --num-nodes ${num_nodes} (current)"
  fi
  if scale_storage_size_requested; then
    storage_part=" --storage-size-mib ${SCALE_STORAGE_SIZE_MIB}"
  fi
  printf 'doctl -u %s -t <DO_API_TOKEN> databases resize %s --size %s%s%s' \
    "${api_url}" "${CLUSTER_ID}" "${SCALE_TARGET_SIZE}" "${num_nodes_part}" "${storage_part}"
}

run_scale_resize() {
  local num_nodes
  local -a resize_args=(
    databases resize "${CLUSTER_ID}"
    --size "${SCALE_TARGET_SIZE}"
  )

  if scale_num_nodes_requested; then
    num_nodes="${SCALE_NUM_NODES}"
  else
    num_nodes="$(get_cluster_num_nodes "${CLUSTER_ID}")" || return 1
  fi
  resize_args+=(--num-nodes "${num_nodes}")

  if scale_storage_size_requested; then
    resize_args+=(--storage-size-mib "${SCALE_STORAGE_SIZE_MIB}")
  fi
  run_doctl "${resize_args[@]}"
}

get_cluster_resize_state() {
  local cluster_id="${1:?cluster id required}"
  run_doctl databases get "${cluster_id}" \
    --format Status,Size,NumNodes,StorageMib --no-header 2>/dev/null
}

# Poll until cluster status=online, size slug, and any requested num_nodes/storage_mib match.
# Requires resize API to have been accepted (caller should skip poll on trigger failure).
# Writes poll lines to log_file; prints total wait seconds on stdout.
wait_for_cluster_resize() {
  local cluster_id="${1:?cluster id required}"
  local target_size="${2:?target size required}"
  local poll_sec="${3:-10}"
  local timeout_sec="${4:-1800}"
  local log_file="${5:?log file required}"
  local target_num_nodes="${6:-}"
  local target_storage_mib="${7:-}"

  local start_ts now_ts elapsed status size num_nodes storage_mib saw_resizing=0
  local poll_targets="size=${target_size}"
  if [[ -n "${target_num_nodes}" ]]; then
    poll_targets="${poll_targets} num_nodes=${target_num_nodes}"
  fi
  if [[ -n "${target_storage_mib}" ]]; then
    poll_targets="${poll_targets} storage_mib=${target_storage_mib}"
  fi

  start_ts=$(date +%s)
  echo "--- Polling cluster ${cluster_id} for ${poll_targets} (timeout=${timeout_sec}s) ---" \
    >> "${log_file}"

  while true; do
    now_ts=$(date +%s)
    elapsed=$((now_ts - start_ts))
    if [[ "${elapsed}" -ge "${timeout_sec}" ]]; then
      echo "ERROR: resize poll timed out after ${timeout_sec}s (last status=${status:-unknown} size=${size:-unknown} num_nodes=${num_nodes:-unknown} storage_mib=${storage_mib:-unknown})" \
        >> "${log_file}"
      return 1
    fi

    if ! read -r status size num_nodes storage_mib < <(get_cluster_resize_state "${cluster_id}"); then
      echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) poll status=unknown size=unknown num_nodes=unknown storage_mib=unknown elapsed=${elapsed}s" \
        >> "${log_file}"
      sleep "${poll_sec}"
      continue
    fi

    if [[ "${status}" == "resizing" ]]; then
      saw_resizing=1
    fi

    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) poll status=${status} size=${size} num_nodes=${num_nodes} storage_mib=${storage_mib} elapsed=${elapsed}s" \
      >> "${log_file}"

    if [[ "${status}" == "failed" ]]; then
      echo "ERROR: cluster status=failed" >> "${log_file}"
      return 1
    fi

    local num_nodes_ok=1 storage_ok=1
    if [[ -n "${target_num_nodes}" && "${num_nodes}" != "${target_num_nodes}" ]]; then
      num_nodes_ok=0
    fi
    if [[ -n "${target_storage_mib}" && "${storage_mib}" != "${target_storage_mib}" ]]; then
      storage_ok=0
    fi

    if [[ "${status}" == "online" \
        && "${size}" == "${target_size}" \
        && "${num_nodes_ok}" -eq 1 \
        && "${storage_ok}" -eq 1 \
        && "${saw_resizing}" -eq 1 ]]; then
      break
    fi

    sleep "${poll_sec}"
  done

  elapsed=$(( $(date +%s) - start_ts ))
  echo "Cluster resize confirmed: status=${status} size=${size} num_nodes=${num_nodes} storage_mib=${storage_mib} poll_duration=${elapsed}s" \
    >> "${log_file}"
  printf '%s\n' "${elapsed}"
}
