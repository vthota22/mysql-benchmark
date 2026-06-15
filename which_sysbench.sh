#!/usr/bin/env bash
# Prefer sysbench 1.1+ if installed locally, else fall back to PATH (Homebrew/apt 1.0)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SYSBENCH_11="${SCRIPT_DIR}/sysbench-1.1/bin/sysbench"

if [[ -x "${SYSBENCH_11}" ]]; then
  echo "${SYSBENCH_11}"
elif command -v sysbench >/dev/null 2>&1; then
  command -v sysbench
else
  echo "ERROR: sysbench not found. Run ${SCRIPT_DIR}/setup_benchmark.sh or install_sysbench_11.sh" >&2
  exit 1
fi
