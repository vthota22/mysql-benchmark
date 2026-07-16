#!/usr/bin/env python3
"""Control UI entrypoint for local laptop and DigitalOcean App Platform.

Frontend is HTML/JS/CSS; this process is the Python HTTP + SSH backend.
App Platform must run this (not static hosting alone).
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path

from control.server import run_server

UI_ROOT = Path(__file__).resolve().parent
DEFAULT_CONFIG = UI_ROOT / "control.local.conf"
# Convenience when launched from repo root via wrapper.
REPO_CONFIG = UI_ROOT.parent / "control.local.conf"


def _default_config_path() -> Path | None:
    explicit = os.environ.get("CONTROL_CONFIG", "").strip()
    if explicit:
        return Path(explicit)
    if DEFAULT_CONFIG.is_file():
        return DEFAULT_CONFIG
    if REPO_CONFIG.is_file():
        return REPO_CONFIG
    # App Platform: env-only (BENCHMARK_DROPLET_MAP + SSH key).
    return None


def main() -> None:
    default_host = os.environ.get("CONTROL_HOST", os.environ.get("HOST", "0.0.0.0"))
    default_port = int(os.environ.get("PORT") or os.environ.get("CONTROL_PORT") or "8765")

    parser = argparse.ArgumentParser(
        description="Failover benchmark control UI (SSH to droplets; serve HTML reports)"
    )
    parser.add_argument(
        "--config",
        type=Path,
        default=None,
        help="Optional control.local.conf (default: ui/ or repo control.local.conf, else env-only)",
    )
    parser.add_argument("--host", default=default_host, help="Bind address (default 0.0.0.0)")
    parser.add_argument("--port", type=int, default=default_port, help="Port (default $PORT or 8765)")
    args = parser.parse_args()

    config_path = args.config if args.config is not None else _default_config_path()
    if config_path is not None and not config_path.is_file():
        example = UI_ROOT / "control.local.conf.example"
        raise SystemExit(
            f"Missing {config_path}\n"
            f"Copy the example and set your droplet:\n"
            f"  cp {example} {DEFAULT_CONFIG}\n"
            f"Or set env: BENCHMARK_DROPLET_MAP, BENCHMARK_REMOTE_REPO, BENCHMARK_SSH_PRIVATE_KEY"
        )

    run_server(args.host, args.port, config_path)


if __name__ == "__main__":
    main()
