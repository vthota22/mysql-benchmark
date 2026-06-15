#!/usr/bin/env bash
# Shared helpers for MySQL Standard vs Advanced benchmarking
set -euo pipefail

BENCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=/dev/null
source "${BENCH_ROOT}/sysbench_mysql_opts.sh"

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

run_tpcc_command() {
  local command="${1:?prepare|run|check|cleanup}"
  shift

  local tpcc
  tpcc="$(tpcc_dir)"
  if [[ ! -f "${tpcc}/tpcc.lua" ]]; then
    echo "ERROR: Missing ${tpcc}/tpcc.lua — run setup_benchmark.sh first" >&2
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
