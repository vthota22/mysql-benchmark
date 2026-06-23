#!/usr/bin/env python3
"""Generate an HTML scaling benchmark report with Plotly charts.

Usage:
  pip install plotly
  python3 generate_report.py scaling-benchmarking/results/run_20260621_074113_advanced-s-4-16-200-1gb
  python3 generate_report.py /path/to/run_dir -o /path/to/report.html
"""

from __future__ import annotations

import argparse
import csv
import html
import re
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

try:
    import plotly.graph_objects as go
    from plotly.subplots import make_subplots
except ImportError as exc:  # pragma: no cover
    print("ERROR: plotly is required. Install with: pip install plotly", file=sys.stderr)
    raise SystemExit(1) from exc

from parse_timeseries import resolve_sysbench_offset


ENV_LINE_RE = re.compile(r"^([A-Z_]+)=(.*)$")
CONF_LINE_RE = re.compile(r'^([A-Z_][A-Z0-9_]*)="(.*)"\s*$')
POLL_LINE_RE = re.compile(
    r"^(?P<ts>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z) poll "
    r"status=(?P<status>\S+) size=(?P<size>\S+) num_nodes=(?P<num_nodes>\d+) "
    r"storage_mib=(?P<storage_mib>\d+) elapsed=(?P<elapsed>\d+)s"
)
CONFIRMED_RE = re.compile(
    r"Cluster resize confirmed: status=(?P<status>\S+) size=(?P<size>\S+) "
    r"num_nodes=(?P<num_nodes>\d+) storage_mib=(?P<storage_mib>\d+) "
    r"poll_duration=(?P<poll_duration>\d+)s"
)
SECRET_KEYS = {"MYSQL_PASSWORD", "DO_API_TOKEN", "DIGITALOCEAN_ACCESS_TOKEN"}


@dataclass
class ClusterState:
    status: str
    size: str
    num_nodes: int
    storage_mib: int
    timestamp: str = ""

    def storage_gib(self) -> str:
        return f"{self.storage_mib / 1024:.0f} GiB"


@dataclass
class MetricRow:
    wall_clock_utc: str
    elapsed_sec: int
    phase: str
    threads: int
    tps: float
    qps: float
    qps_read: float
    qps_write: float
    qps_other: float
    lat_p95: float
    err_per_sec: float
    reconn_per_sec: float


@dataclass
class DowntimeEpisode:
    episode: int
    start_elapsed: int
    end_elapsed: int
    start_wall_utc: str
    end_wall_utc: str
    duration_sec: int
    phases: list[str]

    @property
    def phase_label(self) -> str:
        if len(self.phases) == 1:
            return self.phases[0].replace("_", " ")
        return " → ".join(p.replace("_", " ") for p in self.phases)


