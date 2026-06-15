#!/usr/bin/env bash
# Build sysbench MySQL connection args — supports 1.0.x and 1.1+
# Usage: source this file after setting MYSQL_HOST, MYSQL_PORT, MYSQL_USER, MYSQL_PASSWORD, MYSQL_DB

SYSBENCH_BIN="$("$(dirname "${BASH_SOURCE[0]}")/which_sysbench.sh")"
SYSBENCH_VERSION=$("${SYSBENCH_BIN}" --version 2>&1 | awk '{print $2}')

MYSQL_BASE_OPTS=(
  --db-driver=mysql
  --mysql-host="${MYSQL_HOST}"
  --mysql-port="${MYSQL_PORT}"
  --mysql-user="${MYSQL_USER}"
  --mysql-password="${MYSQL_PASSWORD}"
  --mysql-db="${MYSQL_DB}"
)

# Detect sysbench 1.1+ (--mysql-ssl=REQUIRED; no PEM files in cwd)
SB_VER=$("${SYSBENCH_BIN}" --version 2>&1 | awk '{print $2}' | cut -d- -f1)
SB_MAJOR=$(echo "${SB_VER}" | cut -d. -f1)
SB_MINOR=$(echo "${SB_VER}" | cut -d. -f2)
SB_HELP=$("${SYSBENCH_BIN}" --help 2>&1 || true)

if [[ "${SB_MAJOR}" -ge 1 && "${SB_MINOR}" -ge 1 ]] 2>/dev/null \
    || echo "${SB_HELP}" | grep -qE 'mysql-ssl.*REQUIRED|ssl-mode option'; then
  SYSBENCH_SSL_MODE="1.1"
  MYSQL_SSL_OPTS=(--mysql-ssl=REQUIRED)
else
  SYSBENCH_SSL_MODE="1.0"
  MYSQL_SSL_OPTS=(--mysql-ssl=on)
  SSL_DIR="$(dirname "${BASH_SOURCE[0]}")/ssl-certs"
  "$(dirname "${BASH_SOURCE[0]}")/setup_sysbench_ssl.sh" >/dev/null
fi

run_sysbench() {
  if [[ "${SYSBENCH_SSL_MODE}" == "1.0" ]]; then
    (cd "${SSL_DIR}" && "${SYSBENCH_BIN}" "$@")
  else
    "${SYSBENCH_BIN}" "$@"
  fi
}

# TPC-C must run from repo dir (Lua require). For 1.0.x also copy SSL PEMs there.
run_sysbench_tpcc() {
  local tpcc_dir="${1:?tpcc dir required}"
  shift
  if [[ "${SYSBENCH_SSL_MODE}" == "1.0" ]]; then
    "$(dirname "${BASH_SOURCE[0]}")/setup_tpcc_ssl.sh" "${tpcc_dir}"
  fi
  (cd "${tpcc_dir}" && "${SYSBENCH_BIN}" tpcc.lua "$@")
}
