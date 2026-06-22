#!/usr/bin/env bash
# Helpers for sustained TPC-C longevity benchmarks (multi-day runs)
set -euo pipefail

BENCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=/dev/null
source "${BENCH_ROOT}/lib/benchmark_common.sh"

longevity_duration_human() {
  local sec="${1:?seconds required}"
  local days=$((sec / 86400))
  local hours=$(((sec % 86400) / 3600))
  local mins=$(((sec % 3600) / 60))
  if [[ "${days}" -gt 0 ]]; then
    printf "%dd %dh %dm" "${days}" "${hours}" "${mins}"
  elif [[ "${hours}" -gt 0 ]]; then
    printf "%dh %dm" "${hours}" "${mins}"
  else
    printf "%dm" "${mins}"
  fi
}

# Resolve target run duration. LONGEVITY_DURATION_SEC overrides LONGEVITY_DAYS when set.
resolve_longevity_duration_sec() {
  if [[ -n "${LONGEVITY_DURATION_SEC:-}" ]]; then
    echo "${LONGEVITY_DURATION_SEC}"
    return 0
  fi

  local days="${LONGEVITY_DAYS:-7}"
  echo $((days * 86400))
}

longevity_target_days_display() {
  local sec="${1:?seconds required}"
  awk -v s="${sec}" 'BEGIN { printf "%.4g", s / 86400 }'
}

generate_longevity_graphs() {
  local results_dir="${1:?results dir required}"
  local edition="${2:?edition required}"
  local target_sec="${3:?target seconds required}"

  if [[ "${LONGEVITY_GENERATE_GRAPHS:-1}" != "1" ]]; then
    echo "Graph generation disabled (LONGEVITY_GENERATE_GRAPHS!=1)"
    return 0
  fi

  local script="${BENCH_ROOT}/scripts/generate_longevity_graphs.py"
  local timeseries="${results_dir}/longevity_timeseries.csv"
  if [[ ! -f "${script}" ]]; then
    echo "WARNING: graph script missing: ${script}" >&2
    return 0
  fi
  if [[ ! -f "${timeseries}" ]]; then
    echo "WARNING: no timeseries CSV — skipping graphs" >&2
    return 0
  fi
  if ! python3 -c "import matplotlib" 2>/dev/null; then
    echo "WARNING: python3-matplotlib not installed — skipping graphs"
    echo "  Ubuntu: apt-get install -y python3-matplotlib"
    echo "  macOS:  pip3 install matplotlib"
    return 0
  fi

  local target_days
  target_days="$(longevity_target_days_display "${target_sec}")"

  echo ""
  echo "--- Generating longevity graphs ---"
  if python3 "${script}" \
      --results-dir "${results_dir}" \
      --edition "${edition}" \
      --target-days "${target_days}"; then
    echo "Graphs: ${results_dir}/graphs/"
  else
    echo "WARNING: graph generation failed — see output above" >&2
  fi
}

init_longevity_results_dir() {
  local base="${1:?base results dir required}"
  local edition="${2:?edition required}"
  local ts
  ts="$(date +%Y%m%d_%H%M%S)"
  LONGEVITY_RESULTS_DIR="${base}/longevity_${edition}_${ts}"
  mkdir -p "${LONGEVITY_RESULTS_DIR}"
  export LONGEVITY_RESULTS_DIR
}

write_longevity_state() {
  local state_file="${1:?state file required}"
  local elapsed="${2:-0}"
  local restart_count="${3:-0}"
  local phase="${4:-running}"

  cat > "${state_file}" <<EOF
ELAPSED_SEC=${elapsed}
RESTART_COUNT=${restart_count}
PHASE=${phase}
UPDATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
}

read_longevity_state() {
  local state_file="${1:?state file required}"
  ELAPSED_SEC=0
  RESTART_COUNT=0
  PHASE="unknown"
  if [[ -f "${state_file}" ]]; then
    # shellcheck source=/dev/null
    source "${state_file}"
  fi
  export ELAPSED_SEC RESTART_COUNT PHASE
}

init_longevity_timeseries() {
  local csv="${1:?csv file required}"
  if [[ ! -f "${csv}" ]]; then
    echo "timestamp_utc,elapsed_sec,tps,qps,lat_p95_ms,err_per_sec,reconn_per_sec,threads" > "${csv}"
  fi
}

init_primary_monitor() {
  local csv="${1:?csv file required}"
  if [[ ! -f "${csv}" ]]; then
    echo "timestamp_utc,hostname,server_id,read_only" > "${csv}"
  fi
}

