#!/usr/bin/env python3
"""Generate failover graphs from failover_timeseries.csv (sysbench 1s intervals)."""

from __future__ import annotations

import argparse
import csv
import sys
from pathlib import Path

try:
    import matplotlib.pyplot as plt
except ImportError:
    print(
        "ERROR: matplotlib is required for graph generation.\n"
        "  Ubuntu: sudo apt-get install -y python3-matplotlib\n"
        "  macOS:  pip3 install matplotlib",
        file=sys.stderr,
    )
    sys.exit(1)


def load_metadata(path: Path) -> dict[str, str]:
    meta: dict[str, str] = {}
    if not path.exists():
        return meta
    for line in path.read_text().splitlines():
        if "=" in line:
            key, _, value = line.partition("=")
            meta[key.strip()] = value.strip()
    return meta


def load_timeseries(path: Path) -> list[dict[str, float]]:
    rows: list[dict[str, float]] = []
    with path.open(newline="") as fh:
        reader = csv.DictReader(fh)
        for row in reader:
            rows.append(
                {
                    "elapsed_sec": float(row["elapsed_sec"]),
                    "tps": float(row["tps"]),
                    "qps": float(row["qps"]),
                    "err_per_sec": float(row["err_per_sec"]),
                    "reconn_per_sec": float(row["reconn_per_sec"]),
                    "lat_p95_ms": float(row["lat_p95_ms"]),
                }
            )
    return rows


def _vline_trigger(ax, trigger_sec: float, label: str = "failover trigger") -> None:
    ax.axvline(trigger_sec, color="crimson", linestyle="--", linewidth=1.2, label=label)


def _shade_outage(ax, start: float, end: float) -> None:
    if start >= 0 and end >= start:
        ax.axvspan(start, end, alpha=0.15, color="red", label="outage window")


def plot_tps_qps(
    rows: list[dict[str, float]],
    out_path: Path,
    trigger_sec: float,
    outage_start: float,
    outage_end: float,
    baseline_tps: float,
    recovery_threshold: float,
    title: str,
) -> None:
    elapsed = [r["elapsed_sec"] for r in rows]
    tps = [r["tps"] for r in rows]
    qps = [r["qps"] for r in rows]

    fig, ax1 = plt.subplots(figsize=(12, 5))
    ax1.plot(elapsed, tps, color="#2563eb", linewidth=1.2, label="TPS")
    ax1.set_xlabel("Elapsed time (s from sysbench start)")
    ax1.set_ylabel("Transactions/s", color="#2563eb")
    ax1.tick_params(axis="y", labelcolor="#2563eb")

    ax2 = ax1.twinx()
    ax2.plot(elapsed, qps, color="#059669", linewidth=1.0, alpha=0.85, label="QPS")
    ax2.set_ylabel("Queries/s", color="#059669")
    ax2.tick_params(axis="y", labelcolor="#059669")

    _vline_trigger(ax1, trigger_sec)
    _shade_outage(ax1, outage_start, outage_end)
    if baseline_tps > 0:
        ax1.axhline(baseline_tps, color="#64748b", linestyle=":", linewidth=1, label="baseline TPS")
        ax1.axhline(
            recovery_threshold,
            color="#f59e0b",
            linestyle=":",
            linewidth=1,
            label="90% recovery threshold",
        )

    ax1.set_title(title)
    lines1, labels1 = ax1.get_legend_handles_labels()
    lines2, labels2 = ax2.get_legend_handles_labels()
    ax1.legend(lines1 + lines2, labels1 + labels2, loc="upper right", fontsize=8)
    fig.tight_layout()
    fig.savefig(out_path, dpi=150)
    plt.close(fig)


def plot_errors(
    rows: list[dict[str, float]],
    out_path: Path,
    trigger_sec: float,
    outage_start: float,
    outage_end: float,
    title: str,
) -> None:
    elapsed = [r["elapsed_sec"] for r in rows]
    err = [r["err_per_sec"] for r in rows]
    reconn = [r["reconn_per_sec"] for r in rows]

    fig, ax = plt.subplots(figsize=(12, 4))
    ax.plot(elapsed, err, color="#dc2626", linewidth=1.2, label="errors/s")
    ax.plot(elapsed, reconn, color="#9333ea", linewidth=1.0, label="reconnects/s")
    _vline_trigger(ax, trigger_sec)
    _shade_outage(ax, outage_start, outage_end)
    ax.set_xlabel("Elapsed time (s from sysbench start)")
    ax.set_ylabel("Rate (/s)")
    ax.set_title(title)
    ax.legend(loc="upper right", fontsize=8)
    fig.tight_layout()
    fig.savefig(out_path, dpi=150)
    plt.close(fig)


