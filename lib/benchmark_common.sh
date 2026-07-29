#!/usr/bin/env bash
# Shared helpers for MySQL Standard vs Advanced benchmarking
set -euo pipefail

BENCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=/dev/null
source "${BENCH_ROOT}/bootstrap/sysbench_mysql_opts.sh"

load_benchmark_config() {
  local config_file="${1:?config file required}"
  if [[ ! -f "${config_file}" ]]; then
    echo "ERROR: Config not found: ${config_file}" >&2
    echo "Copy benchmark.conf.example to benchmark.conf and fill in credentials." >&2
    exit 1
  fi
  # shellcheck source=/dev/null
  source "${config_file}"
}

set_mysql_env_for_edition() {
  local edition="${1:?edition required (standard|advanced)}"
  local prefix upper
  prefix="$(echo "${edition}" | tr '[:lower:]' '[:upper:]')"

  local host_var="${prefix}_MYSQL_HOST"
  local port_var="${prefix}_MYSQL_PORT"
  local user_var="${prefix}_MYSQL_USER"
  local pass_var="${prefix}_MYSQL_PASSWORD"
  local db_var="${prefix}_MYSQL_DB"

  export MYSQL_HOST="${!host_var:?Set ${host_var} in config}"
  export MYSQL_PORT="${!port_var:?Set ${port_var} in config}"
  export MYSQL_USER="${!user_var:?Set ${user_var} in config}"
  export MYSQL_PASSWORD="${!pass_var:?Set ${pass_var} in config}"
  export MYSQL_DB="${!db_var:?Set ${db_var} in config}"

  build_mysql_base_opts
}

mysql_connectivity_check() {
  local edition="${1:?edition required}"
  local out_file="${2:?output file required}"

  set_mysql_env_for_edition "${edition}"

  echo "--- ${edition} connectivity ---" | tee -a "${out_file}"
  if mysql -h "${MYSQL_HOST}" -P "${MYSQL_PORT}" -u "${MYSQL_USER}" -p"${MYSQL_PASSWORD}" \
      --ssl-mode=REQUIRED "${MYSQL_DB}" \
      -e "SELECT VERSION() AS version, @@hostname AS hostname, @@sql_require_primary_key AS require_pk;" \
      2>/dev/null | tee -a "${out_file}"; then
    echo "${edition}: connection OK" | tee -a "${out_file}"
    return 0
  else
    echo "${edition}: connection FAILED" | tee -a "${out_file}"
    return 1
  fi
}

tpcc_dir() {
  echo "${TPCC_DIR:-${BENCH_ROOT}/TPCC/sysbench-tpcc}"
}

# True when tpcc_common.lua defines --trx_profile (mixed / write_only / read_heavy).
# Prefer grepping Lua over `sysbench help` so PATH/SYSBENCH_BIN glitches cannot false-negative mid-run.
tpcc_supports_trx_profile() {
  local tpcc="${1:-$(tpcc_dir)}"
  [[ -f "${tpcc}/tpcc_common.lua" ]] || return 1
  grep -qE '^\s*trx_profile\s*=' "${tpcc}/tpcc_common.lua"
}

run_tpcc_command() {
  local command="${1:?prepare|run|check|cleanup}"
  shift

  build_mysql_base_opts

  local tpcc
  tpcc="$(tpcc_dir)"
  if [[ ! -f "${tpcc}/tpcc.lua" ]]; then
    echo "ERROR: Missing ${tpcc}/tpcc.lua — run bootstrap/setup_benchmark.sh first" >&2
    exit 1
  fi

  local tables="${TPCC_TABLES:-10}"
  local scale="${TPCC_SCALE:-100}"
  local threads="${TPCC_THREADS:-16}"
  local force_pk="${TPCC_FORCE_PK:-1}"
  local trx_level="${TPCC_TRX_LEVEL:-RR}"

  local opts=(
    "${MYSQL_BASE_OPTS[@]}"
    "${MYSQL_SSL_OPTS[@]}"
    --tables="${tables}"
    --scale="${scale}"
    --threads="${threads}"
    --trx_level="${trx_level}"
    --force_pk="${force_pk}"
  )

  case "${command}" in
    prepare|check|cleanup)
      run_sysbench_tpcc "${tpcc}" "${opts[@]}" "${command}"
      ;;
    run)
      local time_sec="${TPCC_TIME:?TPCC_TIME required for run}"
      local warmup="${TPCC_WARMUP:-60}"
      local report_interval="${TPCC_REPORT_INTERVAL:-10}"
      run_sysbench_tpcc "${tpcc}" "${opts[@]}" \
        --time="${time_sec}" \
        --warmup-time="${warmup}" \
        --report-interval="${report_interval}" \
        run
      ;;
    *)
      echo "Unknown tpcc command: ${command}" >&2
      exit 1
      ;;
  esac
}

