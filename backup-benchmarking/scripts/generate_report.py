#!/usr/bin/env python3
"""
Generate an HTML report for the backup benchmark run.
Shows sysbench metrics with color-coded backup-in-progress regions,
plus per-backup summary statistics.

Usage:
  python3 generate_report.py <run_dir>
  python3 generate_report.py <run_dir> -o /path/to/report.html
"""

from __future__ import annotations

import argparse
import csv
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path


def parse_conf(path: Path) -> dict[str, str]:
    """Parse shell-style benchmark.conf into a dict."""
    conf: dict[str, str] = {}
    if not path.is_file():
        return conf
    secret_keys = {"MYSQL_PASSWORD", "DO_API_TOKEN", "DIGITALOCEAN_ACCESS_TOKEN"}
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        m = re.match(r'^([A-Z_][A-Z0-9_]*)="?([^"]*)"?$', line)
        if m:
            key, value = m.group(1), m.group(2)
            if key in secret_keys:
                value = "***"
            conf[key] = value
    return conf


def load_timing(path: Path) -> dict[str, str]:
    """Load run_timing.env."""
    values: dict[str, str] = {}
    if not path.is_file():
        return values
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        m = re.match(r"^([A-Z_]+)=(.*)$", line)
        if m:
            values[m.group(1)] = m.group(2)
    return values


def load_csv_data(path: Path) -> list[dict]:
    """Load the benchmark CSV into a list of dicts."""
    rows = []
    with open(path) as f:
        reader = csv.DictReader(f)
        for row in reader:
            row["epoch"] = int(row["epoch"])
            row["interval_s"] = int(row["interval_s"])
            row["threads"] = int(row["threads"])
            row["tps"] = float(row["tps"])
            row["qps"] = float(row["qps"])
            row["reads_ps"] = float(row["reads_ps"])
            row["writes_ps"] = float(row["writes_ps"])
            row["other_ps"] = float(row["other_ps"])
            row["lat_p95_ms"] = float(row["lat_p95_ms"])
            row["err_s"] = float(row["err_s"])
            row["reconn_s"] = float(row["reconn_s"])
            row["backup_in_progress"] = int(row["backup_in_progress"])
            rows.append(row)
    return rows


def load_backups_detected(path: Path) -> list[dict]:
    """Load backups_detected.json."""
    if not path.is_file():
        return []
    with open(path) as f:
        data = json.load(f)
    return data.get("backups", [])


def compute_backup_summaries(rows: list[dict]) -> list[dict]:
    """Compute per-backup summary statistics."""
    backup_groups: dict[str, list[dict]] = {}
    for row in rows:
        name = row["backup_name"]
        if not name:
            continue
        if name not in backup_groups:
            backup_groups[name] = []
        backup_groups[name].append(row)

    summaries = []
    for name, group in sorted(backup_groups.items()):
        n = len(group)
        avg_tps = sum(r["tps"] for r in group) / n
        avg_qps = sum(r["qps"] for r in group) / n
        avg_lat = sum(r["lat_p95_ms"] for r in group) / n
        max_lat = max(r["lat_p95_ms"] for r in group)
        min_tps = min(r["tps"] for r in group)
        max_tps = max(r["tps"] for r in group)
        total_err = sum(r["err_s"] for r in group)
        start_ts = group[0]["timestamp"]
        end_ts = group[-1]["timestamp"]
        summaries.append({
            "name": name,
            "duration_s": n,
            "start": start_ts,
            "end": end_ts,
            "avg_tps": avg_tps,
            "min_tps": min_tps,
            "max_tps": max_tps,
            "avg_qps": avg_qps,
            "avg_lat_p95": avg_lat,
            "max_lat_p95": max_lat,
            "total_errors": total_err,
        })
    return summaries


