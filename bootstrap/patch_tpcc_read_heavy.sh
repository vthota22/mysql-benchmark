#!/usr/bin/env bash
# Ensure TPC-C supports --trx_profile=read_heavy (90% read / 10% write).
# Idempotent: safe to re-run on an already-patched tree.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TPCC_DIR="${1:-${ROOT}/TPCC/sysbench-tpcc}"
TPCC_LUA="${TPCC_DIR}/tpcc.lua"
COMMON_LUA="${TPCC_DIR}/tpcc_common.lua"

if [[ ! -f "${TPCC_LUA}" || ! -f "${COMMON_LUA}" ]]; then
  echo "ERROR: TPC-C files not found under ${TPCC_DIR}" >&2
  exit 1
fi

python3 - "${TPCC_LUA}" "${COMMON_LUA}" <<'PY'
import pathlib
import re
import sys

tpcc_path = pathlib.Path(sys.argv[1])
common_path = pathlib.Path(sys.argv[2])
tpcc = tpcc_path.read_text()
common = common_path.read_text()

pick_trx = r'''
function pick_trx()
  local profile = sysbench.opt.trx_profile or "mixed"
  if profile == "write_only" then
    if sysbench.rand.uniform(1, 2) == 1 then
      return "new_order"
    end
    return "payment"
  end
  -- 90% read (orderstatus/stocklevel) / 10% write (new_order/payment)
  if profile == "read_heavy" then
    if sysbench.rand.uniform(1, 100) <= 90 then
      if sysbench.rand.uniform(1, 2) == 1 then
        return "orderstatus"
      end
      return "stocklevel"
    end
    if sysbench.rand.uniform(1, 2) == 1 then
      return "new_order"
    end
    return "payment"
  end

  local max_trx = sysbench.opt.enable_purge == "yes" and 24 or 23
  local trx_type = sysbench.rand.uniform(1, max_trx)
  if trx_type <= 10 then
    return "new_order"
  elseif trx_type <= 20 then
    return "payment"
  elseif trx_type <= 21 then
    return "orderstatus"
  elseif trx_type <= 22 then
    return "delivery"
  elseif trx_type <= 23 then
    return "stocklevel"
  end
  return "purge"
end

function event()
  _G[pick_trx()]()

end
'''

restart_hook = r'''
function sysbench.hooks.before_restart_event(err)
  -- FAILOVER_PATCH: safe before_restart_event
  -- ROLLBACK (and reconnect) may themselves hit ignored errors (e.g. 4094 while
  -- set_as_primary blocks queries). Never let that abort thread_run.
  pcall(function() con:query("ROLLBACK") end)
  if type(err) == "table" then
    local errno = err.sql_errno
    if errno == 2013 or errno == 2055 or errno == 2006 or errno == 2011 or errno == 2003 then
      pcall(function() con:reconnect() end)
    end
  end
end
'''

if "profile == \"read_heavy\"" not in tpcc or "function pick_trx()" not in tpcc:
    # Replace stock event()+before_restart or existing pick_trx block.
    pat = re.compile(
        r"function (?:pick_trx|event)\(\).*?function sysbench\.hooks\.before_restart_event\(err\).*?end\n",
        re.S,
    )
    if not pat.search(tpcc):
        # Fallback: replace from function event through before_restart_event end
        pat = re.compile(
            r"function event\(\).*?function sysbench\.hooks\.before_restart_event\(err\).*?^end\n",
            re.S | re.M,
        )
    new_tpcc, n = pat.subn(pick_trx.lstrip("\n") + restart_hook.lstrip("\n"), tpcc, count=1)
    if n != 1:
        sys.stderr.write("ERROR: could not patch pick_trx/event in tpcc.lua\n")
        sys.exit(1)
    tpcc = new_tpcc
    tpcc_path.write_text(tpcc)
    print(f"Patched {tpcc_path}: pick_trx + read_heavy + safe before_restart")
else:
    print(f"OK {tpcc_path}: read_heavy already present")

trx_opt = (
    '   trx_profile =\n'
    '      {"Transaction mix: mixed (default TPC-C), write_only (new_order+payment), '
    'or read_heavy (90% orderstatus/stocklevel + 10% new_order/payment)", "mixed"}\n'
)
if "trx_profile" not in common:
    if "splittable =" not in common:
        sys.stderr.write("ERROR: splittable option anchor not found in tpcc_common.lua\n")
        sys.exit(1)
    common2, n = re.subn(
        r"(   splittable =\n"
        r'      \{"Create READ WRITE or READ ONLY transactions to allow using a splitting proxy", "no"\})\n'
        r"\}",
        r"\1,\n" + trx_opt + "}",
        common,
        count=1,
    )
    if n != 1 or "trx_profile" not in common2:
        sys.stderr.write("ERROR: failed to insert trx_profile into tpcc_common.lua\n")
        sys.exit(1)
    common_path.write_text(common2)
    print(f"Patched {common_path}: added trx_profile option")
elif "read_heavy" not in common:
    # Fix missing comma after splittable if a prior broken insert left it out.
    common = re.sub(
        r'(splittable =\n'
        r'      \{"Create READ WRITE or READ ONLY transactions to allow using a splitting proxy", "no"\})\n'
        r'(\s*trx_profile =)',
        r"\1,\n\2",
        common,
        count=1,
    )
    common = re.sub(
        r'   trx_profile =\n\s*\{[^}]+\}\n',
        trx_opt,
        common,
        count=1,
    )
    common_path.write_text(common)
    print(f"Patched {common_path}: updated trx_profile help for read_heavy")
else:
    # Heal missing comma if present from an older patch.
    fixed, n = re.subn(
        r'(splittable =\n'
        r'      \{"Create READ WRITE or READ ONLY transactions to allow using a splitting proxy", "no"\})\n'
        r'(\s*trx_profile =)',
        r"\1,\n\2",
        common,
        count=1,
    )
    if n:
        common_path.write_text(fixed)
        print(f"Patched {common_path}: added missing comma before trx_profile")
    else:
        print(f"OK {common_path}: trx_profile/read_heavy already present")
PY

echo "TPC-C read_heavy patch complete: ${TPCC_DIR}"
