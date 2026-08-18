#!/usr/bin/env python3
"""Generate a comprehensive HTML scaling analysis report.

Correlates TPC-C metrics, K8s pod states, PVC changes, and Temporal workflow
activities into a single interactive report with synchronized time axes.

Usage:
  pip install plotly
  python3 generate_scaling_analysis_report.py scaling-benchmarking/results/run_20260702_142729_advanced-2-july-s-scale
  python3 generate_scaling_analysis_report.py /path/to/run_dir -o /path/to/report.html

  python3 scaling-benchmarking/scripts/generate_scaling_analysis_report.py

"""

from __future__ import annotations

import argparse
import csv
import html as html_mod
import json
import re
import sys
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

try:
    import plotly.graph_objects as go
    from plotly.subplots import make_subplots
except ImportError as exc:
    print("ERROR: plotly is required. Install with: pip install plotly", file=sys.stderr)
    raise SystemExit(1) from exc


# =============================================================================
# Data models
# =============================================================================

ENV_LINE_RE = re.compile(r"^([A-Z_]+)=(.*)$")
CONF_LINE_RE = re.compile(r'^([A-Z_][A-Z0-9_]*)="(.*)"\s*$')
SECRET_KEYS = {"MYSQL_PASSWORD", "DO_API_TOKEN", "DIGITALOCEAN_ACCESS_TOKEN"}


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
    lat_pct: float
    percentile: int
    err_per_sec: float
    reconn_per_sec: float


@dataclass
class K8sPodRow:
    timestamp: str
    pod: str
    phase: str
    ready: str
    gr_role: str
    gr_state: str
    gr_detail: str
    gr_members: str
    gr_online: str
    doks_node: str
    slug: str
    vcpus: str
    mem_gib: str
    pvc_req: str
    pvc_cap: str
    restarts: str
    deleting: str
    read_only: str = "?"
    super_read_only: str = "?"
    gr_queue: str = ""
    gr_applier_queue: str = ""
    replica_parallel_workers: str = ""
    replica_parallel_active: str = ""


@dataclass
class TemporalActivity:
    activity_type: str
    started_at: str
    ended_at: str
    duration_sec: float
    status: str
    workflow_path: str = ""
    scheduled_at: str = ""
    attempt: int = 1

    @property
    def wall_clock_sec(self) -> float:
        """Total wall-clock time from scheduled (or started) to ended, including retries."""
        start = self.scheduled_at or self.started_at
        if start and self.ended_at:
            s = _parse_utc(start)
            e = _parse_utc(self.ended_at)
            return (e - s).total_seconds()
        return self.duration_sec


@dataclass
class ScaleTiming:
    run_start_epoch: int = 0
    sysbench_offset: int = 0
    scale_start_epoch: int = 0
    scale_start_elapsed: int = 0
    scale_complete_epoch: int = 0
    scale_complete_elapsed: int = 0
    scale_duration_sec: int = 0
    scale_types: str = ""
    scale_description: str = ""
    engine: str = ""
    initial_size: str = ""
    initial_nodes: int = 0
    initial_storage_gib: int = 0
    target_size: str = ""
    target_nodes: int = 0
    target_storage_gib: int = 0
    success: bool = False

    @property
    def scale_start_utc(self) -> str:
        if self.scale_start_epoch:
            return _epoch_to_utc(self.scale_start_epoch)
        return ""

    @property
    def scale_complete_utc(self) -> str:
        if self.scale_complete_epoch:
            return _epoch_to_utc(self.scale_complete_epoch)
        return ""

    @property
    def tpcc_start_utc(self) -> str:
        if self.run_start_epoch and self.sysbench_offset:
            return _epoch_to_utc(self.run_start_epoch + self.sysbench_offset)
        if self.run_start_epoch:
            return _epoch_to_utc(self.run_start_epoch)
        return ""


# =============================================================================
# Parsing
# =============================================================================


