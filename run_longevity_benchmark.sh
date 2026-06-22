#!/usr/bin/env bash
# Sustained TPC-C longevity benchmark — multi-day continuous load
#
# Compares cluster stability over days (Advanced vs Standard). Run one edition
# at a time or both sequentially via LONGEVITY_EDITIONS in benchmark.conf.
#
# Usage:
#   cp benchmark.conf.example benchmark.conf   # edit credentials
#   ./setup_benchmark.sh                       # one-time
#   ./run_longevity_benchmark.sh
#
# For a 7-day detached run (recommended on a stable host):
#   nohup ./run_longevity_benchmark.sh >> results/longevity_nohup.log 2>&1 &
#   echo $! > results/longevity.pid
#
# Optional:
#   BENCHMARK_CONF=/path/to/benchmark.conf ./run_longevity_benchmark.sh
#   LONGEVITY_EDITIONS=advanced ./run_longevity_benchmark.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${BENCHMARK_CONF:-${SCRIPT_DIR}/benchmark.conf}"

export PATH="${SCRIPT_DIR}/sysbench-1.1/bin:${PATH}"

# shellcheck source=lib/longevity_common.sh
source "${SCRIPT_DIR}/lib/longevity_common.sh"
load_benchmark_config "${CONFIG}"

verify_longevity_prerequisites() {
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/sysbench_mysql_opts.sh"
  if [[ ! -x "${SYSBENCH_BIN}" ]]; then
    echo "ERROR: sysbench not found at ${SYSBENCH_BIN:-sysbench-1.1/bin/sysbench}" >&2
    echo "Run: ./setup_benchmark.sh" >&2
    exit 1
  fi
  if [[ ! -f "${SCRIPT_DIR}/TPCC/sysbench-tpcc/tpcc.lua" ]]; then
    echo "ERROR: missing TPCC/sysbench-tpcc/tpcc.lua — run ./setup_benchmark.sh" >&2
    exit 1
  fi
  echo "Prerequisites OK: sysbench=${SYSBENCH_BIN}"
}

verify_longevity_prerequisites

TARGET_SEC="$(resolve_longevity_duration_sec)"
EDITIONS="${LONGEVITY_EDITIONS:-advanced}"
AUTO_RESTART="${LONGEVITY_AUTO_RESTART:-1}"
RUN_CHECK="${LONGEVITY_RUN_TPCC_CHECK:-1}"
GENERATE_GRAPHS="${LONGEVITY_GENERATE_GRAPHS:-1}"

RESULTS_BASE="${SCRIPT_DIR}/results"
mkdir -p "${RESULTS_BASE}"

echo "=== TPC-C Longevity Benchmark ==="
echo "Config:   ${CONFIG}"
echo "Duration: ${TARGET_SEC}s ($(longevity_duration_human "${TARGET_SEC}") / $(longevity_target_days_display "${TARGET_SEC}") days)"
if [[ -n "${LONGEVITY_DURATION_SEC:-}" ]]; then
  echo "          (from LONGEVITY_DURATION_SEC; overrides LONGEVITY_DAYS=${LONGEVITY_DAYS:-7})"
else
  echo "          (from LONGEVITY_DAYS=${LONGEVITY_DAYS:-7})"
fi
echo "Editions: ${EDITIONS}"
echo "Graphs:   ${GENERATE_GRAPHS} (needs python3-matplotlib)"
echo "Dataset:  tables=${TPCC_TABLES:-10} scale=${TPCC_SCALE:-100} (~100 GB)"
echo "Load:     threads=${LONGEVITY_THREADS:-32} warmup=${LONGEVITY_WARMUP_SEC:-300}s"
echo "          report_interval=${LONGEVITY_REPORT_INTERVAL:-60}s auto_restart=${AUTO_RESTART}"
echo "Sysbench: $("${SCRIPT_DIR}/which_sysbench.sh")"
echo ""

