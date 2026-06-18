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
}

failover_total_runtime_sec() {
  failover_defaults
  echo $((FAILOVER_WARMUP_SEC + FAILOVER_BASELINE_SEC + FAILOVER_OBSERVE_SEC))
}

failover_trigger_second() {
  failover_defaults
  echo $((FAILOVER_WARMUP_SEC + FAILOVER_BASELINE_SEC))
}

mysql_cli() {
  mysql -h "${MYSQL_HOST}" -P "${MYSQL_PORT}" -u "${MYSQL_USER}" -p"${MYSQL_PASSWORD}" \
    --ssl-mode=REQUIRED "${MYSQL_DB}" "$@"
}

start_primary_monitor() {
  local results_dir="${1:?results dir required}"
  local pid_file="${results_dir}/primary_monitor.pid"
  local out_file="${results_dir}/primary_monitor.tsv"
  local interval="${FAILOVER_MONITOR_INTERVAL:-1}"

  : > "${out_file}"
  echo -e "timestamp_utc\thostname\tread_only" >> "${out_file}"

  (
    while true; do
      ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      row=$(mysql_cli -N -B -e "SELECT @@hostname, @@global.read_only;" 2>&1 || echo "ERROR\tERROR")
      echo -e "${ts}\t${row}" >> "${out_file}"
      sleep "${interval}"
    done
  ) &

  echo $! > "${pid_file}"
  echo "Primary monitor started (pid=$(cat "${pid_file}"), interval=${interval}s)"
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
}

run_tpcc_failover_load() {
  local results_dir="${1:?results dir required}"
  local log_file="${results_dir}/sysbench_run.log"
  local pid_file="${results_dir}/sysbench.pid"

  failover_defaults
  build_mysql_base_opts

  local tpcc total_time
  tpcc="$(tpcc_dir)"
  total_time=$(failover_total_runtime_sec)

  export TPCC_THREADS="${FAILOVER_THREADS}"
  export TPCC_TIME="${total_time}"
  export TPCC_WARMUP="${FAILOVER_WARMUP_SEC}"
  export TPCC_REPORT_INTERVAL="${FAILOVER_REPORT_INTERVAL}"

  echo "SYSBENCH_START_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${results_dir}/sysbench_timing.txt"
  echo "FAILOVER_TRIGGER_SECOND=$(failover_trigger_second)" >> "${results_dir}/sysbench_timing.txt"
  echo "FAILOVER_TOTAL_SEC=${total_time}" >> "${results_dir}/sysbench_timing.txt"

  (
    run_tpcc_command run 2>&1 | tee "${log_file}"
  ) &

  echo $! > "${pid_file}"
  echo "Sysbench TPC-C started (pid=$(cat "${pid_file}"), time=${total_time}s, report-interval=${FAILOVER_REPORT_INTERVAL}s)"
}

stop_sysbench_load() {
  local results_dir="${1:?results dir required}"
  local pid_file="${results_dir}/sysbench.pid"

  if [[ -f "${pid_file}" ]]; then
    local pid
    pid=$(cat "${pid_file}")
    if kill -0 "${pid}" 2>/dev/null; then
      kill -INT "${pid}" 2>/dev/null || true
      local i
      for i in $(seq 1 30); do
        kill -0 "${pid}" 2>/dev/null || break
        sleep 1
      done
      kill -KILL "${pid}" 2>/dev/null || true
      wait "${pid}" 2>/dev/null || true
    fi
    rm -f "${pid_file}"
  fi
  echo "SYSBENCH_END_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "${results_dir}/sysbench_timing.txt"
}

wait_for_sysbench_start() {
  local results_dir="${1:?results dir required}"
  local log_file="${results_dir}/sysbench_run.log"
  local timeout="${2:-120}"
  local i

  for i in $(seq 1 "${timeout}"); do
    if [[ -f "${log_file}" ]] && grep -qE '^\[[[:space:]]*[0-9]+s \]' "${log_file}"; then
      return 0
    fi
    sleep 1
  done
  echo "ERROR: sysbench did not produce interval output within ${timeout}s" >&2
  return 1
}

