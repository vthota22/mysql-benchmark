#!/usr/bin/env bash
# Compatibility wrapper — prefer ./bootstrap/which_sysbench.sh
exec "$(cd "$(dirname "$0")" && pwd)/bootstrap/which_sysbench.sh" "$@"