# Parse sysbench final report from a run log file.
# Sets: METRIC_TPS METRIC_QPS METRIC_LAT_AVG METRIC_LAT_P95 METRIC_LAT_P99
#       METRIC_TX_TOTAL METRIC_ERRORS METRIC_RECONNECTS
parse_sysbench_metrics() {
  local out_file="${1:?output file required}"

  METRIC_TPS=$(grep -E 'transactions:' "${out_file}" | tail -1 | awk '{print $3}' | tr -d '()' || echo "N/A")
  METRIC_QPS=$(grep -E 'queries:' "${out_file}" | tail -1 | awk '{print $3}' | tr -d '()' || echo "N/A")
  METRIC_LAT_AVG=$(grep -E 'avg:' "${out_file}" | tail -1 | awk '{print $2}' || echo "N/A")
  METRIC_LAT_P95=$(grep '95th percentile:' "${out_file}" | awk '{print $3}' || echo "N/A")
  METRIC_LAT_P99=$(grep '99th percentile:' "${out_file}" | awk '{print $3}' || echo "N/A")
  METRIC_TX_TOTAL=$(grep 'total number of transactions:' "${out_file}" | awk '{print $5}' || echo "N/A")
  METRIC_ERRORS=$(grep -E 'errors:' "${out_file}" | tail -1 | awk '{print $2}' | tr -d '()' || echo "N/A")
  METRIC_RECONNECTS=$(grep -E 'reconnects:' "${out_file}" | tail -1 | awk '{print $2}' | tr -d '()' || echo "N/A")
}

append_result_row() {
  local csv_file="${1:?csv required}"
  local edition="${2:?edition required}"
  local threads="${3:?threads required}"
  local duration="${4:?duration required}"
  local out_file="${5:?run output required}"

  parse_sysbench_metrics "${out_file}"
  echo "${edition},${threads},${duration},${METRIC_TPS},${METRIC_QPS},${METRIC_LAT_AVG},${METRIC_LAT_P95},${METRIC_LAT_P99},${METRIC_TX_TOTAL},${METRIC_ERRORS},${METRIC_RECONNECTS}" \
    >> "${csv_file}"
}

write_comparison_summary() {
  local csv_file="${1:?csv required}"
  local summary_file="${2:?summary required}"

  {
    echo "=== MySQL Standard vs Advanced — TPC-C Comparison ==="
    echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo ""
    printf "%-10s %8s %10s %12s %12s %12s %12s %8s\n" \
      "Edition" "Threads" "Duration" "TPS" "QPS" "Lat_avg" "Lat_p95" "Errors"
    echo "--------------------------------------------------------------------------------"

    tail -n +2 "${csv_file}" | while IFS=',' read -r edition threads duration tps qps lat_avg lat_p95 lat_p99 tx_total errors reconnects; do
      printf "%-10s %8s %10s %12s %12s %12s %12s %8s\n" \
        "${edition}" "${threads}" "${duration}s" "${tps}" "${qps}" "${lat_avg}" "${lat_p95}" "${errors}"
    done

    echo ""
    echo "--- Head-to-head (same threads + duration) ---"
    echo ""

    # Compare TPS for matching configs
    local std_lines adv_lines
    std_lines=$(grep '^standard,' "${csv_file}" || true)
    adv_lines=$(grep '^advanced,' "${csv_file}" || true)

    if [[ -z "${std_lines}" || -z "${adv_lines}" ]]; then
      echo "(insufficient data for comparison)"
      return
    fi

    printf "%-8s %-10s %14s %14s %12s\n" "Threads" "Duration" "Standard TPS" "Advanced TPS" "Winner"
    echo "----------------------------------------------------------------"

    while IFS=',' read -r _s threads duration s_tps _rest; do
      local a_tps winner
      a_tps=$(grep "^advanced,${threads},${duration}," "${csv_file}" | cut -d, -f4 || echo "N/A")
      if [[ "${s_tps}" != "N/A" && "${a_tps}" != "N/A" ]]; then
        if awk -v s="${s_tps}" -v a="${a_tps}" 'BEGIN { exit (a > s) ? 0 : 1 }'; then
          winner="Advanced"
        elif awk -v s="${s_tps}" -v a="${a_tps}" 'BEGIN { exit (s > a) ? 0 : 1 }'; then
          winner="Standard"
        else
          winner="Tie"
        fi
      else
        winner="N/A"
      fi
      printf "%-8s %-10s %14s %14s %12s\n" "${threads}" "${duration}s" "${s_tps}" "${a_tps}" "${winner}"
    done <<< "${std_lines}"

    echo ""
    echo "Full CSV: ${csv_file}"
  } | tee "${summary_file}"
}

