#!/usr/bin/env python3
"""Generate PNG charts from longevity benchmark CSV output."""

from __future__ import annotations

import argparse
import csv
from datetime import datetime, timezone
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.dates as mdates
import matplotlib.pyplot as plt


def parse_utc(ts: str) -> datetime | None:
    ts = ts.strip()
    if not ts:
        return None
    for fmt in ("%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%d %H:%M:%S"):
        try:
            return datetime.strptime(ts, fmt).replace(tzinfo=timezone.utc)
        except ValueError:
            continue
    return None


def load_timeseries(path: Path) -> list[dict]:
    rows: list[dict] = []
    with path.open(newline="") as fh:
        reader = csv.DictReader(fh)
        for row in reader:
            ts = parse_utc(row.get("timestamp_utc", ""))
            if ts is None:
                continue
            try:
                rows.append(
                    {
                        "ts": ts,
                        "elapsed_sec": float(row["elapsed_sec"]) if row.get("elapsed_sec") else None,
                        "tps": float(row["tps"]) if row.get("tps") else None,
                        "qps": float(row["qps"]) if row.get("qps") else None,
                        "lat_p95_ms": float(row["lat_p95_ms"]) if row.get("lat_p95_ms") else None,
                        "err_per_sec": float(row["err_per_sec"]) if row.get("err_per_sec") else 0.0,
                        "reconn_per_sec": float(row["reconn_per_sec"]) if row.get("reconn_per_sec") else 0.0,
                    }
                )
            except (TypeError, ValueError):
                continue
    rows.sort(key=lambda r: r["ts"])
    return rows


def load_failover_events(path: Path) -> list[tuple[datetime, str, str]]:
    if not path.is_file():
        return []

    events: list[tuple[datetime, str, str]] = []
    prev_host: str | None = None
    with path.open(newline="") as fh:
        reader = csv.DictReader(fh)
        for row in reader:
            ts = parse_utc(row.get("timestamp_utc", ""))
            host = (row.get("hostname") or "").strip()
            if ts is None or not host or host == "UNREACHABLE":
                continue
            if prev_host is not None and host != prev_host:
                events.append((ts, prev_host, host))
            prev_host = host
    return events


def add_failover_markers(ax, events: list[tuple[datetime, str, str]]) -> None:
    for idx, (ts, old_host, new_host) in enumerate(events):
        ax.axvline(ts, color="#d62728", linewidth=0.8, alpha=0.55, linestyle="--")
        if idx < 8:
            ax.text(
                ts,
                ax.get_ylim()[1],
                f" {new_host}",
                rotation=90,
                va="top",
                ha="right",
                fontsize=7,
                color="#d62728",
            )


def style_time_axis(ax, start: datetime) -> None:
    ax.xaxis.set_major_formatter(mdates.DateFormatter("%m-%d\n%H:%M"))
    ax.set_xlabel(f"UTC time (elapsed from {start.strftime('%Y-%m-%d %H:%M')} UTC)")
    ax.grid(True, alpha=0.25)


def plot_tps(rows: list[dict], events: list[tuple[datetime, str, str]], out: Path, edition: str) -> None:
    if not rows:
        return

    start = rows[0]["ts"]
    xs = [r["ts"] for r in rows if r["tps"] is not None]
    ys = [r["tps"] for r in rows if r["tps"] is not None]
    if not xs:
        return

    fig, ax = plt.subplots(figsize=(14, 5))
    ax.plot(xs, ys, color="#1f77b4", linewidth=0.9, label="TPS")
    add_failover_markers(ax, events)
    ax.set_ylabel("Transactions/sec")
    ax.set_title(f"Longevity TPS — {edition}")
    style_time_axis(ax, start)
    if events:
        ax.plot([], [], color="#d62728", linestyle="--", label="Primary change")
        ax.legend(loc="upper right")
    fig.tight_layout()
    fig.savefig(out, dpi=150)
    plt.close(fig)


def plot_latency(rows: list[dict], events: list[tuple[datetime, str, str]], out: Path, edition: str) -> None:
    xs = [r["ts"] for r in rows if r["lat_p95_ms"] is not None]
    ys = [r["lat_p95_ms"] for r in rows if r["lat_p95_ms"] is not None]
    if not xs:
        return

    start = rows[0]["ts"]
    fig, ax = plt.subplots(figsize=(14, 5))
    ax.plot(xs, ys, color="#ff7f0e", linewidth=0.9, label="p95 latency")
    add_failover_markers(ax, events)
    ax.set_ylabel("Latency (ms, p95)")
    ax.set_title(f"Longevity latency — {edition}")
    style_time_axis(ax, start)
    fig.tight_layout()
    fig.savefig(out, dpi=150)
    plt.close(fig)


