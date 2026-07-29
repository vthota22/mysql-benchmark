#!/usr/bin/env bash
# Patch Percona sysbench-tpcc so prepare threads reconnect and retry a warehouse
# after connection drops / timeouts instead of dying permanently.
#
# Why not --mysql-ignore-errors alone?
#   Prepare uses bulk_insert_*; ignored 2013 can clear the error without
#   re-sending the INSERT (silent data loss). Warehouse-level pcall + purge
#   + reconnect is the safe approach.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TPCC_DIR="${1:-${REPO_ROOT}/TPCC/sysbench-tpcc}"
COMMON="${TPCC_DIR}/tpcc_common.lua"

if [[ ! -f "${COMMON}" ]]; then
  echo "ERROR: missing ${COMMON}" >&2
  exit 1
fi

if grep -q 'function load_tables_with_retry' "${COMMON}"; then
  echo "Already patched: ${COMMON}"
  exit 0
fi

cp -a "${COMMON}" "${COMMON}.pre_retry_patch.bak"

python3 - "${COMMON}" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()

old = """function cmd_prepare()

   local drv,con = db_connection_init()

   -- create tables in parallel table per thread
   for i = sysbench.tid % sysbench.opt.threads + 1, sysbench.opt.tables,
   sysbench.opt.threads do
     create_tables(drv, con, i)
   end

   -- make sure all tables are created before we load data

   print("Waiting on tables 30 sec\\n")
   sleep(30)

   for i = sysbench.tid % sysbench.opt.threads + 1, sysbench.opt.scale,
   sysbench.opt.threads do
     load_tables(drv, con, i)
   end

end"""

new = """-- Max warehouse-load attempts after disconnect/timeout (override via env).
function prepare_max_retries()
   local n = tonumber(os.getenv("TPCC_PREPARE_MAX_RETRIES") or "10")
   if n == nil or n < 1 then
      return 10
   end
   return n
end

-- Remove partial rows for one warehouse across all table sets so a retry is safe.
function purge_warehouse(con, warehouse_num)
   for table_num = 1, sysbench.opt.tables do
      pcall(function()
         con:query(string.format("DELETE FROM order_line%d WHERE ol_w_id=%d", table_num, warehouse_num))
         con:query(string.format("DELETE FROM new_orders%d WHERE no_w_id=%d", table_num, warehouse_num))
         con:query(string.format("DELETE FROM orders%d WHERE o_w_id=%d", table_num, warehouse_num))
         con:query(string.format("DELETE FROM history%d WHERE h_w_id=%d", table_num, warehouse_num))
         con:query(string.format("DELETE FROM customer%d WHERE c_w_id=%d", table_num, warehouse_num))
         con:query(string.format("DELETE FROM stock%d WHERE s_w_id=%d", table_num, warehouse_num))
         con:query(string.format("DELETE FROM district%d WHERE d_w_id=%d", table_num, warehouse_num))
         con:query(string.format("DELETE FROM warehouse%d WHERE w_id=%d", table_num, warehouse_num))
      end)
   end
end

function reconnect_prepare(drv, con)
   pcall(function() con:disconnect() end)
   local new_con = drv:connect()
   set_isolation_level(drv, new_con)
   if drv:name() == "mysql" then
      new_con:query("SET FOREIGN_KEY_CHECKS=0")
      new_con:query("SET autocommit=0")
   end
   return new_con
end

function load_tables_with_retry(drv, con, warehouse_num)
   local max_attempts = prepare_max_retries()
   local last_err = nil
   for attempt = 1, max_attempts do
      local ok, err = pcall(function()
         load_tables(drv, con, warehouse_num)
      end)
      if ok then
         if attempt > 1 then
            print(string.format("RETRY ok: warehouse %d succeeded on attempt %d\\n",
                                warehouse_num, attempt))
         end
         return con
      end
      last_err = err
      print(string.format("RETRY: warehouse %d failed attempt %d/%d: %s\\n",
                          warehouse_num, attempt, max_attempts, tostring(err)))
      -- Backoff 1s, 2s, ... then reconnect and purge partial warehouse rows.
      ffi.C.usleep(1000000 * attempt)
      con = reconnect_prepare(drv, con)
      pcall(function() purge_warehouse(con, warehouse_num) end)
   end
   error(string.format("prepare gave up on warehouse %d after %d attempts: %s",
                       warehouse_num, max_attempts, tostring(last_err)))
end

function cmd_prepare()

   local drv,con = db_connection_init()

   -- create tables in parallel table per thread
   for i = sysbench.tid % sysbench.opt.threads + 1, sysbench.opt.tables,
   sysbench.opt.threads do
     create_tables(drv, con, i)
   end

   -- make sure all tables are created before we load data

   print("Waiting on tables 30 sec\\n")
   sleep(30)

   for i = sysbench.tid % sysbench.opt.threads + 1, sysbench.opt.scale,
   sysbench.opt.threads do
     con = load_tables_with_retry(drv, con, i)
   end

end"""

if old not in text:
    sys.stderr.write("ERROR: expected cmd_prepare() block not found; refusing to patch\n")
    sys.exit(1)

path.write_text(text.replace(old, new, 1))
print(f"Patched {path}")
PY

# sanity
grep -q 'function load_tables_with_retry' "${COMMON}"
grep -q 'function purge_warehouse' "${COMMON}"
echo "OK: prepare retry patch applied to ${COMMON}"
echo "Override attempts with: TPCC_PREPARE_MAX_RETRIES=20 (default 10)"
