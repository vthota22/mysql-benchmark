#!/usr/bin/env bash
# Make sysbench-tpcc tolerate --mysql-ignore-errors during failover/resize.
# Upstream tpcc.lua rolls back in before_restart_event without pcall; a failed
# ROLLBACK throws a non-string error and kills thread_run with "(not a string)".
set -euo pipefail

TPCC_DIR="${1:?Usage: $0 /path/to/sysbench-tpcc}"
TPCC_LUA="${TPCC_DIR}/tpcc.lua"

if [[ ! -f "${TPCC_LUA}" ]]; then
  echo "ERROR: ${TPCC_LUA} not found" >&2
  exit 1
fi

if grep -q 'pcall(function() con:query("ROLLBACK")' "${TPCC_LUA}"; then
  echo "tpcc.lua already has failover-safe before_restart_event"
  exit 0
fi

SAFE_HOOK=$(
  cat <<'EOF'

function sysbench.hooks.before_restart_event(errdesc)
  pcall(function() con:query("ROLLBACK") end)
end
EOF
)

python3 - "${TPCC_LUA}" "${SAFE_HOOK}" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
hook = sys.argv[2]
text = path.read_text()

pattern = re.compile(
    r"\nfunction sysbench\.hooks\.before_restart_event\([^\)]*\)\n(?:.*?\n)*?^end\n",
    re.MULTILINE,
)

if pattern.search(text):
    text = pattern.sub(hook, text, count=1)
else:
    marker = "function sysbench.hooks.report_intermediate"
    if marker not in text:
        text = text.rstrip() + hook + "\n"
    else:
        text = text.replace(marker, hook.lstrip("\n") + "\n\n" + marker, 1)

path.write_text(text)
PY

echo "Patched ${TPCC_LUA} with failover-safe before_restart_event"
