#!/usr/bin/env python3
"""Generate failover PNG graphs and/or interactive HTML report from failover_timeseries.csv."""

from __future__ import annotations

import argparse
import csv
import html
import json
import sys
from pathlib import Path

HAS_MPL = False
plt = None


def _ensure_mpl() -> bool:
    global HAS_MPL, plt
    if HAS_MPL:
        return True
    try:
        import matplotlib.pyplot as _plt

        plt = _plt
        HAS_MPL = True
        return True
    except ImportError:
        return False

KPI_LABELS = {
    "failure_detection_sec": "Failure detection (s)",
    "primary_election_sec": "Primary election (s)",
    "app_recovery_sec": "App recovery (s)",
    "tps_dip_duration_sec": "TPS dip duration (s)",
    "peak_latency_failover_ms": "Peak latency (ms)",
    "transactions_failed_during_failover": "Failed transactions",
    "data_loss": "Data loss",
}


def load_metadata(path: Path) -> dict[str, str]:
    meta: dict[str, str] = {}
    if not path.exists():
        return meta
    for line in path.read_text().splitlines():
        if "=" in line:
            key, _, value = line.partition("=")
            meta[key.strip()] = value.strip()
    return meta


def load_kpi(path: Path) -> dict[str, str]:
    if not path.exists():
        return {}
    with path.open(newline="") as fh:
        reader = csv.DictReader(fh)
        for row in reader:
            return {k: v for k, v in row.items() if k != "edition"}
    return {}


