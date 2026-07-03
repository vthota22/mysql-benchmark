#!/usr/bin/env bash
# Prefer sysbench 1.1+ if installed locally, else fall back to PATH (Homebrew/apt 1.0)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SYSBENCH_11="${SCRIPT_DIR}/sysbench-1.1/bin/sysbench"

_sysbench_usable() {
  local bin="${1:?binary required}"
  [[ -x "${bin}" ]] && "${bin}" --version >/dev/null 2>&1
}

if _sysbench_usable "${SYSBENCH_11}"; then
  echo "${SYSBENCH_11}"
elif command -v sysbench >/dev/null 2>&1 && _sysbench_usable "$(command -v sysbench)"; then
  command -v sysbench
else
  echo "ERROR: sysbench not found or not runnable on this host." >&2
  echo "  Local prefix not usable: ${SYSBENCH_11}" >&2
  echo "  Run ${SCRIPT_DIR}/install_sysbench_11.sh on this machine (do not copy macOS binaries to Linux)." >&2
  exit 1
fi