# Parse sysbench intermediate report lines into longevity_timeseries.csv
parse_sysbench_intermediate_line() {
  local line="${1:?line required}"
  local csv="${2:?csv required}"
  local run_start="${3:?run start epoch required}"

  if [[ ! "${line}" =~ ^\[ ]]; then
    return 0
  fi

  local elapsed tps qps lat_p95 err reconn threads
  elapsed=$(echo "${line}" | sed -n 's/^\[\ *\([0-9]*\)s \].*/\1/p')
  [[ -n "${elapsed}" ]] || return 0

  tps=$(echo "${line}" | sed -n 's/.*tps: \([0-9.]*\).*/\1/p')
  qps=$(echo "${line}" | sed -n 's/.*qps: \([0-9.]*\).*/\1/p')
  lat_p95=$(echo "${line}" | sed -n 's/.*lat (ms,95%): \([0-9.]*\).*/\1/p')
  err=$(echo "${line}" | sed -n 's/.*err\/s: \([0-9.]*\).*/\1/p')
  reconn=$(echo "${line}" | sed -n 's/.*reconn\/s: \([0-9.]*\).*/\1/p')
  threads=$(echo "${line}" | sed -n 's/.*thds: \([0-9]*\).*/\1/p')

  local ts=$((run_start + elapsed))
  echo "$(date -u -r "${ts}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ),${elapsed},${tps:-},${qps:-},${lat_p95:-},${err:-},${reconn:-},${threads:-}" \
    >> "${csv}"
}

# Background loop: poll @@hostname while sysbench PID is alive
start_primary_monitor() {
  local edition="${1:?edition required}"
  local monitor_csv="${2:?monitor csv required}"
  local interval="${3:-60}"
  local sysbench_pid="${4:?sysbench pid required}"
  local stop_file="${5:?stop file required}"

  (
    set +e
    init_primary_monitor "${monitor_csv}"
    set_mysql_env_for_edition "${edition}"

    while [[ ! -f "${stop_file}" ]] && kill -0 "${sysbench_pid}" 2>/dev/null; do
      local row
      row=$(mysql -h "${MYSQL_HOST}" -P "${MYSQL_PORT}" -u "${MYSQL_USER}" -p"${MYSQL_PASSWORD}" \
        --ssl-mode=REQUIRED "${MYSQL_DB}" -N -B \
        -e "SELECT @@hostname, @@server_id, @@read_only;" 2>/dev/null || echo "UNREACHABLE")
      if [[ "${row}" == "UNREACHABLE" ]]; then
        echo "$(date -u +%Y-%m-%dT%H:%M:%SZ),UNREACHABLE,," >> "${monitor_csv}"
      else
        local hostname server_id read_only
        hostname=$(echo "${row}" | awk '{print $1}')
        server_id=$(echo "${row}" | awk '{print $2}')
        read_only=$(echo "${row}" | awk '{print $3}')
        echo "$(date -u +%Y-%m-%dT%H:%M:%SZ),${hostname},${server_id},${read_only}" >> "${monitor_csv}"
      fi
      sleep "${interval}"
    done
  ) &
  echo $!
}

_longevity_tee_linebuffer() {
  if command -v stdbuf >/dev/null 2>&1; then
    stdbuf -oL -eL tee "$@"
  else
    tee "$@"
  fi
}

wait_for_longevity_sysbench_start() {
  local log_file="${1:?log required}"
  local pid="${2:?pid required}"
  local timeout="${3:-300}"
  local i

  for i in $(seq 1 "${timeout}"); do
    if ! kill -0 "${pid}" 2>/dev/null; then
      echo "ERROR: sysbench (pid=${pid}) exited before load started — see ${log_file}" >&2
      if [[ -f "${log_file}" ]]; then
        tail -20 "${log_file}" >&2 || true
      fi
      return 1
    fi
    if [[ -f "${log_file}" ]] && grep -qE 'Threads started!|^\[[[:space:]]*[0-9]+s \]' "${log_file}"; then
      echo "Sysbench load confirmed running (pid=${pid}) at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
      return 0
    fi
    if (( i % 30 == 0 )); then
      echo "Waiting for sysbench to start (${i}s / ${timeout}s) — thread init on scale=${TPCC_SCALE:-100} can take 1–3 min..."
    fi
    sleep 1
  done
  echo "ERROR: sysbench did not reach running state within ${timeout}s — see ${log_file}" >&2
  return 1
}

_start_longevity_timeseries_parser() {
  local log_file="${1:?log required}"
  local csv="${2:?csv required}"
  local run_start="${3:?epoch required}"
  local stop_file="${4:?stop file required}"

  (
    set +e
    # Wait for log file (created before this runs)
    while [[ ! -f "${log_file}" ]] && [[ ! -f "${stop_file}" ]]; do
      sleep 0.2
    done
    tail -n 0 -F "${log_file}" 2>/dev/null | while IFS= read -r line; do
      [[ -f "${stop_file}" ]] && break
      parse_sysbench_intermediate_line "${line}" "${csv}" "${run_start}"
    done
  ) &
  echo $!
}