def load_timeseries(path: Path) -> list[dict[str, float]]:
    rows: list[dict[str, float]] = []
    with path.open(newline="") as fh:
        reader = csv.DictReader(fh)
        for row in reader:
            rows.append(
                {
                    "elapsed_sec": float(row["elapsed_sec"]),
                    "seconds_from_trigger": float(row.get("seconds_from_trigger", 0)),
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


def _kpi_table_html(kpi: dict[str, str]) -> str:
    if not kpi:
        return "<p class=\"muted\">No failover_kpi.csv found.</p>"
    rows_html = "".join(
        f"<tr><th>{html.escape(KPI_LABELS.get(k, k))}</th>"
        f"<td>{html.escape(str(v))}</td></tr>"
        for k, v in kpi.items()
    )
    return f"<table class=\"kpi\"><tbody>{rows_html}</tbody></table>"


def generate_html_report(
    edition_dir: Path,
    rows: list[dict[str, float]],
    meta: dict[str, str],
    parsed: dict[str, str],
    event: dict[str, str],
    kpi: dict[str, str],
    png_files: list[Path],
) -> Path:
    trigger = float(meta.get("FAILOVER_TRIGGER_SECOND", "0"))
    edition = meta.get("FAILOVER_EDITION", edition_dir.name)
    baseline = float(parsed.get("BASELINE_TPS", "0"))
    recovery = float(parsed.get("RECOVERY_THRESHOLD", str(baseline * 0.9 if baseline else 0)))
    outage_start = float(parsed.get("OUTAGE_START", trigger))
    outage_end = float(parsed.get("OUTAGE_END", trigger))

    elapsed = [r["elapsed_sec"] for r in rows]
    chart_data = {
        "elapsed": elapsed,
        "tps": [r["tps"] for r in rows],
        "qps": [r["qps"] for r in rows],
        "err": [r["err_per_sec"] for r in rows],
        "reconn": [r["reconn_per_sec"] for r in rows],
        "lat_p95": [r["lat_p95_ms"] for r in rows],
        "trigger_sec": trigger,
        "baseline_tps": baseline,
        "recovery_threshold": recovery,
        "outage_start": outage_start,
        "outage_end": outage_end,
    }

    png_links = ""
    for png in png_files:
        if png.exists():
            png_links += (
                f'<li><a href="{html.escape(png.name)}">{html.escape(png.name)}</a></li>'
            )

    meta_rows = [
        ("Edition", edition),
        ("Sysbench start (UTC)", meta.get("SYSBENCH_START_UTC", "N/A")),
        ("Failover trigger (UTC)", event.get("FAILOVER_TRIGGER_UTC", "N/A")),
        ("Trigger second", str(int(trigger)) if trigger else "N/A"),
        ("Trigger method", event.get("FAILOVER_METHOD", "N/A")),
        ("Target pod", event.get("FAILOVER_TARGET_POD", "N/A")),
        ("Baseline TPS", f"{baseline:.2f}" if baseline else "N/A"),
    ]
    meta_html = "".join(
        f"<tr><th>{html.escape(k)}</th><td>{html.escape(v)}</td></tr>"
        for k, v in meta_rows
    )

    out_path = edition_dir / "graphs" / "failover_report.html"
    out_path.parent.mkdir(exist_ok=True)

    page = f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Failover report — {html.escape(edition)}</title>
  <script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.1/dist/chart.umd.min.js"></script>
  <script src="https://cdn.jsdelivr.net/npm/chartjs-plugin-annotation@3.0.1/dist/chartjs-plugin-annotation.min.js"></script>
  <style>
    :root {{
      --bg: #0f172a; --card: #1e293b; --text: #e2e8f0; --muted: #94a3b8;
      --accent: #38bdf8; --border: #334155;
    }}
    * {{ box-sizing: border-box; }}
    body {{
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      background: var(--bg); color: var(--text); margin: 0; padding: 1.5rem;
      line-height: 1.5;
    }}
    h1 {{ font-size: 1.5rem; margin: 0 0 0.25rem; }}
    .subtitle {{ color: var(--muted); margin-bottom: 1.5rem; }}
    .grid {{ display: grid; gap: 1rem; grid-template-columns: 1fr; }}
    @media (min-width: 960px) {{
      .grid {{ grid-template-columns: 320px 1fr; }}
    }}
    .card {{
      background: var(--card); border: 1px solid var(--border);
      border-radius: 8px; padding: 1rem 1.25rem;
    }}
    .card h2 {{ font-size: 1rem; margin: 0 0 0.75rem; color: var(--accent); }}
    table {{ width: 100%; border-collapse: collapse; font-size: 0.9rem; }}
    th {{ text-align: left; color: var(--muted); font-weight: 500; padding: 0.35rem 0.5rem 0.35rem 0; }}
    td {{ padding: 0.35rem 0; }}
    table.kpi th {{ width: 55%; }}
    .chart-wrap {{ position: relative; height: 320px; margin-bottom: 1rem; }}
    .muted {{ color: var(--muted); font-size: 0.9rem; }}
    ul {{ margin: 0.25rem 0 0; padding-left: 1.25rem; }}
    a {{ color: var(--accent); }}
  </style>
</head>
<body>
  <h1>Failover benchmark report</h1>
  <p class="subtitle">{html.escape(edition)} · generated from {html.escape(edition_dir.name)}</p>

  <div class="grid">
    <div>
      <div class="card">
        <h2>Run metadata</h2>
        <table><tbody>{meta_html}</tbody></table>
      </div>
      <div class="card" style="margin-top:1rem">
        <h2>KPI summary</h2>
        {_kpi_table_html(kpi)}
      </div>
      {"<div class=\"card\" style=\"margin-top:1rem\"><h2>PNG exports</h2><ul>" + png_links + "</ul></div>" if png_links else ""}
    </div>
    <div>
      <div class="card">
        <h2>TPS &amp; QPS</h2>
        <div class="chart-wrap"><canvas id="tpsQpsChart"></canvas></div>
      </div>
      <div class="card">
        <h2>Errors &amp; reconnects</h2>
        <div class="chart-wrap"><canvas id="errorsChart"></canvas></div>
      </div>
      <div class="card">
        <h2>Latency p95 (ms)</h2>
        <div class="chart-wrap"><canvas id="latencyChart"></canvas></div>
      </div>
    </div>
  </div>

  <script>
    const DATA = {json.dumps(chart_data)};
    Chart.defaults.color = "#94a3b8";
    Chart.defaults.borderColor = "#334155";

    function triggerAnnotations() {{
      return {{
        annotation: {{
          annotations: {{
            trigger: {{
              type: "line", xMin: DATA.trigger_sec, xMax: DATA.trigger_sec,
              borderColor: "#f87171", borderWidth: 2, borderDash: [6, 4],
              label: {{ display: true, content: "failover trigger", color: "#fca5a5", backgroundColor: "rgba(30,41,59,0.8)" }}
            }},
            outage: {{
              type: "box", xMin: DATA.outage_start, xMax: DATA.outage_end,
              backgroundColor: "rgba(248,113,113,0.08)", borderWidth: 0,
            }}
          }}
        }}
      }};
    }}

    function baseScales(yTitle) {{
      return {{
        x: {{ title: {{ display: true, text: "Elapsed time (s from sysbench start)" }} }},
        y: {{ title: {{ display: true, text: yTitle }}, beginAtZero: true }}
      }};
    }}

    new Chart(document.getElementById("tpsQpsChart"), {{
      type: "line",
      data: {{
        labels: DATA.elapsed,
        datasets: [
          {{ label: "TPS", data: DATA.tps, borderColor: "#60a5fa", backgroundColor: "rgba(96,165,250,0.1)", borderWidth: 1.5, pointRadius: 0, yAxisID: "y" }},
          {{ label: "QPS", data: DATA.qps, borderColor: "#34d399", backgroundColor: "rgba(52,211,153,0.08)", borderWidth: 1.2, pointRadius: 0, yAxisID: "y1" }},
        ]
      }},
      options: {{
        responsive: true, maintainAspectRatio: false, interaction: {{ mode: "index", intersect: false }},
        plugins: triggerAnnotations(),
        scales: {{
          x: {{ title: {{ display: true, text: "Elapsed time (s)" }} }},
          y: {{ type: "linear", position: "left", title: {{ display: true, text: "TPS" }}, beginAtZero: true }},
          y1: {{ type: "linear", position: "right", title: {{ display: true, text: "QPS" }}, beginAtZero: true, grid: {{ drawOnChartArea: false }} }}
        }}
      }}
    }});

    new Chart(document.getElementById("errorsChart"), {{
      type: "line",
      data: {{
        labels: DATA.elapsed,
        datasets: [
          {{ label: "errors/s", data: DATA.err, borderColor: "#f87171", borderWidth: 1.5, pointRadius: 0 }},
          {{ label: "reconnects/s", data: DATA.reconn, borderColor: "#c084fc", borderWidth: 1.2, pointRadius: 0 }},
        ]
      }},
      options: {{
        responsive: true, maintainAspectRatio: false, interaction: {{ mode: "index", intersect: false }},
        plugins: triggerAnnotations(), scales: baseScales("Rate (/s)")
      }}
    }});

    new Chart(document.getElementById("latencyChart"), {{
      type: "line",
      data: {{
        labels: DATA.elapsed,
        datasets: [
          {{ label: "p95 latency (ms)", data: DATA.lat_p95, borderColor: "#2dd4bf", borderWidth: 1.5, pointRadius: 0 }},
        ]
      }},
      options: {{
        responsive: true, maintainAspectRatio: false, interaction: {{ mode: "index", intersect: false }},
        plugins: triggerAnnotations(), scales: baseScales("Latency p95 (ms)")
      }}
    }});
  </script>
</body>
</html>
"""
    out_path.write_text(page, encoding="utf-8")
    return out_path


def generate_png_for_edition(
    edition_dir: Path,
    rows: list[dict[str, float]],
    meta: dict[str, str],
    parsed: dict[str, str],
) -> list[Path]:
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
        rows, outputs[0], trigger, outage_start, outage_end, baseline, recovery,
        f"{title_base} — TPS & QPS",
    )
    plot_errors(rows, outputs[1], trigger, outage_start, outage_end, f"{title_base} — errors & reconnects")
    plot_latency(rows, outputs[2], trigger, outage_start, outage_end, f"{title_base} — latency p95")
    return outputs


def generate_for_edition(edition_dir: Path, *, png: bool = True, html: bool = True) -> list[Path]:
    ts_path = edition_dir / "failover_timeseries.csv"
    if not ts_path.exists():
        raise FileNotFoundError(f"Missing {ts_path}")

    rows = load_timeseries(ts_path)
    meta = load_metadata(edition_dir / "failover_timeseries_meta.txt")
    parsed = load_metadata(edition_dir / "failover_parsed.env")
    event = load_metadata(edition_dir / "failover_event.txt")
    kpi = load_kpi(edition_dir / "failover_kpi.csv")

    outputs: list[Path] = []
    png_files: list[Path] = []

    if png:
        if not _ensure_mpl():
            print(
                "WARNING: matplotlib not installed — skipping PNG graphs.\n"
                "  Ubuntu: sudo apt-get install -y python3-matplotlib\n"
                "  macOS:  pip3 install matplotlib",
                file=sys.stderr,
            )
        else:
            png_files = generate_png_for_edition(edition_dir, rows, meta, parsed)
            outputs.extend(png_files)

    if html:
        html_path = generate_html_report(edition_dir, rows, meta, parsed, event, kpi, png_files)
        outputs.append(html_path)

    return outputs


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate failover benchmark graphs and HTML report")
    parser.add_argument(
        "path",
        type=Path,
        help="Edition results dir or failover_<timestamp> root containing standard/ advanced/",
    )
    parser.add_argument("--png-only", action="store_true", help="Generate PNG files only")
    parser.add_argument("--html-only", action="store_true", help="Generate HTML report only")
    args = parser.parse_args()
    path: Path = args.path

    do_png = not args.html_only
    do_html = not args.png_only

    if (path / "failover_timeseries.csv").exists():
        edition_dirs = [path]
        results_root = path.parent
    else:
        edition_dirs = sorted(
            d for d in path.iterdir() if d.is_dir() and (d / "failover_timeseries.csv").exists()
        )
        results_root = path

    if not edition_dirs:
        print(f"ERROR: no failover_timeseries.csv found under {path}", file=sys.stderr)
        return 1

    for edition_dir in edition_dirs:
        for out in generate_for_edition(edition_dir, png=do_png, html=do_html):
            print(f"Wrote {out}")

    if do_png and len(edition_dirs) >= 2 and _ensure_mpl():
        comp_path = results_root / "graphs" / "failover_tps_comparison.png"
        comp_path.parent.mkdir(exist_ok=True)
        plot_comparison(edition_dirs, comp_path)
        print(f"Wrote {comp_path}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
