#!/usr/bin/env bash
# Add --reconnect_time_sec support to sysbench-tpcc.
# Every N seconds one randomly chosen thread gracefully reconnects.
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

if grep -q 'reconnect_time_sec' "${TPCC_COMMON}" && grep -q '_reconn_last_slot' "${TPCC_LUA}"; then
  echo "tpcc already has reconnect_time_sec support"
  exit 0
fi

# --- 1. Add option to tpcc_common.lua ---
if ! grep -q 'reconnect_time_sec' "${TPCC_COMMON}"; then
  python3 - "${TPCC_COMMON}" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()

option_line = (
    '   reconnect_time_sec =\n'
    '      {"Every N seconds one randomly chosen thread gracefully reconnects (0 = disabled)", 0},\n'
)

# Insert before the closing brace of sysbench.cmdline.options
# Find the last "}" that closes the options table (preceded by a line with a value)
import re
# Match the final closing brace of the options table
m = re.search(r'^}\s*$', text, re.MULTILINE)
if m:
    text = text[:m.start()] + option_line + text[m.start():]
    path.write_text(text)
else:
    sys.exit("Could not find closing brace of sysbench.cmdline.options")
PY
  echo "Patched ${TPCC_COMMON}: added reconnect_time_sec option"
fi

# --- 2. Add reconnect logic to tpcc.lua ---
if ! grep -q '_reconn_last_slot' "${TPCC_LUA}"; then
  python3 - "${TPCC_LUA}" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()

# Add the slot tracker before thread_init
init_block = """
local _reconn_last_slot = 0

"""

# Find "function thread_init()" and prepend the slot tracker
m = re.search(r'^function thread_init\(\)', text, re.MULTILINE)
if not m:
    sys.exit("Could not find function thread_init()")
text = text[:m.start()] + init_block + text[m.start():]

# Patch thread_init to initialize the slot
text = text.replace(
    "function thread_init()\n   drv,con=db_connection_init()\nend",
    "function thread_init()\n"
    "   drv,con=db_connection_init()\n"
    "   if sysbench.opt.reconnect_time_sec > 0 then\n"
    "      _reconn_last_slot = math.floor(os.time() / sysbench.opt.reconnect_time_sec)\n"
    "   end\n"
    "end",
    1,
)

# Add reconnect check at the end of event(), just before the closing "end"
# We look for the transaction execution line followed by end-of-event
reconn_code = (
    "\n"
    "   -- One-thread-per-interval graceful reconnect.\n"
    "   local interval = sysbench.opt.reconnect_time_sec\n"
    "   if interval > 0 then\n"
    "      local slot = math.floor(os.time() / interval)\n"
    "      if slot > _reconn_last_slot then\n"
    "         _reconn_last_slot = slot\n"
    "         local nthreads = sysbench.opt.threads\n"
    "         local winner = (slot * 2654435761) % nthreads\n"
    "         if (sysbench.tid or 0) == winner then\n"
    "            con:reconnect()\n"
    "         end\n"
    "      end\n"
    "   end\n"
)

# Find the end of event(): match the last "end" after the transaction execution
# The event() function ends with a standalone "end" on its own line.
# We insert the reconnect code before that "end".
# Strategy: find "function event()" then its closing "end"
event_match = re.search(r'^function event\(\)', text, re.MULTILINE)
if not event_match:
    sys.exit("Could not find function event()")

# Find the block from event() to the next top-level function
event_start = event_match.start()
# Find "end" lines after event_start; the first standalone "^end$" is the close
rest = text[event_start:]
end_match = re.search(r'^end$', rest, re.MULTILINE)
if not end_match:
    sys.exit("Could not find end of event()")

insert_pos = event_start + end_match.start()

# Only insert if not already there
if '_reconn_last_slot' not in text[event_start:event_start + end_match.end()]:
    text = text[:insert_pos] + reconn_code + "\n" + text[insert_pos:]

path.write_text(text)
PY
  echo "Patched ${TPCC_LUA}: added one-thread-per-interval reconnect in event()"
fi
