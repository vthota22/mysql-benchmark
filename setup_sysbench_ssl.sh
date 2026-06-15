#!/usr/bin/env bash
# sysbench 1.0.x SSL setup for managed MySQL
#
# sysbench 1.0 hard-codes these filenames in the *working directory* when
# --mysql-ssl=on: client-key.pem, client-cert.pem, cacert.pem
#
# IMPORTANT: mysql CLI --ssl-mode=REQUIRED encrypts WITHOUT verifying the CA.
# If cacert.pem exists, sysbench/MySQL client tries to VERIFY the chain and
# fails on internal/self-signed CAs ("self-signed certificate in certificate chain").
# For dev/internal clusters: do NOT use cacert.pem — only dummy client certs.
set -euo pipefail

SSL_DIR="$(dirname "$0")/ssl-certs"
mkdir -p "${SSL_DIR}"

# Dummy client cert/key — required by sysbench 1.0.x file checks; server won't verify these
if [[ ! -f "${SSL_DIR}/client-key.pem" || ! -f "${SSL_DIR}/client-cert.pem" ]]; then
  echo "Generating dummy client-key.pem and client-cert.pem ..."
  openssl req -newkey rsa:2048 -days 365 -nodes -x509 \
    -subj "/CN=sysbench-dummy/O=benchmark" \
    -keyout "${SSL_DIR}/client-key.pem" \
    -out "${SSL_DIR}/client-cert.pem" 2>/dev/null
  chmod 600 "${SSL_DIR}/client-key.pem"
fi

# Remove auto-fetched or wrong CA — it causes error 2026 on self-signed/internal chains
if [[ -f "${SSL_DIR}/cacert.pem" && "${KEEP_CACERT:-0}" != "1" ]]; then
  echo "Removing ${SSL_DIR}/cacert.pem (use KEEP_CACERT=1 to keep for production CA verify)"
  rm -f "${SSL_DIR}/cacert.pem"
fi

# Optional: use official cluster CA (production). Save as ca-certificate.crt then:
if [[ -f "${SSL_DIR}/ca-certificate.crt" && "${KEEP_CACERT:-0}" == "1" ]]; then
  cp "${SSL_DIR}/ca-certificate.crt" "${SSL_DIR}/cacert.pem"
  echo "Using official CA: ${SSL_DIR}/cacert.pem"
fi

echo "SSL files ready in ${SSL_DIR}:"
ls -la "${SSL_DIR}/client-key.pem" "${SSL_DIR}/client-cert.pem"
if [[ -f "${SSL_DIR}/cacert.pem" ]]; then
  ls -la "${SSL_DIR}/cacert.pem"
else
  echo "(no cacert.pem — SSL encrypted, CA not verified; same as mysql --ssl-mode=REQUIRED)"
fi
echo ""
echo "Always run sysbench from: cd ${SSL_DIR}"