def plot_latency(
    rows: list[dict[str, float]],
    out_path: Path,
    trigger_sec: float,
    outage_start: float,
    outage_end: float,
    title: str,
) -> None:
    elapsed = [r["elapsed_sec"] for r in rows]
    lat = [r["lat_p95_ms"] for r in rows]

    fig, ax = plt.subplots(figsize=(12, 4))
    ax.plot(elapsed, lat, color="#0f766e", linewidth=1.2, label="p95 latency (ms)")
    _vline_trigger(ax, trigger_sec)
    _shade_outage(ax, outage_start, outage_end)
    ax.set_xlabel("Elapsed time (s from sysbench start)")
    ax.set_ylabel("Latency p95 (ms)")
    ax.set_title(title)
    ax.legend(loc="upper right", fontsize=8)
    fig.tight_layout()
    fig.savefig(out_path, dpi=150)
    plt.close(fig)


def plot_comparison(
    edition_dirs: list[Path],
    out_path: Path,
    window_before: int = 120,
    window_after: int = 300,
) -> None:
    fig, ax = plt.subplots(figsize=(12, 5))
    colors = {"standard": "#2563eb", "advanced": "#059669"}

    for edition_dir in edition_dirs:
        ts_path = edition_dir / "failover_timeseries.csv"
        meta_path = edition_dir / "failover_timeseries_meta.txt"
        if not ts_path.exists():
            continue
        rows = load_timeseries(ts_path)
        meta = load_metadata(meta_path)
        trigger = float(meta.get("FAILOVER_TRIGGER_SECOND", "0"))
        edition = edition_dir.name
        color = colors.get(edition, None)

        rel = [
            (r["elapsed_sec"] - trigger, r["tps"])
            for r in rows
            if -window_before <= r["elapsed_sec"] - trigger <= window_after
        ]
        if not rel:
            continue
        xs, ys = zip(*rel)
        ax.plot(xs, ys, linewidth=1.2, color=color, label=f"{edition} TPS")

    ax.axvline(0, color="crimson", linestyle="--", linewidth=1.2, label="failover trigger")
    ax.set_xlabel("Seconds relative to failover trigger")
    ax.set_ylabel("Transactions/s")
    ax.set_title("Failover TPS comparison (Standard vs Advanced)")
    ax.legend(loc="upper right", fontsize=8)
    fig.tight_layout()
    fig.savefig(out_path, dpi=150)
    plt.close(fig)


def generate_for_edition(edition_dir: Path) -> list[Path]:
    ts_path = edition_dir / "failover_timeseries.csv"
    meta_path = edition_dir / "failover_timeseries_meta.txt"
    parsed_path = edition_dir / "failover_parsed.env"

    if not ts_path.exists():
        raise FileNotFoundError(f"Missing {ts_path}")

    rows = load_timeseries(ts_path)
    meta = load_metadata(meta_path)
    parsed = load_metadata(parsed_path)

    trigger = float(meta.get("FAILOVER_TRIGGER_SECOND", "0"))
    edition = meta.get("FAILOVER_EDITION", edition_dir.name)
    baseline = float(parsed.get("BASELINE_TPS", "0"))
    recovery = float(parsed.get("RECOVERY_THRESHOLD", str(baseline * 0.9)))
    outage_start = float(parsed.get("OUTAGE_START", trigger))
    outage_end = float(parsed.get("OUTAGE_END", trigger))
    title_base = f"Failover — {edition}"

    graphs_dir = edition_dir / "graphs"
    graphs_dir.mkdir(exist_ok=True)

    outputs = [
        graphs_dir / "failover_tps_qps.png",
        graphs_dir / "failover_errors_reconnects.png",
        graphs_dir / "failover_latency_p95.png",
    ]

    plot_tps_qps(
        rows,
        outputs[0],
        trigger,
        outage_start,
        outage_end,
        baseline,
        recovery,
        f"{title_base} — TPS & QPS",
    )
    plot_errors(
        rows,
        outputs[1],
        trigger,
        outage_start,
        outage_end,
        f"{title_base} — errors & reconnects",
    )
    plot_latency(
        rows,
        outputs[2],
        trigger,
        outage_start,
        outage_end,
        f"{title_base} — latency p95",
    )

    return outputs


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate failover benchmark graphs")
    parser.add_argument(
        "path",
        type=Path,
        help="Edition results dir or failover_<timestamp> root containing standard/ advanced/",
    )
    args = parser.parse_args()
    path: Path = args.path

    if (path / "failover_timeseries.csv").exists():
        edition_dirs = [path]
    else:
        edition_dirs = sorted(
            d for d in path.iterdir() if d.is_dir() and (d / "failover_timeseries.csv").exists()
        )

    if not edition_dirs:
        print(f"ERROR: no failover_timeseries.csv found under {path}", file=sys.stderr)
        return 1

    all_outputs: list[Path] = []
    for edition_dir in edition_dirs:
        all_outputs.extend(generate_for_edition(edition_dir))
        for out in all_outputs[-3:]:
            print(f"Wrote {out}")

    if len(edition_dirs) >= 2:
        comp_path = path / "graphs" / "failover_tps_comparison.png"
        comp_path.parent.mkdir(exist_ok=True)
        plot_comparison(edition_dirs, comp_path)
        print(f"Wrote {comp_path}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
