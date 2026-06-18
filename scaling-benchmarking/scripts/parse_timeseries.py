#!/usr/bin/env python3
"""Parse sysbench TPC-C scaling run logs into per-timestamp metrics (no averages)."""

from __future__ import annotations

import argparse
import csv
import re
import sys
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path


INTERVAL_RE = re.compile(
    r"^\[\s*(\d+)s\s*\]\s+thds:\s+(\d+)\s+tps:\s+([\d.]+)\s+qps:\s+([\d.]+)\s+"
    r"\(r/w/o:\s+([\d.]+)/([\d.]+)/([\d.]+)\)\s+"
    r"lat \(ms,95%\):\s+([\d.]+)\s+err/s\s+([\d.]+)\s+reconn/s:\s+([\d.]+)"
)

ENV_LINE_RE = re.compile(r"^([A-Z_]+)=(.*)$")


@dataclass
class Interval:
    elapsed_sec: int
    threads: int
    tps: float
    qps: float
    qps_read: float
    qps_write: float
    qps_other: float
    lat_p95: float
    err_per_sec: float
    reconn_per_sec: float
    phase: str = ""
    wall_clock_utc: str = ""


@dataclass
class ScaleEvent:
    wall_clock_utc: str
    event_type: str
    elapsed_sec: str
    detail: str


def load_scale_timing(path: Path) -> dict[str, str]:
    if not path.is_file():
        return {}
    values: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        match = ENV_LINE_RE.match(line.strip())
        if match:
            values[match.group(1)] = match.group(2)
    return values


def scale_markers(timing: dict[str, str]) -> tuple[int | None, int | None]:
    trigger = timing.get("SCALE_START_ELAPSED")
    complete = timing.get("SCALE_COMPLETE_ELAPSED")
    return (
        int(trigger) if trigger else None,
        int(complete) if complete else None,
    )


def build_scale_events(timing: dict[str, str]) -> list[ScaleEvent]:
    events: list[ScaleEvent] = []
    run_start = timing.get("RUN_START_EPOCH")

    start_epoch = timing.get("SCALE_START_EPOCH")
    start_elapsed = timing.get("SCALE_START_ELAPSED")
    if start_epoch and start_elapsed:
        events.append(
            ScaleEvent(
                wall_clock_utc=epoch_to_utc(int(start_epoch)),
                event_type="SCALE_START",
                elapsed_sec=start_elapsed,
                detail=f"resize triggered after {start_elapsed}s",
            )
        )

    complete_epoch = timing.get("SCALE_COMPLETE_EPOCH")
    complete_elapsed = timing.get("SCALE_COMPLETE_ELAPSED")
    duration = timing.get("SCALE_DURATION_SEC", "")
    if complete_epoch and complete_elapsed:
        events.append(
            ScaleEvent(
                wall_clock_utc=epoch_to_utc(int(complete_epoch)),
                event_type="SCALE_COMPLETE",
                elapsed_sec=complete_elapsed,
                detail=f"resize complete duration={duration}s",
            )
        )

    if not events and run_start:
        return events
    return events


def epoch_to_utc(epoch: int) -> str:
    return datetime.fromtimestamp(epoch, tz=UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def classify_phase(elapsed: int, trigger: int | None, complete: int | None) -> str:
    if trigger is None or elapsed < trigger:
        return "pre_scaling"
    if complete is None or elapsed < complete:
        return "during_scaling"
    return "post_scaling"


def wall_clock_from_elapsed(run_start_epoch: int | None, elapsed_sec: int) -> str:
    if run_start_epoch is None:
        return ""
    return datetime.fromtimestamp(run_start_epoch + elapsed_sec, tz=UTC).strftime(
        "%Y-%m-%dT%H:%M:%SZ"
    )


def parse_intervals(path: Path) -> list[Interval]:
    rows: list[Interval] = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        match = INTERVAL_RE.match(line)
        if not match:
            continue
        rows.append(
            Interval(
                elapsed_sec=int(match.group(1)),
                threads=int(match.group(2)),
                tps=float(match.group(3)),
                qps=float(match.group(4)),
                qps_read=float(match.group(5)),
                qps_write=float(match.group(6)),
                qps_other=float(match.group(7)),
                lat_p95=float(match.group(8)),
                err_per_sec=float(match.group(9)),
                reconn_per_sec=float(match.group(10)),
            )
        )
    return rows


def write_timeseries_csv(intervals: list[Interval], out_path: Path) -> None:
    with out_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow([
            "wall_clock_utc",
            "elapsed_sec",
            "phase",
            "threads",
            "tps",
            "qps",
            "qps_read",
            "qps_write",
            "qps_other",
            "lat_p95",
            "err_per_sec",
            "reconn_per_sec",
        ])
        for row in intervals:
            writer.writerow([
                row.wall_clock_utc,
                row.elapsed_sec,
                row.phase,
                row.threads,
                row.tps,
                row.qps,
                row.qps_read,
                row.qps_write,
                row.qps_other,
                row.lat_p95,
                row.err_per_sec,
                row.reconn_per_sec,
            ])


def write_scale_events_csv(events: list[ScaleEvent], out_path: Path) -> None:
    with out_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(["wall_clock_utc", "event_type", "elapsed_sec", "detail"])
        for event in events:
            writer.writerow([
                event.wall_clock_utc,
                event.event_type,
                event.elapsed_sec,
                event.detail,
            ])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-log", type=Path, required=True)
    parser.add_argument("--scale-timing-file", type=Path, required=True)
    parser.add_argument("--timeseries-csv", type=Path, required=True)
    parser.add_argument("--scale-events-csv", type=Path, required=True)
    parser.add_argument("--run-start-epoch", type=int, default=0)
    args = parser.parse_args()

    timing = load_scale_timing(args.scale_timing_file)
    run_start = args.run_start_epoch or int(timing["RUN_START_EPOCH"]) if timing.get("RUN_START_EPOCH") else None
    trigger, complete = scale_markers(timing)
    intervals = parse_intervals(args.run_log)
    events = build_scale_events(timing)

    if not intervals:
        print(f"WARNING: no sysbench interval lines found in {args.run_log}", file=sys.stderr)

    for row in intervals:
        row.phase = classify_phase(row.elapsed_sec, trigger, complete)
        row.wall_clock_utc = wall_clock_from_elapsed(run_start, row.elapsed_sec)

    write_timeseries_csv(intervals, args.timeseries_csv)
    write_scale_events_csv(events, args.scale_events_csv)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