run_longevity_edition() {
  local edition="${1:?edition required}"

  init_longevity_results_dir "${RESULTS_BASE}" "${edition}"
  local results_dir="${LONGEVITY_RESULTS_DIR}"
  local full_log="${results_dir}/full_run.log"
  local state_file="${results_dir}/state.env"

  (
  exec > >(tee -a "${full_log}") 2>&1

  echo ""
  echo "========================================"
  echo " Longevity: ${edition}"
  echo " Results:  ${results_dir}"
  echo " Started:  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "========================================"
  echo ""

  set_mysql_env_for_edition "${edition}"
  export TPCC_TABLES="${TPCC_TABLES:-10}"
  export TPCC_SCALE="${TPCC_SCALE:-100}"
  export TPCC_FORCE_PK="${TPCC_FORCE_PK:-1}"
  export TPCC_TRX_LEVEL="${TPCC_TRX_LEVEL:-RR}"

  echo "Host: ${MYSQL_HOST}:${MYSQL_PORT}  DB: ${MYSQL_DB}"
  echo ""

  mysql_connectivity_check "${edition}" "${results_dir}/mysql_info.txt" \
    || { echo "Aborting ${edition}: cannot connect"; return 1; }
  echo ""

  if [[ "${SKIP_PREPARE:-0}" != "1" ]]; then
    echo "--- Cleanup (fresh 100 GB dataset) ---"
    export TPCC_THREADS="${PREP_THREADS:-16}"
    run_tpcc_command cleanup 2>&1 | tee "${results_dir}/cleanup.log" || true
    echo ""

    echo "--- Prepare (threads=${PREP_THREADS:-16}, tables=${TPCC_TABLES}, scale=${TPCC_SCALE}) ---"
    echo "NOTE: ~100 GB prepare can take several hours."
    PREP_START=$(date +%s)
    run_tpcc_command prepare 2>&1 | tee "${results_dir}/prepare.log"
    PREP_END=$(date +%s)
    echo "Prepare completed in $((PREP_END - PREP_START))s ($(longevity_duration_human $((PREP_END - PREP_START))))"
    echo ""
  else
    echo "--- Skipping prepare (SKIP_PREPARE=1) — reusing existing dataset ---"
    echo ""
  fi

  if [[ "${RUN_CHECK}" == "1" ]]; then
    echo "--- TPC-C consistency check (pre-run) ---"
    export TPCC_THREADS="${PREP_THREADS:-16}"
    run_tpcc_command check 2>&1 | tee "${results_dir}/check_pre.log" \
      || { echo "ERROR: pre-run TPC-C check failed"; return 1; }
    echo "Pre-run check complete; releasing check connections before load..."
    sleep 3
    echo ""
  fi

  echo "timestamp_utc,segment_idx,run_start,run_end,wall_sec,requested_sec,warmup_sec,exit_code" \
    > "${results_dir}/segments.csv"

  local remaining="${TARGET_SEC}"
  local total_elapsed=0
  local restart_count=0
  local segment_idx=0
  local bench_start
  bench_start=$(date +%s)

  write_longevity_state "${state_file}" 0 0 "running"

  while [[ "${remaining}" -gt 0 ]]; do
    local warmup=0
    if [[ "${segment_idx}" -eq 0 ]]; then
      warmup="${LONGEVITY_WARMUP_SEC:-300}"
    fi

    echo ""
    echo "=== Segment ${segment_idx}: remaining=${remaining}s ($(longevity_duration_human "${remaining}")) ==="

    local seg_start seg_end seg_wall exit_code=0
    seg_start=$(date +%s)

    if ! run_longevity_tpcc_segment "${edition}" "${results_dir}" "${remaining}" "${warmup}" "${segment_idx}"; then
      exit_code=$?
    fi

    seg_end=$(date +%s)
    seg_wall=$((seg_end - seg_start))

    # Count productive time toward target (exclude warmup on first segment)
    local productive=$((seg_wall - warmup))
    if [[ "${productive}" -lt 0 ]]; then
      productive=0
    fi
    total_elapsed=$((total_elapsed + productive))
    remaining=$((TARGET_SEC - total_elapsed))
    if [[ "${remaining}" -lt 0 ]]; then
      remaining=0
    fi

    write_longevity_state "${state_file}" "${total_elapsed}" "${restart_count}" "running"
    echo "Segment ${segment_idx} wall=${seg_wall}s productive=${productive}s total_elapsed=${total_elapsed}s remaining=${remaining}s exit=${exit_code}"

    if [[ "${exit_code}" -eq 0 && "${remaining}" -le 0 ]]; then
      echo "Target duration reached."
      break
    fi

    if [[ "${exit_code}" -ne 0 ]]; then
      if [[ "${AUTO_RESTART}" != "1" ]]; then
        echo "ERROR: sysbench exited with code ${exit_code} and LONGEVITY_AUTO_RESTART!=1"
        write_longevity_state "${state_file}" "${total_elapsed}" "${restart_count}" "failed"
        return 1
      fi
      restart_count=$((restart_count + 1))
      echo "WARNING: sysbench exited early (code ${exit_code}); restart #${restart_count} in 10s..."
      sleep 10
    fi

    segment_idx=$((segment_idx + 1))
  done

  write_longevity_state "${state_file}" "${total_elapsed}" "${restart_count}" "complete"

  if [[ "${RUN_CHECK}" == "1" ]]; then
    echo ""
    echo "--- TPC-C consistency check (post-run) ---"
    export TPCC_THREADS="${PREP_THREADS:-16}"
    run_tpcc_command check 2>&1 | tee "${results_dir}/check_post.log" \
      || { echo "WARNING: post-run TPC-C check failed — see ${results_dir}/check_post.log"; }
    echo ""
  fi

  local bench_end=$((bench_start + total_elapsed + LONGEVITY_WARMUP_SEC))
  bench_end=$(date +%s)
  echo "Longevity run finished: wall clock $((bench_end - bench_start))s, productive ${total_elapsed}s, restarts ${restart_count}"

  write_longevity_summary "${results_dir}" "${edition}" "${TARGET_SEC}"
  generate_longevity_graphs "${results_dir}" "${edition}" "${TARGET_SEC}"
  # Re-write summary so graph paths are included
  write_longevity_summary "${results_dir}" "${edition}" "${TARGET_SEC}" >/dev/null
  echo "${results_dir}" > "${RESULTS_BASE}/LATEST_LONGEVITY_$(echo "${edition}" | tr '[:lower:]' '[:upper:]').txt"
  echo "${results_dir}" > "${RESULTS_BASE}/LATEST_LONGEVITY.txt"

  echo ""
  echo "${edition}: longevity benchmark complete → ${results_dir}/longevity_summary.txt"
  )
}

FAILED=0
for edition in ${EDITIONS}; do
  if ! run_longevity_edition "${edition}"; then
    FAILED=$((FAILED + 1))
  fi
done

echo ""
echo "=== Longevity benchmark finished ==="
if [[ "${FAILED}" -gt 0 ]]; then
  echo "WARNING: ${FAILED} edition(s) failed"
  exit 1
fi
