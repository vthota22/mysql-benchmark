#!/usr/bin/env python3
"""Parse sidecar memory CSV and produce a summary table.

Usage:
    python3 scripts/build_sidecar_report.py logs/sidecar_memory.csv

Input CSV columns: timestamp,pod,container,memory_bytes,phase
Output: per-container peak/avg memory by phase, printed to stdout and
        written as HTML to logs/sidecar_report.html.
"""
import csv
import sys
from collections import defaultdict
from pathlib import Path

PHASE_ORDER = [
    "baseline",
    "prepare",
    "load_50tps",
    "load_100tps",
    "load_200tps",
    "load_300tps",
]

SIDECAR_CONTAINERS = ["mysqld-exporter", "slow-log-tailer", "do-agent", "xtrabackup", "mysql"]


def mi(b: int) -> str:
    if b < 0:
        return "N/A"
    return f"{b / (1024 * 1024):.1f}"


def parse_csv(path: str):
    """Return {(container, phase): [memory_bytes, ...]}."""
    data = defaultdict(list)
    with open(path) as f:
        reader = csv.DictReader(f)
        for row in reader:
            container = row["container"]
            phase = row["phase"]
            try:
                mem = int(row["memory_bytes"])
            except (ValueError, KeyError):
                continue
            if mem < 0:
                continue
            data[(container, phase)].append(mem)
    return data


def build_table(data):
    """Return list of dicts for the summary table."""
    rows = []
    for container in SIDECAR_CONTAINERS:
        row = {"container": container}
        for phase in PHASE_ORDER:
            samples = data.get((container, phase), [])
            if samples:
                row[f"{phase}_avg"] = sum(samples) // len(samples)
                row[f"{phase}_peak"] = max(samples)
                row[f"{phase}_min"] = min(samples)
                row[f"{phase}_count"] = len(samples)
            else:
                row[f"{phase}_avg"] = -1
                row[f"{phase}_peak"] = -1
                row[f"{phase}_min"] = -1
                row[f"{phase}_count"] = 0
        rows.append(row)
    return rows


LIMITS = {
    "mysqld-exporter": 256 * 1024 * 1024,
    "slow-log-tailer": 32 * 1024 * 1024,
    "do-agent": 192 * 1024 * 1024,
    "xtrabackup": 256 * 1024 * 1024,
    "mysql": 13926 * 1024 * 1024,
}


def print_text_report(rows):
    phases = PHASE_ORDER
    hdr = f"{'Container':<20}"
    for p in phases:
        hdr += f" | {'Peak ' + p:>22}"
    print(hdr)
    print("-" * len(hdr))

    for r in rows:
        line = f"{r['container']:<20}"
        for p in phases:
            peak = r.get(f"{p}_peak", -1)
            limit = LIMITS.get(r["container"], 0)
            pct = ""
            if peak > 0 and limit > 0:
                pct = f" ({100 * peak / limit:.0f}%)"
            line += f" | {mi(peak) + ' Mi' + pct:>22}"
        print(line)

    print()
    print("Limits: mysqld-exporter=256Mi, slow-log-tailer=32Mi, do-agent=192Mi, mysql=13926Mi")
    print()

    for r in rows:
        c = r["container"]
        limit = LIMITS.get(c, 0)
        if limit <= 0:
            continue
        worst_peak = max(r.get(f"{p}_peak", 0) for p in phases)
        if worst_peak <= 0:
            continue
        pct = 100 * worst_peak / limit
        status = "OK" if pct < 80 else ("WARNING" if pct < 95 else "CRITICAL")
        print(f"  {c}: peak {mi(worst_peak)} Mi / {mi(limit)} Mi limit = {pct:.1f}% [{status}]")


def build_html(rows, out_path):
    phases = PHASE_ORDER
    html = [
        "<!DOCTYPE html><html><head><meta charset='utf-8'>",
        "<title>Sidecar Memory Report</title>",
        "<style>",
        "body{font-family:sans-serif;margin:2em}",
        "table{border-collapse:collapse;width:100%}",
        "th,td{border:1px solid #ccc;padding:8px 12px;text-align:right}",
        "th{background:#f5f5f5}",
        "td:first-child,th:first-child{text-align:left}",
        ".warn{background:#fff3cd}.crit{background:#f8d7da}.ok{background:#d4edda}",
        "</style></head><body>",
        "<h1>Sidecar Memory Profiling Report</h1>",
        "<h2>Peak Memory by Phase (MiB)</h2>",
        "<table><tr><th>Container</th><th>Limit</th>",
    ]
    for p in phases:
        html.append(f"<th>{p}</th>")
    html.append("<th>Max %</th></tr>")

    for r in rows:
        c = r["container"]
        limit = LIMITS.get(c, 0)
        html.append(f"<tr><td>{c}</td><td>{mi(limit)} Mi</td>")
        worst_peak = 0
        for p in phases:
            peak = r.get(f"{p}_peak", -1)
            if peak > worst_peak:
                worst_peak = peak
            cls = ""
            if peak > 0 and limit > 0:
                pct = 100 * peak / limit
                if pct >= 95:
                    cls = " class='crit'"
                elif pct >= 80:
                    cls = " class='warn'"
                else:
                    cls = " class='ok'"
            html.append(f"<td{cls}>{mi(peak)}</td>")
        pct_max = 100 * worst_peak / limit if limit > 0 and worst_peak > 0 else 0
        cls = "ok" if pct_max < 80 else ("warn" if pct_max < 95 else "crit")
        html.append(f"<td class='{cls}'>{pct_max:.1f}%</td></tr>")

    html.append("</table>")

    html.append("<h2>Average Memory by Phase (MiB)</h2>")
    html.append("<table><tr><th>Container</th>")
    for p in phases:
        html.append(f"<th>{p}</th>")
    html.append("</tr>")
    for r in rows:
        html.append(f"<tr><td>{r['container']}</td>")
        for p in phases:
            avg = r.get(f"{p}_avg", -1)
            html.append(f"<td>{mi(avg)}</td>")
        html.append("</tr>")
    html.append("</table>")

    html.append("<h2>Sample Counts by Phase</h2>")
    html.append("<table><tr><th>Container</th>")
    for p in phases:
        html.append(f"<th>{p}</th>")
    html.append("</tr>")
    for r in rows:
        html.append(f"<tr><td>{r['container']}</td>")
        for p in phases:
            cnt = r.get(f"{p}_count", 0)
            html.append(f"<td>{cnt}</td>")
        html.append("</tr>")
    html.append("</table>")

    html.append("</body></html>")

    Path(out_path).write_text("\n".join(html))
    print(f"\nHTML report: {out_path}")


def main():
    if len(sys.argv) < 2:
        print(f"usage: {sys.argv[0]} <sidecar_memory.csv>", file=sys.stderr)
        sys.exit(1)

    csv_path = sys.argv[1]
    data = parse_csv(csv_path)

    if not data:
        print(f"No data found in {csv_path}", file=sys.stderr)
        sys.exit(1)

    rows = build_table(data)
    print_text_report(rows)

    html_path = str(Path(csv_path).parent / "sidecar_report.html")
    build_html(rows, html_path)


if __name__ == "__main__":
    main()
