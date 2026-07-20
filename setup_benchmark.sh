#!/usr/bin/env bash
# Compatibility wrapper — prefer ./bootstrap/setup_benchmark.sh
exec "$(cd "$(dirname "$0")" && pwd)/bootstrap/setup_benchmark.sh" "$@"