start_longevity_sysbench_load() {
  local segment_log="${1:?log required}"
  local pid_file="${2:?pid file required}"

  build_mysql_base_opts

  local tpcc tables scale threads force_pk trx_level time_sec warmup report_interval
  tpcc="$(tpcc_dir)"
  tables="${TPCC_TABLES:-10}"
  scale="${TPCC_SCALE:-100}"
  threads="${TPCC_THREADS:-32}"
  force_pk="${TPCC_FORCE_PK:-1}"
  trx_level="${TPCC_TRX_LEVEL:-RR}"
  time_sec="${TPCC_TIME:?TPCC_TIME required}"
  warmup="${TPCC_WARMUP:-0}"
  report_interval="${TPCC_REPORT_INTERVAL:-60}"

  local ignore_errors="${LONGEVITY_MYSQL_IGNORE_ERRORS:-${FAILOVER_MYSQL_IGNORE_ERRORS:-1053,2013,1290,3100,1205,1213,2006,2014,2003,2055,1047,1158,1159,1161,3011}}"

  local opts=(
    "${MYSQL_BASE_OPTS[@]}"
    "${MYSQL_SSL_OPTS[@]}"
    --tables="${tables}"
    --scale="${scale}"
    --threads="${threads}"
    --trx_level="${trx_level}"
    --force_pk="${force_pk}"
    --mysql-ignore-errors="${ignore_errors}"
    --db-ps-mode=disable
    --time="${time_sec}"
    --warmup-time="${warmup}"
    --report-interval="${report_interval}"
  )

  : > "${segment_log}"
  {
    echo "# longevity segment started $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "# time=${time_sec}s warmup=${warmup}s threads=${threads} report-interval=${report_interval}s"
  } >> "${segment_log}"

  (cd "${tpcc}" && "${SYSBENCH_BIN}" tpcc.lua "${opts[@]}" run) \
    > >(_longevity_tee_linebuffer -a "${segment_log}") 2>&1 &
  local load_pid=$!
  echo "${load_pid}" > "${pid_file}"
  echo "${load_pid}"
}

run_longevity_tpcc_segment() {
  local edition="${1:?edition required}"
  local results_dir="${2:?results dir required}"
  local segment_time="${3:?segment seconds required}"
  local warmup="${4:-0}"
  local segment_idx="${5:-0}"

  set_mysql_env_for_edition "${edition}"

  export TPCC_TABLES="${TPCC_TABLES:-10}"
  export TPCC_SCALE="${TPCC_SCALE:-100}"
  export TPCC_FORCE_PK="${TPCC_FORCE_PK:-1}"
  export TPCC_TRX_LEVEL="${TPCC_TRX_LEVEL:-RR}"
  export TPCC_THREADS="${LONGEVITY_THREADS:-32}"
  export TPCC_TIME="${segment_time}"
  export TPCC_WARMUP="${warmup}"
  export TPCC_REPORT_INTERVAL="${LONGEVITY_REPORT_INTERVAL:-60}"

  local segment_log="${results_dir}/run_segment_${segment_idx}.log"
  local timeseries_csv="${results_dir}/longevity_timeseries.csv"
  local stop_file="${results_dir}/.monitor_stop"
  local parser_stop="${results_dir}/.parser_stop"
  local pid_file="${results_dir}/sysbench_segment_${segment_idx}.pid"
  local monitor_pid=""
  local parser_pid=""
  local sysbench_pid=""

  rm -f "${stop_file}" "${parser_stop}" "${pid_file}"
  init_longevity_timeseries "${timeseries_csv}"

  local run_start
  run_start=$(date +%s)

  echo "--- Longevity segment ${segment_idx}: time=${segment_time}s warmup=${warmup}s threads=${TPCC_THREADS} ---"
  echo "Segment log: ${segment_log}"
  if [[ "${warmup}" -gt 0 ]]; then
    echo "NOTE: ${warmup}s warmup before measured load; first TPS report ~${LONGEVITY_REPORT_INTERVAL:-60}s after warmup ends."
  fi

  parser_pid=$(_start_longevity_timeseries_parser "${segment_log}" "${timeseries_csv}" "${run_start}" "${parser_stop}")

  echo "Launching sysbench TPC-C (scale=${TPCC_SCALE}, tables=${TPCC_TABLES})..."
  sysbench_pid=$(start_longevity_sysbench_load "${segment_log}" "${pid_file}")
  echo "Sysbench pid=${sysbench_pid} (log streams via line-buffered tee)"

  if ! wait_for_longevity_sysbench_start "${segment_log}" "${sysbench_pid}" 300; then
    touch "${parser_stop}" "${stop_file}"
    wait "${parser_pid}" 2>/dev/null || true
    return 1
  fi

  if [[ "${LONGEVITY_MONITOR_PRIMARY:-0}" == "1" ]]; then
    monitor_pid=$(start_primary_monitor "${edition}" "${results_dir}/primary_monitor.csv" \
      "${LONGEVITY_MONITOR_INTERVAL:-60}" "${sysbench_pid}" "${stop_file}")
    echo "Primary monitor PID: ${monitor_pid} (watching sysbench pid=${sysbench_pid})"
  fi

  local exit_code=0
  set +e
  wait "${sysbench_pid}"
  exit_code=$?
  set -e

  touch "${parser_stop}" "${stop_file}"
  wait "${parser_pid}" 2>/dev/null || true
  if [[ -n "${monitor_pid}" ]]; then
    wait "${monitor_pid}" 2>/dev/null || true
  fi
  rm -f "${pid_file}"

  local run_end wall_sec
  run_end=$(date +%s)
  wall_sec=$((run_end - run_start))

  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ),${segment_idx},${run_start},${run_end},${wall_sec},${segment_time},${warmup},${exit_code}" \
    >> "${results_dir}/segments.csv"

  return "${exit_code}"
}

