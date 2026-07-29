#!/usr/bin/env bash
# Patch Percona sysbench-tpcc tpcc_run.lua so warehouse sampling can skip IDs.
#
# When TPCC_SKIP_WAREHOUSE_IDS is set (comma/space-separated ints), pick_warehouse()
# and other_ware() redraw until they land outside that set. Empty/unset = stock
# behavior (uniform 1..scale), aside from fixing other_ware to use ~= home_ware.
#
# Usage:
#   ./bootstrap/patch_tpcc_skip_warehouses.sh [TPCC_DIR]
#   TPCC_SKIP_WAREHOUSE_IDS=977,978,979 ./run_failover_benchmark.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TPCC_DIR="${1:-${REPO_ROOT}/TPCC/sysbench-tpcc}"
RUN_LUA="${TPCC_DIR}/tpcc_run.lua"

if [[ ! -f "${RUN_LUA}" ]]; then
  echo "ERROR: missing ${RUN_LUA}" >&2
  exit 1
fi

if grep -q 'SKIP_WAREHOUSES_PATCH: pick_warehouse' "${RUN_LUA}"; then
  echo "Already patched: ${RUN_LUA}"
  exit 0
fi

cp -a "${RUN_LUA}" "${RUN_LUA}.pre_skip_warehouses_patch.bak"

python3 - "${RUN_LUA}" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text()

helper = r'''
-- SKIP_WAREHOUSES_PATCH: pick_warehouse
-- Optional env TPCC_SKIP_WAREHOUSE_IDS (e.g. "977,978,1023") excludes those
-- warehouse IDs from run-phase sampling. Clear the env to use the full 1..scale range.
local _tpcc_skip_warehouses = nil

local function _tpcc_load_skip_warehouses()
   if _tpcc_skip_warehouses ~= nil then
      return
   end
   _tpcc_skip_warehouses = {}
   local raw = os.getenv("TPCC_SKIP_WAREHOUSE_IDS") or ""
   for id in string.gmatch(raw, "%d+") do
      _tpcc_skip_warehouses[tonumber(id)] = true
   end
end

function pick_warehouse()
   _tpcc_load_skip_warehouses()
   local w
   local tries = 0
   repeat
      w = sysbench.rand.uniform(1, sysbench.opt.scale)
      tries = tries + 1
   until (not _tpcc_skip_warehouses[w]) or tries > 100000
   if _tpcc_skip_warehouses[w] then
      error("pick_warehouse: exhausted retries; check TPCC_SKIP_WAREHOUSE_IDS vs --scale")
   end
   return w
end

'''

# Insert helpers after require("tpcc_common")
req = 'require("tpcc_common")'
if req not in text:
    sys.stderr.write("ERROR: require(\"tpcc_common\") not found\n")
    sys.exit(1)
text = text.replace(req, req + "\n" + helper, 1)

# Replace other_ware to honor skip list and fix ~= home_ware
other_new = '''function other_ware (home_ware)
    local tmp

    if sysbench.opt.scale == 1 then return home_ware end
    _tpcc_load_skip_warehouses()
    local tries = 0
    repeat
       tmp = sysbench.rand.uniform(1, sysbench.opt.scale)
       tries = tries + 1
    until (tmp ~= home_ware and not _tpcc_skip_warehouses[tmp]) or tries > 100000
    if tmp == home_ware or _tpcc_skip_warehouses[tmp] then
       return home_ware
    end
    return tmp
end'''

pat_other = re.compile(
    r"function\s+other_ware\s*\(\s*home_ware\s*\)\s*.*?^end",
    re.M | re.S,
)
text2, n = pat_other.subn(other_new, text, count=1)
if n != 1:
    sys.stderr.write("ERROR: failed to replace other_ware\n")
    sys.exit(1)
text = text2

# Replace home-warehouse sampling sites
old = "local w_id = sysbench.rand.uniform(1, sysbench.opt.scale)"
new = "local w_id = pick_warehouse()"
count = text.count(old)
if count < 1:
    sys.stderr.write("ERROR: no w_id sampling sites found\n")
    sys.exit(1)
text = text.replace(old, new)
print(f"Replaced {count} w_id sampling site(s); patched other_ware + pick_warehouse in {path}")
path.write_text(text)
PY

echo "Patched: ${RUN_LUA}"
echo "Set TPCC_SKIP_WAREHOUSE_IDS to activate skips (empty = all warehouses)."
