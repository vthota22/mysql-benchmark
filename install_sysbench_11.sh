#!/usr/bin/env bash
# Compatibility wrapper — prefer ./bootstrap/install_sysbench_11.sh
exec "$(cd "$(dirname "$0")" && pwd)/bootstrap/install_sysbench_11.sh" "$@"