def compute_overall_summary(rows: list[dict]) -> dict:
    """Compute overall stats split by backup/no-backup."""
    backup_rows = [r for r in rows if r["backup_in_progress"] == 1]
    normal_rows = [r for r in rows if r["backup_in_progress"] == 0]

    def stats(subset):
        if not subset:
            return None
        n = len(subset)
        return {
            "samples": n,
            "avg_tps": sum(r["tps"] for r in subset) / n,
            "avg_qps": sum(r["qps"] for r in subset) / n,
            "avg_lat_p95": sum(r["lat_p95_ms"] for r in subset) / n,
            "max_lat_p95": max(r["lat_p95_ms"] for r in subset),
            "min_tps": min(r["tps"] for r in subset),
            "max_err_s": max(r["err_s"] for r in subset),
        }

    return {
        "overall": stats(rows),
        "during_backup": stats(backup_rows),
        "no_backup": stats(normal_rows),
    }


def build_plotly_json(rows: list[dict]) -> dict:
    """Build Plotly data for the time-series chart."""
    backup_x = []
    backup_tps = []
    backup_qps = []
    backup_lat = []
    backup_err = []

    normal_x = []
    normal_tps = []
    normal_qps = []
    normal_lat = []
    normal_err = []

    for r in rows:
        x_val = r["interval_s"]
        if r["backup_in_progress"]:
            backup_x.append(x_val)
            backup_tps.append(r["tps"])
            backup_qps.append(r["qps"])
            backup_lat.append(r["lat_p95_ms"])
            backup_err.append(r["err_s"])
        else:
            normal_x.append(x_val)
            normal_tps.append(r["tps"])
            normal_qps.append(r["qps"])
            normal_lat.append(r["lat_p95_ms"])
            normal_err.append(r["err_s"])

    # Build backup region shapes for highlighting
    shapes = []
    in_backup = False
    region_start = None
    for r in rows:
        if r["backup_in_progress"] and not in_backup:
            region_start = r["interval_s"]
            in_backup = True
        elif not r["backup_in_progress"] and in_backup:
            shapes.append({"x0": region_start, "x1": r["interval_s"]})
            in_backup = False
    if in_backup:
        shapes.append({"x0": region_start, "x1": rows[-1]["interval_s"]})

    return {
        "normal_x": normal_x,
        "normal_tps": normal_tps,
        "normal_qps": normal_qps,
        "normal_lat": normal_lat,
        "normal_err": normal_err,
        "backup_x": backup_x,
        "backup_tps": backup_tps,
        "backup_qps": backup_qps,
        "backup_lat": backup_lat,
        "backup_err": backup_err,
        "shapes": shapes,
    }


def fmt_duration(seconds) -> str:
    if seconds is None or seconds == "" or seconds == "0":
        return "N/A"
    total = int(seconds)
    hours, remainder = divmod(total, 3600)
    minutes, secs = divmod(remainder, 60)
    if hours:
        return f"{total}s ({hours}h {minutes}m {secs}s)"
    if minutes:
        return f"{total}s ({minutes}m {secs}s)"
    return f"{total}s"


