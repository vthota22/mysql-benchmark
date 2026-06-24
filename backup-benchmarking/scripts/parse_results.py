#!/usr/bin/env python3
"""
Parse sysbench TPC-C benchmark log and backup snapshot files to produce a CSV
with per-second metrics annotated with backup-in-progress status.

Usage:
  python3 parse_results.py <run_dir>

Reads:
  <run_dir>/tpcc_run.log          — sysbench interval output
  <run_dir>/backup_snapshots/     — timestamped JSON backup list snapshots

Writes:
  <run_dir>/benchmark_with_backup_status.csv
  <run_dir>/backups_detected.json — consolidated list of backups seen during the run
"""

from __future__ import annotations

import json
import re
import csv
import sys
from datetime import datetime, timezone
from pathlib import Path


def parse_backup_snapshots(snapshot_dir: Path) -> list[dict]:
    """
    Load all backup snapshot JSONs and extract unique backups.
    Returns list of {name, start_epoch, end_epoch, status, backup_type, incremental}.
    """
    all_backups: dict[str, dict] = {}

    for snap_file in sorted(snapshot_dir.glob("*.json")):
        try:
            with open(snap_file) as f:
                data = json.load(f)
        except (json.JSONDecodeError, OSError):
            continue

        backup_list = data.get("Backups", data.get("backups", []))
        if not backup_list:
            continue

        for b in backup_list:
            name = b.get("name", "")
            if not name:
                continue

            # Extract completion epoch from time.seconds
            time_obj = b.get("time", {})
            end_epoch = int(time_obj.get("seconds", 0))

            # Extract start timestamp from backup name
            # Format: "backup-fork-2026-06-23-12:40:03-full"
            m = re.search(r'(\d{4}-\d{2}-\d{2}-\d{2}:\d{2}:\d{2})', name)
            if m:
                ts_str = m.group(1)
                dt = datetime.strptime(ts_str, "%Y-%m-%d-%H:%M:%S").replace(
                    tzinfo=timezone.utc
                )
                start_epoch = int(dt.timestamp())
            else:
                continue

            status = b.get("status", "unknown")
            backup_type = b.get("backup_type", "unknown")
            incremental = b.get("incremental", False)

            # Keep the latest version of each backup (status may change)
            if name not in all_backups or status == "completed":
                all_backups[name] = {
                    "name": name,
                    "start_epoch": start_epoch,
                    "end_epoch": end_epoch,
                    "status": status,
                    "backup_type": backup_type,
                    "incremental": incremental,
                }

    return sorted(all_backups.values(), key=lambda b: b["start_epoch"])


def find_active_backup(epoch: int, backups: list[dict]) -> str:
    """Return the backup name if epoch falls within any backup's window."""
    for b in backups:
        if b["start_epoch"] <= epoch <= b["end_epoch"]:
            return b["name"]
    return ""


INTERVAL_RE = re.compile(
    r"\[(?P<ts>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)\]\s+"
    r"\[\s*(?P<interval>\d+)s\s*\]\s+"
    r"thds:\s*(?P<threads>\d+)\s+"
    r"tps:\s*(?P<tps>[\d.]+)\s+"
    r"qps:\s*(?P<qps>[\d.]+)\s+"
    r"\(r/w/o:\s*(?P<reads>[\d.]+)/(?P<writes>[\d.]+)/(?P<other>[\d.]+)\)\s+"
    r"lat\s*\(ms,95%\):\s*(?P<lat_p95>[\d.]+)\s+"
    r"err/s\s*(?P<err_s>[\d.]+)\s+"
    r"reconn/s:\s*(?P<reconn_s>[\d.]+)"
)

INTERVAL_NO_TS_RE = re.compile(
    r"\[\s*(?P<interval>\d+)s\s*\]\s+"
    r"thds:\s*(?P<threads>\d+)\s+"
    r"tps:\s*(?P<tps>[\d.]+)\s+"
    r"qps:\s*(?P<qps>[\d.]+)\s+"
    r"\(r/w/o:\s*(?P<reads>[\d.]+)/(?P<writes>[\d.]+)/(?P<other>[\d.]+)\)\s+"
    r"lat\s*\(ms,95%\):\s*(?P<lat_p95>[\d.]+)\s+"
    r"err/s\s*(?P<err_s>[\d.]+)\s+"
    r"reconn/s:\s*(?P<reconn_s>[\d.]+)"
)