# Default variables when MYSQL_VARS is unset
default_mysql_vars() {
  echo "version version_comment innodb_buffer_pool_size innodb_buffer_pool_instances innodb_log_file_size innodb_flush_log_at_trx_commit innodb_io_capacity innodb_io_capacity_max innodb_read_io_threads innodb_write_io_threads max_connections sql_require_primary_key transaction_isolation binlog_format sync_binlog character_set_server collation_server"
}

mysql_query_global_variables() {
  local edition="${1:?edition required}"
  local out_file="${2:?output file required}"

  set_mysql_env_for_edition "${edition}"

  local vars=(${MYSQL_VARS:-$(default_mysql_vars)})
  local in_list=""
  local v

  for v in "${vars[@]}"; do
    [[ -n "${v}" ]] || continue
    if [[ -n "${in_list}" ]]; then
      in_list="${in_list},'${v}'"
    else
      in_list="'${v}'"
    fi
  done

  {
    echo "# ${edition} — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "# host=${MYSQL_HOST}:${MYSQL_PORT} db=${MYSQL_DB}"
    mysql -h "${MYSQL_HOST}" -P "${MYSQL_PORT}" -u "${MYSQL_USER}" -p"${MYSQL_PASSWORD}" \
      --ssl-mode=REQUIRED "${MYSQL_DB}" -N -B \
      -e "SHOW GLOBAL VARIABLES WHERE Variable_name IN (${in_list});"
  } > "${out_file}" 2>&1
}

capture_mysql_settings_for_edition() {
  local edition="${1:?edition required}"
  local dest_dir="${2:?dest dir required}"
  local out_file="${dest_dir}/${edition}_mysql_variables.tsv"

  if mysql_query_global_variables "${edition}" "${out_file}"; then
    echo "Captured MySQL settings: ${out_file}"
    return 0
  else
    echo "WARNING: Failed to capture settings for ${edition}" >&2
    return 1
  fi
}

