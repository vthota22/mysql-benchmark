#!/usr/bin/env bash
# Ensure sysbench-tpcc rolls back open transactions after reconnect (failover-safe).
# Idempotent — safe to run on every setup.
set -euo pipefail

TPCC_DIR="${1:?Usage: $0 /path/to/sysbench-tpcc}"
TPCC_LUA="${TPCC_DIR}/tpcc.lua"

if [[ ! -f "${TPCC_LUA}" ]]; then
  echo "ERROR: ${TPCC_LUA} not found" >&2
  exit 1
fi

if grep -q 'sysbench.hooks.before_restart_event' "${TPCC_LUA}"; then
  echo "tpcc.lua already patched for failover reconnect"
  exit 0
fi

HOOK=$(
  cat <<'EOF'

function sysbench.hooks.before_restart_event(err)
  pcall(function() con:query("ROLLBACK") end)
end
EOF
)

# Insert before report_intermediate hook if present, else append before EOF
if grep -q 'function sysbench.hooks.report_intermediate' "${TPCC_LUA}"; then
  awk -v hook="${HOOK}" '
    /function sysbench\.hooks\.report_intermediate/ && !done {
      print hook
      done=1
    }
    { print }
  ' "${TPCC_LUA}" > "${TPCC_LUA}.tmp"
else
  cp "${TPCC_LUA}" "${TPCC_LUA}.tmp"
  printf '%s\n' "${HOOK}" >> "${TPCC_LUA}.tmp"
fi

mv "${TPCC_LUA}.tmp" "${TPCC_LUA}"
echo "Patched ${TPCC_LUA} with before_restart_event ROLLBACK hook"
