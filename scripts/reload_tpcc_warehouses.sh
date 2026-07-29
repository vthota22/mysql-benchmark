#!/usr/bin/env bash
# Purge + reload specific TPC-C warehouse IDs (all table sets) without full prepare.
#
# Usage (on benchmark droplet):
#   BENCHMARK_CONF=/root/mysql-benchmark/benchmark.conf \
#   EDITION=advanced \
#   TPCC_RELOAD_IDS_FILE=results/prepare_.../reload_warehouse_ids.txt \
#   TPCC_THREADS=4 \
#   ./scripts/reload_tpcc_warehouses.sh
#
# Requires tpcc_common.lua with purge_warehouse + load_tables_with_retry.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export PATH="${REPO_ROOT}/sysbench-1.1/bin:${PATH}"

# shellcheck source=lib/benchmark_common.sh
source "${REPO_ROOT}/lib/benchmark_common.sh"

CONFIG="${BENCHMARK_CONF:-${REPO_ROOT}/benchmark.conf}"
EDITION="${EDITION:-advanced}"
load_benchmark_config "${CONFIG}"
set_mysql_env_for_edition "${EDITION}"

IDS_FILE="${TPCC_RELOAD_IDS_FILE:?Set TPCC_RELOAD_IDS_FILE to a newline-separated warehouse id list}"
[[ -f "${IDS_FILE}" ]] || { echo "ERROR: missing ${IDS_FILE}" >&2; exit 1; }

TPCC="$(tpcc_dir)"
COMMON="${TPCC}/tpcc_common.lua"
[[ -f "${COMMON}" ]] || { echo "ERROR: missing ${COMMON}" >&2; exit 1; }
grep -q 'function load_tables_with_retry' "${COMMON}" \
  || { echo "ERROR: ${COMMON} missing load_tables_with_retry — run bootstrap/patch_tpcc_prepare_retry.sh" >&2; exit 1; }
grep -q 'function purge_warehouse' "${COMMON}" \
  || { echo "ERROR: ${COMMON} missing purge_warehouse" >&2; exit 1; }

THREADS="${TPCC_THREADS:-${PREP_THREADS:-4}}"
TABLES="${TPCC_TABLES:-10}"
SCALE="${TPCC_SCALE:-5000}"
FORCE_PK="${TPCC_FORCE_PK:-1}"
TRX_LEVEL="${TPCC_TRX_LEVEL:-RR}"

RESULTS_ROOT="${RESULTS_ROOT:-${REPO_ROOT}/results/reload_warehouses_$(date +%Y%m%d_%H%M%S)}"
mkdir -p "${RESULTS_ROOT}"
ABS_IDS="$(cd "$(dirname "${IDS_FILE}")" && pwd)/$(basename "${IDS_FILE}")"
cp -a "${ABS_IDS}" "${RESULTS_ROOT}/reload_warehouse_ids.txt"
ABS_IDS="${RESULTS_ROOT}/reload_warehouse_ids.txt"
ID_COUNT="$(grep -cE '^[0-9]+$' "${ABS_IDS}" || true)"
echo "Reload ${ID_COUNT} warehouses from ${ABS_IDS}"
echo "threads=${THREADS} tables=${TABLES} results=${RESULTS_ROOT}"

# Ensure cmd_prepare branches to list reload when TPCC_RELOAD_IDS_FILE is set.
python3 - "${COMMON}" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
if "function cmd_prepare_reload_list" in text:
    print(f"Reload helper already present in {path}")
    raise SystemExit(0)

helper = r'''
function cmd_prepare_reload_list()
   local list_file = os.getenv("TPCC_RELOAD_IDS_FILE")
   if list_file == nil or list_file == "" then
      error("TPCC_RELOAD_IDS_FILE is not set")
   end
   local f = io.open(list_file, "r")
   if f == nil then
      error("cannot open TPCC_RELOAD_IDS_FILE=" .. tostring(list_file))
   end
   local ids = {}
   for line in f:lines() do
      local n = tonumber(line)
      if n ~= nil then
         table.insert(ids, n)
      end
   end
   f:close()
   if #ids == 0 then
      error("no warehouse ids in " .. list_file)
   end

   local drv, con = db_connection_init()
   for idx = sysbench.tid % sysbench.opt.threads + 1, #ids, sysbench.opt.threads do
      local w = ids[idx]
      print(string.format("RELOAD: purge+load warehouse %d (%d/%d)\n", w, idx, #ids))
      pcall(function() purge_warehouse(con, w) end)
      con = load_tables_with_retry(drv, con, w)
      print(string.format("RELOAD ok: warehouse %d\n", w))
   end
end

'''

marker = "function cmd_prepare()"
idx = text.find(marker)
if idx < 0:
    sys.stderr.write("ERROR: cmd_prepare() not found\n")
    sys.exit(1)

# Insert helper before cmd_prepare, and branch at top of cmd_prepare.
branch = """function cmd_prepare()
   if os.getenv("TPCC_RELOAD_IDS_FILE") ~= nil and os.getenv("TPCC_RELOAD_IDS_FILE") ~= "" then
      return cmd_prepare_reload_list()
   end
"""
# Avoid double-wrapping if somehow present
if "return cmd_prepare_reload_list()" in text:
    print("Branch already present")
    raise SystemExit(0)

cp = pathlib.Path(str(path) + ".pre_reload_list.bak")
if not cp.exists():
    cp.write_text(text)

text = text[:idx] + helper + branch + text[idx + len(marker):]
# The above replaced "function cmd_prepare()" with helper + "function cmd_prepare()\n   if ...",
# but left the original body — good.
path.write_text(text)
print(f"Patched {path} with reload-list prepare")
PY

export TPCC_RELOAD_IDS_FILE="${ABS_IDS}"
export TPCC_PREPARE_MAX_RETRIES="${TPCC_PREPARE_MAX_RETRIES:-15}"
export TPCC_TABLES="${TABLES}"
export TPCC_SCALE="${SCALE}"
export TPCC_THREADS="${THREADS}"
export TPCC_FORCE_PK="${FORCE_PK}"
export TPCC_TRX_LEVEL="${TRX_LEVEL}"

{
  echo "RELOAD_STARTED_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "IDS_FILE=${ABS_IDS}"
  echo "ID_COUNT=${ID_COUNT}"
  echo "THREADS=${THREADS}"
  echo "TABLES=${TABLES}"
  echo "HOST=${MYSQL_HOST}"
} > "${RESULTS_ROOT}/reload_meta.env"

echo "--- MySQL knobs ---"
mysql -h"${MYSQL_HOST}" -P"${MYSQL_PORT}" -u"${MYSQL_USER}" -p"${MYSQL_PASSWORD}" \
  --ssl-mode=REQUIRED "${MYSQL_DB}" -N -e \
  "SELECT @@group_replication_transaction_size_limit, @@sync_binlog, @@innodb_flush_log_at_trx_commit;" \
  2>/dev/null | grep -v 'Using a password' || true

echo "--- Purge+reload prepare ---"
set +e
run_tpcc_command prepare 2>&1 | tee "${RESULTS_ROOT}/reload.log"
rc=${PIPESTATUS[0]}
set -e
echo "RELOAD_FINISHED_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "${RESULTS_ROOT}/reload_meta.env"
echo "RELOAD_EXIT=${rc}" >> "${RESULTS_ROOT}/reload_meta.env"
if (( rc != 0 )); then
  echo "ERROR: reload prepare exited ${rc}" >&2
  exit "${rc}"
fi
echo "=== Reload prepare done ==="
echo "Next: run TPC-C check and verify missing count is 0"