write_mysql_settings_comparison() {
  local results_dir="${1:?results dir required}"
  local summary_file="${2:?summary file required}"
  local std_file="${results_dir}/standard_mysql_variables.tsv"
  local adv_file="${results_dir}/advanced_mysql_variables.tsv"
  local mismatch=0

  capture_mysql_settings_for_edition "standard" "${results_dir}" || true
  capture_mysql_settings_for_edition "advanced" "${results_dir}" || true

  {
    echo "=== MySQL Server Settings — Standard vs Advanced ==="
    echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo ""
    echo "NOTE: sysbench does NOT configure these values. They come from each"
    echo "DigitalOcean Managed MySQL cluster. Align cluster size and parameters"
    echo "in the DO control panel before benchmarking for a fair comparison."
    echo ""
    if [[ -n "${MYSQL_CLUSTER_PLAN:-}" ]]; then
      echo "Documented cluster plan: ${MYSQL_CLUSTER_PLAN}"
    fi
    if [[ -n "${MYSQL_NOTES:-}" ]]; then
      echo "Notes: ${MYSQL_NOTES}"
    fi
    echo ""
    printf "%-40s %-35s %-35s %s\n" "Variable" "Standard" "Advanced" "Match"
    echo "----------------------------------------------------------------------------------------------------------------"

    if [[ ! -f "${std_file}" || ! -f "${adv_file}" ]]; then
      echo "(Could not read one or both variable dumps)"
      return 1
    fi

    local vars=(${MYSQL_VARS:-$(default_mysql_vars)})
    local name std_val adv_val match_flag

    for name in "${vars[@]}"; do
      [[ -n "${name}" ]] || continue
      std_val=$(awk -F'\t' -v n="${name}" '$1==n {print $2; exit}' "${std_file}" 2>/dev/null || echo "N/A")
      adv_val=$(awk -F'\t' -v n="${name}" '$1==n {print $2; exit}' "${adv_file}" 2>/dev/null || echo "N/A")
      if [[ "${std_val}" == "${adv_val}" ]]; then
        match_flag="OK"
      else
        match_flag="DIFF"
        mismatch=$((mismatch + 1))
      fi
      printf "%-40s %-35s %-35s %s\n" "${name}" "${std_val}" "${adv_val}" "${match_flag}"
    done

    echo ""
    if [[ "${mismatch}" -eq 0 ]]; then
      echo "All captured settings match between Standard and Advanced."
    else
      echo "WARNING: ${mismatch} setting(s) differ — results may not be apples-to-apples."
      echo "Align cluster size and MySQL parameters in DigitalOcean before comparing editions."
    fi
    echo ""
    echo "Raw dumps:"
    echo "  ${std_file}"
    echo "  ${adv_file}"
  } | tee "${summary_file}"

  return "${mismatch}"
}

run_mysql_settings_check() {
  local results_dir="${1:?results dir required}"
  local summary="${results_dir}/mysql_settings_comparison.txt"
  local mismatches=0

  echo ""
  echo "--- MySQL server settings comparison ---"
  if ! write_mysql_settings_comparison "${results_dir}" "${summary}"; then
    mismatches=1
  else
    mismatches=$?
  fi

  if [[ "${mismatches}" -gt 0 && "${MYSQL_FAIL_ON_SETTINGS_MISMATCH:-0}" == "1" ]]; then
    echo ""
    echo "ERROR: MySQL settings differ and MYSQL_FAIL_ON_SETTINGS_MISMATCH=1"
    exit 1
  fi
  echo ""
}

# Capture InnoDB/GR runtime settings + buffer pool hit rate before benchmark/prepare.
# Writes mysql_variables.tsv, mysql_status_at_start.tsv, mysql_runtime.env and
# merges key fields into benchmark_config.env (when present).
capture_mysql_runtime_metadata() {
  local edition="${1:?edition required}"
  local dest_dir="${2:?dest dir required}"
  local tables="${3:-${TPCC_TABLES:-10}}"
  local scale="${4:-${TPCC_SCALE:-100}}"

  set_mysql_env_for_edition "${edition}"

  local vars_tsv="${dest_dir}/mysql_variables.tsv"
  local status_tsv="${dest_dir}/mysql_status_at_start.tsv"
  local runtime_env="${dest_dir}/mysql_runtime.env"
  local bench_cfg="${dest_dir}/benchmark_config.env"
  local captured_utc
  captured_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  mkdir -p "${dest_dir}"

  {
    echo "# ${edition} — ${captured_utc}"
    echo "# host=${MYSQL_HOST}:${MYSQL_PORT} db=${MYSQL_DB}"
    mysql -h "${MYSQL_HOST}" -P "${MYSQL_PORT}" -u "${MYSQL_USER}" -p"${MYSQL_PASSWORD}" \
      --ssl-mode=REQUIRED "${MYSQL_DB}" -N -B \
      -e "SHOW GLOBAL VARIABLES WHERE Variable_name IN (
        'innodb_buffer_pool_size',
        'innodb_page_size',
        'innodb_redo_log_capacity',
        'innodb_log_file_size',
        'innodb_log_files_in_group',
        'replica_parallel_workers',
        'group_replication_flow_control_certifier_threshold',
        'group_replication_flow_control_applier_threshold'
      );"
  } > "${vars_tsv}" 2>&1 || true

  {
    echo "# ${edition} — ${captured_utc}"
    echo "# host=${MYSQL_HOST}:${MYSQL_PORT} db=${MYSQL_DB}"
    mysql -h "${MYSQL_HOST}" -P "${MYSQL_PORT}" -u "${MYSQL_USER}" -p"${MYSQL_PASSWORD}" \
      --ssl-mode=REQUIRED "${MYSQL_DB}" -N -B \
      -e "SHOW GLOBAL STATUS WHERE Variable_name IN (
        'Innodb_buffer_pool_read_requests',
        'Innodb_buffer_pool_reads',
        'Innodb_buffer_pool_bytes_data',
        'Innodb_buffer_pool_pages_data',
        'Innodb_redo_log_capacity_resized'
      );"
  } > "${status_tsv}" 2>&1 || true

  MYSQL_RUNTIME_TABLES="${tables}" MYSQL_RUNTIME_SCALE="${scale}" \
  python3 - "${vars_tsv}" "${status_tsv}" "${runtime_env}" "${bench_cfg}" "${captured_utc}" \
    "${edition}" "${MYSQL_HOST}" "${MYSQL_PORT}" "${MYSQL_DB}" <<'PY'