def generate_html(
    conf: dict[str, str],
    timing: dict[str, str],
    rows: list[dict],
    backup_summaries: list[dict],
    overall_summary: dict,
    plot_data: dict,
    backups_detected: list[dict],
) -> str:
    """Generate the full HTML report."""
    data_size_gib = int(conf.get("TPCC_SCALE", "10")) * int(conf.get("TPCC_TABLES", "10")) * 0.1
    generated_at = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")

    cluster_slug = conf.get("CLUSTER_SLUG", timing.get("CLUSTER_SLUG", "unknown"))
    cluster_num_nodes = conf.get("CLUSTER_NUM_NODES", timing.get("CLUSTER_NUM_NODES", "1"))
    cluster_storage = conf.get("CLUSTER_STORAGE_SIZE_GIB", timing.get("CLUSTER_STORAGE_SIZE_GIB", "0"))

    # Per-backup summary table rows
    backup_rows_html = ""
    for s in backup_summaries:
        backup_rows_html += (
            f'<tr><td><code>{s["name"]}</code></td>'
            f'<td>{s["start"]}</td><td>{s["end"]}</td>'
            f'<td>{s["duration_s"]}s</td>'
            f'<td>{s["avg_tps"]:.2f}</td><td>{s["min_tps"]:.2f}</td><td>{s["max_tps"]:.2f}</td>'
            f'<td>{s["avg_qps"]:.2f}</td>'
            f'<td>{s["avg_lat_p95"]:.2f}</td><td>{s["max_lat_p95"]:.2f}</td>'
            f'<td>{s["total_errors"]:.0f}</td></tr>\n'
        )

    avg_backup_duration = (
        sum(s["duration_s"] for s in backup_summaries) / len(backup_summaries)
        if backup_summaries else 0
    )

    # Backup details table
    backup_details_html = ""
    for b in backups_detected:
        duration = b["end_epoch"] - b["start_epoch"]
        start_utc = datetime.fromtimestamp(b["start_epoch"], tz=timezone.utc).strftime(
            "%Y-%m-%d %H:%M:%S"
        )
        end_utc = datetime.fromtimestamp(b["end_epoch"], tz=timezone.utc).strftime(
            "%Y-%m-%d %H:%M:%S"
        )
        backup_details_html += (
            f'<tr><td><code>{b["name"]}</code></td>'
            f'<td>{start_utc}</td><td>{end_utc}</td>'
            f'<td>{fmt_duration(duration)}</td>'
            f'<td>{b.get("backup_type", "?")}</td>'
            f'<td>{"yes" if b.get("incremental") else "no"}</td>'
            f'<td>{b.get("status", "?")}</td></tr>\n'
        )

    # Overall comparison
    ov = overall_summary
    no_bk = ov["no_backup"]
    dur_bk = ov["during_backup"]
    all_ov = ov["overall"]

    # Compute impact percentages
    tps_impact = ""
    qps_impact = ""
    lat_impact = ""
    if no_bk and dur_bk:
        tps_pct = ((dur_bk["avg_tps"] - no_bk["avg_tps"]) / no_bk["avg_tps"]) * 100
        tps_direction = "decrease" if tps_pct < 0 else "increase"
        tps_impact = f'{abs(tps_pct):.1f}% {tps_direction}'

        qps_pct = ((dur_bk["avg_qps"] - no_bk["avg_qps"]) / no_bk["avg_qps"]) * 100
        qps_direction = "decrease" if qps_pct < 0 else "increase"
        qps_impact = f'{abs(qps_pct):.1f}% {qps_direction}'

        lat_pct = ((dur_bk["avg_lat_p95"] - no_bk["avg_lat_p95"]) / no_bk["avg_lat_p95"]) * 100
        lat_direction = "increase" if lat_pct > 0 else "decrease"
        lat_impact = f'{abs(lat_pct):.1f}% {lat_direction}'

    shapes_js = json.dumps(plot_data["shapes"])

    # Handle missing stats gracefully
    def stat_val(d, key, fmt=".2f"):
        if d is None:
            return "N/A"
        return f"{d[key]:{fmt}}"

    def stat_int(d, key):
        if d is None:
            return "N/A"
        return str(d[key])

    html = f'''<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Backup impact benchmark — {cluster_slug}</title>
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
      background: #dafbe1;
      color: #116329;
    }}
    .badge-warn {{
      background: #fff8c5;
      color: #6a5d00;
    }}
    .badge-danger {{
      background: #ffebe9;
      color: #cf222e;
    }}
    table.kv {{
      width: 100%;
      border-collapse: collapse;
      background: #fff;
      border: 1px solid #d0d7de;
      border-radius: 8px;
      overflow: hidden;
      margin-bottom: 1rem;
    }}
    table.kv th, table.kv td {{
      padding: 0.55rem 0.75rem;
      border-bottom: 1px solid #eaeef2;
      text-align: left;
      vertical-align: top;
    }}
    table.kv th {{ width: 28%; background: #f6f8fa; }}
    table.kv thead th {{ background: #f0f3f6; font-weight: 600; width: auto; }}
    table.kv tfoot th, table.kv tfoot td {{ background: #f6f8fa; font-weight: 600; }}
    section {{ margin-bottom: 1.5rem; }}
    .chart-box {{
      background: #fff;
      border: 1px solid #d0d7de;
      border-radius: 8px;
      padding: 12px;
      margin-bottom: 1rem;
    }}
    code {{ font-size: 0.92em; }}
    .legend-inline {{
      display: flex; gap: 1.5rem; margin: 0.5rem 0 1rem;
      font-size: 0.9rem;
    }}
    .legend-inline span {{
      display: flex; align-items: center; gap: 0.4rem;
    }}
    .legend-dot {{
      width: 12px; height: 12px; border-radius: 50%; display: inline-block;
    }}
  </style>
</head>
<body>
  <h1>Backup Impact Benchmark Report</h1>
  <p class="meta">
    Cluster: <code>{cluster_slug}</code>
    &nbsp;&middot;&nbsp; Nodes: {cluster_num_nodes}
    &nbsp;&middot;&nbsp; Storage: {cluster_storage} GiB
    &nbsp;&middot;&nbsp; Engine: <code>{conf.get("ENGINE", "advanced")}</code>
    &nbsp;&middot;&nbsp; Generated {generated_at}
    &nbsp;&middot;&nbsp; <span class="badge">{len(backup_summaries)} backups during run</span>
    {f'&nbsp;&middot;&nbsp; <span class="badge badge-warn">TPS impact: {tps_impact}</span>' if tps_impact else ''}
    {f'&nbsp;&middot;&nbsp; <span class="badge badge-warn">Latency impact: {lat_impact}</span>' if lat_impact else ''}
  </p>

  <section>
    <h2>Run configuration</h2>
    <table class="kv">
      <tbody>
        <tr><th>Engine</th><td>{conf.get("ENGINE", "advanced")}</td></tr>
        <tr><th>Cluster ID</th><td><code>{conf.get("CLUSTER_ID", "")}</code></td></tr>
        <tr><th>Cluster slug</th><td><code>{cluster_slug}</code></td></tr>
        <tr><th>Num nodes</th><td>{cluster_num_nodes}</td></tr>
        <tr><th>Storage</th><td>{cluster_storage} GiB</td></tr>
        <tr><th>MySQL host</th><td><code>{conf.get("MYSQL_HOST", "")}</code></td></tr>
        <tr><th>Database</th><td>{conf.get("MYSQL_DB", "")}</td></tr>
        <tr><th>TPCC threads</th><td>{conf.get("TPCC_THREADS", "")}</td></tr>
        <tr><th>TPCC max time</th><td>{fmt_duration(conf.get("TPCC_MAX_TIME", ""))}</td></tr>
        <tr><th>Report interval</th><td>{conf.get("TPCC_REPORT_INTERVAL", "")}s</td></tr>
        <tr><th>Backup poll interval</th><td>{conf.get("BACKUP_POLL_INTERVAL_SEC", "300")}s</td></tr>
        <tr><th>Run duration</th><td>{fmt_duration(timing.get("RUN_DURATION_SEC", ""))}</td></tr>
        <tr><th>Metric samples</th><td>{len(rows)}</td></tr>
      </tbody>
    </table>
  </section>

  <section>
    <h2>TPC-C dataset</h2>
    <table class="kv">
      <tbody>
        <tr><th>Database</th><td>{conf.get("MYSQL_DB", "")}</td></tr>
        <tr><th>TPCC_SCALE (warehouses)</th><td>{conf.get("TPCC_SCALE", "")}</td></tr>
        <tr><th>TPCC_TABLES</th><td>{conf.get("TPCC_TABLES", "")}</td></tr>
        <tr><th>Data size</th><td>{data_size_gib:.0f} GiB ({conf.get("TPCC_SCALE", "")} &times; {conf.get("TPCC_TABLES", "")} &times; 0.1 GiB)</td></tr>
      </tbody>
    </table>
  </section>

  <section>
    <h2>Backups detected during run</h2>
    <table class="kv">
      <thead>
        <tr>
          <th>Backup name</th><th>Started (UTC)</th><th>Completed (UTC)</th>
          <th>Duration</th><th>Type</th><th>Incremental</th><th>Status</th>
        </tr>
      </thead>
      <tbody>
        {backup_details_html if backup_details_html else '<tr><td colspan="7"><em>No backups detected during the run</em></td></tr>'}
      </tbody>
    </table>
  </section>

  <section>
    <h2>Overall summary &mdash; Backup vs No-Backup</h2>
    <table class="kv">
      <thead>
        <tr><th>Metric</th><th>No Backup</th><th>During Backup</th><th>Overall</th></tr>
      </thead>
      <tbody>
        <tr><th>Samples (seconds)</th><td>{stat_int(no_bk, "samples")}</td><td>{stat_int(dur_bk, "samples")}</td><td>{stat_int(all_ov, "samples")}</td></tr>
        <tr><th>Avg TPS</th><td>{stat_val(no_bk, "avg_tps")}</td><td>{stat_val(dur_bk, "avg_tps")}</td><td>{stat_val(all_ov, "avg_tps")}</td></tr>
        <tr><th>Avg QPS</th><td>{stat_val(no_bk, "avg_qps")}</td><td>{stat_val(dur_bk, "avg_qps")}</td><td>{stat_val(all_ov, "avg_qps")}</td></tr>
        <tr><th>Avg p95 latency (ms)</th><td>{stat_val(no_bk, "avg_lat_p95")}</td><td>{stat_val(dur_bk, "avg_lat_p95")}</td><td>{stat_val(all_ov, "avg_lat_p95")}</td></tr>
        <tr><th>Max p95 latency (ms)</th><td>{stat_val(no_bk, "max_lat_p95")}</td><td>{stat_val(dur_bk, "max_lat_p95")}</td><td>{stat_val(all_ov, "max_lat_p95")}</td></tr>
        <tr><th>Min TPS</th><td>{stat_val(no_bk, "min_tps")}</td><td>{stat_val(dur_bk, "min_tps")}</td><td>{stat_val(all_ov, "min_tps")}</td></tr>
        <tr><th>Max errors/s</th><td>{stat_val(no_bk, "max_err_s", ".0f")}</td><td>{stat_val(dur_bk, "max_err_s", ".0f")}</td><td>{stat_val(all_ov, "max_err_s", ".0f")}</td></tr>
      </tbody>
    </table>
    {f'<p><strong>Impact during backup:</strong> TPS {tps_impact}, QPS {qps_impact}, p95 latency {lat_impact}</p>' if tps_impact else ''}
  </section>

  <section>
    <h2>Per-backup performance summary</h2>
    <table class="kv">
      <thead>
        <tr>
          <th>Backup name</th><th>Start (UTC)</th><th>End (UTC)</th><th>Duration</th>
          <th>Avg TPS</th><th>Min TPS</th><th>Max TPS</th><th>Avg QPS</th>
          <th>Avg p95 lat (ms)</th><th>Max p95 lat (ms)</th><th>Errors</th>
        </tr>
      </thead>
      <tbody>
        {backup_rows_html if backup_rows_html else '<tr><td colspan="11"><em>No backup windows overlapping with metrics</em></td></tr>'}
      </tbody>
      {f'<tfoot><tr><th colspan="3">Average backup duration</th><td colspan="8"><strong>{avg_backup_duration:.1f}s</strong></td></tr></tfoot>' if backup_summaries else ''}
    </table>
  </section>

  <section>
    <h2>Metrics &mdash; Time Series</h2>
    <div class="legend-inline">
      <span><span class="legend-dot" style="background:#2ca02c"></span> No backup</span>
      <span><span class="legend-dot" style="background:#d62728"></span> During backup</span>
      <span><span class="legend-dot" style="background:rgba(255,200,200,0.3); border:1px solid #d62728"></span> Backup window</span>
    </div>

    <div class="chart-box"><div id="tps-chart" style="height:320px; width:100%;"></div></div>
    <div class="chart-box"><div id="qps-chart" style="height:320px; width:100%;"></div></div>
    <div class="chart-box"><div id="lat-chart" style="height:320px; width:100%;"></div></div>
    <div class="chart-box"><div id="err-chart" style="height:320px; width:100%;"></div></div>
  </section>

  <script>
    const normal_x = {json.dumps(plot_data["normal_x"])};
    const backup_x = {json.dumps(plot_data["backup_x"])};
    const normal_tps = {json.dumps(plot_data["normal_tps"])};
    const backup_tps = {json.dumps(plot_data["backup_tps"])};
    const normal_qps = {json.dumps(plot_data["normal_qps"])};
    const backup_qps = {json.dumps(plot_data["backup_qps"])};
    const normal_lat = {json.dumps(plot_data["normal_lat"])};
    const backup_lat = {json.dumps(plot_data["backup_lat"])};
    const normal_err = {json.dumps(plot_data["normal_err"])};
    const backup_err = {json.dumps(plot_data["backup_err"])};
    const backupShapes = {shapes_js};

    function makeShapes() {{
      return backupShapes.map(s => ({{
        type: 'rect', xref: 'x', yref: 'paper',
        x0: s.x0, x1: s.x1, y0: 0, y1: 1,
        fillcolor: 'rgba(214,39,40,0.08)',
        line: {{ color: 'rgba(214,39,40,0.3)', width: 1 }}
      }}));
    }}

    function makeLayout(title, yTitle) {{
      return {{
        title: {{ text: title, font: {{ size: 14 }} }},
        xaxis: {{ title: 'Elapsed time (s)' }},
        yaxis: {{ title: yTitle }},
        shapes: makeShapes(),
        margin: {{ t: 40, b: 50, l: 60, r: 20 }},
        legend: {{ orientation: 'h', y: -0.2 }},
        hovermode: 'x unified',
      }};
    }}

    const cfg = {{ responsive: true, displayModeBar: false }};

    Plotly.newPlot('tps-chart', [
      {{ x: normal_x, y: normal_tps, mode: 'lines', name: 'No backup', line: {{ color: '#2ca02c', width: 1 }} }},
      {{ x: backup_x, y: backup_tps, mode: 'lines', name: 'During backup', line: {{ color: '#d62728', width: 1.5 }} }},
    ], makeLayout('Transactions per Second (TPS)', 'TPS'), cfg);

    Plotly.newPlot('qps-chart', [
      {{ x: normal_x, y: normal_qps, mode: 'lines', name: 'No backup', line: {{ color: '#2ca02c', width: 1 }} }},
      {{ x: backup_x, y: backup_qps, mode: 'lines', name: 'During backup', line: {{ color: '#d62728', width: 1.5 }} }},
    ], makeLayout('Queries per Second (QPS)', 'QPS'), cfg);

    Plotly.newPlot('lat-chart', [
      {{ x: normal_x, y: normal_lat, mode: 'lines', name: 'No backup', line: {{ color: '#2ca02c', width: 1 }} }},
      {{ x: backup_x, y: backup_lat, mode: 'lines', name: 'During backup', line: {{ color: '#d62728', width: 1.5 }} }},
    ], makeLayout('p95 Latency (ms)', 'Latency (ms)'), cfg);

    Plotly.newPlot('err-chart', [
      {{ x: normal_x, y: normal_err, mode: 'lines', name: 'No backup', line: {{ color: '#2ca02c', width: 1 }} }},
      {{ x: backup_x, y: backup_err, mode: 'lines', name: 'During backup', line: {{ color: '#d62728', width: 1.5 }} }},
    ], makeLayout('Errors per Second', 'Errors/s'), cfg);
  </script>
</body>
</html>'''
    return html


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "run_dir",
        type=Path,
        help="Path to run directory",
    )
    parser.add_argument(
        "-o", "--output",
        type=Path,
        default=None,
        help="Output HTML path (default: <run_dir>/backup_benchmark_report.html)",
    )
    args = parser.parse_args()

    run_dir = args.run_dir.resolve()
    if not run_dir.is_dir():
        print(f"ERROR: run directory not found: {run_dir}", file=sys.stderr)
        return 1

    conf = parse_conf(run_dir / "benchmark.conf")
    timing = load_timing(run_dir / "run_timing.env")

    csv_path = run_dir / "benchmark_with_backup_status.csv"
    if not csv_path.is_file():
        print(f"ERROR: CSV not found: {csv_path}", file=sys.stderr)
        print("Run parse_results.py first.", file=sys.stderr)
        return 1

    rows = load_csv_data(csv_path)
    backups_detected = load_backups_detected(run_dir / "backups_detected.json")
    backup_summaries = compute_backup_summaries(rows)
    overall_summary = compute_overall_summary(rows)
    plot_data = build_plotly_json(rows)

    html = generate_html(
        conf, timing, rows, backup_summaries, overall_summary, plot_data, backups_detected
    )

    output_path = args.output or (run_dir / "backup_benchmark_report.html")
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(html, encoding="utf-8")

    print(f"Report generated: {output_path}")
    print(f"  {len(rows)} metric samples")
    print(f"  {len(backup_summaries)} backup windows identified")
    print(f"  {len(backups_detected)} backups detected during run")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