def _epoch_to_utc(epoch: int) -> str:
    return datetime.fromtimestamp(epoch, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _parse_utc(s: str) -> datetime:
    s = s.strip()
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    return datetime.fromisoformat(s)


def load_scale_timing(path: Path) -> ScaleTiming:
    if not path.is_file():
        return ScaleTiming()
    values: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        m = ENV_LINE_RE.match(line.strip())
        if m:
            values[m.group(1)] = m.group(2).strip('"')
    return ScaleTiming(
        run_start_epoch=int(values.get("RUN_START_EPOCH", 0)),
        sysbench_offset=int(values.get("SYSBENCH_OFFSET_SEC", 0)),
        scale_start_epoch=int(values.get("SCALE_START_EPOCH", 0)),
        scale_start_elapsed=int(values.get("SCALE_START_ELAPSED", 0)),
        scale_complete_epoch=int(values.get("SCALE_COMPLETE_EPOCH", 0)),
        scale_complete_elapsed=int(values.get("SCALE_COMPLETE_ELAPSED", 0)),
        scale_duration_sec=int(values.get("SCALE_DURATION_SEC", 0)),
        scale_types=values.get("SCALE_TYPES", "").strip('"'),
        scale_description=values.get("SCALE_DESCRIPTION", "").strip('"'),
        engine=values.get("ENGINE", ""),
        initial_size=values.get("INITIAL_SIZE", ""),
        initial_nodes=int(values.get("INITIAL_NUM_NODES", 0)),
        initial_storage_gib=int(values.get("INITIAL_STORAGE_SIZE_GIB", 0)),
        target_size=values.get("SCALE_TARGET_SIZE", ""),
        target_nodes=int(values.get("SCALE_TARGET_NUM_NODES", 0)),
        target_storage_gib=int(values.get("SCALE_TARGET_STORAGE_SIZE_GIB", 0)),
        success=values.get("SCALE_SUCCESS") == "1",
    )


def load_benchmark_conf(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.is_file():
        return values
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        m = CONF_LINE_RE.match(stripped) or ENV_LINE_RE.match(stripped)
        if m:
            key, value = m.group(1), m.group(2)
            if key in SECRET_KEYS:
                value = "***"
            values[key] = value
    return values


def load_metrics(path: Path) -> list[MetricRow]:
    if not path.is_file():
        return []
    rows: list[MetricRow] = []
    with path.open(encoding="utf-8", errors="replace", newline="") as f:
        reader = csv.DictReader(f)
        for raw in reader:
            rows.append(MetricRow(
                wall_clock_utc=raw["wall_clock_utc"],
                elapsed_sec=int(raw["elapsed_sec"]),
                phase=raw["phase"],
                threads=int(raw["threads"]),
                tps=float(raw["tps"]),
                qps=float(raw["qps"]),
                qps_read=float(raw["qps_read"]),
                qps_write=float(raw["qps_write"]),
                qps_other=float(raw["qps_other"]),
                lat_pct=float(raw.get("lat_pct") or raw.get("lat_p95", 0)),
                percentile=int(raw["percentile"]) if "percentile" in raw else 99,
                err_per_sec=float(raw["err_per_sec"]),
                reconn_per_sec=float(raw["reconn_per_sec"]),
            ))
    return rows


def load_k8s_monitor(path: Path) -> list[K8sPodRow]:
    if not path.is_file():
        return []
    rows: list[K8sPodRow] = []
    with path.open(encoding="utf-8", errors="replace", newline="") as f:
        reader = csv.DictReader(f, delimiter="\t")
        for raw in reader:
            rows.append(K8sPodRow(
                timestamp=raw["timestamp"],
                pod=raw["pod"],
                phase=raw["phase"],
                ready=raw["ready"],
                gr_role=raw["gr_role"],
                gr_state=raw["gr_state"],
                gr_detail=raw.get("gr_detail", ""),
                gr_members=raw.get("gr_members", ""),
                gr_online=raw.get("gr_online", ""),
                doks_node=raw.get("doks_node", ""),
                slug=raw.get("slug", ""),
                vcpus=raw.get("vcpus", ""),
                mem_gib=raw.get("mem_gib", ""),
                pvc_req=raw.get("pvc_req", ""),
                pvc_cap=raw.get("pvc_cap", ""),
                restarts=raw.get("restarts", "0"),
                deleting=raw.get("deleting", "no"),
                read_only=raw.get("read_only", "?"),
                super_read_only=raw.get("super_read_only", "?"),
                gr_queue=raw.get("gr_queue", ""),
                gr_applier_queue=raw.get("gr_applier_queue", ""),
                replica_parallel_workers=raw.get("replica_parallel_workers", ""),
                replica_parallel_active=raw.get("replica_parallel_active", ""),
            ))
    return rows


def load_temporal_activities(path: Path) -> list[TemporalActivity]:
    if not path.is_file():
        return []
    data = json.loads(path.read_text(encoding="utf-8", errors="replace"))
    timeline = data.get("activity_timeline", [])
    activities: list[TemporalActivity] = []
    for a in timeline:
        if not a.get("started_at") or not a.get("ended_at"):
            continue
        activities.append(TemporalActivity(
            activity_type=a.get("activity_type", "unknown"),
            started_at=a["started_at"],
            ended_at=a["ended_at"],
            duration_sec=float(a.get("duration_sec", 0)),
            status=a.get("status", "unknown"),
            workflow_path=a.get("workflow_path", ""),
            scheduled_at=a.get("scheduled_at", ""),
            attempt=int(a.get("attempt", 1)),
        ))
    return activities


# =============================================================================
# Analysis helpers
# =============================================================================


def _fmt_duration(seconds: float | int) -> str:
    total = int(seconds)
    if total < 60:
        frac = seconds - total
        if frac > 0.01:
            return f"{seconds:.1f}s"
        return f"{total}s"
    hours, remainder = divmod(total, 3600)
    minutes, secs = divmod(remainder, 60)
    parts: list[str] = []
    if hours:
        parts.append(f"{hours}h")
    if minutes:
        parts.append(f"{minutes}m")
    if secs:
        parts.append(f"{secs}s")
    return " ".join(parts)


def _fmt_tpcc_data_gib(conf: dict[str, str]) -> str:
    """Estimate TPC-C dataset size as scale * tables * 0.1 GiB."""
    try:
        scale = float(conf.get("TPCC_SCALE", "") or 0)
        tables = float(conf.get("TPCC_TABLES", "") or 0)
    except ValueError:
        return "N/A"
    if scale <= 0 or tables <= 0:
        return "N/A"
    gib = scale * tables * 0.1
    scale_s = str(int(scale)) if scale == int(scale) else str(scale)
    tables_s = str(int(tables)) if tables == int(tables) else str(tables)
    if gib >= 10 or gib == int(gib):
        gib_s = f"{gib:.0f} GiB"
    else:
        gib_s = f"{gib:.1f} GiB"
    return f"{gib_s} ({scale_s} × {tables_s} × 0.1)"


def _is_offline_gr_token(val: str) -> bool:
    """True for OFFLINE or k8s-monitor placeholders like '?\\t?\\t' / '?'."""
    s = (val or "").strip()
    if not s:
        return True
    if s.upper() in ("OFFLINE", "UNKNOWN"):
        return True
    # Monitor emits "?\t?\t" (literal backslash-t or real tabs) when GR lookup fails.
    cleaned = (
        s.replace("\\t", "")
        .replace("\t", "")
        .replace("?", "")
        .strip()
    )
    return cleaned == ""


def _pct_change(current: float, baseline: float) -> float:
    if baseline <= 0:
        return 0.0
    return (current / baseline - 1) * 100


def _format_size_slug(slug: str) -> str:
    """Turn gd-8vcpu-32gb into 8 vCPU · 32 GB for display."""
    if not slug:
        return ""
    m = re.match(r"(?:gd-)?(\d+)vcpu-(\d+)gb", slug.lower())
    if m:
        return f"{m.group(1)} vCPU · {m.group(2)} GB"
    return slug.replace("-", " ").replace("_", " ")


def _append_disk_to_label(label: str, storage_gib: int) -> str:
    if storage_gib <= 0:
        return label
    disk = f"{storage_gib} GiB disk"
    return f"{label} · {disk}" if label else disk


def _parse_scale_header(timing: ScaleTiming, run_dir_name: str) -> dict[str, str]:
    desc = timing.scale_description or timing.scale_types or run_dir_name
    scale_type = desc
    from_size = timing.initial_size
    to_size = timing.target_size or timing.initial_size
    initial_storage = timing.initial_storage_gib
    target_storage = timing.target_storage_gib or timing.initial_storage_gib
    initial_nodes = timing.initial_nodes
    target_nodes = timing.target_nodes or timing.initial_nodes

    m = re.match(r"^([^(]+?)\s*\(([^)]+)\)\s*$", desc)
    if m:
        scale_type = m.group(1).strip()
        transition = m.group(2).strip()
        parts = re.split(r"\s*->\s*", transition)
        if len(parts) == 2:
            # Only override from_size/to_size for vertical scale (slug transitions)
            if "vertical" in scale_type:
                from_size, to_size = parts[0].strip(), parts[1].strip()

    slug_label = _format_size_slug(from_size) or from_size
    is_horizontal = "horizontal" in scale_type
    is_storage = "storage" in scale_type

    if is_horizontal:
        from_label = f"{slug_label} · {initial_nodes} node{'s' if initial_nodes != 1 else ''} · {initial_storage} GiB disk"
        to_label = f"{slug_label} · {target_nodes} node{'s' if target_nodes != 1 else ''} · {target_storage} GiB disk"
    elif is_storage:
        from_label = f"{slug_label} · {initial_nodes} node{'s' if initial_nodes != 1 else ''} · {initial_storage} GiB disk"
        to_label = f"{slug_label} · {initial_nodes} node{'s' if initial_nodes != 1 else ''} · {target_storage} GiB disk"
    else:
        from_label = _append_disk_to_label(_format_size_slug(from_size) or from_size, initial_storage)
        to_label = _append_disk_to_label(_format_size_slug(to_size) or to_size, target_storage)

    return {
        "scale_type": scale_type.replace("_", " ").title(),
        "from_size": from_size,
        "to_size": to_size,
        "from_label": from_label,
        "to_label": to_label,
    }


def _fmt_pct_badge(pct: float, *, higher_is_good: bool, decimals: int = 1) -> str:
    """Render a colored delta badge with arrow for KPI cards."""
    if abs(pct) < 0.05:
        cls = "delta-neutral"
        arrow = "→"
        sign = ""
    elif pct > 0:
        cls = "delta-good" if higher_is_good else "delta-bad"
        arrow = "↑"
        sign = "+"
    else:
        cls = "delta-bad" if higher_is_good else "delta-good"
        arrow = "↓"
        sign = ""

    return (
        f'<span class="delta-badge {cls}">'
        f'<span class="delta-arrow">{arrow}</span>'
        f'{sign}{abs(pct):.{decimals}f}%'
        f"</span>"
    )


def phase_stats(metrics: list[MetricRow], phase: str) -> dict[str, float]:
    rows = [m for m in metrics if m.phase == phase]
    if not rows:
        return {"count": 0, "avg_tps": 0, "avg_qps": 0, "avg_lat": 0, "max_lat": 0,
                "p50_tps": 0, "max_err": 0, "zero_tps_count": 0}
    tps_vals = sorted(m.tps for m in rows)
    return {
        "count": len(rows),
        "avg_tps": sum(m.tps for m in rows) / len(rows),
        "avg_qps": sum(m.qps for m in rows) / len(rows),
        "avg_lat": sum(m.lat_pct for m in rows) / len(rows),
        "max_lat": max(m.lat_pct for m in rows),
        "p50_tps": tps_vals[len(tps_vals) // 2],
        "max_err": max(m.err_per_sec for m in rows),
        "zero_tps_count": sum(1 for m in rows if m.tps == 0),
    }


def compute_impact_summary(
    metrics: list[MetricRow], timing: ScaleTiming, activities: list[TemporalActivity]
) -> dict[str, Any]:
    pre = phase_stats(metrics, "pre_scaling")
    during = phase_stats(metrics, "during_scaling")
    post = phase_stats(metrics, "post_scaling")

    tps_during_pct = _pct_change(during["avg_tps"], pre["avg_tps"])
    qps_during_pct = _pct_change(during["avg_qps"], pre["avg_qps"])
    lat_during_pct = _pct_change(during["avg_lat"], pre["avg_lat"])

    tps_post_pct = _pct_change(post["avg_tps"], pre["avg_tps"])
    qps_post_pct = _pct_change(post["avg_qps"], pre["avg_qps"])
    lat_post_pct = _pct_change(post["avg_lat"], pre["avg_lat"])

    slowest_activity = None
    if activities:
        slowest = max(activities, key=lambda a: a.wall_clock_sec)
        slowest_activity = {
            "name": slowest.activity_type,
            "duration_sec": slowest.wall_clock_sec,
            "started_at": slowest.scheduled_at or slowest.started_at,
            "ended_at": slowest.ended_at,
            "attempt": slowest.attempt,
        }

    return {
        "pre": pre,
        "during": during,
        "post": post,
        "tps_during_pct": tps_during_pct,
        "qps_during_pct": qps_during_pct,
        "lat_during_pct": lat_during_pct,
        "tps_post_pct": tps_post_pct,
        "qps_post_pct": qps_post_pct,
        "lat_post_pct": lat_post_pct,
        "scale_duration_sec": timing.scale_duration_sec,
        "zero_tps_during": during["zero_tps_count"],
        "slowest_activity": slowest_activity,
    }


def pvc_change_events(k8s_rows: list[K8sPodRow]) -> list[dict[str, Any]]:
    """Track PVC resize: request issued → capacity expanded, with duration."""
    pod_state: dict[str, dict[str, str]] = {}
    pending_req: dict[str, dict[str, str]] = {}
    completed: list[dict[str, Any]] = []

    for row in k8s_rows:
        pod = row.pod
        if not row.pvc_req or not row.pvc_cap:
            continue
        if pod not in pod_state:
            pod_state[pod] = {"pvc_req": row.pvc_req, "pvc_cap": row.pvc_cap}
            continue

        prev = pod_state[pod]

        if row.pvc_req != prev["pvc_req"] and pod not in pending_req:
            pending_req[pod] = {
                "pod": pod,
                "request_started_at": row.timestamp,
                "old_req": prev["pvc_req"],
                "new_req": row.pvc_req,
                "old_cap": prev["pvc_cap"],
            }

        if pod in pending_req and row.pvc_cap and row.pvc_cap != prev["pvc_cap"]:
            req = pending_req.pop(pod)
            start_ts = _parse_utc(req["request_started_at"])
            end_ts = _parse_utc(row.timestamp)
            duration = (end_ts - start_ts).total_seconds()
            completed.append({
                "pod": pod,
                "request_started_at": req["request_started_at"],
                "fulfilled_at": row.timestamp,
                "duration_sec": duration,
                "old_size": req["old_cap"],
                "new_size": row.pvc_cap,
            })

        pod_state[pod] = {"pvc_req": row.pvc_req, "pvc_cap": row.pvc_cap}

    return completed


# =============================================================================
# Plotly chart builders
# =============================================================================

PHASE_COLORS = {
    "pre_scaling": "#2ca02c",
    "during_scaling": "#ff7f0e",
    "post_scaling": "#1f77b4",
}


def _wall_times(metrics: list[MetricRow]) -> list[str]:
    return [m.wall_clock_utc for m in metrics]


def build_main_figure(
    metrics: list[MetricRow],
    timing: ScaleTiming,
    k8s_rows: list[K8sPodRow],
    activities: list[TemporalActivity],
    run_dir: Path | None = None,
) -> go.Figure:
    pct = metrics[0].percentile if metrics else 99

    fig = make_subplots(
        rows=4,
        cols=1,
        shared_xaxes=True,
        vertical_spacing=0.05,
        row_heights=[0.24, 0.24, 0.24, 0.28],
        subplot_titles=(
            "TPS (Transactions/sec)",
            "QPS (Queries/sec)",
            f"Latency p{pct} (ms)",
            "Temporal Workflow Activities (within scaling window)",
        ),
    )

    for phase, color in PHASE_COLORS.items():
        phase_rows = [m for m in metrics if m.phase == phase]
        if not phase_rows:
            continue
        times = [m.wall_clock_utc for m in phase_rows]
        label = phase.replace("_", " ").title()

        fig.add_trace(go.Scatter(
            x=times, y=[m.tps for m in phase_rows],
            mode="lines", name=label, line=dict(color=color, width=1.2),
            legendgroup=phase, showlegend=True,
        ), row=1, col=1)

        fig.add_trace(go.Scatter(
            x=times, y=[m.qps for m in phase_rows],
            mode="lines", name=label, line=dict(color=color, width=1.2),
            legendgroup=phase, showlegend=False,
        ), row=2, col=1)

        fig.add_trace(go.Scatter(
            x=times, y=[m.lat_pct for m in phase_rows],
            mode="lines", name=label, line=dict(color=color, width=1.2),
            legendgroup=phase, showlegend=False,
        ), row=3, col=1)

    if run_dir is not None:
        failovers = _resolve_failovers(k8s_rows or [], run_dir)
        drains = _detect_secondary_drains(k8s_rows or [], run_dir, failovers=failovers)
        drains = _with_separate_proxy_drain_markers(drains, k8s_rows or [], run_dir)
    elif k8s_rows:
        failovers = _resolve_failovers(k8s_rows, None)
        drains = _detect_secondary_drains(k8s_rows, None, failovers=failovers)
        drains = _with_separate_proxy_drain_markers(drains, k8s_rows, None)
    else:
        failovers = []
        drains = []

    # Event markers on metric panels (temporal row added after Gantt bars)
    _add_scale_event_vlines(fig, timing, failovers, [1, 2, 3], drains)

    metric_times = [m.wall_clock_utc for m in metrics] if metrics else []
    if metric_times:
        t_start, t_end = min(metric_times), max(metric_times)
    elif k8s_rows:
        valid_ts = [r.timestamp for r in k8s_rows if r.timestamp[:4].isdigit()]
        t_start, t_end = min(valid_ts), max(valid_ts)
    else:
        t_start = t_end = ""

    fig_height = 1200
    bottom_margin = 72
    event_band_h, event_items = _prepare_event_band(
        timing, failovers, t_start, t_end, drains,
    )
    top_margin = max(72, event_band_h + 28)
    plot_h_px = fig_height - bottom_margin - top_margin
    if event_items:
        _render_event_band(fig, event_items, plot_h_px)

    # Temporal activities as Gantt bars — scale window shaded region
    if activities:
        if timing.scale_start_utc and timing.scale_complete_utc:
            fig.add_vrect(
                x0=timing.scale_start_utc, x1=timing.scale_complete_utc,
                fillcolor="#ff7f0e", opacity=0.08, line_width=0,
                row=4, col=1,
            )

        sorted_activities = sorted(activities, key=lambda a: _parse_utc(a.scheduled_at or a.started_at))
        y_labels = [a.activity_type for a in sorted_activities]

        for idx, act in enumerate(sorted_activities):
            real_start = act.scheduled_at or act.started_at
            start_dt = _parse_utc(real_start)
            end_dt = _parse_utc(act.ended_at)
            dur_ms = (end_dt - start_dt).total_seconds() * 1000
            retry_note = f"<br>Attempts: {act.attempt}" if act.attempt > 1 else ""

            fig.add_trace(go.Bar(
                x=[dur_ms],
                y=[act.activity_type],
                base=[real_start],
                orientation="h",
                marker=dict(
                    color="#d62728" if act.attempt > 1 else "#2da44e" if act.status == "completed" else "#d62728" if act.status == "failed" else "#bf8700",
                    line=dict(width=0),
                ),
                width=0.7,
                name=act.activity_type,
                showlegend=False,
                hovertemplate=(
                    f"<b>{act.activity_type}</b><br>"
                    f"Wall clock: {_fmt_duration(act.wall_clock_sec)}<br>"
                    f"Scheduled: {real_start[11:19]} UTC<br>"
                    f"Started: {act.started_at[11:19]} UTC<br>"
                    f"End: {act.ended_at[11:19]} UTC<br>"
                    f"Status: {act.status}{retry_note}"
                    "<extra></extra>"
                ),
            ), row=4, col=1)

        fig.update_xaxes(type="date", row=4, col=1)
        fig.update_yaxes(
            categoryorder="array",
            categoryarray=y_labels,
            row=4, col=1,
            tickfont=dict(size=10),
        )

    # Temporal panel: scale start / complete / failover / secondary drain on top of Gantt bars
    _add_scale_event_vlines(fig, timing, failovers, [4], drains)

    fig.update_layout(
        height=fig_height,
        hovermode="x unified",
        legend=dict(
            orientation="h",
            yanchor="top", y=-0.04,
            x=0.5, xanchor="center",
            tracegroupgap=14,
            itemwidth=30,
            bgcolor="rgba(255,255,255,0.92)",
            bordercolor="#d0d7de",
            borderwidth=1,
        ),
        margin=dict(t=top_margin, b=bottom_margin),
    )

    fig.update_xaxes(title_text="Time (UTC)", row=4, col=1)
    fig.update_yaxes(title_text="TPS", row=1, col=1)
    fig.update_yaxes(title_text="QPS", row=2, col=1)
    fig.update_yaxes(title_text="ms", row=3, col=1)

    return fig


def _is_horizontal_scale(timing: ScaleTiming) -> bool:
    return "horizontal" in timing.scale_types.lower() or (
        timing.target_nodes > 0 and timing.target_nodes != timing.initial_nodes
    )


def _is_vertical_scale(timing: ScaleTiming) -> bool:
    return "vertical" in timing.scale_types.lower() or (
        timing.target_size != "" and timing.target_size != timing.initial_size
    )


def build_k8s_figure(
    k8s_rows: list[K8sPodRow], timing: ScaleTiming
) -> go.Figure | None:
    if not k8s_rows:
        return None

    pods, pod_short = _discover_mysql_pods(k8s_rows)
    if not pods:
        return None
    k8s_rows = _filter_k8s_rows_for_pods(k8s_rows, pods)
    horizontal = _is_horizontal_scale(timing)
    vertical = _is_vertical_scale(timing)

    if horizontal:
        subplot_titles = (
            "GR Role (PRIMARY / SECONDARY)",
            "GR State (ONLINE / RECOVERING / ERROR)",
            "GR Group Membership (Members / Online)",
        )
    elif vertical:
        subplot_titles = (
            "GR Role (PRIMARY / SECONDARY)",
            "GR State (ONLINE / RECOVERING / ERROR)",
            "vCPUs per Pod (Node Slug)",
        )
    else:
        subplot_titles = (
            "GR Role (PRIMARY / SECONDARY)",
            "GR State (ONLINE / RECOVERING / ERROR)",
            "PVC Capacity (GiB)",
        )

    fig = make_subplots(
        rows=3, cols=1,
        shared_xaxes=True,
        vertical_spacing=0.07,
        subplot_titles=subplot_titles,
    )

    def _pvc_gib(val: str) -> float:
        val = val.strip()
        if val.endswith("Gi"):
            return float(val[:-2])
        if val.endswith("Ti"):
            return float(val[:-2]) * 1024
        return 0

    role_map = {"PRIMARY": 2, "SECONDARY": 1}
    state_map = {"ONLINE": 3, "RECOVERING": 2, "PODINITIALIZING": 1, "ERROR": 0, "OFFLINE": 0}

    def _resolve_gr_state(row: K8sPodRow) -> str:
        if row.gr_state in ("ONLINE", "RECOVERING", "ERROR"):
            return row.gr_state
        if "PodInitializing" in (row.gr_detail or ""):
            return "PODINITIALIZING"
        if row.phase == "Pending" or (row.phase == "Running" and row.ready == "false"):
            return "PODINITIALIZING"
        if _is_offline_gr_token(row.gr_state) or row.deleting == "yes":
            return "OFFLINE"
        return "OFFLINE"

    def _resolve_gr_role(row: K8sPodRow) -> tuple[int, str]:
        if row.gr_role in ("PRIMARY", "SECONDARY"):
            return role_map[row.gr_role], row.gr_role
        return 0, "Unknown"

    pod_colors = ["#0969da", "#d62728", "#2ca02c", "#9467bd", "#8c564b"]
    cluster_tl = _cluster_primary_timeline(k8s_rows)

    for idx, pod in enumerate(pods):
        pod_rows = [r for r in k8s_rows if r.pod == pod]
        times = [r.timestamp for r in pod_rows]
        label = f"mysql-{pod_short[pod]}"
        color = pod_colors[idx % len(pod_colors)]

        role_labels = _resolve_gr_role_keys(pod_rows, pod, cluster_tl)
        role_vals = [
            (role_map.get(role, 0), role or "Unknown") for role in role_labels
        ]
        fig.add_trace(go.Scatter(
            x=times,
            y=[v[0] for v in role_vals],
            mode="lines",
            name=label,
            line=dict(width=3, color=color),
            hovertext=[f"{label}: {v[1]}" for v in role_vals],
            hoverinfo="text+x",
            legendgroup=label,
            showlegend=True,
        ), row=1, col=1)

        # GR State
        state_vals = [_resolve_gr_state(r) for r in pod_rows]
        fig.add_trace(go.Scatter(
            x=times,
            y=[state_map.get(s, 0) for s in state_vals],
            mode="lines",
            name=label,
            line=dict(width=2, color=color),
            hovertext=[f"{label}: {s}" for s in state_vals],
            hoverinfo="text+x",
            legendgroup=label,
            showlegend=False,
        ), row=2, col=1)

    if horizontal:
        # GR Group Size — deduplicate by timestamp, pick max members/online
        ts_members: dict[str, int] = {}
        ts_online: dict[str, int] = {}
        for r in k8s_rows:
            m = int(r.gr_members) if r.gr_members and r.gr_members.isdigit() else 0
            o = int(r.gr_online) if r.gr_online and r.gr_online.isdigit() else 0
            ts_members[r.timestamp] = max(ts_members.get(r.timestamp, 0), m)
            ts_online[r.timestamp] = max(ts_online.get(r.timestamp, 0), o)
        sorted_ts = sorted(ts_members.keys())
        fig.add_trace(go.Scatter(
            x=sorted_ts, y=[ts_members[t] for t in sorted_ts],
            mode="lines", name="GR Members",
            line=dict(width=2, color="#0969da"),
            legendgroup="gr_size", showlegend=True,
        ), row=3, col=1)
        fig.add_trace(go.Scatter(
            x=sorted_ts, y=[ts_online[t] for t in sorted_ts],
            mode="lines", name="GR Online",
            line=dict(width=2, color="#2ca02c", dash="dot"),
            legendgroup="gr_size", showlegend=True,
        ), row=3, col=1)
    elif vertical:
        # vCPU/RAM per pod — carry forward last known size during brief gaps
        for idx, pod in enumerate(pods):
            pod_rows = [r for r in k8s_rows if r.pod == pod]
            times = [r.timestamp for r in pod_rows]
            label = f"mysql-{pod_short[pod]}"
            color = pod_colors[idx % len(pod_colors)]
            size_labels = _resolve_carry_forward_keys(pod_rows, _format_node_size)
            vcpus = [
                int(s.split()[0]) if s and s.split()[0].isdigit() else 0
                for s in size_labels
            ]
            fig.add_trace(go.Scatter(
                x=times, y=vcpus,
                mode="lines", name=label,
                line=dict(width=2, color=color),
                hovertext=[
                    f"{label}: {s or 'unknown'}" for s in size_labels
                ],
                hoverinfo="text+x",
                legendgroup=label,
                showlegend=False,
            ), row=3, col=1)
    else:
        for idx, pod in enumerate(pods):
            pod_rows = [r for r in k8s_rows if r.pod == pod]
            times = [r.timestamp for r in pod_rows]
            label = f"mysql-{pod_short[pod]}"
            color = pod_colors[idx % len(pod_colors)]
            fig.add_trace(go.Scatter(
                x=times, y=[_pvc_gib(r.pvc_cap) for r in pod_rows],
                mode="lines", name=f"{label} cap",
                line=dict(width=2, color=color),
                legendgroup=label,
                showlegend=False,
            ), row=3, col=1)

    # Scale markers
    num_rows = 3
    if timing.scale_start_utc:
        for row_idx in range(1, num_rows + 1):
            fig.add_vline(x=timing.scale_start_utc, line_dash="dash",
                          line_color="#d62728", line_width=1.5, row=row_idx, col=1)
    if timing.scale_complete_utc:
        for row_idx in range(1, num_rows + 1):
            fig.add_vline(x=timing.scale_complete_utc, line_dash="dash",
                          line_color="#9467bd", line_width=1.5, row=row_idx, col=1)

    fig.update_layout(height=700, hovermode="x unified", margin=dict(t=50),
                      legend=dict(orientation="h", yanchor="bottom", y=1.01, x=0))
    fig.update_yaxes(title_text="Role", tickvals=[0, 1, 2],
                     ticktext=["Unknown", "SECONDARY", "PRIMARY"], row=1, col=1)
    fig.update_yaxes(title_text="State", tickvals=[0, 1, 2, 3],
                     ticktext=["ERROR/OFFLINE", "PodInitializing", "RECOVERING", "ONLINE"], row=2, col=1)
    if horizontal:
        fig.update_yaxes(title_text="Count", row=3, col=1)
    elif vertical:
        fig.update_yaxes(title_text="vCPUs", row=3, col=1)
    else:
        fig.update_yaxes(title_text="GiB", row=3, col=1)
    fig.update_xaxes(title_text="Time (UTC)", row=3, col=1)

    return fig


def _round_mem_gb(mem_gib: str, slug: str = "") -> int | None:
    """Round raw GiB from monitor (e.g. 31.3, 62.8) to display GB (32, 64)."""
    if slug:
        slug_m = re.search(r"-(\d+)gb", slug.lower())
        if slug_m:
            return int(slug_m.group(1))
    if not mem_gib:
        return None
    try:
        val = float(mem_gib)
        return max(1, int(round(val / 8) * 8))
    except ValueError:
        return None


def _load_failover_timestamp(path: Path, k8s_rows: list[K8sPodRow]) -> str | None:
    """Parse failover_time.txt — supports full ISO or '(HH:MM:SS UTC)'."""
    if not path.is_file():
        return None
    text = path.read_text(encoding="utf-8", errors="replace").strip()
    if not text:
        return None

    iso = re.search(r"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)", text)
    if iso:
        return iso.group(1)

    time_m = re.search(r"(\d{2}:\d{2}:\d{2})", text)
    if not time_m:
        return None

    date_hint = ""
    for row in k8s_rows:
        if row.timestamp[:4].isdigit():
            date_hint = row.timestamp[:10]
            break
    if not date_hint:
        return None
    return f"{date_hint}T{time_m.group(1)}Z"


def _infer_failover_at_time(
    k8s_rows: list[K8sPodRow], file_ts: str,
) -> dict[str, str] | None:
    """Infer failover pods from last/first PRIMARY around a known timestamp."""
    ts = _parse_utc(file_ts)
    last_before = ""
    for row in sorted(k8s_rows, key=lambda r: r.timestamp):
        if _parse_utc(row.timestamp) > ts:
            break
        if row.gr_role == "PRIMARY":
            last_before = row.pod

    first_after = ""
    for row in sorted(k8s_rows, key=lambda r: r.timestamp):
        if _parse_utc(row.timestamp) < ts:
            continue
        if row.gr_role == "PRIMARY":
            first_after = row.pod
            break

    if not last_before or not first_after or last_before == first_after:
        return None

    from_short = (
        last_before.split("-mysql-")[-1]
        if "-mysql-" in last_before else last_before
    )
    to_short = (
        first_after.split("-mysql-")[-1]
        if "-mysql-" in first_after else first_after
    )
    return {
        "timestamp": file_ts,
        "from": from_short,
        "to": to_short,
        "label": f"Failover mysql-{from_short} → mysql-{to_short}",
    }


def _detect_failovers(k8s_rows: list[K8sPodRow]) -> list[dict[str, str]]:
    failovers: list[dict[str, str]] = []
    prev_primary = ""
    for row in k8s_rows:
        if row.gr_role != "PRIMARY":
            continue
        if prev_primary and row.pod != prev_primary:
            from_short = (
                prev_primary.split("-mysql-")[-1]
                if "-mysql-" in prev_primary else prev_primary
            )
            to_short = (
                row.pod.split("-mysql-")[-1]
                if "-mysql-" in row.pod else row.pod
            )
            failovers.append({
                "timestamp": row.timestamp,
                "from": from_short,
                "to": to_short,
                "label": f"Failover mysql-{from_short} → mysql-{to_short}",
            })
        prev_primary = row.pod
    return failovers


def _resolve_failovers(
    k8s_rows: list[K8sPodRow],
    run_dir: Path | None = None,
) -> list[dict[str, str]]:
    """Use failover_time.txt when present; otherwise detect from k8s monitor."""
    detected = _detect_failovers(k8s_rows)
    if run_dir is None:
        return detected

    file_ts = _load_failover_timestamp(run_dir / "failover_time.txt", k8s_rows)
    if not file_ts:
        return detected

    if detected:
        fo = dict(detected[0])
        fo["timestamp"] = file_ts
        fo["label"] = f"Failover mysql-{fo['from']} → mysql-{fo['to']}"
        return [fo, *detected[1:]]

    inferred = _infer_failover_at_time(k8s_rows, file_ts)
    if inferred:
        return [inferred]

    return [{
        "timestamp": file_ts,
        "from": "?",
        "to": "?",
        "label": f"Failover ({file_ts[11:19]} UTC)",
    }]


def _component_short_name(pod: str) -> str:
    """Human label for a drained companion pod."""
    # Check specialized components before '-mysql-' — cluster names often
    # contain 'mysql' as a substring (e.g. adv-mysql-v-scale-...-haproxy-0).
    if "-haproxy-" in pod:
        return f"haproxy-{pod.split('-haproxy-')[-1]}"
    if "binlog-server" in pod or "-binlog-" in pod:
        return "binlog-server"
    if "-router-" in pod:
        return f"router-{pod.split('-router-')[-1]}"
    if re.search(r"-mysql-\d+$", pod):
        return f"mysql-{pod.rsplit('-mysql-', 1)[-1]}"
    return pod.rsplit("-", 1)[-1]


def _load_killing_events(run_dir: Path | None) -> list[dict[str, str]]:
    """Load Pod Killing events from k8s_monitor/k8s_events.tsv."""
    if run_dir is None:
        return []
    path = run_dir / "k8s_monitor" / "k8s_events.tsv"
    if not path.is_file():
        return []
    events: list[dict[str, str]] = []
    with path.open(encoding="utf-8", errors="replace", newline="") as f:
        for raw in csv.DictReader(f, delimiter="\t"):
            if (raw.get("reason") or "") != "Killing":
                continue
            obj = raw.get("object") or ""
            ts = raw.get("event_ts") or raw.get("poll_ts") or ""
            if not obj or not ts or not _VALID_TS_RE.match(ts):
                continue
            events.append({"timestamp": ts, "object": obj})
    return events


def _ts_hhmmss(ts: str) -> str:
    """Return HH:MM:SS from an ISO UTC timestamp, or '' if unavailable."""
    return ts[11:19] if len(ts) >= 19 else ""


def _companion_sort_key(name: str) -> tuple[int, str]:
    return (
        0 if name.startswith("haproxy") else 1 if name.startswith("binlog") else 2,
        name,
    )


def _detect_secondary_drains(
    k8s_rows: list[K8sPodRow],
    run_dir: Path | None = None,
    companion_window_sec: float = 60.0,
    failovers: list[dict[str, str]] | None = None,
    failover_overlap_sec: float = 90.0,
) -> list[dict[str, str]]:
    """Detect SECONDARY mysql pods entering deleting=yes (rolling drain).

    Companion HAProxy / binlog pods killed within companion_window_sec are
    recorded on each drain. Only companions that share the exact same HH:MM:SS
    timestamp are folded into the drain label
    (e.g. 'Secondary Drain mysql-0 (+ haproxy-0)'). Companions at a different
    second are kept in companion_events for separate labels/rows.

    Drains of the old PRIMARY that already have a Failover label (same pod /
    near the same timestamp) are omitted to avoid duplicate markers.
    """
    last_role: dict[str, str] = {}
    prev_deleting: dict[str, str] = {}
    drains: list[dict[str, str]] = []

    for row in sorted(k8s_rows, key=lambda r: (r.timestamp, r.pod)):
        if "-mysql-" not in row.pod:
            continue
        if row.gr_role in ("PRIMARY", "SECONDARY"):
            last_role[row.pod] = row.gr_role

        prev = prev_deleting.get(row.pod, "no")
        prev_deleting[row.pod] = row.deleting
        if prev == "yes" or row.deleting != "yes":
            continue
        if last_role.get(row.pod) != "SECONDARY":
            continue

        short = row.pod.split("-mysql-")[-1]
        drains.append({
            "timestamp": row.timestamp,
            "pod": short,
            "full_pod": row.pod,
            "label": f"Secondary Drain mysql-{short}",
        })

    if not drains:
        return drains

    killings = _load_killing_events(run_dir)
    for drain in drains:
        center = _parse_utc(drain["timestamp"])
        drain_hhmmss = _ts_hhmmss(drain["timestamp"])
        companion_events: list[dict[str, str]] = []
        seen: set[str] = set()
        for ev in killings:
            obj = ev["object"]
            if drain["full_pod"] in obj:
                continue
            if not any(tok in obj for tok in ("haproxy", "binlog", "router")):
                continue
            try:
                delta = abs((_parse_utc(ev["timestamp"]) - center).total_seconds())
            except Exception:
                continue
            if delta > companion_window_sec:
                continue
            name = _component_short_name(obj)
            if name in seen:
                continue
            seen.add(name)
            companion_events.append({
                "name": name,
                "timestamp": ev["timestamp"],
            })
        companion_events.sort(
            key=lambda c: (_companion_sort_key(c["name"]), c["timestamp"])
        )
        same_ts = [
            c["name"] for c in companion_events
            if _ts_hhmmss(c["timestamp"]) == drain_hhmmss
        ]
        drain["companion_events"] = companion_events
        drain["companions"] = ",".join(same_ts)
        drain["companion_first_ts"] = (
            min(c["timestamp"] for c in companion_events) if companion_events else ""
        )
        if same_ts:
            drain["label"] = (
                f"Secondary Drain mysql-{drain['pod']} (+ {', '.join(same_ts)})"
            )

    # Skip drains covered by an existing Failover label (old primary drain).
    if failovers:
        kept: list[dict[str, str]] = []
        for drain in drains:
            drain_ts = _parse_utc(drain["timestamp"])
            redundant = False
            for fo in failovers:
                if drain["pod"] != fo.get("from", ""):
                    continue
                try:
                    delta = abs((drain_ts - _parse_utc(fo["timestamp"])).total_seconds())
                except Exception:
                    continue
                if delta <= failover_overlap_sec:
                    redundant = True
                    break
            if not redundant:
                kept.append(drain)
        drains = kept

    return drains


def _detect_proxy_component_drains(
    k8s_rows: list[K8sPodRow],
    run_dir: Path | None,
) -> list[dict[str, str]]:
    """HAProxy / binlog / router Killing events during the monitor window.

    Used so separately timed proxy moves appear even when they fall outside the
    MySQL-drain companion window.
    """
    if run_dir is None or not k8s_rows:
        return []
    timestamps = [r.timestamp for r in k8s_rows if _VALID_TS_RE.match(r.timestamp)]
    if not timestamps:
        return []
    t_start, t_end = min(timestamps), max(timestamps)

    out: list[dict[str, str]] = []
    seen: set[tuple[str, str]] = set()
    for ev in _load_killing_events(run_dir):
        obj = ev["object"]
        ts = ev["timestamp"]
        if not any(tok in obj for tok in ("haproxy", "binlog", "router")):
            continue
        if ts < t_start or ts > t_end:
            continue
        name = _component_short_name(obj)
        key = (name, _ts_hhmmss(ts))
        if key in seen:
            continue
        seen.add(key)
        kind = (
            "HAProxy" if name.startswith("haproxy")
            else "Binlog" if name.startswith("binlog")
            else "Router"
        )
        out.append({
            "timestamp": ts,
            "name": name,
            "label": f"{kind} Drain {name}",
            "what": f"{name} drained",
        })
    return out


def _short_node_name(node: str) -> str:
    """Short DOKS node label (last hyphen segment), e.g. 37mtj7."""
    node = (node or "").strip()
    if not node or node == "?":
        return "?"
    return node.rsplit("-", 1)[-1]


def _slug_vcpu(slug: str) -> int | None:
    m = re.search(r"(\d+)vcpu", (slug or "").lower())
    return int(m.group(1)) if m else None


def _relative_slug_label(slug: str, known_slugs: set[str]) -> str:
    """Label placement as 'new node' / 'old node' when the run has two sizes.

    Larger vCPU slug => new node; smaller => old node. Falls back to the raw
    slug when size can't be ranked.
    """
    slug = (slug or "").strip()
    if not slug or slug == "?":
        return "?"
    sized = sorted(
        {(v, s) for s in known_slugs if (v := _slug_vcpu(s)) is not None},
        key=lambda x: x[0],
    )
    v = _slug_vcpu(slug)
    if v is None or len(sized) < 2:
        return slug
    min_v, max_v = sized[0][0], sized[-1][0]
    if v == max_v and max_v != min_v:
        return "new node"
    if v == min_v and max_v != min_v:
        return "old node"
    return slug


def _collect_run_slugs(k8s_rows: list[K8sPodRow]) -> set[str]:
    return {r.slug for r in k8s_rows if r.slug and r.slug not in ("?", "")}


def _resolve_mysql_on_node(
    k8s_rows: list[K8sPodRow],
    node: str,
    at_ts: str,
) -> tuple[str, str] | None:
    """Find which mysql-* shares `node` near `at_ts`.

    Prefer same-timestamp occupancy; else the soonest occupancy after at_ts;
    else the latest occupancy before at_ts.
    Returns (mysql_short, slug) or None.
    """
    if not node or node == "?":
        return None
    node_short = _short_node_name(node)

    def _node_match(doks: str) -> bool:
        return doks == node or doks.endswith(node_short) or _short_node_name(doks) == node_short

    at_exact: list[tuple[str, str]] = []
    after: list[tuple[str, str, str]] = []  # ts, short, slug
    before: list[tuple[str, str, str]] = []

    for row in k8s_rows:
        if "-mysql-" not in row.pod:
            continue
        if not _VALID_TS_RE.match(row.timestamp):
            continue
        if not _node_match(row.doks_node or ""):
            continue
        short = row.pod.split("-mysql-")[-1]
        slug = row.slug or "?"
        if row.timestamp == at_ts:
            at_exact.append((short, slug))
        elif row.timestamp > at_ts:
            after.append((row.timestamp, short, slug))
        else:
            before.append((row.timestamp, short, slug))

    if at_exact:
        # Prefer Running/ready if multiple, else first.
        return at_exact[0]
    if after:
        after.sort(key=lambda x: x[0])
        return after[0][1], after[0][2]
    if before:
        before.sort(key=lambda x: x[0])
        return before[-1][1], before[-1][2]
    return None


def _format_host_placement(
    k8s_rows: list[K8sPodRow],
    node: str,
    at_ts: str,
    known_slugs: set[str] | None = None,
) -> str:
    """Human placement label: 'mysql-1 (new node)' or node short fallback."""
    known = known_slugs if known_slugs is not None else _collect_run_slugs(k8s_rows)
    resolved = _resolve_mysql_on_node(k8s_rows, node, at_ts)
    if resolved:
        short, slug = resolved
        return f"mysql-{short} ({_relative_slug_label(slug, known)})"
    return _short_node_name(node)


def _load_pod_scheduled_nodes(run_dir: Path | None) -> list[dict[str, str]]:
    """Pod Scheduled events with assigned node from k8s_events.tsv."""
    if run_dir is None:
        return []
    path = run_dir / "k8s_monitor" / "k8s_events.tsv"
    if not path.is_file():
        return []
    assign_re = re.compile(r"Successfully assigned\s+\S+\s+to\s+(\S+)")
    out: list[dict[str, str]] = []
    with path.open(encoding="utf-8", errors="replace", newline="") as f:
        for raw in csv.DictReader(f, delimiter="\t"):
            if (raw.get("reason") or "") != "Scheduled":
                continue
            obj = raw.get("object") or ""
            ts = raw.get("event_ts") or raw.get("poll_ts") or ""
            msg = raw.get("message") or ""
            if not obj or not ts or not _VALID_TS_RE.match(ts):
                continue
            m = assign_re.search(msg)
            if not m:
                continue
            out.append({
                "timestamp": ts,
                "object": obj,
                "name": _component_short_name(obj),
                "node": m.group(1),
                "node_short": _short_node_name(m.group(1)),
            })
    return out


def _detect_haproxy_recoveries(run_dir: Path | None) -> list[dict[str, str]]:
    """When each HAProxy endpoint becomes ready again, with the node it landed on.

    Uses endpoints_monitor.tsv for ready-set gains and Scheduled events for node.
    Works for any run that captured those monitor files.
    """
    if run_dir is None:
        return []
    ep_path = run_dir / "k8s_monitor" / "endpoints_monitor.tsv"
    if not ep_path.is_file():
        return []

    by_ts: dict[str, set[str]] = {}
    with ep_path.open(encoding="utf-8", errors="replace", newline="") as f:
        for raw in csv.DictReader(f, delimiter="\t"):
            svc = raw.get("service") or ""
            if "haproxy" not in svc:
                continue
            ts = raw.get("timestamp") or ""
            pod = raw.get("pod") or ""
            state = raw.get("state") or ""
            if not ts or not pod or state != "ready":
                continue
            if not _VALID_TS_RE.match(ts):
                continue
            short = _component_short_name(pod)
            by_ts.setdefault(ts, set()).add(short)

    scheduled = _load_pod_scheduled_nodes(run_dir)
    recoveries: list[dict[str, str]] = []
    prev_ready: set[str] | None = None
    for ts in sorted(by_ts):
        ready = by_ts[ts]
        if prev_ready is None:
            # First sample is baseline membership — not a recovery.
            prev_ready = ready
            continue
        gained = ready - prev_ready
        for name in sorted(gained):
            # Prefer Scheduled at/before recovery; fall back to any Scheduled for pod.
            node_short = "?"
            node_full = ""
            best_ts = ""
            for ev in scheduled:
                if ev["name"] != name:
                    continue
                if ev["timestamp"] > ts:
                    continue
                if not best_ts or ev["timestamp"] >= best_ts:
                    best_ts = ev["timestamp"]
                    node_short = ev["node_short"]
                    node_full = ev["node"]
            recoveries.append({
                "timestamp": ts,
                "name": name,
                "node": node_full,
                "node_short": node_short,
                "label": f"{name} ready on {node_short}",
            })
        prev_ready = ready
    return recoveries


def _detect_binlog_recoveries(run_dir: Path | None) -> list[dict[str, str]]:
    """Binlog-server reschedule recovery (Scheduled after Killing), if present."""
    if run_dir is None:
        return []
    path = run_dir / "k8s_monitor" / "k8s_events.tsv"
    if not path.is_file():
        return []

    killings: list[str] = []
    recovers: list[dict[str, str]] = []
    seen_after_kill: set[str] = set()
    assign_re = re.compile(r"Successfully assigned\s+\S+\s+to\s+(\S+)")

    with path.open(encoding="utf-8", errors="replace", newline="") as f:
        rows = list(csv.DictReader(f, delimiter="\t"))

    for raw in sorted(rows, key=lambda r: r.get("event_ts") or r.get("poll_ts") or ""):
        obj = raw.get("object") or ""
        if "binlog" not in obj:
            continue
        ts = raw.get("event_ts") or raw.get("poll_ts") or ""
        if not ts or not _VALID_TS_RE.match(ts):
            continue
        reason = raw.get("reason") or ""
        name = _component_short_name(obj)
        if reason == "Killing":
            killings.append(ts)
            seen_after_kill.discard(name)
            continue
        if reason != "Scheduled" or not killings:
            continue
        # Only count Scheduled that occur after a prior kill for this component.
        try:
            last_kill = max(
                (k for k in killings if _parse_utc(k) <= _parse_utc(ts)),
                default="",
            )
        except Exception:
            last_kill = ""
        if not last_kill:
            continue
        # One recovery per kill cycle.
        key = f"{name}:{last_kill}"
        if key in seen_after_kill:
            continue
        seen_after_kill.add(key)
        m = assign_re.search(raw.get("message") or "")
        node = m.group(1) if m else ""
        recovers.append({
            "timestamp": ts,
            "name": name,
            "node": node,
            "node_short": _short_node_name(node),
            "label": f"{name} ready on {_short_node_name(node)}",
        })
    return recovers


def _drain_failover_summary_rows(
    k8s_rows: list[K8sPodRow],
    run_dir: Path | None,
    failovers: list[dict[str, str]],
) -> list[dict[str, str]]:
    """Chronological drain/failover summary rows for the vertical-scale table.

    Includes failover-window companions (e.g. haproxy-1) that were folded into
    the Failover event-band label and would otherwise be invisible, plus
    HAProxy/binlog recovery (ready again + node).

    Companions are only combined onto a MySQL drain/failover row when they share
    the exact same HH:MM:SS timestamp; otherwise they get their own row.
    """
    # Unfiltered drains — keep companions for failover-overlap rows.
    all_drains = _detect_secondary_drains(k8s_rows, run_dir, failovers=None)
    chart_drains = _detect_secondary_drains(k8s_rows, run_dir, failovers=failovers)
    chart_keys = {(d["pod"], d["timestamp"]) for d in chart_drains}

    rows: list[dict[str, str]] = []
    emitted_proxy: set[tuple[str, str]] = set()  # (name, HH:MM:SS)

    def _emit_proxy_row(ts: str, name: str, what: str | None = None) -> None:
        key = (name, _ts_hhmmss(ts))
        if not key[1] or key in emitted_proxy:
            return
        emitted_proxy.add(key)
        rows.append({
            "sort_ts": ts,
            "time": key[1],
            "what": what or f"{name} drained",
        })

    for drain in all_drains:
        if (drain["pod"], drain["timestamp"]) not in chart_keys:
            continue
        drain_hhmmss = _ts_hhmmss(drain["timestamp"])
        companion_events = drain.get("companion_events") or []
        same_ts = [
            c["name"] for c in companion_events
            if _ts_hhmmss(c.get("timestamp", "")) == drain_hhmmss
        ]
        # Fallback for older drain dicts without companion_events.
        if not companion_events and drain.get("companions"):
            same_ts = [
                c.strip() for c in drain["companions"].split(",") if c.strip()
            ]

        what = f"mysql-{drain['pod']} drain"
        if same_ts:
            what += " + " + " + ".join(same_ts)
            for name in same_ts:
                emitted_proxy.add((name, drain_hhmmss))
        rows.append({
            "sort_ts": drain["timestamp"],
            "time": drain_hhmmss,
            "what": what,
        })
        for ce in companion_events:
            name = ce.get("name") or ""
            cts = ce.get("timestamp") or ""
            if not name or not cts or _ts_hhmmss(cts) == drain_hhmmss:
                continue
            _emit_proxy_row(cts, name)

    for fo in failovers:
        from_short = fo.get("from", "?")
        to_short = fo.get("to", "?")
        fo_ts = fo["timestamp"]
        fo_hhmmss = _ts_hhmmss(fo_ts)
        companion_events: list[dict[str, str]] = []
        for drain in all_drains:
            if drain["pod"] != from_short:
                continue
            try:
                delta = abs(
                    (_parse_utc(drain["timestamp"]) - _parse_utc(fo_ts)).total_seconds()
                )
            except Exception:
                continue
            if delta > 90:
                continue
            companion_events = list(drain.get("companion_events") or [])
            if not companion_events and drain.get("companions"):
                companion_events = [
                    {
                        "name": c.strip(),
                        "timestamp": drain.get("companion_first_ts") or fo_ts,
                    }
                    for c in drain["companions"].split(",")
                    if c.strip()
                ]
            break

        same_ts = [
            c["name"] for c in companion_events
            if _ts_hhmmss(c.get("timestamp", "")) == fo_hhmmss
        ]
        diff_ts = [
            c for c in companion_events
            if _ts_hhmmss(c.get("timestamp", "")) != fo_hhmmss
        ]

        for ce in diff_ts:
            _emit_proxy_row(ce["timestamp"], ce["name"], f"{ce['name']} killed")

        if same_ts:
            for name in same_ts:
                emitted_proxy.add((name, fo_hhmmss))
            rows.append({
                "sort_ts": fo_ts,
                "time": fo_hhmmss,
                "what": (
                    f"{' + '.join(same_ts)} killed, then "
                    f"Failover mysql-{from_short} → mysql-{to_short}"
                ),
            })
        else:
            rows.append({
                "sort_ts": fo_ts,
                "time": fo_hhmmss,
                "what": f"Failover mysql-{from_short} → mysql-{to_short}",
            })

    # Proxy/binlog drains during the monitor window that were not tied to a
    # same-second MySQL drain (e.g. HAProxy moved before secondary drain).
    for proxy in _detect_proxy_component_drains(k8s_rows, run_dir):
        _emit_proxy_row(proxy["timestamp"], proxy["name"], proxy["what"])

    # Recoveries only for components mentioned as drained/killed above.
    mentioned: dict[str, str] = {}  # name -> earliest kill/drain sort_ts
    for r in rows:
        what = r["what"]
        for token in re.findall(r"\b(haproxy-\d+|binlog-server)\b", what):
            if token not in mentioned or r["sort_ts"] < mentioned[token]:
                mentioned[token] = r["sort_ts"]

    known_slugs = _collect_run_slugs(k8s_rows)
    for rec in _detect_haproxy_recoveries(run_dir) + _detect_binlog_recoveries(run_dir):
        kill_ts = mentioned.get(rec["name"])
        if not kill_ts:
            continue
        if rec["timestamp"] < kill_ts:
            continue
        placement = _format_host_placement(
            k8s_rows, rec.get("node") or "", rec["timestamp"], known_slugs,
        )
        rows.append({
            "sort_ts": rec["timestamp"],
            "time": rec["timestamp"][11:19],
            "what": f"{rec['name']} ready on {placement}",
        })

    rows.sort(key=lambda r: r["sort_ts"])
    return rows


def _format_node_size(row: K8sPodRow) -> str | None:
    """Return e.g. '8 vCPU · 32 GB' when vCPU (and optionally RAM) are known."""
    if not row.vcpus or not row.vcpus.isdigit():
        return None
    mem_gb = _round_mem_gb(row.mem_gib, row.slug)
    if mem_gb is not None:
        return f"{row.vcpus} vCPU · {mem_gb} GB"
    return f"{row.vcpus} vCPU"


def _node_size_sort_key(label: str) -> tuple[int, int]:
    parts = label.split()
    vcpu = int(parts[0]) if parts and parts[0].isdigit() else 0
    ram = 0
    for i, part in enumerate(parts):
        if part == "GB" and i > 0:
            try:
                ram = int(round(float(parts[i - 1])))
            except ValueError:
                pass
            break
    return vcpu, ram


def _resolve_carry_forward_keys(
    pod_rows: list[K8sPodRow],
    raw_fn,
) -> list[str]:
    """Map each row to a key, reusing the last valid value when the current row is unknown."""
    keys: list[str] = []
    last: str | None = None
    for row in pod_rows:
        k = raw_fn(row)
        if k:
            last = k
        keys.append(last or "")
    return keys


def _cluster_primary_timeline(k8s_rows: list[K8sPodRow]) -> dict[str, str]:
    """Map each timestamp to the cluster PRIMARY pod (last PRIMARY seen at or before ts)."""
    primary_events: list[tuple[str, str]] = []
    for row in sorted(k8s_rows, key=lambda r: r.timestamp):
        if not _VALID_TS_RE.match(row.timestamp):
            continue
        if row.gr_role == "PRIMARY":
            primary_events.append((row.timestamp, row.pod))
    if not primary_events:
        return {}

    all_ts = sorted({r.timestamp for r in k8s_rows if _VALID_TS_RE.match(r.timestamp)})
    timeline: dict[str, str] = {}
    ei = 0
    current = ""
    for ts in all_ts:
        while ei < len(primary_events) and primary_events[ei][0] <= ts:
            current = primary_events[ei][1]
            ei += 1
        timeline[ts] = current
    return timeline


def _resolve_gr_role_keys(
    pod_rows: list[K8sPodRow],
    pod: str,
    cluster_tl: dict[str, str],
) -> list[str]:
    """Resolve GR role per row; infer from cluster primary when pod row is OFFLINE/corrupt."""
    keys: list[str] = []
    last_direct = ""
    for row in pod_rows:
        if row.gr_role in ("PRIMARY", "SECONDARY"):
            last_direct = row.gr_role
            keys.append(row.gr_role)
            continue
        cluster_primary = cluster_tl.get(row.timestamp, "")
        if cluster_primary == pod:
            keys.append("PRIMARY")
        elif cluster_primary:
            keys.append("SECONDARY")
        elif last_direct:
            keys.append(last_direct)
        else:
            keys.append("")
    return keys


def _segmentize_k8s_pod_rows(
    pod_rows: list[K8sPodRow],
    key_fn=None,
    carry_forward: bool = False,
    precomputed_keys: list[str] | None = None,
) -> list[dict[str, Any]]:
    segs: list[dict[str, Any]] = []
    if precomputed_keys is not None:
        keys = precomputed_keys
    elif carry_forward:
        keys = _resolve_carry_forward_keys(pod_rows, key_fn)
    else:
        keys = [key_fn(r) for r in pod_rows]

    seg_start = pod_rows[0].timestamp
    seg_key = keys[0]
    for row, k in zip(pod_rows[1:], keys[1:]):
        if k != seg_key:
            if seg_key:
                segs.append({"start": seg_start, "end": row.timestamp, "key": seg_key})
            seg_start = row.timestamp
            seg_key = k
    if seg_key:
        segs.append({"start": seg_start, "end": pod_rows[-1].timestamp, "key": seg_key})
    return segs


def _format_utc_dt(dt: datetime) -> str:
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    else:
        dt = dt.astimezone(timezone.utc)
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def _qps_down_intervals(metrics: list[MetricRow]) -> list[tuple[datetime, datetime]]:
    """Contiguous UTC intervals where benchmark QPS was zero."""
    if not metrics:
        return []
    sorted_m = sorted(metrics, key=lambda m: m.wall_clock_utc)
    intervals: list[tuple[datetime, datetime]] = []
    in_down = False
    start: datetime | None = None
    for m in sorted_m:
        ts = _parse_utc(m.wall_clock_utc)
        if m.qps == 0:
            if not in_down:
                start = ts
                in_down = True
        elif in_down and start is not None:
            intervals.append((start, ts))
            in_down = False
            start = None
    if in_down and start is not None:
        last = _parse_utc(sorted_m[-1].wall_clock_utc) + timedelta(seconds=1)
        intervals.append((start, last))
    return intervals


def _merge_adjacent_segments(segments: list[dict[str, Any]]) -> list[dict[str, Any]]:
    if not segments:
        return segments
    merged = [dict(segments[0])]
    for seg in segments[1:]:
        prev = merged[-1]
        if seg["key"] == prev["key"] and seg["start"] == prev["end"]:
            prev["end"] = seg["end"]
        else:
            merged.append(dict(seg))
    return merged


def _overlay_qps_offline_segments(
    segments: list[dict[str, Any]],
    qps_intervals: list[tuple[datetime, datetime]],
) -> list[dict[str, Any]]:
    """Split timeline segments and mark QPS-down windows as OFFLINE."""
    if not qps_intervals or not segments:
        return segments
    out: list[dict[str, Any]] = []
    for seg in segments:
        if not seg.get("key"):
            continue
        seg_start = _parse_utc(seg["start"])
        seg_end = _parse_utc(seg["end"])
        if seg_end <= seg_start:
            continue
        cut_points = [seg_start, seg_end]
        for q0, q1 in qps_intervals:
            if q1 <= seg_start or q0 >= seg_end:
                continue
            cut_points.extend([max(q0, seg_start), min(q1, seg_end)])
        cut_points = sorted(set(cut_points))
        for i in range(len(cut_points) - 1):
            a, b = cut_points[i], cut_points[i + 1]
            if b <= a:
                continue
            mid = a + (b - a) / 2
            offline = any(q0 <= mid < q1 for q0, q1 in qps_intervals)
            key = "OFFLINE" if offline else seg["key"]
            out.append({"start": _format_utc_dt(a), "end": _format_utc_dt(b), "key": key})
    return _merge_adjacent_segments(out)


# MySQL secondary drains stay blue; standalone HAProxy drains use amber/yellow.
_DRAIN_MYSQL_STYLE = {"color": "#0969da", "bg": "rgba(221,244,255,0.95)"}
_DRAIN_HAPROXY_STYLE = {"color": "#bf8700", "bg": "rgba(255,248,197,0.95)"}
_DRAIN_OTHER_PROXY_STYLE = {"color": "#8250df", "bg": "rgba(245,238,255,0.95)"}


def _is_haproxy_drain(drain: dict[str, Any]) -> bool:
    """True for standalone HAProxy drain markers (not MySQL drains with companions)."""
    if (drain.get("kind") or "").lower() == "haproxy":
        return True
    name = (drain.get("name") or drain.get("pod") or "").strip()
    if name.startswith("haproxy"):
        return True
    label = drain.get("label") or ""
    return label.startswith("HAProxy Drain")


def _drain_marker_style(drain: dict[str, Any]) -> dict[str, str]:
    """Line/label colors for a drain marker."""
    if drain.get("color") and drain.get("bg"):
        return {"color": drain["color"], "bg": drain["bg"]}
    if _is_haproxy_drain(drain):
        return dict(_DRAIN_HAPROXY_STYLE)
    label = drain.get("label") or ""
    if label.startswith("Binlog Drain") or label.startswith("Router Drain"):
        return dict(_DRAIN_OTHER_PROXY_STYLE)
    return dict(_DRAIN_MYSQL_STYLE)


def _collect_scale_events(
    timing: ScaleTiming,
    failovers: list[dict[str, str]],
    drains: list[dict[str, str]] | None = None,
) -> list[dict[str, Any]]:
    events: list[dict[str, Any]] = []
    if timing.scale_start_utc:
        events.append({
            "x": timing.scale_start_utc,
            "label": "Scale Start",
            "color": "#116329",
            "bg": "rgba(218,251,225,0.95)",
        })
    if timing.scale_complete_utc:
        events.append({
            "x": timing.scale_complete_utc,
            "label": "Scale Complete",
            "color": "#9467bd",
            "bg": "rgba(237,232,246,0.95)",
        })
    for fo in failovers:
        events.append({
            "x": fo["timestamp"],
            "label": fo["label"],
            "color": "#cf222e",
            "bg": "rgba(255,235,233,0.95)",
        })
    for drain in drains or []:
        style = _drain_marker_style(drain)
        events.append({
            "x": drain["timestamp"],
            "label": drain["label"],
            "color": style["color"],
            "bg": style["bg"],
        })
    return events


def _with_separate_proxy_drain_markers(
    drains: list[dict[str, str]],
    k8s_rows: list[K8sPodRow] | None = None,
    run_dir: Path | None = None,
) -> list[dict[str, str]]:
    """Append separately-timed HAProxy/binlog drains as their own chart markers.

    Same-second companions stay on the MySQL drain label; different-second (or
    fully standalone) proxy moves get their own marker/label.
    """
    out: list[dict[str, str]] = list(drains or [])
    emitted: set[tuple[str, str]] = set()

    for drain in drains or []:
        drain_hhmmss = _ts_hhmmss(drain["timestamp"])
        for name in (drain.get("companions") or "").split(","):
            name = name.strip()
            if name and drain_hhmmss:
                emitted.add((name, drain_hhmmss))
        for ce in drain.get("companion_events") or []:
            name = (ce.get("name") or "").strip()
            ts = ce.get("timestamp") or ""
            hh = _ts_hhmmss(ts)
            if not name or not hh or hh == drain_hhmmss:
                continue
            if (name, hh) in emitted:
                continue
            emitted.add((name, hh))
            kind = (
                "HAProxy" if name.startswith("haproxy")
                else "Binlog" if name.startswith("binlog")
                else "Router"
            )
            marker = {
                "timestamp": ts,
                "pod": "",
                "name": name,
                "label": f"{kind} Drain {name}",
                "kind": "haproxy" if kind == "HAProxy" else kind.lower(),
            }
            marker.update(_drain_marker_style(marker))
            out.append(marker)

    if k8s_rows is not None and run_dir is not None:
        for proxy in _detect_proxy_component_drains(k8s_rows, run_dir):
            key = (proxy["name"], _ts_hhmmss(proxy["timestamp"]))
            if not key[1] or key in emitted:
                continue
            emitted.add(key)
            marker = {
                "timestamp": proxy["timestamp"],
                "pod": "",
                "name": proxy["name"],
                "label": proxy["label"],
                "kind": (
                    "haproxy" if proxy["name"].startswith("haproxy")
                    else "binlog" if proxy["name"].startswith("binlog")
                    else "router"
                ),
            }
            marker.update(_drain_marker_style(marker))
            out.append(marker)
    return out


def _subplot_y_domain(row: int) -> str:
    return "y domain" if row == 1 else f"y{row} domain"


def _add_subplot_vline(
    fig: go.Figure,
    x: str,
    row: int,
    *,
    color: str,
    dash: str,
    width: float = 2,
) -> None:
    """Vertical event marker on one subplot row (shapes render above bar traces)."""
    fig.add_shape(
        type="line",
        x0=x, x1=x, y0=0, y1=1,
        xref="x", yref=_subplot_y_domain(row),
        line=dict(color=color, dash=dash, width=width),
        layer="above",
    )


def _add_scale_event_vlines(
    fig: go.Figure,
    timing: ScaleTiming,
    failovers: list[dict[str, str]],
    rows: list[int],
    drains: list[dict[str, str]] | None = None,
) -> None:
    """Add scale start/complete, failover, and secondary-drain markers to subplot rows."""
    for row_idx in rows:
        if timing.scale_start_utc:
            _add_subplot_vline(
                fig, timing.scale_start_utc, row_idx,
                color="#116329", dash="dash", width=2,
            )
        if timing.scale_complete_utc:
            _add_subplot_vline(
                fig, timing.scale_complete_utc, row_idx,
                color="#9467bd", dash="dash", width=2,
            )
        for fo in failovers:
            _add_subplot_vline(
                fig, fo["timestamp"], row_idx,
                color="#cf222e", dash="dot", width=2,
            )
        for drain in drains or []:
            _add_subplot_vline(
                fig, drain["timestamp"], row_idx,
                color=_drain_marker_style(drain)["color"], dash="dot", width=2,
            )


def _event_label_interval(evt: dict[str, Any], px_per_sec: float) -> tuple[datetime, datetime]:
    label_px = len(evt["label"]) * 6.5 + 28
    half_sec = (label_px / 2) / max(px_per_sec, 1e-9)
    center = _parse_utc(evt["x"])
    return center - timedelta(seconds=half_sec), center + timedelta(seconds=half_sec)


def _assign_event_rows(
    events: list[dict[str, Any]],
    t_start: str,
    t_end: str,
    width_px: int = 960,
) -> int:
    """Assign non-overlapping rows to event labels; returns row count."""
    if not events:
        return 0

    span_sec = max(
        (_parse_utc(t_end) - _parse_utc(t_start)).total_seconds(),
        60,
    )
    px_per_sec = width_px / span_sec
    rows: list[list[dict[str, Any]]] = []

    for evt in sorted(events, key=lambda e: e["x"]):
        placed = False
        for row_idx, row in enumerate(rows):
            evt_iv = _event_label_interval(evt, px_per_sec)
            if all(
                evt_iv[1] <= _event_label_interval(other, px_per_sec)[0]
                or evt_iv[0] >= _event_label_interval(other, px_per_sec)[1]
                for other in row
            ):
                row.append(evt)
                evt["row"] = row_idx
                placed = True
                break
        if not placed:
            evt["row"] = len(rows)
            rows.append([evt])

    return len(rows)


def _prepare_event_band(
    timing: ScaleTiming,
    failovers: list[dict[str, str]],
    t_start: str,
    t_end: str,
    drains: list[dict[str, str]] | None = None,
) -> tuple[int, list[dict[str, Any]]]:
    """Return (band_height_px, events with row assignments)."""
    row_h = 26
    band_pad = 8
    events = _collect_scale_events(timing, failovers, drains)
    if not events or not t_start or not t_end:
        return 0, []
    n_rows = _assign_event_rows(events, t_start, t_end)
    return band_pad + n_rows * row_h + 4, events


def _render_event_band(
    fig: go.Figure,
    events: list[dict[str, Any]],
    plot_h_px: int,
) -> None:
    """Draw event labels and connector lines above the plot (y=1 paper)."""
    row_h = 26
    band_pad = 8
    for evt in events:
        label_y = 1 + (band_pad + (evt["row"] + 1) * row_h) / max(1, plot_h_px)
        fig.add_shape(
            type="line",
            x0=evt["x"], x1=evt["x"],
            y0=1, y1=label_y,
            xref="x", yref="paper",
            line=dict(color=evt["color"], width=1.5),
            layer="above",
        )
        fig.add_annotation(
            x=evt["x"], xref="x",
            y=label_y, yref="paper",
            text=evt["label"],
            showarrow=False,
            xanchor="center", yanchor="bottom",
            font=dict(size=10, color=evt["color"], family="monospace"),
            bgcolor=evt["bg"],
            bordercolor=evt["color"], borderwidth=1, borderpad=3,
        )


def _add_timeline_event_band(
    fig: go.Figure,
    timing: ScaleTiming,
    failovers: list[dict[str, str]],
    plot_h_px: int,
    t_start: str,
    t_end: str,
    drains: list[dict[str, str]] | None = None,
) -> int:
    """Place scale/failover/drain labels above the plot with connector lines to y=1."""
    band_h, events = _prepare_event_band(timing, failovers, t_start, t_end, drains)
    if events:
        _render_event_band(fig, events, plot_h_px)
    return band_h


_MYSQL_POD_RE = re.compile(r"-mysql-(\d+)$")
_VALID_TS_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T")


def _discover_mysql_pods(
    k8s_rows: list[K8sPodRow],
) -> tuple[list[str], dict[str, str]]:
    """Return real mysql-N pods only; ignore corrupted TSV pod/node fragments."""
    from collections import Counter

    counts: Counter[str] = Counter()
    shorts: dict[str, str] = {}
    for row in k8s_rows:
        if not _VALID_TS_RE.match(row.timestamp):
            continue
        m = _MYSQL_POD_RE.search(row.pod)
        if not m:
            continue
        counts[row.pod] += 1
        shorts[row.pod] = m.group(1)

    if not counts:
        return [], {}

    max_n = max(counts.values())
    threshold = max(100, int(max_n * 0.25))
    pods = sorted(
        (p for p, n in counts.items() if n >= threshold),
        key=lambda p: int(shorts[p]),
    )
    return pods, {p: shorts[p] for p in pods}


def _filter_k8s_rows_for_pods(
    k8s_rows: list[K8sPodRow], pods: list[str],
) -> list[K8sPodRow]:
    valid = set(pods)
    return [r for r in k8s_rows if r.pod in valid]


POD_BADGE_STYLES: dict[str, dict[str, str]] = {
    "PRIMARY": {"bg": "rgba(218,251,225,0.95)", "color": "#116329", "border": "#116329"},
    "SECONDARY": {"bg": "rgba(221,244,255,0.95)", "color": "#0969da", "border": "#0969da"},
    # Legacy aliases kept for older call sites / CSS fallbacks.
    "old primary": {"bg": "rgba(221,244,255,0.95)", "color": "#0969da", "border": "#0969da"},
    "new primary": {"bg": "rgba(218,251,225,0.95)", "color": "#116329", "border": "#116329"},
}


def _latest_gr_roles(k8s_rows: list[K8sPodRow]) -> dict[str, str]:
    """Return pod -> latest known PRIMARY/SECONDARY role from member status."""
    latest: dict[str, str] = {}
    for row in sorted(k8s_rows, key=lambda r: r.timestamp):
        if row.gr_role in ("PRIMARY", "SECONDARY"):
            latest[row.pod] = row.gr_role
    return latest


def _compute_pod_badge_labels(
    k8s_rows: list[K8sPodRow],
    pods: list[str],
    pod_short: dict[str, str],
) -> dict[str, str]:
    """Map mysql-N -> badge text from the latest GR member role."""
    latest_roles = _latest_gr_roles(k8s_rows)
    labels: dict[str, str] = {}
    for pod in pods:
        y_id = f"mysql-{pod_short[pod]}"
        labels[y_id] = latest_roles.get(pod, "SECONDARY")
    return labels


def _add_pod_row_labels(
    fig: go.Figure,
    pods: list[str],
    pod_short: dict[str, str],
    badge_labels: dict[str, str],
) -> None:
    """Badge on the far left, pod name just before the plot — no overlap."""
    for pod in pods:
        y_id = f"mysql-{pod_short[pod]}"
        badge_text = badge_labels.get(y_id, "SECONDARY")
        style = POD_BADGE_STYLES.get(badge_text, POD_BADGE_STYLES["SECONDARY"])

        fig.add_annotation(
            xref="paper", yref="y",
            x=0, y=y_id,
            xanchor="right", yanchor="middle",
            xshift=-88,
            text=badge_text,
            showarrow=False,
            font=dict(size=9, color=style["color"], family="monospace"),
            bgcolor=style["bg"],
            bordercolor=style["border"],
            borderwidth=1,
            borderpad=4,
        )
        fig.add_annotation(
            xref="paper", yref="y",
            x=0, y=y_id,
            xanchor="right", yanchor="middle",
            xshift=-6,
            text=y_id,
            showarrow=False,
            font=dict(size=11, color="#1f2328", family="monospace"),
        )


def _build_pod_timeline_figure(
    title: str,
    k8s_rows: list[K8sPodRow],
    timing: ScaleTiming,
    failovers: list[dict[str, str]],
    pods: list[str],
    pod_short: dict[str, str],
    key_fn,
    color_map: dict[str, str],
    label_fn=None,
    show_bar_text: bool = False,
    carry_forward: bool = False,
    pod_badge_labels: dict[str, str] | None = None,
    cluster_tl: dict[str, str] | None = None,
    qps_down_intervals: list[tuple[datetime, datetime]] | None = None,
    drains: list[dict[str, str]] | None = None,
) -> go.Figure | None:
    """Build a single Plotly horizontal-bar Gantt with optional bar text, event lines, and annotations."""
    _TS_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T")
    display_fn = label_fn or (lambda k: k)

    fig = go.Figure()
    legend_seen: set[str] = set()
    pod_count = 0
    all_starts: list[str] = []
    all_ends: list[str] = []

    for pod in pods:
        pr = sorted(
            [r for r in k8s_rows if r.pod == pod and _TS_RE.match(r.timestamp)],
            key=lambda r: r.timestamp,
        )
        if len(pr) < 2:
            continue
        pod_count += 1
        y_id = f"mysql-{pod_short[pod]}"
        y_label = y_id
        if cluster_tl is not None:
            precomputed = _resolve_gr_role_keys(pr, pod, cluster_tl)
            segments = _segmentize_k8s_pod_rows(pr, precomputed_keys=precomputed)
        else:
            segments = _segmentize_k8s_pod_rows(pr, key_fn, carry_forward=carry_forward)
        if qps_down_intervals:
            segments = _overlay_qps_offline_segments(segments, qps_down_intervals)
        for seg in segments:
            key = seg["key"]
            display = display_fn(key)
            color = color_map.get(key, "#8b949e")
            show_legend = key not in legend_seen
            legend_seen.add(key)

            all_starts.append(seg["start"])
            all_ends.append(seg["end"])
            dur_ms = max(
                (_parse_utc(seg["end"]) - _parse_utc(seg["start"])).total_seconds() * 1000,
                1,
            )
            dur_sec = max(
                (_parse_utc(seg["end"]) - _parse_utc(seg["start"])).total_seconds(),
                0,
            )
            hover = (
                f"{y_id}<br>{seg['start'][11:19]}–{seg['end'][11:19]} UTC"
                f"<br>Duration: {_fmt_duration(dur_sec)}"
                f"<br><b>{html_mod.escape(display)}</b>"
            )

            fig.add_trace(go.Bar(
                x=[dur_ms],
                y=[y_label],
                base=[seg["start"]],
                orientation="h",
                marker=dict(color=color, line=dict(width=0)),
                width=0.55,
                name=display,
                legendgroup=key,
                showlegend=show_legend,
                text=[display if show_bar_text else ""],
                textposition="inside" if show_bar_text else "none",
                insidetextanchor="middle",
                textfont=dict(color="white", size=10, family="monospace"),
                constraintext="none",
                hovertext=[hover],
                hoverinfo="text",
            ))

    if pod_count == 0:
        return None

    if all_starts and all_ends:
        span_ms = max(
            (_parse_utc(max(all_ends)) - _parse_utc(min(all_starts))).total_seconds() * 1000,
            1,
        )
        min_text_ms = max(90_000, span_ms * 0.025)
        if show_bar_text:
            for trace in fig.data:
                if trace.x and trace.x[0] < min_text_ms:
                    trace.text = [""]
        t_start = min(all_starts)
        t_end = max(all_ends)
    else:
        t_start = t_end = ""

    plot_h = pod_count * 52
    legend_count = len(legend_seen)
    title_h = 34
    bottom_margin = 58 if legend_count <= 4 else 24
    right_margin = 24 if legend_count <= 4 else 130

    event_band_h, event_items = _prepare_event_band(
        timing, failovers, t_start, t_end, drains,
    )
    top_margin = title_h + event_band_h + 14
    total_h = max(280, plot_h + top_margin + bottom_margin + 20)
    actual_plot_h = total_h - top_margin - bottom_margin
    if event_items:
        _render_event_band(fig, event_items, actual_plot_h)

    if timing.scale_start_utc:
        fig.add_vline(
            x=timing.scale_start_utc, line_dash="dash",
            line_color="#116329", line_width=2,
        )
    if timing.scale_complete_utc:
        fig.add_vline(
            x=timing.scale_complete_utc, line_dash="dash",
            line_color="#9467bd", line_width=2,
        )
    for fo in failovers:
        fig.add_vline(
            x=fo["timestamp"], line_dash="dot",
            line_color="#cf222e", line_width=2,
        )
    for drain in drains or []:
        fig.add_vline(
            x=drain["timestamp"], line_dash="dot",
            line_color=_drain_marker_style(drain)["color"], line_width=2,
        )

    legend_count = len(legend_seen)
    left_margin = 230 if pod_badge_labels else 100
    if legend_count <= 4:
        legend_cfg = dict(
            orientation="h",
            x=0, xanchor="left",
            y=-0.22, yanchor="top",
            yref="paper",
            font=dict(size=10),
            tracegroupgap=10,
            itemwidth=30,
            bgcolor="rgba(255,255,255,0.92)",
            bordercolor="#d0d7de",
            borderwidth=1,
        )
    else:
        legend_cfg = dict(
            orientation="v",
            x=1.01, xanchor="left",
            y=1, yanchor="top",
            yref="paper",
            font=dict(size=9),
            tracegroupgap=4,
            bgcolor="rgba(255,255,255,0.92)",
            bordercolor="#d0d7de",
            borderwidth=1,
        )

    fig.update_layout(
        barmode="overlay",
        dragmode="zoom",
        hovermode="closest",
        height=total_h,
        margin=dict(l=left_margin, r=right_margin, t=top_margin, b=bottom_margin),
        title=dict(
            text=title, font=dict(size=14),
            x=0, xanchor="left",
            pad=dict(b=8),
        ),
        legend=legend_cfg,
        xaxis=dict(type="date", title="Time (UTC)", gridcolor="#eaeef2"),
        yaxis=dict(
            categoryorder="array",
            categoryarray=[f"mysql-{pod_short[p]}" for p in reversed(pods)],
            title="",
            gridcolor="#eaeef2",
            showticklabels=not pod_badge_labels,
        ),
        plot_bgcolor="#fafbfc",
        paper_bgcolor="#ffffff",
    )

    if pod_badge_labels:
        _add_pod_row_labels(fig, pods, pod_short, pod_badge_labels)

    return fig


def build_k8s_status_bars(
    k8s_rows: list[K8sPodRow], timing: ScaleTiming,
    run_dir: Path | None = None,
    metrics: list[MetricRow] | None = None,
) -> str:
    """PMM-style zoomable Plotly timeline charts with bar text, Scale/Failover annotations."""
    if not k8s_rows:
        return ""

    _TS_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T")
    pods, pod_short = _discover_mysql_pods(k8s_rows)
    if not pods:
        return ""
    k8s_rows = _filter_k8s_rows_for_pods(k8s_rows, pods)

    horizontal = _is_horizontal_scale(timing)
    vertical = _is_vertical_scale(timing)
    failovers = _resolve_failovers(k8s_rows, run_dir)
    drains = _detect_secondary_drains(k8s_rows, run_dir, failovers=failovers)
    drains = _with_separate_proxy_drain_markers(drains, k8s_rows, run_dir)
    qps_down = _qps_down_intervals(metrics or [])

    role_colors = {"PRIMARY": "#2da44e", "SECONDARY": "#0969da"}
    state_colors = {
        "ONLINE": "#2da44e", "RECOVERING": "#f0883e",
        "POD INITIALIZING": "#e3b341", "ERROR": "#cf222e", "OFFLINE": "#8b949e",
    }
    slug_palette = ["#0969da", "#2da44e", "#d62728", "#9467bd", "#f0883e", "#8c564b"]

    def _resolve_state(row: K8sPodRow) -> str | None:
        if row.gr_state in ("ONLINE", "RECOVERING", "ERROR"):
            return row.gr_state
        # PodInitializing is more specific than a failed GR lookup placeholder.
        if "PodInitializing" in (row.gr_detail or ""):
            return "POD INITIALIZING"
        if row.phase == "Pending" or (row.phase == "Running" and row.ready == "false"):
            return "POD INITIALIZING"
        # Monitor writes "?\t?\t" (and deleting=yes) while the member is offline.
        if _is_offline_gr_token(row.gr_state) or row.deleting == "yes":
            return "OFFLINE"
        return None

    def _gr_role_key(row: K8sPodRow) -> str | None:
        return row.gr_role if row.gr_role in ("PRIMARY", "SECONDARY") else None

    pod_badge_labels = _compute_pod_badge_labels(k8s_rows, pods, pod_short)
    cluster_tl = _cluster_primary_timeline(k8s_rows)

    common = dict(
        k8s_rows=k8s_rows, timing=timing, failovers=failovers,
        pods=pods, pod_short=pod_short,
        pod_badge_labels=pod_badge_labels,
        drains=drains,
    )

    role_fig = _build_pod_timeline_figure(
        "GR Role", **common,
        key_fn=_gr_role_key,
        color_map=role_colors,
        show_bar_text=True,
        cluster_tl=cluster_tl,
    )
    state_fig = _build_pod_timeline_figure(
        "GR State", **common,
        key_fn=_resolve_state, color_map=state_colors,
        show_bar_text=True,
        carry_forward=True,
        qps_down_intervals=qps_down,
    )

    if vertical:
        node_size_keys: list[str] = []
        node_size_seen: set[str] = set()
        for pod in pods:
            pr = sorted(
                [r for r in k8s_rows if r.pod == pod and _TS_RE.match(r.timestamp)],
                key=lambda r: r.timestamp,
            )
            for k in _resolve_carry_forward_keys(pr, _format_node_size):
                if k and k not in node_size_seen:
                    node_size_seen.add(k)
                    node_size_keys.append(k)
        node_size_keys.sort(key=_node_size_sort_key)
        node_size_colors = {
            k: slug_palette[i % len(slug_palette)] for i, k in enumerate(node_size_keys)
        }
        scale_fig = _build_pod_timeline_figure(
            "Node vCPU & RAM",
            **common, key_fn=_format_node_size, color_map=node_size_colors,
            show_bar_text=True,
            carry_forward=True,
        )
    elif horizontal:
        members_colors = {"3": "#2da44e", "2": "#d29922", "1": "#cf222e", "0": "#8b949e"}
        member_display = {f"{k} MEMBERS": v for k, v in members_colors.items()}

        def _member_key(r: K8sPodRow) -> str:
            m = r.gr_members if r.gr_members and r.gr_members.isdigit() else "0"
            return f"{m} MEMBERS"

        scale_fig = _build_pod_timeline_figure(
            "GR Group Members", **common,
            key_fn=_member_key, color_map=member_display,
        )
    else:
        def _pvc_key(r: K8sPodRow) -> str:
            cap = r.pvc_cap or r.pvc_req or ""
            if cap.endswith("Gi"):
                return f"{cap[:-2]} GiB"
            return cap or "UNKNOWN"

        pvc_vals = sorted(
            {_pvc_key(r) for r in k8s_rows if _TS_RE.match(r.timestamp)} - {"UNKNOWN"},
        )
        pvc_colors = {k: slug_palette[i % len(slug_palette)] for i, k in enumerate(pvc_vals)}
        pvc_colors["UNKNOWN"] = "#8b949e"
        scale_fig = _build_pod_timeline_figure(
            "PVC Capacity", **common,
            key_fn=_pvc_key, color_map=pvc_colors,
        )

    _plotly_config = {"scrollZoom": True, "displayModeBar": True, "responsive": True}
    charts_html = ""
    for fig, div_id in [
        (role_fig, "status-role"),
        (state_fig, "status-state"),
        (scale_fig, "status-scale"),
    ]:
        if fig is None:
            continue
        charts_html += (
            f'<div class="chart-box" style="margin-top:12px;">'
            f'{fig.to_html(full_html=False, include_plotlyjs=False, div_id=div_id, config=_plotly_config)}'
            f"</div>"
        )

    if not charts_html:
        return ""

    return f"""
    <section>
      <h2 class="section-title">Pod GR Status Timeline</h2>
      {charts_html}
    </section>"""


def _safe_metric_int(val: str) -> int | None:
    """Parse numeric k8s monitor fields, skipping malformed values like '?'."""
    cleaned = (val or "").strip().strip("?\t ")
    if not cleaned or not cleaned.isdigit():
        return None
    return int(cleaned)


def _read_only_gantt_key(row: K8sPodRow) -> str | None:
    ro = _safe_metric_int(row.read_only)
    sro = _safe_metric_int(row.super_read_only)
    if ro is None:
        return None
    if ro == 0:
        return "WRITABLE"
    if sro == 1:
        return "READ-ONLY"
    return "ro=1 only"


def _read_only_gantt_label(key: str) -> str:
    if key == "WRITABLE":
        return "ro=0, sro=0"
    if key == "READ-ONLY":
        return "ro=1, sro=1"
    return key


READ_ONLY_GANTT_COLORS = {
    "WRITABLE": "#2da44e",
    "READ-ONLY": "#0969da",
    "ro=1 only": "#f0883e",
}


def build_replication_queue_figure(
    k8s_rows: list[K8sPodRow],
    timing: ScaleTiming,
    failovers: list[dict[str, str]],
    drains: list[dict[str, str]] | None = None,
) -> go.Figure | None:
    """Line charts for GR certification queue, applier queue, and parallel workers."""
    pods, pod_short = _discover_mysql_pods(k8s_rows)
    if not pods:
        return None
    k8s_rows = _filter_k8s_rows_for_pods(k8s_rows, pods)

    has_workers = any(
        _safe_metric_int(r.replica_parallel_workers) is not None
        or _safe_metric_int(r.replica_parallel_active) is not None
        for r in k8s_rows
    )
    num_rows = 3 if has_workers else 2
    subplot_titles = [
        "GR Certification Queue (transactions pending certification)",
        "GR Applier Queue (transactions behind on applier)",
    ]
    if has_workers:
        subplot_titles.append(
            "Parallel Applier Workers (configured vs active)"
        )

    fig = make_subplots(
        rows=num_rows,
        cols=1,
        shared_xaxes=True,
        vertical_spacing=0.06,
        subplot_titles=tuple(subplot_titles),
    )

    pod_colors = ["#0969da", "#d62728", "#2ca02c", "#9467bd", "#8c564b"]
    has_data = False

    for idx, pod in enumerate(pods):
        pod_rows = sorted(
            [r for r in k8s_rows if r.pod == pod and r.timestamp and "T" in r.timestamp],
            key=lambda r: r.timestamp,
        )
        if not pod_rows:
            continue

        label = f"mysql-{pod_short[pod]}"
        color = pod_colors[idx % len(pod_colors)]

        cert_times: list[str] = []
        cert_vals: list[int] = []
        applier_times: list[str] = []
        applier_vals: list[int] = []
        rpw_cfg_times: list[str] = []
        rpw_cfg_vals: list[int] = []
        rpw_active_times: list[str] = []
        rpw_active_vals: list[int] = []

        for r in pod_rows:
            cert = _safe_metric_int(r.gr_queue)
            if cert is not None:
                cert_times.append(r.timestamp)
                cert_vals.append(cert)
            applier = _safe_metric_int(r.gr_applier_queue)
            if applier is not None:
                applier_times.append(r.timestamp)
                applier_vals.append(applier)
            rpw_cfg = _safe_metric_int(r.replica_parallel_workers)
            if rpw_cfg is not None:
                rpw_cfg_times.append(r.timestamp)
                rpw_cfg_vals.append(rpw_cfg)
            rpw_act = _safe_metric_int(r.replica_parallel_active)
            if rpw_act is not None:
                rpw_active_times.append(r.timestamp)
                rpw_active_vals.append(rpw_act)

        if cert_times:
            has_data = True
            fig.add_trace(go.Scatter(
                x=cert_times, y=cert_vals,
                mode="lines+markers", name=label,
                line=dict(width=2, color=color),
                marker=dict(size=4),
                legendgroup=label, showlegend=True,
            ), row=1, col=1)

        if applier_times:
            has_data = True
            fig.add_trace(go.Scatter(
                x=applier_times, y=applier_vals,
                mode="lines+markers", name=label,
                line=dict(width=2, color=color),
                marker=dict(size=4),
                legendgroup=label, showlegend=False,
            ), row=2, col=1)

        if has_workers and rpw_cfg_times:
            has_data = True
            fig.add_trace(go.Scatter(
                x=rpw_cfg_times, y=rpw_cfg_vals,
                mode="lines", name=f"{label} configured",
                line=dict(width=2, color=color, dash="dash"),
                legendgroup=label, showlegend=False,
                hovertemplate=f"{label} configured: %{{y}}<extra></extra>",
            ), row=3, col=1)

        if has_workers and rpw_active_times:
            has_data = True
            fig.add_trace(go.Scatter(
                x=rpw_active_times, y=rpw_active_vals,
                mode="lines+markers", name=f"{label} active",
                line=dict(width=2, color=color),
                marker=dict(size=4),
                legendgroup=label, showlegend=False,
                hovertemplate=f"{label} active: %{{y}}<extra></extra>",
            ), row=3, col=1)

    if not has_data:
        return None

    _add_scale_event_vlines(fig, timing, failovers, list(range(1, num_rows + 1)), drains)

    fig.update_layout(
        height=340 * num_rows,
        hovermode="x unified",
        margin=dict(t=60, b=40),
        legend=dict(orientation="h", yanchor="bottom", y=1.02, x=0),
    )
    fig.update_yaxes(title_text="Queue depth", row=1, col=1)
    fig.update_yaxes(title_text="Queue depth", row=2, col=1)
    if has_workers:
        fig.update_yaxes(title_text="Workers", rangemode="tozero", row=3, col=1)
    fig.update_xaxes(title_text="Time (UTC)", row=num_rows, col=1)

    return fig


def render_replication_lag_section(
    k8s_rows: list[K8sPodRow],
    timing: ScaleTiming,
    run_dir: Path | None = None,
) -> str:
    """GR queue line charts + read_only/super_read_only Gantt timeline."""
    if not k8s_rows:
        return ""

    pods, pod_short = _discover_mysql_pods(k8s_rows)
    if not pods:
        return ""
    k8s_rows = _filter_k8s_rows_for_pods(k8s_rows, pods)
    failovers = _resolve_failovers(k8s_rows, run_dir)
    drains = _detect_secondary_drains(k8s_rows, run_dir, failovers=failovers)
    drains = _with_separate_proxy_drain_markers(drains, k8s_rows, run_dir)

    queue_fig = build_replication_queue_figure(k8s_rows, timing, failovers, drains)
    ro_fig = _build_pod_timeline_figure(
        "Read-Only Status (read_only / super_read_only)",
        k8s_rows=k8s_rows,
        timing=timing,
        failovers=failovers,
        pods=pods,
        pod_short=pod_short,
        key_fn=_read_only_gantt_key,
        color_map=READ_ONLY_GANTT_COLORS,
        label_fn=_read_only_gantt_label,
        show_bar_text=True,
        carry_forward=True,
        drains=drains,
    )

    if queue_fig is None and ro_fig is None:
        return ""

    _plotly_config = {"scrollZoom": True, "displayModeBar": True, "responsive": True}
    charts_html = ""
    if queue_fig is not None:
        charts_html += (
            '<div class="chart-box" style="margin-top:12px;">'
            f'{queue_fig.to_html(full_html=False, include_plotlyjs=False, div_id="replication-queues", config=_plotly_config)}'
            "</div>"
        )
    if ro_fig is not None:
        charts_html += (
            '<div class="chart-box" style="margin-top:12px;">'
            f'{ro_fig.to_html(full_html=False, include_plotlyjs=False, div_id="replication-readonly", config=_plotly_config)}'
            "</div>"
        )

    return f"""
    <section>
      <h2 class="section-title">GR Replication Lag</h2>
      <p>Queue depth over time (line charts) and read-only / super-read-only state per pod (Gantt timeline).</p>
      {charts_html}
    </section>"""


@dataclass
class HaproxyConnRow:
    timestamp: str
    pod: str
    curr_conns: float
    cum_conns: float = 0.0
    mysql_primary_scur: float = 0.0


def load_haproxy_conns(path: Path) -> list[HaproxyConnRow]:
    """Load per-pod HAProxy session counts from k8s_monitor/haproxy_conns.tsv."""
    if not path.is_file():
        return []
    rows: list[HaproxyConnRow] = []
    with path.open(encoding="utf-8", errors="replace", newline="") as f:
        for raw in csv.DictReader(f, delimiter="\t"):
            ts = (raw.get("timestamp") or "").strip()
            pod = (raw.get("pod") or "").strip()
            if not ts or not pod or not _VALID_TS_RE.match(ts):
                continue
            try:
                curr = float(raw.get("curr_conns") or 0)
            except ValueError:
                continue
            try:
                cum = float(raw.get("cum_conns") or 0)
            except ValueError:
                cum = 0.0
            try:
                primary_scur = float(raw.get("mysql_primary_scur") or 0)
            except ValueError:
                primary_scur = 0.0
            rows.append(HaproxyConnRow(
                timestamp=ts, pod=pod, curr_conns=curr, cum_conns=cum,
                mysql_primary_scur=primary_scur,
            ))
    return rows


def build_haproxy_conns_figure(
    rows: list[HaproxyConnRow],
    timing: ScaleTiming,
    failovers: list[dict[str, str]] | None = None,
    drains: list[dict[str, str]] | None = None,
) -> go.Figure | None:
    """Line charts of curr_conns and mysql_primary_scur per HAProxy pod."""
    if not rows:
        return None

    by_pod: dict[str, list[HaproxyConnRow]] = {}
    for r in rows:
        by_pod.setdefault(r.pod, []).append(r)

    palette = ["#bf8700", "#0969da", "#2da44e", "#d62728", "#9467bd", "#8c564b"]
    fig = make_subplots(
        rows=2, cols=1, shared_xaxes=True, vertical_spacing=0.08,
        subplot_titles=(
            "HAProxy curr_conns (frontend sessions)",
            "mysql_primary_scur (backend sessions to PRIMARY)",
        ),
    )
    for idx, pod in enumerate(sorted(by_pod, key=_component_short_name)):
        series = sorted(by_pod[pod], key=lambda r: r.timestamp)
        label = _component_short_name(pod)
        color = palette[idx % len(palette)]
        times = [r.timestamp for r in series]
        fig.add_trace(go.Scatter(
            x=times,
            y=[r.curr_conns for r in series],
            mode="lines",
            name=label,
            legendgroup=label,
            line=dict(width=2, color=color),
            hovertemplate=f"{label} curr_conns: %{{y}}<extra></extra>",
        ), row=1, col=1)
        fig.add_trace(go.Scatter(
            x=times,
            y=[r.mysql_primary_scur for r in series],
            mode="lines",
            name=label,
            legendgroup=label,
            showlegend=False,
            line=dict(width=2, color=color),
            hovertemplate=f"{label} mysql_primary_scur: %{{y}}<extra></extra>",
        ), row=2, col=1)

    failovers = failovers or []
    drains = drains or []
    _add_scale_event_vlines(fig, timing, failovers, [1, 2], drains)

    t_start = min(r.timestamp for r in rows)
    t_end = max(r.timestamp for r in rows)
    event_band_h, event_items = _prepare_event_band(
        timing, failovers, t_start, t_end, drains,
    )
    plot_h = 520
    top_margin = 56 + event_band_h
    if event_items:
        _render_event_band(fig, event_items, plot_h)

    fig.update_layout(
        height=plot_h + event_band_h,
        hovermode="x unified",
        margin=dict(t=top_margin, b=50, l=60, r=24),
        legend=dict(orientation="h", yanchor="bottom", y=1.02, x=0),
        plot_bgcolor="#fafbfc",
        paper_bgcolor="#ffffff",
    )
    fig.update_yaxes(title_text="curr_conns", rangemode="tozero", row=1, col=1)
    fig.update_yaxes(title_text="primary scur", rangemode="tozero", row=2, col=1)
    fig.update_xaxes(title_text="Time (UTC)", row=2, col=1)
    return fig


def render_haproxy_conns_section(
    run_dir: Path | None,
    timing: ScaleTiming,
    k8s_rows: list[K8sPodRow] | None = None,
) -> str:
    """HAProxy curr_conns + mysql_primary_scur from k8s_monitor/haproxy_conns.tsv."""
    if run_dir is None:
        return ""
    path = run_dir / "k8s_monitor" / "haproxy_conns.tsv"
    rows = load_haproxy_conns(path)
    if not rows:
        return ""

    failovers = _resolve_failovers(k8s_rows or [], run_dir)
    drains = _detect_secondary_drains(k8s_rows or [], run_dir, failovers=failovers)
    drains = _with_separate_proxy_drain_markers(drains, k8s_rows or [], run_dir)
    fig = build_haproxy_conns_figure(rows, timing, failovers, drains)
    if fig is None:
        return ""

    _plotly_config = {"scrollZoom": True, "displayModeBar": True, "responsive": True}
    chart_html = fig.to_html(
        full_html=False, include_plotlyjs=False,
        div_id="haproxy-conns", config=_plotly_config,
    )
    return f"""
    <section>
      <h2 class="section-title">HAProxy Current Connections</h2>
      <div class="chart-box">{chart_html}</div>
    </section>"""


# =============================================================================
# HTML rendering
# =============================================================================


def render_report_header(
    timing: ScaleTiming,
    run_dir_name: str,
    generated_at: str,
    success: bool,
) -> str:
    header = _parse_scale_header(timing, run_dir_name)
    badge_class = "badge-ok" if success else "badge-fail"
    badge_text = "SUCCESS" if success else "FAILED"

    size_transition = ""
    if header["from_label"] and header["to_label"]:
        size_transition = f"""
        <div class="header-size-row">
          <span class="size-chip from">{html_mod.escape(header['from_label'])}</span>
          <span class="size-arrow" aria-hidden="true">→</span>
          <span class="size-chip to">{html_mod.escape(header['to_label'])}</span>
        </div>"""

    return f"""
    <header class="report-header">
      <div class="header-top">
        <div class="header-titles">
          <p class="header-eyebrow">Benchmark Report</p>
          <h1 class="header-title">Scaling Analysis</h1>
          <p class="header-subtitle">{html_mod.escape(header['scale_type'])}</p>
          {size_transition}
        </div>
        <div class="header-meta">
          <span class="badge {badge_class}">{badge_text}</span>
          <div class="header-run">
            <span class="meta-label">Run</span>
            <code>{html_mod.escape(run_dir_name)}</code>
          </div>
          <div class="header-generated">
            <span class="meta-label">Generated</span>
            <span>{html_mod.escape(generated_at)}</span>
          </div>
        </div>
      </div>
    </header>"""


def _delta_tone(pct: float, higher_is_good: bool) -> str:
    if abs(pct) < 0.05:
        return "neutral"
    good = (pct > 0) if higher_is_good else (pct < 0)
    return "good" if good else "bad"


def _render_metric_row(
    label: str,
    pct: float,
    *,
    higher_is_good: bool,
    current: str,
    baseline: str,
) -> str:
    tone = _delta_tone(pct, higher_is_good)
    return f"""
          <div class="metric-row metric-row-{tone}">
            <div class="metric-row-top">
              <span class="metric-row-label">{html_mod.escape(label)}</span>
              {_fmt_pct_badge(pct, higher_is_good=higher_is_good)}
            </div>
            <div class="metric-row-values">
              <span class="metric-current">{html_mod.escape(current)}</span>
              <span class="metric-sep">·</span>
              <span class="metric-baseline">baseline {html_mod.escape(baseline)}</span>
            </div>
          </div>"""


def _render_phase_panel(title: str, phase_class: str, hint: str, rows_html: str) -> str:
    return f"""
        <div class="phase-panel {phase_class}">
          <div class="phase-panel-head">
            <span class="phase-badge">{html_mod.escape(title)}</span>
            <span class="phase-hint">{html_mod.escape(hint)}</span>
          </div>
          <div class="metric-rows">{rows_html}</div>
        </div>"""


def render_impact_card(impact: dict[str, Any], timing: ScaleTiming) -> str:
    pre = impact["pre"]
    during = impact["during"]
    post = impact["post"]
    slowest = impact.get("slowest_activity")
    zero_tps = int(impact["zero_tps_during"])

    slowest_html = ""
    if slowest:
        retry_note = f" · attempt {slowest['attempt']}" if slowest.get("attempt", 1) > 1 else ""
        slowest_html = f"""
        <div class="impact-footnote">
          <span class="footnote-label">Slowest activity</span>
          <strong>{_fmt_duration(slowest['duration_sec'])}</strong>
          <code>{html_mod.escape(slowest['name'])}</code>{html_mod.escape(retry_note)}
        </div>"""

    return f"""
    <section class="impact-section">
      <h2 class="section-title">Scaling Impact Summary</h2>

      <div class="impact-highlights">
        <div class="highlight-stat stat-duration">
          <div class="highlight-value">{_fmt_duration(timing.scale_duration_sec)}</div>
          <div class="highlight-label">Total Scaling Duration</div>
        </div>
        <div class="highlight-stat {"stat-zero-alert" if zero_tps > 0 else "stat-zero-safe"}">
          <div class="highlight-value">{zero_tps}<span class="highlight-unit">s</span></div>
          <div class="highlight-label">Zero-TPS During Scaling</div>
          <div class="highlight-sub">seconds with 0 transactions</div>
        </div>
      </div>

      <div class="impact-comparison">
        {_render_phase_panel(
            "During Scaling",
            "phase-during",
            "vs pre-scaling baseline",
            _render_metric_row("TPS", impact["tps_during_pct"], higher_is_good=True,
                               current=f"{during['avg_tps']:.1f} avg", baseline=f"{pre['avg_tps']:.1f}")
            + _render_metric_row("QPS", impact["qps_during_pct"], higher_is_good=True,
                                 current=f"{during['avg_qps']:.0f} avg", baseline=f"{pre['avg_qps']:.0f}")
            + _render_metric_row("Latency p99", impact["lat_during_pct"], higher_is_good=False,
                                 current=f"{during['avg_lat']:.1f} ms", baseline=f"{pre['avg_lat']:.1f} ms"),
        )}
        {_render_phase_panel(
            "After Scaling",
            "phase-after",
            "vs pre-scaling baseline",
            _render_metric_row("TPS", impact["tps_post_pct"], higher_is_good=True,
                               current=f"{post['avg_tps']:.1f} avg", baseline=f"{pre['avg_tps']:.1f}")
            + _render_metric_row("QPS", impact["qps_post_pct"], higher_is_good=True,
                                 current=f"{post['avg_qps']:.0f} avg", baseline=f"{pre['avg_qps']:.0f}")
            + _render_metric_row("Latency p99", impact["lat_post_pct"], higher_is_good=False,
                                 current=f"{post['avg_lat']:.1f} ms", baseline=f"{pre['avg_lat']:.1f} ms"),
        )}
      </div>

      {slowest_html}

      <details class="impact-details">
        <summary>Phase breakdown table</summary>
        <table class="phase-table">
          <thead>
            <tr><th>Metric</th><th>Pre-Scaling</th><th>During Scaling</th><th>Post-Scaling</th></tr>
          </thead>
          <tbody>
            <tr><td>Duration (samples)</td><td>{_fmt_duration(pre['count'])}</td><td>{_fmt_duration(during['count'])}</td><td>{_fmt_duration(post['count'])}</td></tr>
            <tr><td>Avg TPS</td><td>{pre['avg_tps']:.1f}</td><td>{during['avg_tps']:.1f}</td><td>{post['avg_tps']:.1f}</td></tr>
            <tr><td>Avg QPS</td><td>{pre['avg_qps']:.0f}</td><td>{during['avg_qps']:.0f}</td><td>{post['avg_qps']:.0f}</td></tr>
            <tr><td>Avg Latency p99 (ms)</td><td>{pre['avg_lat']:.1f}</td><td>{during['avg_lat']:.1f}</td><td>{post['avg_lat']:.1f}</td></tr>
            <tr><td>Max Latency p99 (ms)</td><td>{pre['max_lat']:.1f}</td><td>{during['max_lat']:.1f}</td><td>{post['max_lat']:.1f}</td></tr>
            <tr><td>Zero-TPS seconds</td><td>{pre['zero_tps_count']}</td><td>{during['zero_tps_count']}</td><td>{post['zero_tps_count']}</td></tr>
          </tbody>
        </table>
      </details>
    </section>
    """


def render_temporal_breakdown(activities: list[TemporalActivity]) -> str:
    if not activities:
        return """
    <section>
      <details class="impact-details">
        <summary>Where Is Time Spent? (Temporal Activities)</summary>
        <p class="details-note"><em>No temporal_history.json found.</em></p>
      </details>
    </section>"""

    sorted_acts = sorted(activities, key=lambda a: a.wall_clock_sec, reverse=True)
    total_wall = 0.0
    if activities:
        earliest = min(_parse_utc(a.scheduled_at or a.started_at) for a in activities)
        end = max(_parse_utc(a.ended_at) for a in activities)
        total_wall = (end - earliest).total_seconds()

    rows_html = ""
    for a in sorted_acts:
        wall = a.wall_clock_sec
        pct_of_total = (wall / total_wall * 100) if total_wall > 0 else 0
        bar_width = min(pct_of_total, 100)
        retry_badge = f' <span style="color:#cf222e;font-weight:600;">(attempt {a.attempt})</span>' if a.attempt > 1 else ""
        sched_time = a.scheduled_at[11:19] if a.scheduled_at else "–"
        rows_html += f"""
        <tr>
          <td><code>{html_mod.escape(a.activity_type)}</code>{retry_badge}</td>
          <td>{_fmt_duration(wall)}</td>
          <td>{pct_of_total:.1f}%</td>
          <td><div class="bar" style="width:{bar_width}%"></div></td>
          <td>{html_mod.escape(sched_time)}</td>
          <td>{html_mod.escape(a.started_at[11:19])}</td>
          <td>{html_mod.escape(a.ended_at[11:19])}</td>
          <td>{html_mod.escape(a.status)}</td>
        </tr>"""

    return f"""
    <section>
      <details class="impact-details">
        <summary>Where Is Time Spent? (Temporal Activities) · {_fmt_duration(total_wall)} total</summary>
        <p class="details-note">Sorted by wall-clock duration descending (includes retry/backoff time).</p>
        <table class="activity-table">
          <thead>
            <tr><th>Activity</th><th>Wall Clock</th><th>% of Total</th><th>Bar</th><th>Scheduled</th><th>Started</th><th>Ended</th><th>Status</th></tr>
          </thead>
          <tbody>{rows_html}</tbody>
        </table>
      </details>
    </section>
    """


def render_pvc_timeline(k8s_rows: list[K8sPodRow]) -> str:
    changes = pvc_change_events(k8s_rows)
    if not changes:
        return ""
    rows_html = "".join(
        f"<tr>"
        f"<td><code>mysql-{html_mod.escape(c['pod'].split('-mysql-')[-1])}</code></td>"
        f"<td>{html_mod.escape(c['old_size'])} → {html_mod.escape(c['new_size'])}</td>"
        f"<td>{html_mod.escape(c['request_started_at'][11:19])}</td>"
        f"<td>{html_mod.escape(c['fulfilled_at'][11:19])}</td>"
        f"<td><strong>{_fmt_duration(c['duration_sec'])}</strong></td>"
        f"</tr>"
        for c in changes
    )
    return f"""
    <section>
      <h2>PVC Storage Changes During Run</h2>
      <table class="kv">
        <thead><tr><th>Pod</th><th>Resize</th><th>Request Started (UTC)</th><th>Fulfilled (UTC)</th><th>Duration</th></tr></thead>
        <tbody>{rows_html}</tbody>
      </table>
    </section>
    """


def render_node_join_timeline(k8s_rows: list[K8sPodRow], timing: ScaleTiming) -> str:
    """For horizontal scaling: show when each new pod appeared, joined GR, became ONLINE."""
    if not _is_horizontal_scale(timing):
        return ""

    pod_events: dict[str, dict[str, str]] = {}
    for row in k8s_rows:
        pod = row.pod
        if pod not in pod_events:
            pod_events[pod] = {"first_seen": row.timestamp}

        # Track PodInitializing phase (gr_detail contains "PodInitializing")
        if "pod_initializing" not in pod_events[pod] and "PodInitializing" in (row.gr_detail or ""):
            pod_events[pod]["pod_initializing"] = row.timestamp

        # First time pod becomes Running (containers started, mysql starting)
        if "running" not in pod_events[pod] and row.phase == "Running":
            pod_events[pod]["running"] = row.timestamp

        if "running_not_ready" not in pod_events[pod] and row.phase == "Running" and row.ready == "false":
            pod_events[pod]["running_not_ready"] = row.timestamp

        if "ready" not in pod_events[pod] and row.ready == "true":
            pod_events[pod]["ready"] = row.timestamp

        if "gr_recovering" not in pod_events[pod] and row.gr_state == "RECOVERING":
            pod_events[pod]["gr_recovering"] = row.timestamp

        if "gr_online" not in pod_events[pod] and row.gr_state == "ONLINE":
            pod_events[pod]["gr_online"] = row.timestamp

        # Track final role
        if row.gr_role in ("PRIMARY", "SECONDARY"):
            pod_events[pod]["final_role"] = row.gr_role

    scale_start = timing.scale_start_utc
    rows_html = ""
    for pod in sorted(pod_events.keys()):
        ev = pod_events[pod]
        short_name = pod.split("-mysql-")[-1] if "-mysql-" in pod else pod
        first_seen = ev.get("first_seen", "")
        pod_initializing = ev.get("pod_initializing", "")
        running = ev.get("running", "")
        gr_recovering = ev.get("gr_recovering", "")
        gr_online = ev.get("gr_online", "")
        ready = ev.get("ready", "")
        final_role = ev.get("final_role", "–")

        # Pod Init time: first_seen → Running (init containers + image pull)
        init_time = "–"
        if first_seen and running:
            fs_dt = _parse_utc(first_seen)
            run_dt = _parse_utc(running)
            delta = (run_dt - fs_dt).total_seconds()
            if delta > 0:
                init_time = _fmt_duration(delta)

        # MySQL startup time: Running → GR RECOVERING (mysql starting, not yet in GR)
        mysql_startup = "–"
        if running and gr_recovering:
            run_dt = _parse_utc(running)
            rec_dt = _parse_utc(gr_recovering)
            delta = (rec_dt - run_dt).total_seconds()
            if delta > 0:
                mysql_startup = _fmt_duration(delta)

        # Time spent in RECOVERING (catching up with group replication)
        gr_catchup_time = "–"
        if gr_recovering and gr_online:
            rec_dt = _parse_utc(gr_recovering)
            online_dt = _parse_utc(gr_online)
            delta = (online_dt - rec_dt).total_seconds()
            if delta > 0:
                gr_catchup_time = _fmt_duration(delta)

        # Time from first seen to GR ONLINE (pod-level total)
        pod_bootstrap = "–"
        if first_seen and gr_online:
            fs_dt = _parse_utc(first_seen)
            online_dt = _parse_utc(gr_online)
            delta = (online_dt - fs_dt).total_seconds()
            if delta > 0:
                pod_bootstrap = _fmt_duration(delta)

        # Time from scale start to GR ONLINE
        time_to_online = "–"
        if scale_start and gr_online:
            start_dt = _parse_utc(scale_start)
            online_dt = _parse_utc(gr_online)
            delta = (online_dt - start_dt).total_seconds()
            if delta > 0:
                time_to_online = _fmt_duration(delta)

        role_badge = ""
        if final_role == "PRIMARY":
            role_badge = '<span style="background:#dafbe1;color:#116329;padding:2px 8px;border-radius:4px;font-size:0.8rem;font-weight:600;">PRIMARY</span>'
        elif final_role == "SECONDARY":
            role_badge = '<span style="background:#ddf4ff;color:#0969da;padding:2px 8px;border-radius:4px;font-size:0.8rem;font-weight:600;">SECONDARY</span>'

        rows_html += (
            f"<tr>"
            f"<td><code>mysql-{html_mod.escape(short_name)}</code> {role_badge}</td>"
            f"<td>{html_mod.escape(first_seen[11:19]) if first_seen else '–'}</td>"
            f"<td>{init_time}</td>"
            f"<td>{mysql_startup}</td>"
            f"<td>{gr_catchup_time}</td>"
            f"<td>{html_mod.escape(gr_online[11:19]) if gr_online else '–'}</td>"
            f"<td><strong>{pod_bootstrap}</strong></td>"
            f"<td><strong>{time_to_online}</strong></td>"
            f"</tr>"
        )

    return f"""
    <section>
      <h2>Node Join Timeline (Horizontal Scale)</h2>
      <p>Lifecycle breakdown per pod: PodInitializing (init containers) → MySQL Starting (container running, not in GR) → GR Recovering (catching up) → GR Online.</p>
      <table class="kv">
        <thead>
          <tr>
            <th>Pod / Role</th>
            <th>First Seen (UTC)</th>
            <th>Pod Init Time</th>
            <th>MySQL Startup</th>
            <th>GR Catch-up</th>
            <th>GR ONLINE (UTC)</th>
            <th>Total Bootstrap</th>
            <th>Time from Scale Start</th>
          </tr>
        </thead>
        <tbody>{rows_html}</tbody>
      </table>
    </section>
    """


def render_vertical_scale_timeline(
    k8s_rows: list[K8sPodRow], timing: ScaleTiming,
    run_dir: Path | None = None,
) -> str:
    """For vertical scaling: show rolling restart order, node migration, and downtime per pod."""
    if not _is_vertical_scale(timing):
        return ""

    # Two-pass approach: first find node changes, then trace the lifecycle
    # Pass 1: identify each pod's node migrations (node actually changes)
    pod_last_stable: dict[str, dict[str, str]] = {}
    pod_migrations: list[dict[str, Any]] = []
    pod_tracking: dict[str, dict[str, Any]] = {}

    for row in k8s_rows:
        pod = row.pod

        # Initialize with first stable state (ready=true, ONLINE)
        if pod not in pod_last_stable:
            if row.ready == "true" and row.gr_state == "ONLINE":
                pod_last_stable[pod] = {
                    "node": row.doks_node, "slug": row.slug,
                    "vcpus": row.vcpus, "mem_gib": row.mem_gib,
                    "gr_role": row.gr_role,
                }
            continue

        stable = pod_last_stable[pod]

        # Detect restart beginning: pod was stable but now goes offline/deleting
        if pod not in pod_tracking:
            if row.deleting == "yes" or (row.ready == "false" and row.gr_state != "ONLINE"):
                pod_tracking[pod] = {
                    "restart_started": row.timestamp,
                    "old_node": stable["node"],
                    "old_slug": stable["slug"],
                    "old_vcpus": stable["vcpus"],
                    "old_mem_gib": stable["mem_gib"],
                    "old_role": stable["gr_role"],
                    "pod_initializing": "",
                    "running": "",
                    "gr_recovering": "",
                    "gr_online": "",
                    "new_node": "",
                    "new_slug": "",
                    "new_vcpus": "",
                    "new_mem_gib": "",
                }
            continue

        # Track phases during restart
        track = pod_tracking[pod]
        if not track["pod_initializing"] and "PodInitializing" in (row.gr_detail or ""):
            track["pod_initializing"] = row.timestamp
            if row.doks_node and row.doks_node != track["old_node"]:
                track["new_node"] = row.doks_node
                track["new_slug"] = row.slug
                track["new_vcpus"] = row.vcpus
                track["new_mem_gib"] = row.mem_gib
        if not track["running"] and row.phase == "Running" and row.doks_node != track["old_node"]:
            track["running"] = row.timestamp
            if not track["new_node"]:
                track["new_node"] = row.doks_node
                track["new_slug"] = row.slug
                track["new_vcpus"] = row.vcpus
                track["new_mem_gib"] = row.mem_gib
        if not track["gr_recovering"] and row.gr_state == "RECOVERING":
            track["gr_recovering"] = row.timestamp
        if not track["gr_online"] and row.gr_state == "ONLINE":
            track["gr_online"] = row.timestamp
            pod_migrations.append({"pod": pod, **track})
            del pod_tracking[pod]
            # Update stable state
            pod_last_stable[pod] = {
                "node": row.doks_node, "slug": row.slug,
                "vcpus": row.vcpus, "mem_gib": row.mem_gib,
                "gr_role": row.gr_role,
            }

    # Only keep migrations where the node actually changed (filter spurious GR flaps)
    pod_migrations = [m for m in pod_migrations if m.get("new_node") and m["new_node"] != m["old_node"]]

    if not pod_migrations:
        return ""

    pod_migrations.sort(key=lambda m: m["restart_started"])

    # Failover — prefer failover_time.txt when available
    failovers = _resolve_failovers(k8s_rows, run_dir)
    latest_roles = _latest_gr_roles(k8s_rows)

    rows_html = ""
    for i, m in enumerate(pod_migrations):
        short_name = m["pod"].split("-mysql-")[-1] if "-mysql-" in m["pod"] else m["pod"]

        # Calculate phase durations
        init_time = "–"
        if m["pod_initializing"] and m["running"]:
            delta = (_parse_utc(m["running"]) - _parse_utc(m["pod_initializing"])).total_seconds()
            if delta > 0:
                init_time = _fmt_duration(delta)
        elif m["restart_started"] and m["running"]:
            delta = (_parse_utc(m["running"]) - _parse_utc(m["restart_started"])).total_seconds()
            if delta > 0:
                init_time = _fmt_duration(delta)

        mysql_startup = "–"
        if m["running"] and m["gr_recovering"]:
            delta = (_parse_utc(m["gr_recovering"]) - _parse_utc(m["running"])).total_seconds()
            if delta > 0:
                mysql_startup = _fmt_duration(delta)

        gr_catchup = "–"
        if m["gr_recovering"] and m["gr_online"]:
            delta = (_parse_utc(m["gr_online"]) - _parse_utc(m["gr_recovering"])).total_seconds()
            if delta > 0:
                gr_catchup = _fmt_duration(delta)

        total_downtime = "–"
        if m["restart_started"] and m["gr_online"]:
            delta = (_parse_utc(m["gr_online"]) - _parse_utc(m["restart_started"])).total_seconds()
            if delta > 0:
                total_downtime = _fmt_duration(delta)

        role_badge = ""
        latest_role = latest_roles.get(m["pod"], "")
        if latest_role == "PRIMARY":
            role_badge = ' <span style="background:#dafbe1;color:#116329;padding:2px 6px;border-radius:4px;font-size:0.75rem;font-weight:600;">PRIMARY</span>'
        elif latest_role == "SECONDARY":
            role_badge = ' <span style="background:#ddf4ff;color:#0969da;padding:2px 6px;border-radius:4px;font-size:0.75rem;font-weight:600;">SECONDARY</span>'

        slug_change = f"{html_mod.escape(m['old_slug'])} → {html_mod.escape(m['new_slug'])}" if m["new_slug"] else "–"

        rows_html += (
            f"<tr>"
            f"<td>{i+1}</td>"
            f"<td><code>mysql-{html_mod.escape(short_name)}</code>{role_badge}</td>"
            f"<td>{html_mod.escape(m['restart_started'][11:19])}</td>"
            f"<td>{slug_change}</td>"
            f"<td>{init_time}</td>"
            f"<td>{mysql_startup}</td>"
            f"<td>{gr_catchup}</td>"
            f"<td><strong>{total_downtime}</strong></td>"
            f"</tr>"
        )

    failover_html = ""
    if failovers:
        fo_rows = ""
        for fo in failovers:
            from_short = fo["from"].split("-mysql-")[-1] if "-mysql-" in fo["from"] else fo["from"]
            to_short = fo["to"].split("-mysql-")[-1] if "-mysql-" in fo["to"] else fo["to"]
            fo_rows += (
                f"<tr>"
                f"<td>{html_mod.escape(fo['timestamp'][11:19])}</td>"
                f"<td><code>mysql-{html_mod.escape(from_short)}</code> → <code>mysql-{html_mod.escape(to_short)}</code></td>"
                f"</tr>"
            )
        failover_html = f"""
        <h3 style="margin-top:1.2rem;">Primary Failovers During Vertical Scale</h3>
        <table class="kv">
          <thead><tr><th>Time (UTC)</th><th>Failover</th></tr></thead>
          <tbody>{fo_rows}</tbody>
        </table>"""

    event_summary_html = ""
    summary_rows = _drain_failover_summary_rows(k8s_rows, run_dir, failovers)
    if summary_rows:
        body = "".join(
            f"<tr>"
            f"<td>{html_mod.escape(r['time'])}</td>"
            f"<td>{html_mod.escape(r['what'])}</td>"
            f"</tr>"
            for r in summary_rows
        )
        event_summary_html = f"""
        <h3 style="margin-top:1.2rem;">Drain &amp; Failover Events</h3>
        <p style="margin:0.35rem 0 0.6rem;font-size:0.88rem;color:#57606a;">
          Chronological view of secondary drains, separately timed HAProxy / binlog
          moves, primary failover, and when HAProxy / binlog came back (with the node
          they landed on). Co-drained components are only combined when they share the
          exact same timestamp.
        </p>
        <table class="kv">
          <thead><tr><th>Time (UTC)</th><th>What happened</th></tr></thead>
          <tbody>{body}</tbody>
        </table>"""

    return f"""
    <section>
      <h2>Rolling Restart Timeline (Vertical Scale)</h2>
      <p>Pods are restarted one-at-a-time onto new nodes with the target slug ({html_mod.escape(timing.target_size or '–')}). Shows downtime breakdown per pod.</p>
      <table class="kv">
        <thead>
          <tr>
            <th>#</th>
            <th>Pod / Role</th>
            <th>Restart Started (UTC)</th>
            <th>Slug Change</th>
            <th>Pod Init</th>
            <th>MySQL Startup</th>
            <th>GR Catch-up</th>
            <th>Total Downtime</th>
          </tr>
        </thead>
        <tbody>{rows_html}</tbody>
      </table>
      {event_summary_html}
      {failover_html}
    </section>
    """


def _find_cr_snapshot(run_dir: Path) -> Path | None:
    matches = sorted(run_dir.glob("cr_snapshot*.yaml")) + sorted(run_dir.glob("cr_snapshot*.yml"))
    return matches[0] if matches else None


def _yaml_scalar_map(yaml_text: str) -> dict[str, str]:
    """Best-effort path→scalar map from a CR YAML (no PyYAML dependency)."""
    values: dict[str, str] = {}
    stack: list[tuple[int, str]] = [(-1, "")]
    lines = yaml_text.splitlines()
    i = 0
    while i < len(lines):
        raw = lines[i]
        if not raw.strip() or raw.lstrip().startswith("#"):
            i += 1
            continue
        indent = len(raw) - len(raw.lstrip(" "))
        stripped = raw.strip()
        if stripped.startswith("- "):
            i += 1
            continue

        while stack and indent <= stack[-1][0]:
            stack.pop()
        parent = stack[-1][1] if stack else ""

        if ":" not in stripped:
            i += 1
            continue
        key, _, rest = stripped.partition(":")
        key = key.strip()
        rest = rest.strip()
        path = f"{parent}.{key}" if parent else key

        if rest in ("|", ">"):
            block: list[str] = []
            i += 1
            while i < len(lines):
                blk = lines[i]
                if not blk.strip():
                    block.append("")
                    i += 1
                    continue
                blk_indent = len(blk) - len(blk.lstrip(" "))
                if blk_indent <= indent:
                    break
                block.append(blk[indent + 2:] if len(blk) > indent + 2 else blk.lstrip())
                i += 1
            values[path] = "\n".join(block).rstrip()
            stack.append((indent, path))
            continue

        if rest:
            values[path] = rest.strip().strip('"').strip("'")
            stack.append((indent, path))
            i += 1
            continue

        stack.append((indent, path))
        i += 1
    return values


def _cr_config_kv(configuration: str) -> list[tuple[str, str]]:
    rows: list[tuple[str, str]] = []
    for line in configuration.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or stripped.startswith("["):
            continue
        if "=" in stripped:
            k, _, v = stripped.partition("=")
            rows.append((f"mysql.configuration.{k.strip()}", v.strip()))
    return rows


def render_cr_snapshot(run_dir: Path) -> str:
    """Collapsible CR snapshot table (phase-breakdown style) after Run Overview."""
    path = _find_cr_snapshot(run_dir)
    if path is None:
        return """
    <section>
      <details class="impact-details">
        <summary>PerconaServerMySQL CR Snapshot</summary>
        <p class="details-note"><em>No cr_snapshot*.yaml found in this run directory.</em></p>
      </details>
    </section>"""

    text = path.read_text(encoding="utf-8", errors="replace")
    values = _yaml_scalar_map(text)

    preferred = [
        ("metadata.name", "Name"),
        ("metadata.namespace", "Namespace"),
        ("spec.crVersion", "CR Version"),
        ("spec.mysql.image", "MySQL Image"),
        ("spec.mysql.clusterType", "Cluster Type"),
        ("spec.mysql.size", "MySQL Size"),
        ("spec.mysql.gracePeriod", "Grace Period"),
        ("spec.mysql.autoRecovery", "Auto Recovery"),
        ("spec.mysql.resources.requests.cpu", "CPU Request"),
        ("spec.mysql.resources.requests.memory", "Memory Request"),
        ("spec.mysql.resources.limits.memory", "Memory Limit"),
        ("spec.mysql.livenessProbe.initialDelaySeconds", "Liveness initialDelaySeconds"),
        ("spec.mysql.livenessProbe.periodSeconds", "Liveness periodSeconds"),
        ("spec.mysql.livenessProbe.failureThreshold", "Liveness failureThreshold"),
        ("spec.mysql.livenessProbe.timeoutSeconds", "Liveness timeoutSeconds"),
        ("spec.mysql.readinessProbe.initialDelaySeconds", "Readiness initialDelaySeconds"),
        ("spec.mysql.readinessProbe.periodSeconds", "Readiness periodSeconds"),
        ("spec.mysql.readinessProbe.failureThreshold", "Readiness failureThreshold"),
        ("spec.mysql.readinessProbe.timeoutSeconds", "Readiness timeoutSeconds"),
        ("spec.proxy.haproxy.size", "HAProxy Size"),
        ("spec.proxy.haproxy.image", "HAProxy Image"),
        ("spec.pmm.enabled", "PMM Enabled"),
        ("spec.pmm.image", "PMM Image"),
        ("spec.pmm.serverHost", "PMM Server Host"),
        ("status.state", "Status State"),
        ("status.mysql.ready", "MySQL Ready"),
    ]

    rows: list[tuple[str, str]] = []
    for path_key, label in preferred:
        if path_key in values:
            rows.append((label, values[path_key]))

    # Promote interesting mysqld configuration knobs into the table.
    config_text = values.get("spec.mysql.configuration", "")
    interesting_cfg = {
        "replica_parallel_workers",
        "max_connections",
        "innodb_buffer_pool_size",
        "innodb_redo_log_capacity",
        "loose_group_replication_member_expel_timeout",
        "loose_group_replication_autorejoin_tries",
        "loose_group_replication_paxos_single_leader",
        "loose_group_replication_transaction_size_limit",
        "loose_group_replication_message_cache_size",
    }
    for cfg_key, cfg_val in _cr_config_kv(config_text):
        short = cfg_key.rsplit(".", 1)[-1]
        if short in interesting_cfg:
            rows.append((short, cfg_val))

    if not rows:
        rows.append(("Snapshot file", path.name))

    body = "".join(
        f"<tr><td>{html_mod.escape(k)}</td><td><code>{html_mod.escape(v)}</code></td></tr>"
        for k, v in rows
    )
    return f"""
    <section>
      <details class="impact-details">
        <summary>PerconaServerMySQL CR Snapshot ({html_mod.escape(path.name)})</summary>
        <p class="details-note">Key fields from the CR captured during this run.</p>
        <table class="phase-table">
          <thead><tr><th>Setting</th><th>Value</th></tr></thead>
          <tbody>{body}</tbody>
        </table>
      </details>
    </section>
    """


# =============================================================================
# Main report assembly
# =============================================================================


CSS = """
body {
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
  margin: 0; padding: 0;
  background: #eef1f5; color: #1f2328;
}
.report-shell {
  max-width: 1440px; margin: 0 auto;
  padding: 12px 10px 28px;
}
h1 { margin-top: 0; font-size: 1.6rem; }
h2, .section-title {
  margin-top: 0; margin-bottom: 0.75rem;
  border-bottom: 1px solid #d0d7de; padding-bottom: 0.35rem;
  font-size: 1.15rem; font-weight: 650; letter-spacing: -0.01em;
}
.meta { color: #57606a; margin-bottom: 1rem; }
.badge {
  display: inline-block; padding: 0.2rem 0.65rem; border-radius: 999px;
  font-size: 0.78rem; font-weight: 700; letter-spacing: 0.04em;
}
.badge-ok { background: #dafbe1; color: #116329; }
.badge-fail { background: #ffebe9; color: #cf222e; }

/* Shared card surface (foreground on page background) */
.report-header,
section,
.impact-section {
  background: #ffffff;
  border: 1px solid #d8dee4;
  border-radius: 10px;
  padding: 16px 20px;
  margin-bottom: 0.85rem;
  box-shadow: 0 1px 4px rgba(31, 35, 40, 0.05);
}

/* Report header — title left, meta right */
.report-header {
  background: linear-gradient(180deg, #ffffff 0%, #fafbfc 100%);
  padding: 18px 22px;
}
.header-top {
  display: flex; justify-content: space-between; align-items: flex-start;
  gap: 20px; flex-wrap: wrap;
}
.header-titles { flex: 1; min-width: 260px; text-align: left; }
.header-eyebrow {
  margin: 0 0 0.35rem; font-size: 0.72rem; font-weight: 700;
  text-transform: uppercase; letter-spacing: 0.08em; color: #57606a;
}
.header-title {
  margin: 0; font-size: 2rem; font-weight: 750; letter-spacing: -0.03em; line-height: 1.1;
}
.header-subtitle {
  margin: 0.45rem 0 0; font-size: 1.05rem; font-weight: 600; color: #0969da;
}
.header-size-row {
  display: flex; align-items: center; justify-content: flex-start;
  gap: 10px; flex-wrap: wrap; margin-top: 0.75rem;
}
.size-chip {
  display: inline-flex; align-items: center;
  padding: 0.35rem 0.75rem; border-radius: 8px;
  font-size: 0.88rem; font-weight: 600; font-variant-numeric: tabular-nums;
}
.size-chip.from { background: #eef2f6; color: #424a53; border: 1px solid #d0d7de; }
.size-chip.to { background: #ddf4ff; color: #0550ae; border: 1px solid #54aeff66; }
.size-arrow { font-size: 1.1rem; color: #57606a; font-weight: 600; }
.header-meta {
  display: flex; flex-direction: column; align-items: flex-end; gap: 8px;
  min-width: 200px; text-align: right;
}
.header-run, .header-generated { text-align: right; font-size: 0.82rem; color: #57606a; }
.meta-label {
  display: block; font-size: 0.68rem; font-weight: 700;
  text-transform: uppercase; letter-spacing: 0.06em; color: #8c959f; margin-bottom: 2px;
}

/* Impact summary — palette aligned with report header */
.impact-section {
  padding: 18px 22px;
  background: linear-gradient(180deg, #ffffff 0%, #fafbfc 100%);
}
.impact-highlights {
  display: grid; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr));
  gap: 12px; margin-bottom: 1.1rem;
}
.highlight-stat {
  border-radius: 8px; padding: 16px 18px;
  border: 1px solid #d0d7de;
  position: relative; overflow: hidden;
  background: #eef2f6;
  color: #424a53;
}
.highlight-stat::before {
  content: ""; position: absolute; left: 0; top: 0; bottom: 0; width: 4px;
  background: #8c959f;
}
.stat-duration {
  background: #ddf4ff;
  border-color: #54aeff66;
  color: #0550ae;
}
.stat-duration::before { background: #0969da; }
.stat-zero-alert {
  background: #ffebe9;
  border-color: #ff818266;
  color: #cf222e;
}
.stat-zero-alert::before { background: #cf222e; }
.stat-zero-safe {
  background: #eef2f6;
  border-color: #d0d7de;
  color: #424a53;
}
.stat-zero-safe::before { background: #8c959f; }
.highlight-value {
  font-size: 2rem; font-weight: 800; letter-spacing: -0.03em; line-height: 1;
  font-variant-numeric: tabular-nums; padding-left: 6px;
  color: inherit;
}
.highlight-unit { font-size: 1rem; font-weight: 700; margin-left: 2px; }
.highlight-label {
  margin-top: 6px; padding-left: 6px;
  font-size: 0.68rem; font-weight: 700; text-transform: uppercase;
  letter-spacing: 0.06em; color: #8c959f;
}
.stat-duration .highlight-label { color: #0550ae; opacity: 0.85; }
.stat-zero-alert .highlight-label { color: #cf222e; opacity: 0.85; }
.highlight-sub {
  margin-top: 3px; padding-left: 6px;
  font-size: 0.72rem; color: #8c959f;
}
.impact-comparison {
  display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
  gap: 12px;
}
.phase-panel {
  background: #ffffff; border: 1px solid #d8dee4;
  border-radius: 10px; overflow: hidden;
  box-shadow: 0 1px 3px rgba(31, 35, 40, 0.04);
}
.phase-during { border-top: 3px solid #8c959f; }
.phase-after { border-top: 3px solid #0969da; }
.phase-panel-head {
  display: flex; align-items: baseline; gap: 8px; flex-wrap: wrap;
  padding: 11px 14px 9px; background: #fafbfc;
  border-bottom: 1px solid #d0d7de;
}
.phase-badge {
  font-size: 0.88rem; font-weight: 700; color: #1f2328;
}
.phase-during .phase-badge { color: #424a53; }
.phase-after .phase-badge { color: #0550ae; }
.phase-hint { font-size: 0.78rem; color: #8c959f; font-weight: 500; }
.metric-rows { padding: 4px 0; background: #fff; }
.metric-row {
  padding: 10px 14px;
  border-left: 3px solid transparent;
  border-bottom: 1px solid #eaeef2;
}
.metric-row:last-child { border-bottom: none; }
.metric-row-good { border-left-color: #116329; }
.metric-row-bad { border-left-color: #cf222e; }
.metric-row-neutral { border-left-color: #d0d7de; }
.metric-row-top {
  display: flex; align-items: center; justify-content: space-between; gap: 10px;
}
.metric-row-label {
  font-size: 0.82rem; font-weight: 700; color: #57606a;
  text-transform: uppercase; letter-spacing: 0.04em;
}
.metric-row-values {
  display: flex; align-items: center; gap: 6px; flex-wrap: wrap;
  margin-top: 4px; font-size: 0.78rem; font-variant-numeric: tabular-nums;
}
.metric-current { font-weight: 650; color: #1f2328; }
.metric-sep { color: #d0d7de; }
.metric-baseline { color: #8c959f; }
.delta-badge {
  display: inline-flex; align-items: center; gap: 3px;
  font-size: 0.95rem; font-weight: 700; letter-spacing: -0.01em;
  font-variant-numeric: tabular-nums;
  padding: 0.15rem 0.55rem; border-radius: 999px;
}
.delta-good { color: #116329; background: #dafbe1; }
.delta-bad { color: #cf222e; background: #ffebe9; }
.delta-neutral { color: #57606a; background: #eef2f6; }
.delta-arrow { font-size: 0.8rem; }
.impact-footnote {
  margin-top: 0.85rem; padding-top: 0.75rem; border-top: 1px solid #eaeef2;
  font-size: 0.82rem; color: #57606a;
}
.footnote-label {
  font-weight: 650; color: #424a53; margin-right: 6px;
}
.impact-details { margin-top: 0.85rem; }
.impact-details summary {
  cursor: pointer; font-size: 0.85rem; font-weight: 600; color: #0969da;
  user-select: none;
}
.details-note {
  margin: 0.5rem 0 0.65rem; font-size: 0.82rem; color: #57606a;
}

.kpi-grid {
  display: grid; grid-template-columns: repeat(auto-fit, minmax(160px, 1fr));
  gap: 10px; margin: 12px 0;
}
.kpi {
  background: #f4f6f9; border: 1px solid #d0d7de; border-radius: 8px;
  padding: 14px; text-align: center;
}
.kpi-value { font-size: 1.5rem; font-weight: 700; color: #1f2328; }
.kpi-label { font-size: 0.82rem; color: #57606a; margin-top: 4px; }
.kpi-warn .kpi-value { color: #bf8700; }
.kpi-bad .kpi-value { color: #cf222e; }
.kpi-good .kpi-value { color: #116329; }
table.phase-table, table.kv, table.activity-table {
  width: 100%; border-collapse: collapse; background: #f8fafc;
  border: 1px solid #d0d7de; border-radius: 8px; overflow: hidden;
  margin-top: 10px;
}
table.phase-table th, table.phase-table td,
table.kv th, table.kv td,
table.activity-table th, table.activity-table td {
  padding: 0.5rem 0.7rem; border-bottom: 1px solid #eaeef2;
  text-align: left; font-size: 0.88rem;
}
table.phase-table th, table.kv th, table.activity-table th { background: #eef2f6; }
.chart-box {
  background: #f8fafc; border: 1px solid #d8dee4;
  border-radius: 8px; padding: 10px; margin-top: 10px;
}
section p { color: #424a53; font-size: 0.9rem; line-height: 1.5; }
code { font-size: 0.88em; }
.bar { height: 14px; background: #0969da; border-radius: 3px; min-width: 2px; }
"""


def _parse_probe_ts(raw: str) -> datetime | None:
    s = (raw or "").strip()
    if not s:
        return None
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(s)
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt


def load_write_probe(run_dir: Path) -> dict[str, Any] | None:
    probe_dir = run_dir / "write_probe"
    attempts_path = probe_dir / "test_writes_attempts.csv"
    if not attempts_path.is_file():
        return None

    attempts: list[dict[str, str]] = []
    with attempts_path.open(encoding="utf-8", newline="") as f:
        attempts = list(csv.DictReader(f))
    if not attempts:
        return None

    committed_path = probe_dir / "test_writes.csv"
    committed: list[dict[str, str]] = []
    if committed_path.is_file():
        with committed_path.open(encoding="utf-8", newline="") as f:
            committed = list(csv.DictReader(f))
    committed_seqs = {int(r["seq"]) for r in committed if r.get("seq")}

    summary: dict[str, Any] = {}
    summary_path = probe_dir / "test_writes_summary.json"
    if summary_path.is_file():
        try:
            summary = json.loads(summary_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            summary = {}

    return {
        "attempts": attempts,
        "committed": committed,
        "committed_seqs": committed_seqs,
        "summary": summary,
    }


def build_write_probe_figure(
    probe: dict[str, Any],
    timing: ScaleTiming,
    k8s_rows: list[K8sPodRow],
    run_dir: Path,
) -> go.Figure | None:
    attempts: list[dict[str, str]] = probe["attempts"]
    committed_seqs: set[int] = probe["committed_seqs"]
    committed: list[dict[str, str]] = probe["committed"]

    ok_t: list[str] = []
    ok_ms: list[float] = []
    fail_t: list[str] = []
    fail_ms: list[float] = []
    fail_text: list[str] = []
    server_t: list[str] = []
    server_ms: list[float] = []

    for row in attempts:
        sent = _parse_probe_ts(row.get("sent_at_utc", ""))
        if sent is None:
            continue
        ts = sent.strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]
        try:
            seq = int(row.get("seq", ""))
            lat = float(row.get("latency_ms") or 0)
        except ValueError:
            continue
        status = (row.get("status") or "").strip()
        errno = (row.get("errno") or "").strip()
        in_table = seq in committed_seqs
        if status == "ok" and in_table:
            ok_t.append(ts)
            ok_ms.append(lat)
        else:
            fail_t.append(ts)
            fail_ms.append(lat if lat > 0 else 0.0)
            label = "ack missing" if status == "ok" and not in_table else status
            if errno:
                label = f"{label} {errno}"
            fail_text.append(f"seq={seq} {label}")

    for row in committed:
        sent = _parse_probe_ts(row.get("sent_at", ""))
        if sent is None:
            continue
        raw = (row.get("commit_delay_us") or "").strip()
        if raw in ("", "NULL"):
            continue
        try:
            delay_ms = int(raw) / 1000.0
        except ValueError:
            continue
        ts = sent.strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]
        server_t.append(ts)
        server_ms.append(delay_ms)

    if not ok_t and not fail_t and not server_t:
        return None

    fig = make_subplots(
        rows=2,
        cols=1,
        shared_xaxes=True,
        vertical_spacing=0.12,
        subplot_titles=(
            "Client latency (ack − sent, same clock)",
            "Server delay (created_at − sent_at, mixed clocks)",
        ),
    )

    if ok_t:
        fig.add_trace(go.Scatter(
            x=ok_t, y=ok_ms, mode="markers",
            name="committed",
            marker=dict(color="#2da44e", size=5),
            hovertemplate="latency=%{y:.1f} ms<extra>committed</extra>",
        ), row=1, col=1)
    if fail_t:
        fig.add_trace(go.Scatter(
            x=fail_t, y=fail_ms, mode="markers",
            name="failed / lost",
            marker=dict(color="#cf222e", size=8, symbol="x"),
            text=fail_text,
            hovertemplate="%{text}<br>wait=%{y:.1f} ms<extra>failed</extra>",
        ), row=1, col=1)
    if server_t:
        fig.add_trace(go.Scatter(
            x=server_t, y=server_ms, mode="markers",
            name="created_at − sent_at",
            marker=dict(color="#0969da", size=5),
            hovertemplate="delay=%{y:.1f} ms<extra>server</extra>",
            showlegend=True,
        ), row=2, col=1)

    failovers = _resolve_failovers(k8s_rows or [], run_dir)
    drains = _detect_secondary_drains(k8s_rows or [], run_dir, failovers=failovers)
    drains = _with_separate_proxy_drain_markers(drains, k8s_rows or [], run_dir)
    _add_scale_event_vlines(fig, timing, failovers, [1, 2], drains)
    if timing.scale_start_utc and timing.scale_complete_utc:
        for row_idx in (1, 2):
            fig.add_vrect(
                x0=timing.scale_start_utc, x1=timing.scale_complete_utc,
                fillcolor="#ff7f0e", opacity=0.06, line_width=0,
                row=row_idx, col=1,
            )

    fig.update_layout(
        height=620,
        hovermode="closest",
        legend=dict(orientation="h", yanchor="bottom", y=1.02, x=0),
        margin=dict(t=80, b=48),
    )
    fig.update_yaxes(title_text="ms", row=1, col=1)
    fig.update_yaxes(title_text="ms", row=2, col=1)
    fig.update_xaxes(title_text="Time (UTC)", row=2, col=1)
    return fig


def render_write_probe_section(
    run_dir: Path,
    timing: ScaleTiming,
    k8s_rows: list[K8sPodRow],
) -> str:
    probe = load_write_probe(run_dir)
    if probe is None:
        return ""

    summary = probe["summary"]
    attempted = int(summary.get("attempted") or len(probe["attempts"]))
    committed = int(summary.get("committed") or len(probe["committed"]))
    lost = int(summary.get("lost") or 0)
    ack_missing = summary.get("ack_but_missing") or []
    never_committed = summary.get("never_committed") or []
    late_commit = summary.get("late_commit") or []
    by_errno = summary.get("by_errno") or {}
    client_stats = summary.get("client_latency_ms") or {}
    server_stats = summary.get("server_delay_ms") or {}

    lost_class = "stat-zero-alert" if lost else "stat-zero-safe"
    p99 = client_stats.get("p99")
    p99_txt = f"{p99:.1f}" if isinstance(p99, (int, float)) else "–"
    server_p99 = server_stats.get("p99")
    server_p99_txt = f"{server_p99:.1f}" if isinstance(server_p99, (int, float)) else "–"

    errno_rows = ""
    if by_errno:
        errno_rows = "".join(
            f"<tr><th>{html_mod.escape(str(k))}</th><td>{v}</td></tr>"
            for k, v in sorted(by_errno.items(), key=lambda kv: (-int(kv[1]), str(kv[0])))
        )
        errno_html = f"""
        <table class="kv"><thead><tr><th>errno / status</th><th>attempts</th></tr></thead>
        <tbody>{errno_rows}</tbody></table>"""
    else:
        errno_html = ""

    def _seq_preview(seqs: list[Any], label: str) -> str:
        if not seqs:
            return ""
        shown = ", ".join(str(s) for s in seqs[:30])
        extra = f" … +{len(seqs) - 30} more" if len(seqs) > 30 else ""
        return f"<p><strong>{html_mod.escape(label)} ({len(seqs)}):</strong> <code>{html_mod.escape(shown + extra)}</code></p>"

    fig = build_write_probe_figure(probe, timing, k8s_rows, run_dir)
    chart_html = "<p><em>No plottable write-probe samples.</em></p>"
    if fig is not None:
        chart_html = fig.to_html(full_html=False, include_plotlyjs=False, div_id="write-probe-chart")

    return f"""
    <section>
      <h2 class="section-title">Write-Loss Canary (<code>test_writes</code>)</h2>
      <p>
        One autocommit INSERT every 0.25s with a client-assigned <code>seq</code>.
        <code>sent_at</code> is the client clock when the query was fired;
        <code>created_at</code> is MySQL <code>CURRENT_TIMESTAMP(6)</code> when the row was written.
        Failed attempts are <em>not</em> queued — they must be retried.
        Client latency (ack − sent) is the reliable number; server delay mixes two clocks.
      </p>
      <div class="impact-highlights">
        <div class="highlight-stat stat-duration">
          <div class="highlight-value">{attempted}</div>
          <div class="highlight-label">Attempts sent</div>
        </div>
        <div class="highlight-stat {"stat-duration" if committed else "stat-zero-safe"}">
          <div class="highlight-value">{committed}</div>
          <div class="highlight-label">Rows committed</div>
        </div>
        <div class="highlight-stat {lost_class}">
          <div class="highlight-value">{lost}</div>
          <div class="highlight-label">Lost (no row)</div>
          <div class="highlight-sub">ack-missing {len(ack_missing)} · never committed {len(never_committed)}</div>
        </div>
        <div class="highlight-stat stat-duration">
          <div class="highlight-value">{html_mod.escape(p99_txt)}<span class="highlight-unit">ms</span></div>
          <div class="highlight-label">Client latency p99</div>
          <div class="highlight-sub">server delay p99 {html_mod.escape(server_p99_txt)} ms</div>
        </div>
      </div>
      {_seq_preview(ack_missing, "Ack but missing (true durability miss)")}
      {_seq_preview(never_committed, "Never committed (timeout / 4094 / disconnect)")}
      {_seq_preview(late_commit, "Late commit (client gave up, row still landed)")}
      {errno_html}
      <div class="chart-box">{chart_html}</div>
    </section>
    """


def generate_report(run_dir: Path, output_path: Path | None = None) -> Path:
    run_dir = run_dir.resolve()
    if not run_dir.is_dir():
        raise FileNotFoundError(f"Run directory not found: {run_dir}")

    timing = load_scale_timing(run_dir / "scale_timing.env")
    conf = load_benchmark_conf(run_dir / "benchmark.conf")
    metrics = load_metrics(run_dir / "metrics_timeseries.csv")
    k8s_rows = load_k8s_monitor(run_dir / "k8s_monitor" / "k8s_monitor.tsv")
    activities = load_temporal_activities(run_dir / "temporal_history.json")

    if output_path is None:
        output_path = run_dir / "scaling_analysis_report.html"
    else:
        output_path = output_path.resolve()

    impact = compute_impact_summary(metrics, timing, activities)
    main_fig = build_main_figure(metrics, timing, k8s_rows, activities, run_dir) if metrics else None

    main_chart_html = main_fig.to_html(full_html=False, include_plotlyjs=False, div_id="main-chart") if main_fig else "<p><em>No metrics data.</em></p>"

    generated_at = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    title = f"Scaling Analysis — {timing.scale_description or timing.scale_types or run_dir.name}"

    overview_items = [
        ("Engine", timing.engine or conf.get("ENGINE", "N/A")),
        ("Cluster ID", conf.get("CLUSTER_ID", "N/A")),
        ("Scale Type", timing.scale_description or timing.scale_types or "N/A"),
        ("Before", f"{timing.initial_size} · {timing.initial_nodes} node{'s' if timing.initial_nodes != 1 else ''} · {timing.initial_storage_gib} GiB"),
        ("After", f"{timing.target_size or timing.initial_size} · {timing.target_nodes or timing.initial_nodes} node{'s' if (timing.target_nodes or timing.initial_nodes) != 1 else ''} · {timing.target_storage_gib or timing.initial_storage_gib} GiB"),
        ("Scale Duration", _fmt_duration(timing.scale_duration_sec)),
        ("TPC-C Scale", conf.get("TPCC_SCALE", "N/A")),
        ("TPC-C Tables", conf.get("TPCC_TABLES", "N/A")),
        ("TPC-C Data", _fmt_tpcc_data_gib(conf)),
        ("TPC-C Threads", conf.get("TPCC_THREADS", "N/A")),
        ("TPC-C Duration", _fmt_duration(int(conf.get("TPCC_MAX_TIME", "0") or "0"))),
        ("Report Interval", f"{conf.get('TPCC_REPORT_INTERVAL', '1')}s"),
    ]
    overview_rows = "".join(
        f"<tr><th>{html_mod.escape(k)}</th><td>{html_mod.escape(v)}</td></tr>" for k, v in overview_items
    )

    page = f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>{html_mod.escape(title)}</title>
  <script src="https://cdn.plot.ly/plotly-2.35.2.min.js"></script>
  <style>{CSS}</style>
</head>
<body>
  <div class="report-shell">
  {render_report_header(timing, run_dir.name, generated_at, timing.success)}

  {render_impact_card(impact, timing)}

  <section>
    <h2 class="section-title">Run Overview</h2>
    <table class="kv"><tbody>{overview_rows}</tbody></table>
  </section>

  {render_cr_snapshot(run_dir)}

  <section>
    <h2 class="section-title">TPC-C Metrics & Temporal Activity Timeline</h2>
    <div class="chart-box">{main_chart_html}</div>
  </section>

  {render_write_probe_section(run_dir, timing, k8s_rows)}

  {render_temporal_breakdown(activities)}

  {build_k8s_status_bars(k8s_rows, timing, run_dir, metrics)}
  {render_haproxy_conns_section(run_dir, timing, k8s_rows)}
  {render_replication_lag_section(k8s_rows, timing, run_dir)}
  {render_vertical_scale_timeline(k8s_rows, timing, run_dir)}
  {render_node_join_timeline(k8s_rows, timing)}
  {render_pvc_timeline(k8s_rows)}
  </div>
</body>
</html>
"""

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(page, encoding="utf-8")
    return output_path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "run_dir", type=Path,
        help="Path to run results directory",
    )
    parser.add_argument(
        "-o", "--output", type=Path, default=None,
        help="Output HTML path (default: <run_dir>/scaling_analysis_report.html)",
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