def plot_errors(rows: list[dict], out: Path, edition: str) -> None:
    if not rows:
        return

    start = rows[0]["ts"]
    xs = [r["ts"] for r in rows]
    err = [r["err_per_sec"] for r in rows]
    reconn = [r["reconn_per_sec"] for r in rows]

    fig, ax = plt.subplots(figsize=(14, 4))
    ax.plot(xs, err, color="#d62728", linewidth=0.9, label="errors/s")
    ax.plot(xs, reconn, color="#9467bd", linewidth=0.9, label="reconnects/s")
    ax.set_ylabel("Rate (/sec)")
    ax.set_title(f"Longevity errors & reconnects — {edition}")
    style_time_axis(ax, start)
    ax.legend(loc="upper right")
    fig.tight_layout()
    fig.savefig(out, dpi=150)
    plt.close(fig)


def plot_overview(
    rows: list[dict], events: list[tuple[datetime, str, str]], out: Path, edition: str, target_days: float
) -> None:
    if not rows:
        return

    start = rows[0]["ts"]
    fig, axes = plt.subplots(3, 1, figsize=(14, 10), sharex=True)

    tps_x = [r["ts"] for r in rows if r["tps"] is not None]
    tps_y = [r["tps"] for r in rows if r["tps"] is not None]
    if tps_x:
        axes[0].plot(tps_x, tps_y, color="#1f77b4", linewidth=0.9)
        add_failover_markers(axes[0], events)
    axes[0].set_ylabel("TPS")
    axes[0].set_title(f"TPC-C longevity — {edition} ({target_days:g} day target)")

    lat_x = [r["ts"] for r in rows if r["lat_p95_ms"] is not None]
    lat_y = [r["lat_p95_ms"] for r in rows if r["lat_p95_ms"] is not None]
    if lat_x:
        axes[1].plot(lat_x, lat_y, color="#ff7f0e", linewidth=0.9)
    axes[1].set_ylabel("p95 (ms)")

    xs = [r["ts"] for r in rows]
    axes[2].plot(xs, [r["err_per_sec"] for r in rows], color="#d62728", linewidth=0.9, label="errors/s")
    axes[2].plot(xs, [r["reconn_per_sec"] for r in rows], color="#9467bd", linewidth=0.9, label="reconnects/s")
    axes[2].set_ylabel("/sec")
    axes[2].legend(loc="upper right")

    style_time_axis(axes[2], start)
    for ax in axes:
        ax.grid(True, alpha=0.25)

    fig.tight_layout()
    fig.savefig(out, dpi=150)
    plt.close(fig)


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate longevity benchmark graphs")
    parser.add_argument("--results-dir", required=True, type=Path)
    parser.add_argument("--edition", required=True)
    parser.add_argument("--target-days", type=float, default=7.0)
    args = parser.parse_args()

    results_dir = args.results_dir
    timeseries_path = results_dir / "longevity_timeseries.csv"
    monitor_path = results_dir / "primary_monitor.csv"
    graphs_dir = results_dir / "graphs"
    graphs_dir.mkdir(exist_ok=True)

    if not timeseries_path.is_file():
        print(f"ERROR: missing {timeseries_path}")
        return 1

    rows = load_timeseries(timeseries_path)
    if not rows:
        print(f"ERROR: no usable rows in {timeseries_path}")
        return 1

    events = load_failover_events(monitor_path)
    edition = args.edition

    plot_overview(rows, events, graphs_dir / "longevity_overview.png", edition, args.target_days)
    plot_tps(rows, events, graphs_dir / "longevity_tps.png", edition)
    plot_latency(rows, events, graphs_dir / "longevity_latency_p95.png", edition)
    plot_errors(rows, graphs_dir / "longevity_errors_reconnects.png", edition)

    manifest = graphs_dir / "graphs.txt"
    manifest.write_text(
        "\n".join(
            [
                f"longevity_overview.png ({len(rows)} samples, {len(events)} primary changes)",
                "longevity_tps.png",
                "longevity_latency_p95.png",
                "longevity_errors_reconnects.png",
            ]
        )
        + "\n"
    )

    print(f"Generated graphs in {graphs_dir}")
    for name in (
        "longevity_overview.png",
        "longevity_tps.png",
        "longevity_latency_p95.png",
        "longevity_errors_reconnects.png",
    ):
        print(f"  {graphs_dir / name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
