#!/usr/bin/env bash
# Build and install sysbench 1.1+ (master branch) on Linux or macOS
# Installs to ./sysbench-1.1/ relative to repo — does not replace system sysbench
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PREFIX="${SYSBENCH_PREFIX:-${SCRIPT_DIR}/sysbench-1.1}"
SRC_DIR="${SYSBENCH_SRC:-${SCRIPT_DIR}/src/sysbench}"
JOBS="${JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

echo "=== sysbench 1.1+ installer ==="
echo "Install prefix: ${PREFIX}"
echo ""

is_macos() { [[ "$(uname -s)" == "Darwin" ]]; }

# --- 1. Build dependencies ---
echo "--- Checking build dependencies ---"
if is_macos; then
  MISSING=()
  for cmd in git gcc make autoconf automake libtool pkg-config; do
    command -v "$cmd" >/dev/null 2>&1 || MISSING+=("$cmd")
  done
  if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo "Installing missing tools via Homebrew: ${MISSING[*]}"
    brew install automake libtool pkgconf autoconf luajit openssl mysql-client
  fi

  BREW_PREFIX="${HOMEBREW_PREFIX:-/opt/homebrew}"
  export PATH="${BREW_PREFIX}/opt/mysql-client/bin:${BREW_PREFIX}/opt/pkgconf/bin:${PATH}"
  export LDFLAGS="-L${BREW_PREFIX}/opt/openssl/lib -L${BREW_PREFIX}/opt/mysql-client/lib -L${BREW_PREFIX}/opt/zstd/lib ${LDFLAGS:-}"
  export CPPFLAGS="-I${BREW_PREFIX}/opt/openssl/include -I${BREW_PREFIX}/opt/mysql-client/include ${CPPFLAGS:-}"
  export PKG_CONFIG_PATH="${BREW_PREFIX}/opt/openssl/lib/pkgconfig:${BREW_PREFIX}/opt/mysql-client/lib/pkgconfig:${BREW_PREFIX}/opt/zstd/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
  export CFLAGS="-O3 -std=gnu17 ${CFLAGS:-}"

  MYSQL_CONFIG="${BREW_PREFIX}/opt/mysql-client/bin/mysql_config"
  if [[ ! -x "${MYSQL_CONFIG}" ]]; then
    echo "ERROR: mysql_config not found. Run: brew install mysql-client"
    exit 1
  fi
  if [[ ! -d "${BREW_PREFIX}/opt/zstd/lib" ]]; then
    brew install zstd
  fi
else
  for cmd in git gcc make autoconf automake libtool pkg-config mysql_config; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "ERROR: Missing '${cmd}'. Run setup_benchmark.sh or:"
      echo "  sudo apt-get install git build-essential autoconf automake libtool pkg-config libmysqlclient-dev libssl-dev luajit libluajit-5.1-dev"
      exit 1
    fi
  done
  export CFLAGS="-O3 -std=gnu17 ${CFLAGS:-}"
fi

# --- 2. Clone / update source (master = 1.1+ with proper SSL support) ---
echo "--- Fetching sysbench source (master branch) ---"
mkdir -p "$(dirname "${SRC_DIR}")"
if [[ -d "${SRC_DIR}/.git" ]]; then
  git -C "${SRC_DIR}" fetch origin
  git -C "${SRC_DIR}" checkout master
  git -C "${SRC_DIR}" pull origin master
else
  git clone --depth 1 --branch master https://github.com/akopytov/sysbench.git "${SRC_DIR}"
fi

# --- 3. Build ---
echo "--- Building sysbench ---"
cd "${SRC_DIR}"
rm -f config.cache
./autogen.sh
./configure \
  --prefix="${PREFIX}" \
  --with-system-luajit

make -j"${JOBS}"
make install

# --- 4. Verify ---
echo ""
echo "--- Verification ---"
"${PREFIX}/bin/sysbench" --version
echo ""
"${PREFIX}/bin/sysbench" --help 2>&1 | grep -A1 "mysql-ssl" || true

echo ""
echo "=== Install complete ==="
echo ""
echo "Add to your shell (or run before benchmarks):"
echo "  export PATH=\"${PREFIX}/bin:\$PATH\""
echo ""
echo "Test SSL options:"
echo "  sysbench --help | grep mysql-ssl"
echo ""
echo "You should see --mysql-ssl accepts: DISABLED, PREFERRED, REQUIRED, VERIFY_CA, VERIFY_IDENTITY"
