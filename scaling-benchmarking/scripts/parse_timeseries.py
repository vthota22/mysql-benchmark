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
    r"^(?:\[\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\]\s+)?"
    r"\[\s*(\d+)s\s*\]\s+thds:\s+(\d+)\s+tps:\s+([\d.]+)\s+qps:\s+([\d.]+)\s+"
    r"\(r/w/o:\s+([\d.]+)/([\d.]+)/([\d.]+)\)\s+"
    r"lat \(ms,(\d+)%\):\s+([\d.]+)\s+err/s\s+([\d.]+)\s+reconn/s:\s+([\d.]+)"
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
    lat_pct: float
    err_per_sec: float
    reconn_per_sec: float
    percentile: int = 99
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


def sysbench_offset_sec(timing: dict[str, str]) -> int:
    """Seconds between RUN_START_EPOCH and sysbench's t=0 (first report is t=1)."""
    raw = timing.get("SYSBENCH_OFFSET_SEC")
    return int(raw) if raw else 0


def infer_offset_from_benchmark_log(
    benchmark_log: Path, scale_start_elapsed: int
) -> int | None:
    """Derive sysbench offset from interleaved benchmark.log (legacy runs)."""
    if not benchmark_log.is_file():
        return None

    last_sysbench_elapsed: int | None = None
    scale_before_sysbench = False
    scale_line_re = re.compile(r"^\[.*\] PHASE=SCALE_START elapsed=(\d+)s")
    for line in benchmark_log.read_text(encoding="utf-8", errors="replace").splitlines():
        match = INTERVAL_RE.match(line)
        if match:
            elapsed = int(match.group(1))
            if scale_before_sysbench:
                return scale_start_elapsed - elapsed
            last_sysbench_elapsed = elapsed
            continue
        scale_match = scale_line_re.match(line)
        if scale_match and int(scale_match.group(1)) == scale_start_elapsed:
            if last_sysbench_elapsed is not None:
                return scale_start_elapsed - last_sysbench_elapsed
            scale_before_sysbench = True
    return None


def resolve_sysbench_offset(
    timing: dict[str, str], run_log: Path
) -> int:
    offset = sysbench_offset_sec(timing)
    if offset:
        return offset

    scale_start = timing.get("SCALE_START_ELAPSED")
    if not scale_start:
        return 0

    inferred = infer_offset_from_benchmark_log(
        run_log.parent / "benchmark.log", int(scale_start)
    )
    return inferred if inferred is not None else 0


def scale_markers(timing: dict[str, str]) -> tuple[int | None, int | None]:
    offset = sysbench_offset_sec(timing)
    trigger = timing.get("SCALE_START_ELAPSED")
    complete = timing.get("SCALE_COMPLETE_ELAPSED")
    return (
        int(trigger) - offset if trigger else None,
        int(complete) - offset if complete else None,
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


def wall_clock_from_elapsed(
    run_start_epoch: int | None, elapsed_sec: int, sysbench_offset: int = 0
) -> str:
    if run_start_epoch is None:
        return ""
    return datetime.fromtimestamp(
        run_start_epoch + sysbench_offset + elapsed_sec, tz=UTC
    ).strftime("%Y-%m-%dT%H:%M:%SZ")


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
                lat_pct=float(match.group(9)),
                err_per_sec=float(match.group(10)),
                reconn_per_sec=float(match.group(11)),
                percentile=int(match.group(8)),
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
            "lat_pct",
            "percentile",
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
                row.lat_pct,
                row.percentile,
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
    offset = resolve_sysbench_offset(timing, args.run_log)
    timing_for_markers = (
        {**timing, "SYSBENCH_OFFSET_SEC": str(offset)} if offset else timing
    )
    trigger, complete = scale_markers(timing_for_markers)
    intervals = parse_intervals(args.run_log)
    events = build_scale_events(timing)

    if not intervals:
        print(f"WARNING: no sysbench interval lines found in {args.run_log}", file=sys.stderr)
    elif offset == 0 and timing.get("SCALE_START_ELAPSED"):
        print(
            "WARNING: SYSBENCH_OFFSET_SEC missing — wall_clock_utc and phase may be "
            f"~{int(timing['SCALE_START_ELAPSED']) // 10}s early vs scale events",
            file=sys.stderr,
        )

    for row in intervals:
        row.phase = classify_phase(row.elapsed_sec, trigger, complete)
        row.wall_clock_utc = wall_clock_from_elapsed(run_start, row.elapsed_sec, offset)

    write_timeseries_csv(intervals, args.timeseries_csv)
    write_scale_events_csv(events, args.scale_events_csv)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
