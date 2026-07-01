#!/usr/bin/env python3
"""Local web UI to edit failover settings and start benchmarks on a remote droplet."""

from __future__ import annotations

import argparse
from pathlib import Path

from control.server import run_server

REPO_ROOT = Path(__file__).resolve().parent
DEFAULT_CONFIG = REPO_ROOT / "control.local.conf"


def main() -> None:
    parser = argparse.ArgumentParser(description="Failover benchmark control UI (local → droplet via SSH)")
    parser.add_argument(
        "--config",
        type=Path,
        default=DEFAULT_CONFIG,
        help=f"Droplet SSH settings (default: {DEFAULT_CONFIG.name})",
    )
    parser.add_argument("--host", default="127.0.0.1", help="Local bind address (default: 127.0.0.1)")
    parser.add_argument("--port", type=int, default=8765, help="Local port (default: 8765)")
    args = parser.parse_args()

    if not args.config.is_file():
        example = REPO_ROOT / "control.local.conf.example"
        raise SystemExit(
            f"Missing {args.config}\n"
            f"Copy the example and set your droplet:\n"
            f"  cp {example} {args.config}"
        )

    run_server(args.host, args.port, args.config)


if __name__ == "__main__":
    main()
