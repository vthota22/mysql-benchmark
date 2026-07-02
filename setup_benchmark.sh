#!/usr/bin/env bash
# One-time setup for MySQL Standard vs Advanced benchmarking on Ubuntu DO droplet
# Installs: sysbench 1.1+, sysbench-tpcc, mysql client, doctl, build deps
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PREFIX="${SYSBENCH_PREFIX:-${SCRIPT_DIR}/sysbench-1.1}"
TPCC_DIR="${TPCC_DIR:-${SCRIPT_DIR}/TPCC/sysbench-tpcc}"
JOBS="${JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
DOCTL_VERSION="${DOCTL_VERSION:-1.118.0}"

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
    git curl build-essential autoconf automake libtool pkg-config \
    libmysqlclient-dev libssl-dev luajit libluajit-5.1-dev \
    mysql-client openssl ca-certificates
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

doctl_arch_suffix() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *)
      echo "ERROR: unsupported architecture for doctl: $(uname -m)" >&2
      return 1
      ;;
  esac
}

install_doctl() {
  if command -v doctl >/dev/null 2>&1; then
    echo "--- doctl already installed: $(doctl version) ---"
    return 0
  fi

  echo "--- Installing doctl ${DOCTL_VERSION} ---"
  case "${OS}" in
    ubuntu|debian|linux)
      local arch suffix tmpdir
      arch="$(doctl_arch_suffix)"
      suffix="linux-${arch}"
      tmpdir="$(mktemp -d)"
      curl -fsSL \
        "https://github.com/digitalocean/doctl/releases/download/v${DOCTL_VERSION}/doctl-${DOCTL_VERSION}-${suffix}.tar.gz" \
        -o "${tmpdir}/doctl.tar.gz"
      tar -xzf "${tmpdir}/doctl.tar.gz" -C "${tmpdir}"
      sudo install -m 755 "${tmpdir}/doctl" /usr/local/bin/doctl
      rm -rf "${tmpdir}"
      ;;
    macos)
      brew install doctl
      ;;
    *)
      echo "WARNING: skipping doctl install on unknown OS '${OS}'"
      return 0
      ;;
  esac

  doctl version
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
"${SCRIPT_DIR}/scripts/patch_tpcc_failover.sh" "${TPCC_DIR}"

echo ""
echo "--- Patching sysbench-tpcc prepare (COMMIT after bulk inserts for HA MySQL) ---"
"${SCRIPT_DIR}/scripts/patch_tpcc_prepare_commit.sh" "${TPCC_DIR}"

echo ""
install_doctl

echo ""
echo "--- Installing kubectl (for K8s pod monitoring) ---"
if command -v kubectl >/dev/null 2>&1; then
  echo "kubectl already installed: $(kubectl version --client --short 2>/dev/null || kubectl version --client 2>&1 | head -1)"
else
  case "${OS}" in
    ubuntu|debian|linux)
      KUBE_ARCH="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
      curl -fsSLo /tmp/kubectl "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/${KUBE_ARCH}/kubectl"
      sudo install -m 755 /tmp/kubectl /usr/local/bin/kubectl
      rm -f /tmp/kubectl
      ;;
    macos)
      brew install kubectl
      ;;
    *)
      echo "WARNING: skipping kubectl install on unknown OS '${OS}'"
      ;;
  esac
  command -v kubectl >/dev/null 2>&1 && echo "kubectl installed: $(kubectl version --client 2>&1 | head -1)" || echo "WARNING: kubectl install failed (K8s monitoring will be disabled)"
fi

echo ""
echo "--- Verification ---"
export PATH="${PREFIX}/bin:${PATH}"
sysbench --version
echo ""
sysbench --help 2>&1 | grep -E 'mysql-ssl|mysql-host' | head -5 || true
echo ""
command -v doctl >/dev/null 2>&1 && doctl version || echo "doctl: not installed"
command -v kubectl >/dev/null 2>&1 && echo "kubectl: $(kubectl version --client 2>&1 | head -1)" || echo "kubectl: not installed (K8s monitoring disabled)"
echo ""
ls -la "${TPCC_DIR}/tpcc.lua"

echo ""
echo "=== Setup complete ==="
echo ""
echo "Next steps:"
echo "  1. export PATH=\"${PREFIX}/bin:\$PATH\""
echo "  2. Standard vs Advanced: cp benchmark.conf.example benchmark.conf && ./run_standard_vs_advanced.sh"
echo "  3. Scaling benchmark:   cp scaling-benchmarking/benchmark.conf.example scaling-benchmarking/benchmark.conf"
echo "     Edit DO_API_TOKEN + CLUSTER_ID, then: cd scaling-benchmarking && ./run_benchmark.sh"
echo ""
