#!/usr/bin/env bash
# Build sysbench MySQL connection args — supports 1.0.x and 1.1+
# Usage: set MYSQL_HOST, MYSQL_PORT, MYSQL_USER, MYSQL_PASSWORD, MYSQL_DB
#        then call build_mysql_base_opts (or source after vars are set)

_SYSBENCH_OPTS_DIR="$(dirname "${BASH_SOURCE[0]}")"
SYSBENCH_BIN="$("${_SYSBENCH_OPTS_DIR}/which_sysbench.sh")"
SYSBENCH_VERSION=$("${SYSBENCH_BIN}" --version 2>&1 | awk '{print $2}')

build_mysql_base_opts() {
  : "${MYSQL_HOST:?MYSQL_HOST must be set before building mysql opts}"
  : "${MYSQL_PORT:?MYSQL_PORT must be set}"
  : "${MYSQL_USER:?MYSQL_USER must be set}"
  : "${MYSQL_PASSWORD:?MYSQL_PASSWORD must be set}"
  : "${MYSQL_DB:?MYSQL_DB must be set}"

  MYSQL_BASE_OPTS=(
    --db-driver=mysql
    --mysql-host="${MYSQL_HOST}"
    --mysql-port="${MYSQL_PORT}"
    --mysql-user="${MYSQL_USER}"
    --mysql-password="${MYSQL_PASSWORD}"
    --mysql-db="${MYSQL_DB}"
  )
}

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
  SSL_DIR="${_SYSBENCH_OPTS_DIR}/ssl-certs"
  "${_SYSBENCH_OPTS_DIR}/setup_sysbench_ssl.sh" >/dev/null
fi

run_sysbench() {
  build_mysql_base_opts
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
  build_mysql_base_opts
  if [[ "${SYSBENCH_SSL_MODE}" == "1.0" ]]; then
    "${_SYSBENCH_OPTS_DIR}/setup_tpcc_ssl.sh" "${tpcc_dir}"
  fi
  (cd "${tpcc_dir}" && "${SYSBENCH_BIN}" tpcc.lua "$@")
}

# Auto-build when sourced by single-DB scripts that already export MYSQL_*
if [[ -n "${MYSQL_HOST:-}" ]]; then
  build_mysql_base_opts
fi
