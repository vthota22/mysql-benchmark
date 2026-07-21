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

# If a previous bad patch left broken syntax, reset tpcc_common.lua from git.
if grep -q 'reconnect_time_sec' "${TPCC_COMMON}"; then
  # Quick sanity: try loading just the options table with Lua-like checks
  if python3 -c "
import sys, re
text = open(sys.argv[1]).read()
# Verify every line with reconnect_time_sec has a comma on the line before it
lines = text.split('\n')
ok = True
for i, line in enumerate(lines):
    if 'reconnect_time_sec' in line and '=' in line:
        for j in range(i-1, -1, -1):
            s = lines[j].rstrip()
            if s:
                if not s.endswith(','):
                    ok = False
                break
# Also check for duplicate insertions
count = sum(1 for l in lines if 'reconnect_time_sec' in l and '=' in l)
if count > 1:
    ok = False
if ok:
    sys.exit(0)
else:
    sys.exit(1)
" "${TPCC_COMMON}" 2>/dev/null; then
    # Syntax looks correct
    if grep -q '_reconn_last_slot' "${TPCC_LUA}"; then
      echo "tpcc already has reconnect_time_sec support"
      exit 0
    fi
  else
    echo "Detected broken reconnect_time_sec in tpcc_common.lua — resetting from git"
    if [[ -d "${TPCC_DIR}/.git" ]]; then
      git -C "${TPCC_DIR}" checkout -- tpcc_common.lua
    else
      # No git — strip all reconnect_time_sec lines manually
      python3 -c "
import sys
from pathlib import Path
p = Path(sys.argv[1])
lines = p.read_text().split('\n')
out, skip = [], 0
for line in lines:
    if 'reconnect_time_sec' in line:
        skip = 2; continue
    if skip > 0:
        skip -= 1; continue
    out.append(line)
p.write_text('\n'.join(out))
" "${TPCC_COMMON}"
    fi
  fi
fi

# --- 1. Add option to tpcc_common.lua ---
if ! grep -q 'reconnect_time_sec' "${TPCC_COMMON}"; then
  python3 - "${TPCC_COMMON}" <<'PY'
import re, sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()

new_option = (
    '   reconnect_time_sec =\n'
    '      {"Every N seconds one randomly chosen thread gracefully reconnects (0 = disabled)", 0},\n'
)

# Find "sysbench.cmdline.options = {" then its matching "}"
opts_start = text.find('sysbench.cmdline.options = {')
if opts_start < 0:
    sys.exit("Could not find sysbench.cmdline.options table")

# Find the closing "}" — first standalone "}" after the options table start
rest = text[opts_start:]
m = re.search(r'^}\s*$', rest, re.MULTILINE)
if not m:
    sys.exit("Could not find closing brace of sysbench.cmdline.options")

insert_pos = opts_start + m.start()

# Ensure the last option line before "}" has a trailing comma.
# Look backwards from insert_pos for the last "}" or quote that ends an option value.
before = text[:insert_pos].rstrip()
if before and before[-1] in ('"', '}') and not before.endswith(','):
    text = before + ',\n' + new_option + text[insert_pos:]
else:
    text = text[:insert_pos] + new_option + text[insert_pos:]

path.write_text(text)
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
