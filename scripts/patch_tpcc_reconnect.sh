#!/usr/bin/env bash
# Add sysbench-style --reconnect to sysbench-tpcc (reconnect after every N events).
# Also removes the old custom --reconnect_time_sec patch if present.
# Idempotent: skips if already patched.
set -euo pipefail

TPCC_DIR="${1:?Usage: $0 /path/to/sysbench-tpcc}"
TPCC_LUA="${TPCC_DIR}/tpcc.lua"
TPCC_COMMON="${TPCC_DIR}/tpcc_common.lua"

if [[ ! -f "${TPCC_LUA}" ]]; then
  echo "ERROR: ${TPCC_LUA} not found" >&2
  exit 1
fi
if [[ ! -f "${TPCC_COMMON}" ]]; then
  echo "ERROR: ${TPCC_COMMON} not found" >&2
  exit 1
fi

python3 - "${TPCC_COMMON}" "${TPCC_LUA}" <<'PY'
import re
import sys
from pathlib import Path

common_path = Path(sys.argv[1])
lua_path = Path(sys.argv[2])
common = common_path.read_text()
lua = lua_path.read_text()
changed_common = False
changed_lua = False

# --- Strip custom --reconnect_time_sec from tpcc_common.lua ---
common_new, n = re.subn(
    r"\n\s*reconnect_time_sec\s*=\s*\n\s*\{[^}]*\},?\n",
    "\n",
    common,
    count=1,
)
if n:
    common = common_new
    changed_common = True
else:
    common_new, n = re.subn(
        r"\n\s*reconnect_time_sec\s*=\s*\{[^}]*\},?\n",
        "\n",
        common,
        count=1,
    )
    if n:
        common = common_new
        changed_common = True

# --- Add --reconnect option (same meaning as sysbench oltp_common.lua) ---
if not re.search(r"(?m)^\s*reconnect\s*=", common):
    opts_start = common.find("sysbench.cmdline.options = {")
    if opts_start < 0:
        sys.exit("Could not find sysbench.cmdline.options table")
    rest = common[opts_start:]
    m = re.search(r"^}\s*$", rest, re.MULTILINE)
    if not m:
        sys.exit("Could not find closing brace of sysbench.cmdline.options")
    insert_pos = opts_start + m.start()
    new_option = (
        ' reconnect =\n'
        ' {"Reconnect after every N events. The default (0) is to not reconnect", 0},\n'
    )
    before = common[:insert_pos].rstrip()
    if before and before[-1] in ('"', "}") and not before.endswith(","):
        common = before + ",\n" + new_option + common[insert_pos:]
    else:
        common = common[:insert_pos] + new_option + common[insert_pos:]
    changed_common = True

# --- Strip custom time-based reconnect from tpcc.lua ---
lua_new, n = re.subn(r"\nlocal _reconn_last_slot = 0\n+", "\n", lua)
if n:
    lua = lua_new
    changed_lua = True

old_init = (
    "function thread_init()\n"
    "   drv,con=db_connection_init()\n"
    "   if sysbench.opt.reconnect_time_sec > 0 then\n"
    "      _reconn_last_slot = math.floor(os.time() / sysbench.opt.reconnect_time_sec)\n"
    "   end\n"
    "end"
)
if old_init in lua:
    lua = lua.replace(
        old_init,
        "function thread_init()\n   drv,con=db_connection_init()\nend",
        1,
    )
    changed_lua = True

reconn_time_block = re.compile(
    r"\n\s*-- One-thread-per-interval graceful reconnect\.\n"
    r"(?:.*\n)*?"
    r"\s*end\n"
    r"\s*end\n"
    r"\s*end\n",
)
lua_new, n = reconn_time_block.subn("\n", lua, count=1)
if n:
    lua = lua_new
    changed_lua = True

# --- Add sysbench-style reconnect-after-N-events in event() ---
if "sysbench.opt.reconnect" not in lua:
    event_match = re.search(r"^function event\(\)", lua, re.MULTILINE)
    if not event_match:
        sys.exit("Could not find function event()")
    rest = lua[event_match.start():]
    end_match = re.search(r"^end$", rest, re.MULTILINE)
    if not end_match:
        sys.exit("Could not find end of event()")
    insert_pos = event_match.start() + end_match.start()
    reconn_code = (
        "\n"
        " -- Reconnect after every N events (--reconnect), matching sysbench OLTP.\n"
        " if sysbench.opt.reconnect > 0 then\n"
        "    _reconnect_events = (_reconnect_events or 0) + 1\n"
        "    if _reconnect_events % sysbench.opt.reconnect == 0 then\n"
        "       con:reconnect()\n"
        "       set_isolation_level(drv, con)\n"
        "       if drv:name() == \"mysql\" then\n"
        "          con:query(\"SET FOREIGN_KEY_CHECKS=0\")\n"
        "          con:query(\"SET autocommit=0\")\n"
        "       end\n"
        "    end\n"
        " end\n"
        "\n"
    )
    lua = lua[:insert_pos] + reconn_code + lua[insert_pos:]
    changed_lua = True

if changed_common:
    common_path.write_text(common)
    print(f"Patched {common_path}: --reconnect option (removed reconnect_time_sec if present)")
if changed_lua:
    lua_path.write_text(lua)
    print(f"Patched {lua_path}: reconnect after every N events")
if not changed_common and not changed_lua:
    print("tpcc already has --reconnect support")
PY
