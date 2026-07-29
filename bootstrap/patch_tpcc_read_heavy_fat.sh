#!/usr/bin/env bash
# Add read_heavy_fat (fat_stock_scan) + --fat_read_rows to TPC-C. Idempotent.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TPCC_DIR="${1:-${ROOT}/TPCC/sysbench-tpcc}"
TPCC_LUA="${TPCC_DIR}/tpcc.lua"
COMMON_LUA="${TPCC_DIR}/tpcc_common.lua"
RUN_LUA="${TPCC_DIR}/tpcc_run.lua"

for f in "${TPCC_LUA}" "${COMMON_LUA}" "${RUN_LUA}"; do
  [[ -f "${f}" ]] || { echo "ERROR: missing ${f}" >&2; exit 1; }
done

# Ensure base read_heavy / trx_profile exists first.
"${ROOT}/bootstrap/patch_tpcc_read_heavy.sh" "${TPCC_DIR}"

python3 - "${TPCC_LUA}" "${COMMON_LUA}" "${RUN_LUA}" <<'PY'
import pathlib
import re
import sys

tpcc_path, common_path, run_path = map(pathlib.Path, sys.argv[1:4])
tpcc = tpcc_path.read_text()
common = common_path.read_text()
run = run_path.read_text()

fat_pick = '''
  -- 90% fat stock range scans (~tens of KB/trx) / 10% write
  if profile == "read_heavy_fat" then
    if sysbench.rand.uniform(1, 100) <= 90 then
      return "fat_stock_scan"
    end
    if sysbench.rand.uniform(1, 2) == 1 then
      return "new_order"
    end
    return "payment"
  end
  -- 100% fat stock scans (safe against HAProxy replica/read pool :3307)
  if profile == "read_only_fat" then
    return "fat_stock_scan"
  end
'''

if 'profile == "read_heavy_fat"' not in tpcc:
    # Insert after read_heavy block (before classic mixed max_trx)
    m = re.search(
        r'(  if profile == "read_heavy" then\n'
        r'.*?  end\n)'
        r'(\n  local max_trx)',
        tpcc,
        re.S,
    )
    if not m:
        sys.stderr.write("ERROR: could not find read_heavy block in tpcc.lua\n")
        sys.exit(1)
    tpcc = tpcc[: m.end(1)] + fat_pick + tpcc[m.start(2) :]
    tpcc_path.write_text(tpcc)
    print(f"Patched {tpcc_path}: read_heavy_fat + read_only_fat pick_trx")
elif 'profile == "read_only_fat"' not in tpcc:
    m = re.search(
        r'(  if profile == "read_heavy_fat" then\n'
        r'.*?  end\n)'
        r'(\n  local max_trx)',
        tpcc,
        re.S,
    )
    if not m:
        sys.stderr.write("ERROR: could not find read_heavy_fat block in tpcc.lua\n")
        sys.exit(1)
    only_pick = '''
  -- 100% fat stock scans (safe against HAProxy replica/read pool :3307)
  if profile == "read_only_fat" then
    return "fat_stock_scan"
  end
'''
    tpcc = tpcc[: m.end(1)] + only_pick + tpcc[m.start(2) :]
    tpcc_path.write_text(tpcc)
    print(f"Patched {tpcc_path}: read_only_fat pick_trx")
else:
    print(f"OK {tpcc_path}: read_heavy_fat + read_only_fat already present")

# trx_profile help + fat_read_rows option
if "fat_read_rows" not in common:
    common2, n = re.subn(
        r'(   trx_profile =\n'
        r'      \{[^}]+\})\n'
        r'(\})',
        r'\1,\n'
        r'   fat_read_rows =\n'
        r'      {"Rows returned per fat_stock_scan trx (read_heavy_fat); '
        r'~250-300 bytes/row on the wire", 150}\n'
        r'\2',
        common,
        count=1,
    )
    if n != 1:
        # try append before closing of options after trx_profile line variants
        sys.stderr.write("ERROR: could not insert fat_read_rows into tpcc_common.lua\n")
        sys.exit(1)
    # also refresh trx_profile help text if needed
    common2 = re.sub(
        r'   trx_profile =\n\s*\{[^}]+\},?\n',
        '   trx_profile =\n'
        '      {"Transaction mix: mixed, write_only, read_heavy (90% tiny reads), '
        'read_heavy_fat (90% fat stock scans), or read_only_fat (100% fat stock scans)", '
        '"mixed"},\n',
        common2,
        count=1,
    )
    common_path.write_text(common2)
    print(f"Patched {common_path}: fat_read_rows option")
else:
    print(f"OK {common_path}: fat_read_rows already present")

fat_fn = r'''
-- Wide stock range scan for network throughput calibration (read_heavy_fat).
-- ~250-300 bytes/row × fat_read_rows ≈ tens of KB returned per trx on the wire.
function fat_stock_scan()
    local table_num = sysbench.rand.uniform(1, sysbench.opt.tables)
    local w_id
    if type(pick_warehouse) == "function" then
        w_id = pick_warehouse()
    else
        w_id = sysbench.rand.uniform(1, sysbench.opt.scale)
    end

    local rows = tonumber(sysbench.opt.fat_read_rows) or 150
    if rows < 1 then
        rows = 1
    end
    if rows > MAXITEMS then
        rows = MAXITEMS
    end

    local start_id = sysbench.rand.uniform(1, MAXITEMS - rows + 1)
    local end_id = start_id + rows - 1

    if (sysbench.opt.splittable == "yes") then
        con:query("START TRANSACTION READ ONLY")
    else
        con:query("BEGIN")
    end

    rs = con:query(([[SELECT s_i_id, s_w_id, s_quantity, s_ytd, s_order_cnt, s_remote_cnt,
                             s_dist_01, s_dist_02, s_dist_03, s_dist_04, s_dist_05,
                             s_dist_06, s_dist_07, s_dist_08, s_dist_09, s_dist_10,
                             s_data
                        FROM stock%d
                       WHERE s_w_id = %d
                         AND s_i_id BETWEEN %d AND %d]])
            :format(table_num, w_id, start_id, end_id))

    -- Drain the full result so the client pulls the payload off the wire.
    for i = 1, rs.nrows do
        rs:fetch_row()
    end

    con:query("COMMIT")
end
'''

if "function fat_stock_scan()" not in run:
    if "-- function purge" in run:
        run = run.replace("-- function purge", fat_fn.lstrip("\n") + "\n-- function purge", 1)
    elif "\nfunction purge()" in run:
        run = run.replace("\nfunction purge()", "\n" + fat_fn.lstrip("\n") + "\nfunction purge()", 1)
    else:
        sys.stderr.write("ERROR: could not find purge() anchor in tpcc_run.lua\n")
        sys.exit(1)
    run_path.write_text(run)
    print(f"Patched {run_path}: fat_stock_scan()")
else:
    print(f"OK {run_path}: fat_stock_scan already present")
PY

echo "TPC-C read_heavy_fat patch complete: ${TPCC_DIR}"
