#!/usr/bin/env bash
# Commit after each sysbench bulk insert during TPC-C prepare.
#
# On DO managed MySQL HA (Group Replication), large uncommitted bulk loads hit:
#   ERROR 3100: Error on observer while running replication hook 'before_commit'
# sysbench sets autocommit=0 and the MySQL driver does not COMMIT between bulk
# INSERT chunks (needs_commit=0), so a single stock/customer load can exceed
# group_replication_transaction_size_limit (~82–150 MB).
set -euo pipefail

TPCC_DIR="${1:?Usage: $0 /path/to/sysbench-tpcc}"
TPCC_COMMON="${TPCC_DIR}/tpcc_common.lua"

if [[ ! -f "${TPCC_COMMON}" ]]; then
  echo "ERROR: ${TPCC_COMMON} not found" >&2
  exit 1
fi

if grep -q 'tpcc-benchmark: commit after bulk insert' "${TPCC_COMMON}"; then
  echo "tpcc_common.lua already has prepare commit patch"
  exit 0
fi

python3 - "${TPCC_COMMON}" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()

commit_line = (
    ' con:bulk_insert_done()\n'
    ' if drv:name() == "mysql" then con:query("COMMIT") end -- tpcc-benchmark: commit after bulk insert\n'
)

if 'tpcc-benchmark: commit after bulk insert' in text:
    sys.exit(0)

if ' con:bulk_insert_done()\n' not in text:
    print(f"ERROR: bulk_insert_done() not found in {path}", file=sys.stderr)
    sys.exit(1)

text = text.replace(' con:bulk_insert_done()\n', commit_line)
path.write_text(text)
PY

echo "Patched ${TPCC_COMMON} with COMMIT after each bulk_insert_done()"