def parse_env_file(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.is_file():
        return values
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        match = ENV_LINE_RE.match(line.strip())
        if match:
            values[match.group(1)] = match.group(2)
    return values


def parse_benchmark_conf(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.is_file():
        return values
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        match = CONF_LINE_RE.match(stripped)
        if match:
            key, value = match.group(1), match.group(2)
            if key in SECRET_KEYS:
                value = "***"
            values[key] = value
            continue
        match = ENV_LINE_RE.match(stripped)
        if match:
            key, value = match.group(1), match.group(2)
            if key in SECRET_KEYS:
                value = "***"
            values[key] = value
    return values


def parse_scale_log(path: Path) -> tuple[ClusterState | None, ClusterState | None]:
    if not path.is_file():
        return None, None

    before: ClusterState | None = None
    after: ClusterState | None = None

    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        confirmed = CONFIRMED_RE.search(line)
        if confirmed:
            after = ClusterState(
                status=confirmed.group("status"),
                size=confirmed.group("size"),
                num_nodes=int(confirmed.group("num_nodes")),
                storage_mib=int(confirmed.group("storage_mib")),
            )
            continue

        poll = POLL_LINE_RE.match(line.strip())
        if poll and before is None:
            before = ClusterState(
                status=poll.group("status"),
                size=poll.group("size"),
                num_nodes=int(poll.group("num_nodes")),
                storage_mib=int(poll.group("storage_mib")),
                timestamp=poll.group("ts"),
            )

    return before, after


def load_metrics(path: Path) -> list[MetricRow]:
    if not path.is_file():
        return []

    rows: list[MetricRow] = []
    with path.open(encoding="utf-8", errors="replace", newline="") as handle:
        reader = csv.DictReader(handle)
        for raw in reader:
            rows.append(
                MetricRow(
                    wall_clock_utc=raw["wall_clock_utc"],
                    elapsed_sec=int(raw["elapsed_sec"]),
                    phase=raw["phase"],
                    threads=int(raw["threads"]),
                    tps=float(raw["tps"]),
                    qps=float(raw["qps"]),
                    qps_read=float(raw["qps_read"]),
                    qps_write=float(raw["qps_write"]),
                    qps_other=float(raw["qps_other"]),
                    lat_p95=float(raw["lat_p95"]),
                    err_per_sec=float(raw["err_per_sec"]),
                    reconn_per_sec=float(raw["reconn_per_sec"]),
                )
            )
    return rows


def fmt_duration(seconds: str | int | None) -> str:
    if seconds is None or seconds == "":
        return "N/A"
    total = int(seconds)
    minutes, secs = divmod(total, 60)
    if minutes:
        return f"{total}s ({minutes}m {secs}s)"
    return f"{total}s"


def tpcc_dataset_items(conf: dict[str, str]) -> list[tuple[str, str]]:
    scale = int(conf.get("TPCC_SCALE") or 10)
    tables = int(conf.get("TPCC_TABLES") or 10)
    size_gib = scale * tables * 0.1
    size_label = f"{size_gib:g} GiB"
    return [
        ("Database", conf.get("MYSQL_DB", "N/A")),
        ("TPCC_SCALE (warehouses)", str(scale)),
        ("TPCC_TABLES", str(tables)),
        ("Data size", f"{size_label} ({scale} × {tables} × 0.1 GiB)"),
    ]


def cluster_table_row(label: str, state: ClusterState | None) -> str:
    if state is None:
        return f"<tr><th>{html.escape(label)}</th><td colspan='4'>N/A</td></tr>"
    return (
        f"<tr><th>{html.escape(label)}</th>"
        f"<td>{html.escape(state.status)}</td>"
        f"<td><code>{html.escape(state.size)}</code></td>"
        f"<td>{state.num_nodes}</td>"
        f"<td>{html.escape(state.storage_gib())}</td></tr>"
    )


def render_kv_table(title: str, items: list[tuple[str, str]]) -> str:
  rows = "".join(
      f"<tr><th>{html.escape(k)}</th><td>{html.escape(v)}</td></tr>"
      for k, v in items
  )
  return f"""
  <section>
    <h2>{html.escape(title)}</h2>
    <table class="kv">
      <tbody>{rows}</tbody>
    </table>
  </section>
  """


PHASE_COLORS = {
    "pre_scaling": "#2ca02c",
    "during_scaling": "#ff7f0e",
    "post_scaling": "#1f77b4",
}


def add_phase_traces(fig, metrics: list[MetricRow], y_field: str, row: int, col: int) -> None:
    for phase, color in PHASE_COLORS.items():
        phase_rows = [m for m in metrics if m.phase == phase]
        if not phase_rows:
            continue
        fig.add_trace(
            go.Scatter(
                x=[m.elapsed_sec for m in phase_rows],
                y=[getattr(m, y_field) for m in phase_rows],
                mode="lines",
                name=phase.replace("_", " "),
                line=dict(color=color, width=1.5),
                legendgroup=phase,
                showlegend=(row == 1 and col == 1),
            ),
            row=row,
            col=col,
        )


def sysbench_scale_markers(
    timing: dict[str, str], run_dir: Path
) -> tuple[int | None, int | None]:
    """Map wall-clock scale elapsed times onto the sysbench x-axis."""
    offset = resolve_sysbench_offset(timing, run_dir / "tpcc_run.log")
    start = timing.get("SCALE_START_ELAPSED")
    complete = timing.get("SCALE_COMPLETE_ELAPSED")
    return (
        int(start) - offset if start else None,
        int(complete) - offset if complete else None,
    )


def add_scale_markers(
    fig,
    start: int | None,
    complete: int | None,
) -> None:
    if start is not None:
        fig.add_vline(
            x=start,
            line_dash="dash",
            line_color="#d62728",
            line_width=2,
            annotation_text="scale start",
            annotation_position="top left",
            row="all",
            col=1,
        )
    if complete is not None:
        fig.add_vline(
            x=complete,
            line_dash="dash",
            line_color="#9467bd",
            line_width=2,
            annotation_text="scale complete",
            annotation_position="top right",
            row="all",
            col=1,
        )


def build_metrics_figure(
    metrics: list[MetricRow], timing: dict[str, str], run_dir: Path
) -> go.Figure:
    fig = make_subplots(
        rows=4,
        cols=1,
        shared_xaxes=True,
        vertical_spacing=0.06,
        subplot_titles=("TPS", "QPS", "Latency p95 (ms)", "Errors & reconnects / sec"),
    )

    add_phase_traces(fig, metrics, "tps", row=1, col=1)
    add_phase_traces(fig, metrics, "qps", row=2, col=1)
    add_phase_traces(fig, metrics, "lat_p95", row=3, col=1)
    add_phase_traces(fig, metrics, "err_per_sec", row=4, col=1)
    add_phase_traces(fig, metrics, "reconn_per_sec", row=4, col=1)

    add_scale_markers(fig, *sysbench_scale_markers(timing, run_dir))

    fig.update_layout(
        height=1100,
        title="TPC-C metrics during scaling benchmark",
        hovermode="x unified",
        legend=dict(orientation="h", yanchor="bottom", y=1.02, x=0),
        margin=dict(t=80),
    )
    fig.update_xaxes(title_text="Elapsed (seconds)", row=4, col=1)
    return fig


def phase_summary(metrics: list[MetricRow]) -> list[tuple[str, str]]:
    summary: list[tuple[str, str]] = []
    for phase in ("pre_scaling", "during_scaling", "post_scaling"):
        rows = [m for m in metrics if m.phase == phase]
        if not rows:
            continue
        avg_tps = sum(m.tps for m in rows) / len(rows)
        max_err = max(m.err_per_sec for m in rows)
        avg_lat = sum(m.lat_p95 for m in rows) / len(rows)
        summary.append((f"{phase} samples", str(len(rows))))
        summary.append((f"{phase} avg TPS", f"{avg_tps:.2f}"))
        summary.append((f"{phase} avg p95 latency (ms)", f"{avg_lat:.2f}"))
        summary.append((f"{phase} max err/s", f"{max_err:.2f}"))
    return summary


def is_zero_tps(row: MetricRow) -> bool:
    return row.tps == 0.0


def detect_downtime_episodes(metrics: list[MetricRow]) -> list[DowntimeEpisode]:
    """Find consecutive 1-second windows where TPS is exactly zero."""
    episodes: list[DowntimeEpisode] = []
    start_idx: int | None = None

    for idx, row in enumerate(metrics):
        if is_zero_tps(row):
            if start_idx is None:
                start_idx = idx
            continue
        if start_idx is not None:
            episodes.append(_episode_from_range(metrics, start_idx, idx - 1, len(episodes) + 1))
            start_idx = None

    if start_idx is not None:
        episodes.append(_episode_from_range(metrics, start_idx, len(metrics) - 1, len(episodes) + 1))

    return episodes


def _episode_from_range(
    metrics: list[MetricRow],
    start_idx: int,
    end_idx: int,
    episode_num: int,
) -> DowntimeEpisode:
    start = metrics[start_idx]
    end = metrics[end_idx]
    phases: list[str] = []
    seen: set[str] = set()
    for row in metrics[start_idx : end_idx + 1]:
        if row.phase not in seen:
            phases.append(row.phase)
            seen.add(row.phase)
    duration = end.elapsed_sec - start.elapsed_sec + 1
    return DowntimeEpisode(
        episode=episode_num,
        start_elapsed=start.elapsed_sec,
        end_elapsed=end.elapsed_sec,
        start_wall_utc=start.wall_clock_utc,
        end_wall_utc=end.wall_clock_utc,
        duration_sec=duration,
        phases=phases,
    )


def downtime_seconds_by_phase(metrics: list[MetricRow]) -> dict[str, int]:
    totals = {phase: 0 for phase in ("pre_scaling", "during_scaling", "post_scaling")}
    for row in metrics:
        if is_zero_tps(row) and row.phase in totals:
            totals[row.phase] += 1
    return totals


def render_downtime_section(
    episodes: list[DowntimeEpisode],
    phase_totals: dict[str, int],
) -> str:
    total = sum(ep.duration_sec for ep in episodes)
    if not episodes:
        return """
  <section>
    <h2>Downtime (TPS = 0)</h2>
    <p><em>No zero-TPS intervals detected in metrics_timeseries.csv.</em></p>
  </section>
  """

    episode_rows = "".join(
        "<tr>"
        f"<td>{ep.episode}</td>"
        f"<td>{html.escape(ep.start_wall_utc)}</td>"
        f"<td>{html.escape(ep.end_wall_utc)}</td>"
        f"<td>{ep.start_elapsed}</td>"
        f"<td>{ep.end_elapsed}</td>"
        f"<td>{fmt_duration(ep.duration_sec)}</td>"
        f"<td>{html.escape(ep.phase_label)}</td>"
        "</tr>"
        for ep in episodes
    )

    phase_rows = "".join(
        f"<tr><th>{html.escape(phase.replace('_', ' '))}</th>"
        f"<td>{fmt_duration(phase_totals.get(phase, 0))}</td></tr>"
        for phase in ("pre_scaling", "during_scaling", "post_scaling")
        if phase_totals.get(phase, 0) > 0
    )

    return f"""
  <section>
    <h2>Downtime (TPS = 0)</h2>
    <p>Intervals where sysbench reported <code>tps: 0</code> for consecutive seconds.</p>
    <table class="kv">
      <thead>
        <tr>
          <th>#</th>
          <th>Started (UTC)</th>
          <th>Ended (UTC)</th>
          <th>Elapsed start (s)</th>
          <th>Elapsed end (s)</th>
          <th>Duration</th>
          <th>Phase</th>
        </tr>
      </thead>
      <tbody>{episode_rows}</tbody>
      <tfoot>
        <tr>
          <th colspan="5">Total downtime</th>
          <td colspan="2"><strong>{html.escape(fmt_duration(total))}</strong></td>
        </tr>
      </tfoot>
    </table>
    <h3>Downtime by phase</h3>
    <table class="kv">
      <thead><tr><th>Phase</th><th>Duration</th></tr></thead>
      <tbody>{phase_rows}</tbody>
      <tfoot>
        <tr><th>Total</th><td><strong>{html.escape(fmt_duration(total))}</strong></td></tr>
      </tfoot>
    </table>
  </section>
  """


def generate_report(run_dir: Path, output_path: Path | None = None) -> Path:
    run_dir = run_dir.resolve()
    if not run_dir.is_dir():
        raise FileNotFoundError(f"Run directory not found: {run_dir}")

    timing = parse_env_file(run_dir / "scale_timing.env")
    conf = parse_benchmark_conf(run_dir / "benchmark.conf")
    before, after = parse_scale_log(run_dir / "scale.log")
    metrics = load_metrics(run_dir / "metrics_timeseries.csv")
    downtime_episodes = detect_downtime_episodes(metrics)
    downtime_by_phase = downtime_seconds_by_phase(metrics)

    if output_path is None:
        output_path = run_dir / "scaling_report.html"
    else:
        output_path = output_path.resolve()

    generated_at = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    success = timing.get("SCALE_SUCCESS", "unknown")

    timing_items = [
        ("Scale trigger delay", fmt_duration(conf.get("SCALE_TRIGGER_DELAY"))),
        ("Scale started at (elapsed)", fmt_duration(timing.get("SCALE_START_ELAPSED"))),
        ("Scale completed at (elapsed)", fmt_duration(timing.get("SCALE_COMPLETE_ELAPSED"))),
        ("Resize duration", fmt_duration(timing.get("SCALE_DURATION_SEC"))),
        ("Poll duration", fmt_duration(timing.get("SCALE_POLL_DURATION_SEC"))),
        ("Scale success", success),
        ("Trigger RC", timing.get("SCALE_TRIGGER_RC", "N/A")),
        ("Poll RC", timing.get("SCALE_POLL_RC", "N/A")),
    ]

    config_items = [
        ("Run directory", str(run_dir)),
        ("Engine", conf.get("ENGINE", timing.get("ENGINE", "N/A"))),
        ("Cluster ID", conf.get("CLUSTER_ID", "N/A")),
        ("MySQL host", conf.get("MYSQL_HOST", "N/A")),
        ("Database", conf.get("MYSQL_DB", "N/A")),
        ("Target size", conf.get("SCALE_TARGET_SIZE", timing.get("SCALE_TARGET_SIZE", "N/A"))),
        ("Target num nodes", conf.get("SCALE_NUM_NODES", "unchanged")),
        ("TPCC threads", conf.get("TPCC_THREADS", "N/A")),
        ("TPCC max time", fmt_duration(conf.get("TPCC_MAX_TIME"))),
        ("Metric samples", str(len(metrics))),
    ]

    cluster_html = f"""
    <section>
      <h2>Cluster state</h2>
      <table class="kv">
        <thead>
          <tr><th>When</th><th>Status</th><th>Size slug</th><th>Nodes</th><th>Storage</th></tr>
        </thead>
        <tbody>
          {cluster_table_row("Before scaling", before)}
          {cluster_table_row("After scaling", after)}
        </tbody>
      </table>
    </section>
    """

    figure_html = ""
    if metrics:
        fig = build_metrics_figure(metrics, timing, run_dir)
        figure_html = fig.to_html(full_html=False, include_plotlyjs=False, div_id="metrics-chart")
    else:
        figure_html = "<p><em>No metrics_timeseries.csv data found.</em></p>"

    page = f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Scaling benchmark report — {html.escape(run_dir.name)}</title>
  <script src="https://cdn.plot.ly/plotly-2.35.2.min.js"></script>
  <style>
    body {{
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      margin: 0;
      padding: 24px 32px 48px;
      background: #f6f8fa;
      color: #1f2328;
    }}
    h1 {{ margin-top: 0; }}
    h2 {{ margin-top: 2rem; border-bottom: 1px solid #d0d7de; padding-bottom: 0.3rem; }}
    .meta {{ color: #57606a; margin-bottom: 1.5rem; }}
    .badge {{
      display: inline-block;
      padding: 0.15rem 0.55rem;
      border-radius: 999px;
      font-size: 0.85rem;
      font-weight: 600;
      background: {"#dafbe1" if success == "1" else "#ffebe9"};
      color: {"#116329" if success == "1" else "#cf222e"};
    }}
    table.kv {{
      width: 100%;
      border-collapse: collapse;
      background: #fff;
      border: 1px solid #d0d7de;
      border-radius: 8px;
      overflow: hidden;
    }}
    table.kv th, table.kv td {{
      padding: 0.55rem 0.75rem;
      border-bottom: 1px solid #eaeef2;
      text-align: left;
      vertical-align: top;
    }}
    table.kv th {{ width: 28%; background: #f6f8fa; }}
    table.kv tfoot th, table.kv tfoot td {{ background: #f6f8fa; font-weight: 600; }}
    section {{ margin-bottom: 1.5rem; }}
    .chart-box {{
      background: #fff;
      border: 1px solid #d0d7de;
      border-radius: 8px;
      padding: 12px;
    }}
    code {{ font-size: 0.92em; }}
  </style>
</head>
<body>
  <h1>Scaling benchmark report</h1>
  <p class="meta">
    <strong>{html.escape(run_dir.name)}</strong>
    &nbsp;·&nbsp; generated {html.escape(generated_at)}
    &nbsp;·&nbsp; <span class="badge">SCALE_SUCCESS={html.escape(success)}</span>
  </p>

  {cluster_html}
  {render_kv_table("TPC-C dataset", tpcc_dataset_items(conf))}
  {render_kv_table("Scaling timing", timing_items)}
  {render_kv_table("Run configuration", config_items)}
  {render_kv_table("Phase summary", phase_summary(metrics))}
  {render_downtime_section(downtime_episodes, downtime_by_phase)}

  <section>
    <h2>Metrics</h2>
    <div class="chart-box">{figure_html}</div>
  </section>
</body>
</html>
"""

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(page, encoding="utf-8")
    return output_path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "run_dir",
        type=Path,
        help="Path to run directory (e.g. scaling-benchmarking/results/run_...)",
    )
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        default=None,
        help="Output HTML path (default: <run_dir>/scaling_report.html)",
    )
    args = parser.parse_args()

    try:
        out = generate_report(args.run_dir, args.output)
    except FileNotFoundError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    print(f"Report written: {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
