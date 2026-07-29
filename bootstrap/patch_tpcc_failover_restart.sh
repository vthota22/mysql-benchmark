#!/usr/bin/env bash
# Patch Percona sysbench-tpcc before_restart_event so ignored SQL errors during
# ROLLBACK cannot abort the load.
#
# Why:
#   With --mysql-ignore-errors (incl. 4094 during group_replication_set_as_primary),
#   sysbench marks the failure IGNORABLE and calls before_restart_event().
#   Upstream tpcc.lua does bare con:query("ROLLBACK"). If ROLLBACK also returns
#   an ignored errno, Lua throws a table (RESTART_EVENT) outside thread_run's
#   pcall → FATAL: thread_run function failed: (not a string) and sysbench exits.
#
# Fix: wrap ROLLBACK in pcall; optionally reconnect on lost-connection errnos.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TPCC_DIR="${1:-${REPO_ROOT}/TPCC/sysbench-tpcc}"
TPCC_LUA="${TPCC_DIR}/tpcc.lua"

if [[ ! -f "${TPCC_LUA}" ]]; then
  echo "ERROR: missing ${TPCC_LUA}" >&2
  exit 1
fi

if grep -q 'FAILOVER_PATCH: safe before_restart_event' "${TPCC_LUA}"; then
  echo "Already patched: ${TPCC_LUA}"
  exit 0
fi

cp -a "${TPCC_LUA}" "${TPCC_LUA}.pre_failover_restart_patch.bak"

python3 - "${TPCC_LUA}" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

new_hook = """function sysbench.hooks.before_restart_event(err)
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
end"""

import re
pat = re.compile(
    r"function\s+sysbench\.hooks\.before_restart_event\s*\([^)]*\)\s*.*?^end",
    re.M | re.S,
)
if pat.search(text):
    text2, n = pat.subn(new_hook, text, count=1)
    if n != 1:
        sys.stderr.write("ERROR: failed to replace before_restart_event\n")
        sys.exit(1)
    path.write_text(text2)
    print(f"Replaced before_restart_event in {path}")
    sys.exit(0)

# Insert before report_intermediate if present, else append before final vim modeline.
marker = "function sysbench.hooks.report_intermediate"
if marker in text:
    path.write_text(text.replace(marker, new_hook + "\n\n" + marker, 1))
    print(f"Inserted before_restart_event before report_intermediate in {path}")
    sys.exit(0)

vim = "\n-- vim:"
if vim in text:
    path.write_text(text.replace(vim, "\n" + new_hook + "\n" + vim, 1))
else:
    path.write_text(text.rstrip() + "\n\n" + new_hook + "\n")
print(f"Appended before_restart_event to {path}")
PY

grep -q 'FAILOVER_PATCH: safe before_restart_event' "${TPCC_LUA}"
grep -q 'pcall(function() con:query("ROLLBACK") end)' "${TPCC_LUA}"
echo "OK: failover restart patch applied to ${TPCC_LUA}"