def parse_benchmark_log(path: Path, run_start_epoch: int = 0, sysbench_offset: int = 0):
    """Parse sysbench report lines and yield per-interval dicts."""
    with open(path) as f:
        for line in f:
            m = INTERVAL_RE.search(line)
            if m:
                ts_str = m.group("ts")
                dt = datetime.strptime(ts_str, "%Y-%m-%dT%H:%M:%SZ").replace(
                    tzinfo=timezone.utc
                )
                yield {
                    "timestamp": ts_str,
                    "epoch": int(dt.timestamp()),
                    "interval_s": int(m.group("interval")),
                    "threads": int(m.group("threads")),
                    "tps": float(m.group("tps")),
                    "qps": float(m.group("qps")),
                    "reads_ps": float(m.group("reads")),
                    "writes_ps": float(m.group("writes")),
                    "other_ps": float(m.group("other")),
                    "lat_p95_ms": float(m.group("lat_p95")),
                    "err_s": float(m.group("err_s")),
                    "reconn_s": float(m.group("reconn_s")),
                }
                continue

            # Fallback: lines without prefixed timestamp
            m2 = INTERVAL_NO_TS_RE.search(line)
            if m2 and run_start_epoch > 0:
                elapsed = int(m2.group("interval"))
                epoch = run_start_epoch + sysbench_offset + elapsed
                ts_str = datetime.fromtimestamp(epoch, tz=timezone.utc).strftime(
                    "%Y-%m-%dT%H:%M:%SZ"
                )
                yield {
                    "timestamp": ts_str,
                    "epoch": epoch,
                    "interval_s": elapsed,
                    "threads": int(m2.group("threads")),
                    "tps": float(m2.group("tps")),
                    "qps": float(m2.group("qps")),
                    "reads_ps": float(m2.group("reads")),
                    "writes_ps": float(m2.group("writes")),
                    "other_ps": float(m2.group("other")),
                    "lat_p95_ms": float(m2.group("lat_p95")),
                    "err_s": float(m2.group("err_s")),
                    "reconn_s": float(m2.group("reconn_s")),
                }


def load_timing(run_dir: Path) -> dict[str, str]:
    """Load run_timing.env into a dict."""
    timing_file = run_dir / "run_timing.env"
    values: dict[str, str] = {}
    if not timing_file.is_file():
        return values
    for line in timing_file.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        m = re.match(r"^([A-Z_]+)=(.*)$", line)
        if m:
            values[m.group(1)] = m.group(2)
    return values


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <run_dir>", file=sys.stderr)
        sys.exit(1)

    run_dir = Path(sys.argv[1]).resolve()
    if not run_dir.is_dir():
        print(f"ERROR: run directory not found: {run_dir}", file=sys.stderr)
        sys.exit(1)

    timing = load_timing(run_dir)
    run_start_epoch = int(timing.get("RUN_START_EPOCH", "0"))
    sysbench_offset = int(timing.get("SYSBENCH_OFFSET_SEC", "0"))

    # Parse backup snapshots
    snapshot_dir = run_dir / "backup_snapshots"
    backups = parse_backup_snapshots(snapshot_dir) if snapshot_dir.is_dir() else []

    # Filter backups to those that overlap with the run window
    run_end_epoch = int(timing.get("RUN_END_EPOCH", "0"))
    if run_start_epoch and run_end_epoch:
        relevant_backups = [
            b for b in backups
            if b["end_epoch"] >= run_start_epoch and b["start_epoch"] <= run_end_epoch
        ]
    else:
        relevant_backups = backups

    print(f"Parsed {len(relevant_backups)} relevant backups (of {len(backups)} total):")
    for b in relevant_backups:
        duration = b["end_epoch"] - b["start_epoch"]
        print(f"  {b['name']}: {b['start_epoch']} -> {b['end_epoch']} "
              f"(duration {duration}s, status={b['status']})")

    # Save consolidated backup info
    backup_info_path = run_dir / "backups_detected.json"
    with open(backup_info_path, "w") as f:
        json.dump({"backups": relevant_backups}, f, indent=2)
    print(f"\nBackup info saved: {backup_info_path}")

    # Generate CSV
    output_path = run_dir / "benchmark_with_backup_status.csv"
    fieldnames = [
        "timestamp", "epoch", "interval_s", "threads",
        "tps", "qps", "reads_ps", "writes_ps", "other_ps",
        "lat_p95_ms", "err_s", "reconn_s",
        "backup_in_progress", "backup_name",
    ]

    count = 0
    with open(output_path, "w", newline="") as csvfile:
        writer = csv.DictWriter(csvfile, fieldnames=fieldnames)
        writer.writeheader()

        for row in parse_benchmark_log(
            run_dir / "tpcc_run.log", run_start_epoch, sysbench_offset
        ):
            backup_name = find_active_backup(row["epoch"], relevant_backups)
            row["backup_in_progress"] = 1 if backup_name else 0
            row["backup_name"] = backup_name
            writer.writerow(row)
            count += 1

    print(f"Wrote {count} rows to {output_path}")


if __name__ == "__main__":
    main()