write_longevity_summary() {
  local results_dir="${1:?results dir required}"
  local edition="${2:?edition required}"
  local target_sec="${3:?target duration required}"
  local summary="${results_dir}/longevity_summary.txt"
  local timeseries="${results_dir}/longevity_timeseries.csv"
  local segments="${results_dir}/segments.csv"
  local monitor="${results_dir}/primary_monitor.csv"

  local elapsed restarts
  read_longevity_state "${results_dir}/state.env"
  elapsed="${ELAPSED_SEC:-0}"
  restarts="${RESTART_COUNT:-0}"

  {
    echo "=== TPC-C Longevity Benchmark Summary ==="
    echo "Edition:   ${edition}"
    echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo ""
    echo "Target duration: ${target_sec}s ($(longevity_duration_human "${target_sec}"))"
    echo "Elapsed:         ${elapsed}s ($(longevity_duration_human "${elapsed}"))"
    echo "Restarts:        ${restarts}"
    echo ""
    echo "Dataset: tables=${TPCC_TABLES:-10} scale=${TPCC_SCALE:-100} (~100 GB profile)"
    echo "Load:    threads=${LONGEVITY_THREADS:-32} report_interval=${LONGEVITY_REPORT_INTERVAL:-60}s"
    echo ""
    echo "Results directory: ${results_dir}"
    echo ""

    if [[ -f "${timeseries}" ]]; then
      local rows avg_tps max_err
      rows=$(tail -n +2 "${timeseries}" | wc -l | tr -d ' ')
      avg_tps=$(tail -n +2 "${timeseries}" | awk -F, '$3 != "" {sum+=$3; n++} END {if(n>0) printf "%.2f", sum/n; else print "N/A"}')
      max_err=$(tail -n +2 "${timeseries}" | awk -F, '$6 != "" {if($6+0>max) max=$6+0} END {if(max=="") print "0"; else print max}')
      echo "Timeseries samples: ${rows}"
      echo "Average TPS:        ${avg_tps}"
      echo "Peak err/s:         ${max_err}"
      echo ""
    fi

    if [[ -f "${monitor}" ]]; then
      local unique_hosts host_changes
      unique_hosts=$(tail -n +2 "${monitor}" | cut -d, -f2 | sort -u | grep -v UNREACHABLE | wc -l | tr -d ' ')
      host_changes=$(tail -n +2 "${monitor}" | cut -d, -f2 | awk 'NR>1 && $0!=prev {c++} {prev=$0} END {print c+0}')
      echo "Primary monitor:"
      echo "  Unique hostnames: ${unique_hosts}"
      echo "  Hostname changes: ${host_changes}"
      echo ""
    fi

    local seg
    for seg in "${results_dir}"/run_segment_*.log; do
      [[ -f "${seg}" ]] || continue
      parse_sysbench_metrics "${seg}"
      echo "--- $(basename "${seg}") ---"
      echo "  TPS=${METRIC_TPS}  QPS=${METRIC_QPS}  avg=${METRIC_LAT_AVG}  p95=${METRIC_LAT_P95}  errors=${METRIC_ERRORS}  reconnects=${METRIC_RECONNECTS}"
    done

    echo ""
    echo "Artifacts:"
    echo "  ${timeseries}"
    echo "  ${monitor}"
    echo "  ${segments}"
    echo "  ${results_dir}/full_run.log"
    if [[ -d "${results_dir}/graphs" ]]; then
      echo "  ${results_dir}/graphs/"
      ls -1 "${results_dir}/graphs/"*.png 2>/dev/null | sed 's/^/    /' || true
    fi
  } | tee "${summary}"
}