import os
import sys

vars_tsv, status_tsv, runtime_env, bench_cfg, captured_utc, edition, host, port, db = sys.argv[1:10]
tables = float(os.environ.get("MYSQL_RUNTIME_TABLES", "10"))
scale = float(os.environ.get("MYSQL_RUNTIME_SCALE", "100"))


def read_tsv(path):
    out = {}
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                parts = line.split("\t", 1)
                if len(parts) == 2:
                    out[parts[0]] = parts[1]
    except OSError:
        pass
    return out


def to_int(val):
    try:
        return int(str(val).strip())
    except (TypeError, ValueError):
        return None


def fmt_gb(num_bytes):
    # Shell-safe: no spaces (values are sourced from mysql_runtime.env).
    if num_bytes is None:
        return "N/A"
    if num_bytes <= 0:
        return "0GB"
    gb = num_bytes / (1024 ** 3)
    if abs(gb - round(gb)) < 0.05:
        return f"{int(round(gb))}GB"
    return f"{gb:.2f}GB"


def fmt_ratio(bp_bytes, data_gb):
    if bp_bytes is None or bp_bytes <= 0 or data_gb <= 0:
        return "N/A"
    ratio = (bp_bytes / (1024 ** 3)) / data_gb
    return f"{ratio:.3f}x"


def fmt_hit_pct(read_requests, reads):
    if read_requests is None or read_requests <= 0:
        return "N/A"
    reads = reads or 0
    hit = max(0.0, min(100.0, (1.0 - (reads / read_requests)) * 100.0))
    return f"{hit:.2f}%"


vars_map = read_tsv(vars_tsv)
status_map = read_tsv(status_tsv)

bp_bytes = to_int(vars_map.get("innodb_buffer_pool_size"))
redo_bytes = to_int(vars_map.get("innodb_redo_log_capacity"))
if redo_bytes is None:
    redo_bytes = to_int(status_map.get("Innodb_redo_log_capacity_resized"))
if redo_bytes is None:
    log_size = to_int(vars_map.get("innodb_log_file_size"))
    log_files = to_int(vars_map.get("innodb_log_files_in_group")) or 2
    if log_size is not None:
        redo_bytes = log_size * log_files

data_gb = scale * tables * 0.1
read_requests = to_int(status_map.get("Innodb_buffer_pool_read_requests"))
reads = to_int(status_map.get("Innodb_buffer_pool_reads"))
bp_data_bytes = to_int(status_map.get("Innodb_buffer_pool_bytes_data"))
if bp_data_bytes is None:
    pages_data = to_int(status_map.get("Innodb_buffer_pool_pages_data"))
    page_size = to_int(vars_map.get("innodb_page_size")) or 16384
    if pages_data is not None:
        bp_data_bytes = pages_data * page_size


def fmt_used_pct(used_bytes, limit_bytes):
    if used_bytes is None or limit_bytes is None or limit_bytes <= 0:
        return "N/A"
    pct = max(0.0, min(100.0, (used_bytes / limit_bytes) * 100.0))
    return f"{pct:.1f}%"


replica_workers = vars_map.get("replica_parallel_workers", "N/A") or "N/A"
gr_cert = vars_map.get("group_replication_flow_control_certifier_threshold", "N/A") or "N/A"
gr_apply = vars_map.get("group_replication_flow_control_applier_threshold", "N/A") or "N/A"

