#!/usr/bin/env bash
# Copy SSL material into sysbench-tpcc repo for sysbench 1.0.x
# sysbench 1.0 hard-codes: client-key.pem, client-cert.pem, cacert.pem in cwd
set -euo pipefail

SCRIPT_DIR="$(dirname "$0")"
SSL_DIR="${SCRIPT_DIR}/ssl-certs"
TPCC_DIR="${1:-${SCRIPT_DIR}/TPCC/sysbench-tpcc}"

if [[ ! -d "${TPCC_DIR}" ]]; then
  echo "ERROR: TPC-C dir not found: ${TPCC_DIR}"
  exit 1
fi

"${SCRIPT_DIR}/setup_sysbench_ssl.sh" >/dev/null

echo "Setting up SSL files in: ${TPCC_DIR}"

# Use real copies (not symlinks) — macOS cp errors if src/dst are identical
install -m 600 "${SSL_DIR}/client-key.pem" "${TPCC_DIR}/client-key.pem"
install -m 644 "${SSL_DIR}/client-cert.pem" "${TPCC_DIR}/client-cert.pem"

# sysbench 1.0 always opens cacert.pem — file MUST exist or you get:
#   error 2026: TLS/SSL error: No such file or directory (2)
if [[ -f "${SSL_DIR}/ca-certificate.crt" ]]; then
  cp -f "${SSL_DIR}/ca-certificate.crt" "${TPCC_DIR}/cacert.pem"
  echo "Using official CA: ca-certificate.crt -> cacert.pem"
elif [[ -f "${SSL_DIR}/cacert.pem" ]]; then
  cp -f "${SSL_DIR}/cacert.pem" "${TPCC_DIR}/cacert.pem"
  echo "Using ${SSL_DIR}/cacert.pem"
else
  echo ""
  echo "WARNING: No CA certificate found."
  echo "sysbench 1.0.x requires cacert.pem in the TPC-C directory."
  echo ""
  echo "Download CA from your cluster UI (Connection Details -> Download CA certificate)"
  echo "and save as:"
  echo "  ${SSL_DIR}/ca-certificate.crt"
  echo ""
  echo "Then re-run: $0"
  echo ""
  echo "RECOMMENDED: install sysbench 1.1+ (no cacert.pem needed):"
  echo "  ${SCRIPT_DIR}/install_sysbench_11.sh"
  echo "  export PATH=\"${SCRIPT_DIR}/sysbench-1.1/bin:\$PATH\""
  exit 1
fi

echo ""
ls -la "${TPCC_DIR}/client-key.pem" "${TPCC_DIR}/client-cert.pem" "${TPCC_DIR}/cacert.pem"
echo ""
echo "Ready. Run from: cd ${TPCC_DIR}"
