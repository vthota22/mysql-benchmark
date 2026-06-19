#!/usr/bin/env bash
# One-time setup for MySQL Standard vs Advanced benchmarking on Ubuntu DO droplet
# Installs: sysbench 1.1+, sysbench-tpcc, mysql client, build deps
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PREFIX="${SYSBENCH_PREFIX:-${SCRIPT_DIR}/sysbench-1.1}"
TPCC_DIR="${TPCC_DIR:-${SCRIPT_DIR}/TPCC/sysbench-tpcc}"
JOBS="${JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

echo "=== MySQL Benchmark Setup ==="
echo "Install dir: ${SCRIPT_DIR}"
echo ""

detect_os() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    echo "macos"
  elif [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    source /etc/os-release
    echo "${ID:-linux}"
  else
    echo "linux"
  fi
}

OS="$(detect_os)"
echo "Detected OS: ${OS}"
echo ""

install_deps_linux() {
  echo "--- Installing build dependencies (apt) ---"
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    git build-essential autoconf automake libtool pkg-config \
    libmysqlclient-dev libssl-dev luajit libluajit-5.1-dev \
    mysql-client openssl ca-certificates python3-matplotlib
}

install_deps_macos() {
  echo "--- Installing build dependencies (Homebrew) ---"
  local missing=()
  for cmd in git gcc make autoconf automake libtool pkg-config; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    brew install automake libtool pkgconf autoconf luajit openssl mysql-client
  fi
}

case "${OS}" in
  ubuntu|debian|linux)
    install_deps_linux
    ;;
  macos)
    install_deps_macos
    ;;
  *)
    echo "WARNING: Unknown OS '${OS}'. Attempting Linux-style install."
    install_deps_linux || install_deps_macos || true
    ;;
esac

echo ""
echo "--- Building sysbench 1.1+ ---"
SYSBENCH_PREFIX="${PREFIX}" "${SCRIPT_DIR}/install_sysbench_11.sh"

echo ""
echo "--- Cloning sysbench-tpcc ---"
mkdir -p "$(dirname "${TPCC_DIR}")"
if [[ -d "${TPCC_DIR}/.git" ]]; then
  git -C "${TPCC_DIR}" pull --ff-only origin master 2>/dev/null \
    || git -C "${TPCC_DIR}" pull --ff-only origin main 2>/dev/null \
    || echo "Could not update sysbench-tpcc (using existing clone)"
else
  git clone --depth 1 https://github.com/Percona-Lab/sysbench-tpcc.git "${TPCC_DIR}"
fi

if [[ ! -f "${TPCC_DIR}/tpcc.lua" ]]; then
  echo "ERROR: tpcc.lua not found after clone" >&2
  exit 1
fi

echo ""
echo "--- Patching sysbench-tpcc for failover (safe ROLLBACK on reconnect) ---"
"${SCRIPT_DIR}/scripts/patch_tpcc_failover.sh" "${TPCC_DIR}" || true

echo ""
echo "--- Verification ---"
export PATH="${PREFIX}/bin:${PATH}"
sysbench --version
echo ""
sysbench --help 2>&1 | grep -E 'mysql-ssl|mysql-host' | head -5 || true
echo ""
ls -la "${TPCC_DIR}/tpcc.lua"

echo ""
echo "=== Setup complete ==="
echo ""
echo "Next steps:"
echo "  1. cp ${SCRIPT_DIR}/benchmark.conf.example ${SCRIPT_DIR}/benchmark.conf"
echo "  2. Edit benchmark.conf with Standard & Advanced DB credentials"
echo "  3. export PATH=\"${PREFIX}/bin:\$PATH\""
echo "  4. ${SCRIPT_DIR}/run_standard_vs_advanced.sh"
echo ""
