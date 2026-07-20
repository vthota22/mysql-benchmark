#!/usr/bin/env python3
"""Thin wrapper — runs the App Platform UI package from the repo root."""

from __future__ import annotations

import runpy
import sys
from pathlib import Path

UI_DIR = Path(__file__).resolve().parent / "ui"
sys.path.insert(0, str(UI_DIR))
runpy.run_path(str(UI_DIR / "control_ui.py"), run_name="__main__")