fields = {
    "MYSQL_RUNTIME_CAPTURED_UTC": captured_utc,
    "MYSQL_RUNTIME_EDITION": edition,
    "MYSQL_RUNTIME_HOST": f"{host}:{port}",
    "MYSQL_RUNTIME_DB": db,
    "BUFFER_POOL_BYTES": str(bp_bytes if bp_bytes is not None else ""),
    "BUFFER_POOL_GB": fmt_gb(bp_bytes),
    "BUFFER_POOL_USED_BYTES": str(bp_data_bytes if bp_data_bytes is not None else ""),
    "BUFFER_POOL_USED_GB": fmt_gb(bp_data_bytes),
    "BUFFER_POOL_USED_PCT": fmt_used_pct(bp_data_bytes, bp_bytes),
    "REDO_LOG_CAPACITY_BYTES": str(redo_bytes if redo_bytes is not None else ""),
    "REDO_LOG_CAPACITY_GB": fmt_gb(redo_bytes),
    "BUFFER_POOL_HIT_PCT": fmt_hit_pct(read_requests, reads),
    "BUFFER_POOL_DATA_RATIO": fmt_ratio(bp_bytes, data_gb),
    "TPCC_DATA_SIZE_GB": f"{data_gb:.1f}",
    "REPLICA_PARALLEL_WORKERS": str(replica_workers),
    "GR_FLOW_CONTROL_CERTIFIER_THRESHOLD": str(gr_cert),
    "GR_FLOW_CONTROL_APPLIER_THRESHOLD": str(gr_apply),
}

lines = [f"{k}={v}" for k, v in fields.items()]
with open(runtime_env, "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")

merge_keys = (
    "BUFFER_POOL_GB",
    "BUFFER_POOL_USED_GB",
    "BUFFER_POOL_USED_PCT",
    "REDO_LOG_CAPACITY_GB",
    "BUFFER_POOL_HIT_PCT",
    "BUFFER_POOL_DATA_RATIO",
    "REPLICA_PARALLEL_WORKERS",
    "GR_FLOW_CONTROL_CERTIFIER_THRESHOLD",
    "GR_FLOW_CONTROL_APPLIER_THRESHOLD",
    "MYSQL_RUNTIME_CAPTURED_UTC",
)
if os.path.isfile(bench_cfg):
    existing = {}
    with open(bench_cfg, encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, val = line.split("=", 1)
            existing[key] = val
    for key in merge_keys:
        existing[key] = fields[key]
    with open(bench_cfg, "w", encoding="utf-8") as f:
        for key, val in existing.items():
            f.write(f"{key}={val}\n")
PY

  if [[ -f "${runtime_env}" ]]; then
    echo "Captured MySQL runtime metadata: ${runtime_env}"
    # shellcheck disable=SC1090
    source "${runtime_env}" 2>/dev/null || true
    _runtime_env_get() {
      grep -m1 "^${1}=" "${runtime_env}" 2>/dev/null | cut -d= -f2- || echo "N/A"
    }
    echo "  Buffer pool limit:        $(_runtime_env_get BUFFER_POOL_GB)"
    echo "  Buffer pool used (VIP):   $(_runtime_env_get BUFFER_POOL_USED_GB) ($(_runtime_env_get BUFFER_POOL_USED_PCT))"
    echo "  Redo log capacity:        $(_runtime_env_get REDO_LOG_CAPACITY_GB)"
    echo "  Buffer pool hit %:        $(_runtime_env_get BUFFER_POOL_HIT_PCT)"
    echo "  Buffer pool / data ratio: $(_runtime_env_get BUFFER_POOL_DATA_RATIO)"
    echo "  replica_parallel_workers: $(_runtime_env_get REPLICA_PARALLEL_WORKERS)"
    echo "  GR flow control cert/appl: $(_runtime_env_get GR_FLOW_CONTROL_CERTIFIER_THRESHOLD) / $(_runtime_env_get GR_FLOW_CONTROL_APPLIER_THRESHOLD)"
    return 0
  fi

  echo "WARNING: Failed to capture MySQL runtime metadata for ${edition}" >&2
  return 1
}
