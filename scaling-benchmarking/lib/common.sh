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

require_config() {
  : "${ENGINE:?Set ENGINE in benchmark.conf (standard or advanced)}"
  case "${ENGINE}" in
    standard|advanced) ;;
    *)
      echo "ERROR: ENGINE must be 'standard' or 'advanced' (got: ${ENGINE})" >&2
      exit 1
      ;;
  esac
  : "${MYSQL_HOST:?Set MYSQL_HOST in benchmark.conf}"
  : "${MYSQL_PORT:?Set MYSQL_PORT in benchmark.conf}"
  : "${MYSQL_USER:?Set MYSQL_USER in benchmark.conf}"
  : "${MYSQL_PASSWORD:?Set MYSQL_PASSWORD in benchmark.conf}"
  : "${MYSQL_DB:?Set MYSQL_DB in benchmark.conf}"
  : "${SCALE_TRIGGER_DELAY:?Set SCALE_TRIGGER_DELAY in benchmark.conf}"
  : "${CLUSTER_ID:?Set CLUSTER_ID in benchmark.conf}"
  : "${SCALE_TARGET_SIZE:?Set SCALE_TARGET_SIZE in benchmark.conf}"
  : "${DO_API_TOKEN:?Set DO_API_TOKEN in benchmark.conf}"
}

setup_paths() {
  local root
  root="$(scaling_root)"
  export BENCH_ROOT="$(bench_root)"
  export SCALING_ROOT="${root}"
  export PATH="${BENCH_ROOT}/sysbench-1.1/bin:${PATH}"
  # shellcheck source=/dev/null
  source "${BENCH_ROOT}/sysbench_mysql_opts.sh"
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

tpcc_tables_ready() {
  export TPCC_THREADS="${TPCC_PREP_THREADS:-${TPCC_THREADS:-16}}"
  if run_tpcc check >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

tpcc_dir() {
  echo "${TPCC_DIR:-${BENCH_ROOT}/TPCC/sysbench-tpcc}"
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

  tables="${TPCC_TABLES:-10}"
  scale="${TPCC_SCALE:-10}"
  threads="${TPCC_THREADS:-16}"
  force_pk="${TPCC_FORCE_PK:-1}"
  trx_level="${TPCC_TRX_LEVEL:-RR}"

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
      local ignore_errors="${TPCC_IGNORE_ERRORS:-1290,1053,2013,2006,3100}"
      local reconnect="${TPCC_RECONNECT:-1}"
      run_sysbench_tpcc "${tpcc}" "${opts[@]}" \
        --time="${run_time}" \
        --warmup-time="${TPCC_WARMUP_SEC:-0}" \
        --report-interval="${TPCC_REPORT_INTERVAL:-1}" \
        --mysql-ignore-errors="${ignore_errors}" \
        --reconnect="${reconnect}" \
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