sleep_until_failover_trigger() {
  failover_defaults
  local delay="${FAILOVER_TRIGGER_DELAY_SEC:-$(failover_trigger_second)}"
  echo "Waiting ${delay}s before failover trigger (warmup=${FAILOVER_WARMUP_SEC}s + baseline=${FAILOVER_BASELINE_SEC}s)..."
  sleep "${delay}"
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
    $2 == "ERROR" { next }
    {
      if (before == "" && (trigger == "" || $1 < trigger)) {
        before = $2
      }
      if (trigger != "" && $1 >= trigger) {
        after = $2
      } else if (trigger == "") {
        after = $2
      }
      last = $2
    }
    END {
      if (before == "") before = "N/A"
      if (after == "") after = last
      changed = (before != "N/A" && after != "N/A" && before != after) ? "yes" : "no"
      printf "PRIMARY_BEFORE=%s\nPRIMARY_AFTER=%s\nPRIMARY_CHANGED=%s\n", before, after, changed
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

  local trigger_second start_utc edition
  trigger_second=$(failover_trigger_second)
  start_utc=""
  edition="unknown"

  if [[ -f "${timing_file}" ]]; then
    # shellcheck disable=SC1090
    source "${timing_file}" 2>/dev/null || true
    trigger_second="${FAILOVER_TRIGGER_SECOND:-${trigger_second}}"
    start_utc="${SYSBENCH_START_UTC:-}"
  fi
  if [[ -f "${event_file}" ]]; then
    edition=$(grep -E '^FAILOVER_EDITION=' "${event_file}" | tail -1 | cut -d= -f2- || echo "unknown")
  fi

  {
    echo "SYSBENCH_START_UTC=${start_utc}"
    echo "FAILOVER_TRIGGER_SECOND=${trigger_second}"
    echo "FAILOVER_EDITION=${edition}"
  } > "${meta_file}"

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
    if (f[i] == "err/s:") err = f[i + 1] + 0
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
    echo "WARNING: python3 matplotlib not installed — skipping graphs" >&2
    echo "  Install: sudo apt-get install -y python3-matplotlib  OR  pip3 install matplotlib" >&2
    echo "  Re-run:  ./generate_failover_graphs.sh ${target}" >&2
    return 0
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

  awk -v trigger="${trigger}" \
      -v recovery="${recovery}" \
      -v stable="${stable}" \
      -v outage_ratio="${outage_ratio}" \
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
    if (f[i] == "err/s:") err = f[i + 1] + 0
    if (f[i] == "reconn/s:") reconn = f[i + 1] + 0
    if (f[i] ~ /^lat/ && f[i + 1] ~ /\(ms,95%\):/) lat95 = f[i + 2] + 0
  }
  tps_arr[sec] = tps
  qps_arr[sec] = qps
  err_arr[sec] = err
  reconn_arr[sec] = reconn
  lat_arr[sec] = lat95
  if (sec < trigger) {
    baseline_sum += tps
    baseline_count++
  }
  return 1
}
BEGIN {
  baseline_sum = 0
  baseline_count = 0
}
{
  parse_interval_line($0)
}
END {
  if (baseline_count == 0) {
    print "ERROR: no baseline data before trigger second " trigger > "/dev/stderr"
    exit 1
  }
  baseline_tps = baseline_sum / baseline_count

  outage_start = -1
  outage_end = -1
  max_err = 0
  max_reconn = 0
  max_lat = 0
  total_errors = 0

  for (sec = trigger; sec <= trigger + 600; sec++) {
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
    outage_start = trigger
    outage_end = trigger
    outage_duration = 0
  } else {
    outage_duration = outage_end - outage_start + 1
  }

  recovery_threshold_tps = baseline_tps * recovery
  rto_sec = -1
  stable_count = 0
  for (sec = trigger; sec <= trigger + 600; sec++) {
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

  local trigger_second
  trigger_second=$(failover_trigger_second)
  if [[ -f "${timing_file}" ]]; then
    # shellcheck disable=SC1090
    source "${timing_file}" 2>/dev/null || true
    trigger_second="${FAILOVER_TRIGGER_SECOND:-${trigger_second}}"
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
    "${FAILOVER_OUTAGE_TPS_RATIO}" > "${parsed_file}"

  # shellcheck disable=SC1090
  source "${parsed_file}"

  export_failover_timeseries "${results_dir}"

  {
    echo "=== Failover Benchmark Analysis ==="
    echo "Edition:              ${edition}"
    echo "Trigger method:       ${method}"
    echo "Trigger UTC:          ${trigger_utc:-N/A}"
    echo "Trigger second:       ${trigger_second} (from sysbench start)"
    echo ""
    echo "--- Throughput ---"
    printf "Baseline TPS (avg):   %.2f\n" "${BASELINE_TPS}"
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
  } | tee "${analysis_file}"

  local header="edition,trigger_method,trigger_utc,baseline_tps,outage_start_sec,outage_duration_sec,rto_sec,peak_err_per_sec,peak_reconn_per_sec,peak_lat_p95_ms"
  echo "${header}" > "${csv_file}"
  echo "${edition},${method},${trigger_utc},${BASELINE_TPS},${OUTAGE_START},${OUTAGE_DURATION},${RTO_SEC},${PEAK_ERR},${PEAK_RECONN},${PEAK_LAT95}" \
    >> "${csv_file}"

  generate_failover_graphs "${results_dir}"

  echo "Analysis written: ${analysis_file}"
  echo "Metrics CSV:      ${csv_file}"
}

write_failover_comparison() {
  local results_root="${1:?results root required}"
  local summary="${results_root}/failover_comparison.txt"
  local combined_csv="${results_root}/failover_comparison.csv"

  echo "edition,trigger_method,trigger_utc,baseline_tps,outage_start_sec,outage_duration_sec,rto_sec,peak_err_per_sec,peak_reconn_per_sec,peak_lat_p95_ms" > "${combined_csv}"

  {
    echo "=== Failover Benchmark — Standard vs Advanced ==="
    echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo ""
  } > "${summary}"

  for edition_dir in "${results_root}"/*/; do
    [[ -d "${edition_dir}" ]] || continue
    local metrics="${edition_dir}/failover_metrics.csv"
    local analysis="${edition_dir}/failover_analysis.txt"
    local edition
    edition=$(basename "${edition_dir}")

    if [[ -f "${metrics}" ]]; then
      tail -n +2 "${metrics}" >> "${combined_csv}"
    fi
    if [[ -f "${analysis}" ]]; then
      {
        echo "========================================"
        echo " Edition: ${edition}"
        echo "========================================"
        cat "${analysis}"
        echo ""
      } >> "${summary}"
    fi
  done

  echo "Comparison summary: ${summary}"
  echo "Comparison CSV:     ${combined_csv}"
}
