#!/usr/bin/env python3
"""Generate a comprehensive HTML scaling analysis report.

Correlates TPC-C metrics, K8s pod states, PVC changes, and Temporal workflow
activities into a single interactive report with synchronized time axes.

Usage:
  pip install plotly
  python3 generate_scaling_analysis_report.py scaling-benchmarking/results/run_20260702_142729_advanced-2-july-s-scale
  python3 generate_scaling_analysis_report.py /path/to/run_dir -o /path/to/report.html
"""

from __future__ import annotations

import argparse
import csv
import html as html_mod
import json
import re
import sys
from dataclasses import dataclass, field
from datetime import datetime, timezone
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

    tps_drop_pct = 0.0
    if pre["avg_tps"] > 0:
        tps_drop_pct = (1 - during["avg_tps"] / pre["avg_tps"]) * 100

    tps_post_change_pct = 0.0
    if pre["avg_tps"] > 0:
        tps_post_change_pct = (post["avg_tps"] / pre["avg_tps"] - 1) * 100

    lat_increase_pct = 0.0
    if pre["avg_lat"] > 0:
        lat_increase_pct = (during["avg_lat"] / pre["avg_lat"] - 1) * 100

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
        "tps_drop_pct": tps_drop_pct,
        "tps_post_change_pct": tps_post_change_pct,
        "lat_increase_pct": lat_increase_pct,
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

    # Scale start/complete vertical lines on metric rows only
    if timing.scale_start_utc:
        for row_idx in range(1, 4):
            fig.add_vline(
                x=timing.scale_start_utc, line_dash="dash",
                line_color="#d62728", line_width=2,
                annotation_text="Scale Start" if row_idx == 1 else None,
                annotation_position="top left" if row_idx == 1 else None,
                row=row_idx, col=1,
            )
    if timing.scale_complete_utc:
        for row_idx in range(1, 4):
            fig.add_vline(
                x=timing.scale_complete_utc, line_dash="dash",
                line_color="#9467bd", line_width=2,
                annotation_text="Scale Complete" if row_idx == 1 else None,
                annotation_position="top right" if row_idx == 1 else None,
                row=row_idx, col=1,
            )

    # Detect and annotate failovers on ALL panels (TPS, QPS, Latency, Gantt)
    if k8s_rows:
        prev_primary = ""
        failover_times: list[tuple[str, str, str]] = []
        for row in k8s_rows:
            if row.gr_role == "PRIMARY":
                if prev_primary and row.pod != prev_primary:
                    from_short = prev_primary.split("-mysql-")[-1] if "-mysql-" in prev_primary else prev_primary
                    to_short = row.pod.split("-mysql-")[-1] if "-mysql-" in row.pod else row.pod
                    failover_times.append((row.timestamp, from_short, to_short))
                prev_primary = row.pod
        for fo_time, fo_from, fo_to in failover_times:
            fo_label = f"⚡ Failover mysql-{fo_from} → mysql-{fo_to}"
            for row_idx in range(1, 5):
                fig.add_vline(
                    x=fo_time, line_dash="dot",
                    line_color="#cf222e", line_width=2.5,
                    annotation_text=fo_label if row_idx == 1 else None,
                    annotation_position="top right" if row_idx == 1 else None,
                    annotation_font=dict(size=11, color="#cf222e", family="monospace") if row_idx == 1 else None,
                    annotation_bgcolor="rgba(255,235,233,0.9)" if row_idx == 1 else None,
                    annotation_bordercolor="#cf222e" if row_idx == 1 else None,
                    annotation_borderwidth=1 if row_idx == 1 else None,
                    annotation_borderpad=4 if row_idx == 1 else None,
                    row=row_idx, col=1,
                )

    # Temporal activities as Gantt bars — scale start/end shown as shaded region
    if activities:
        if timing.scale_start_utc and timing.scale_complete_utc:
            fig.add_vrect(
                x0=timing.scale_start_utc, x1=timing.scale_complete_utc,
                fillcolor="#ff7f0e", opacity=0.08, line_width=0,
                row=4, col=1,
            )
            fig.add_vline(x=timing.scale_start_utc, line_dash="dash",
                          line_color="#d62728", line_width=1.5, row=4, col=1)
            fig.add_vline(x=timing.scale_complete_utc, line_dash="dash",
                          line_color="#9467bd", line_width=1.5, row=4, col=1)

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

    fig.update_layout(
        height=1200,
        hovermode="x unified",
        legend=dict(orientation="h", yanchor="bottom", y=1.01, x=0),
        margin=dict(t=60, b=40),
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

    pods = sorted(set(r.pod for r in k8s_rows))
    pod_short = {p: p.split("-mysql-")[-1] if "-mysql-" in p else p for p in pods}
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
        if row.gr_state in ("ONLINE", "RECOVERING", "ERROR", "OFFLINE"):
            return row.gr_state
        if "PodInitializing" in (row.gr_detail or ""):
            return "PODINITIALIZING"
        if row.phase == "Pending" or (row.phase == "Running" and row.ready == "false"):
            return "PODINITIALIZING"
        return "OFFLINE"

    def _resolve_gr_role(row: K8sPodRow) -> tuple[int, str]:
        if row.gr_role in ("PRIMARY", "SECONDARY"):
            return role_map[row.gr_role], row.gr_role
        return 0, "Unknown"

    pod_colors = ["#0969da", "#d62728", "#2ca02c", "#9467bd", "#8c564b"]

    for idx, pod in enumerate(pods):
        pod_rows = [r for r in k8s_rows if r.pod == pod]
        times = [r.timestamp for r in pod_rows]
        label = f"mysql-{pod_short[pod]}"
        color = pod_colors[idx % len(pod_colors)]

        # GR Role
        role_vals = [_resolve_gr_role(r) for r in pod_rows]
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
        # vCPUs per pod — shows the rolling upgrade progression
        for idx, pod in enumerate(pods):
            pod_rows = [r for r in k8s_rows if r.pod == pod]
            times = [r.timestamp for r in pod_rows]
            label = f"mysql-{pod_short[pod]}"
            color = pod_colors[idx % len(pod_colors)]
            vcpus = [int(r.vcpus) if r.vcpus and r.vcpus.isdigit() else 0 for r in pod_rows]
            fig.add_trace(go.Scatter(
                x=times, y=vcpus,
                mode="lines", name=label,
                line=dict(width=2, color=color),
                hovertext=[f"{label}: {v} vCPU ({r.slug})" for v, r in zip(vcpus, pod_rows)],
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


# =============================================================================
# HTML rendering
# =============================================================================


def render_impact_card(impact: dict[str, Any], timing: ScaleTiming) -> str:
    pre = impact["pre"]
    during = impact["during"]
    post = impact["post"]
    slowest = impact.get("slowest_activity")

    slowest_html = ""
    if slowest:
        retry_note = f" (attempt {slowest['attempt']})" if slowest.get('attempt', 1) > 1 else ""
        slowest_html = f"""
        <div class="kpi">
          <div class="kpi-value">{_fmt_duration(slowest['duration_sec'])}</div>
          <div class="kpi-label">Slowest Activity{retry_note}<br><code>{html_mod.escape(slowest['name'])}</code></div>
        </div>"""

    tps_post_val = impact["tps_post_change_pct"]
    tps_post_label = "TPS Increase" if tps_post_val >= 0 else "TPS Decrease"
    tps_post_class = "kpi-good" if tps_post_val >= 0 else "kpi-warn"
    tps_post_sign = "+" if tps_post_val >= 0 else ""

    return f"""
    <section>
      <h2>Scaling Impact Summary</h2>
      <div class="kpi-grid">
        <div class="kpi">
          <div class="kpi-value">{_fmt_duration(timing.scale_duration_sec)}</div>
          <div class="kpi-label">Total Scale Duration</div>
        </div>
        <div class="kpi {"kpi-warn" if impact['tps_drop_pct'] > 10 else ""}">
          <div class="kpi-value">{impact['tps_drop_pct']:.1f}%</div>
          <div class="kpi-label">TPS Drop During Scaling</div>
        </div>
        <div class="kpi {tps_post_class}">
          <div class="kpi-value">{tps_post_sign}{tps_post_val:.1f}%</div>
          <div class="kpi-label">{tps_post_label} After Scaling</div>
        </div>
        <div class="kpi {"kpi-warn" if impact['lat_increase_pct'] > 50 else ""}">
          <div class="kpi-value">{impact['lat_increase_pct']:.1f}%</div>
          <div class="kpi-label">Latency Increase During</div>
        </div>
        <div class="kpi {"kpi-bad" if impact['zero_tps_during'] > 0 else ""}">
          <div class="kpi-value">{impact['zero_tps_during']}s</div>
          <div class="kpi-label">Zero-TPS During Scaling</div>
        </div>
        {slowest_html}
      </div>

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
    </section>
    """


def render_temporal_breakdown(activities: list[TemporalActivity]) -> str:
    if not activities:
        return "<section><h2>Temporal Workflow Timeline</h2><p><em>No temporal_history.json found.</em></p></section>"

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
      <h2>Where Is Time Spent? (Temporal Activities)</h2>
      <p>Total wall-clock span: <strong>{_fmt_duration(total_wall)}</strong>. Sorted by wall-clock duration descending (includes retry/backoff time).</p>
      <table class="activity-table">
        <thead>
          <tr><th>Activity</th><th>Wall Clock</th><th>% of Total</th><th>Bar</th><th>Scheduled</th><th>Started</th><th>Ended</th><th>Status</th></tr>
        </thead>
        <tbody>{rows_html}</tbody>
      </table>
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


def render_vertical_scale_timeline(k8s_rows: list[K8sPodRow], timing: ScaleTiming) -> str:
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

    # Detect failover
    failovers: list[dict[str, str]] = []
    prev_primary = ""
    for row in k8s_rows:
        if row.gr_role == "PRIMARY":
            if prev_primary and prev_primary != row.pod and row.pod != prev_primary:
                failovers.append({"timestamp": row.timestamp, "from": prev_primary, "to": row.pod})
            prev_primary = row.pod

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
        old_role = m.get("old_role", "")
        if old_role == "PRIMARY":
            role_badge = ' <span style="background:#fff8c5;color:#9a6700;padding:2px 6px;border-radius:4px;font-size:0.75rem;font-weight:600;">was PRIMARY</span>'
        elif old_role == "SECONDARY":
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
      {failover_html}
    </section>
    """


# =============================================================================
# Main report assembly
# =============================================================================


CSS = """
body {
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
  margin: 0; padding: 24px 32px 48px;
  background: #f6f8fa; color: #1f2328;
}
h1 { margin-top: 0; font-size: 1.6rem; }
h2 { margin-top: 2rem; border-bottom: 1px solid #d0d7de; padding-bottom: 0.3rem; font-size: 1.2rem; }
.meta { color: #57606a; margin-bottom: 1.5rem; }
.badge {
  display: inline-block; padding: 0.15rem 0.55rem; border-radius: 999px;
  font-size: 0.85rem; font-weight: 600;
}
.badge-ok { background: #dafbe1; color: #116329; }
.badge-fail { background: #ffebe9; color: #cf222e; }
.kpi-grid {
  display: grid; grid-template-columns: repeat(auto-fit, minmax(160px, 1fr));
  gap: 12px; margin: 16px 0;
}
.kpi {
  background: #fff; border: 1px solid #d0d7de; border-radius: 8px;
  padding: 16px; text-align: center;
}
.kpi-value { font-size: 1.5rem; font-weight: 700; color: #1f2328; }
.kpi-label { font-size: 0.82rem; color: #57606a; margin-top: 4px; }
.kpi-warn .kpi-value { color: #bf8700; }
.kpi-bad .kpi-value { color: #cf222e; }
.kpi-good .kpi-value { color: #116329; }
table.phase-table, table.kv, table.activity-table {
  width: 100%; border-collapse: collapse; background: #fff;
  border: 1px solid #d0d7de; border-radius: 8px; overflow: hidden;
  margin-top: 12px;
}
table.phase-table th, table.phase-table td,
table.kv th, table.kv td,
table.activity-table th, table.activity-table td {
  padding: 0.5rem 0.7rem; border-bottom: 1px solid #eaeef2;
  text-align: left; font-size: 0.88rem;
}
table.phase-table th, table.kv th, table.activity-table th { background: #f6f8fa; }
.chart-box { background: #fff; border: 1px solid #d0d7de; border-radius: 8px; padding: 12px; margin-top: 12px; }
section { margin-bottom: 1.5rem; }
code { font-size: 0.88em; }
.bar { height: 14px; background: #0969da; border-radius: 3px; min-width: 2px; }
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
    main_fig = build_main_figure(metrics, timing, k8s_rows, activities) if metrics else None
    k8s_fig = build_k8s_figure(k8s_rows, timing)

    main_chart_html = main_fig.to_html(full_html=False, include_plotlyjs=False, div_id="main-chart") if main_fig else "<p><em>No metrics data.</em></p>"
    k8s_chart_html = k8s_fig.to_html(full_html=False, include_plotlyjs=False, div_id="k8s-chart") if k8s_fig else ""

    generated_at = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    title = f"Scaling Analysis — {timing.scale_description or timing.scale_types or run_dir.name}"
    badge_class = "badge-ok" if timing.success else "badge-fail"
    badge_text = "SUCCESS" if timing.success else "FAILED"

    overview_items = [
        ("Engine", timing.engine or conf.get("ENGINE", "N/A")),
        ("Cluster ID", conf.get("CLUSTER_ID", "N/A")),
        ("Scale Type", timing.scale_description or timing.scale_types or "N/A"),
        ("Before", f"{timing.initial_size} · {timing.initial_nodes} node{'s' if timing.initial_nodes != 1 else ''} · {timing.initial_storage_gib} GiB"),
        ("After", f"{timing.target_size or timing.initial_size} · {timing.target_nodes or timing.initial_nodes} node{'s' if (timing.target_nodes or timing.initial_nodes) != 1 else ''} · {timing.target_storage_gib or timing.initial_storage_gib} GiB"),
        ("Scale Duration", _fmt_duration(timing.scale_duration_sec)),
        ("TPC-C Threads", conf.get("TPCC_THREADS", "N/A")),
        ("TPC-C Duration", _fmt_duration(int(conf.get("TPCC_MAX_TIME", "0")))),
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
  <h1>{html_mod.escape(title)}</h1>
  <p class="meta">
    Run: <code>{html_mod.escape(run_dir.name)}</code>
    &nbsp;·&nbsp; Generated {html_mod.escape(generated_at)}
    &nbsp;·&nbsp; <span class="badge {badge_class}">{badge_text}</span>
  </p>

  <section>
    <h2>Run Overview</h2>
    <table class="kv"><tbody>{overview_rows}</tbody></table>
  </section>

  {render_impact_card(impact, timing)}
  {render_temporal_breakdown(activities)}

  <section>
    <h2>TPC-C Metrics & Temporal Activity Timeline</h2>
    <p>Red dashed = scale start. Purple dashed = scale complete. All panels share the time axis.</p>
    <div class="chart-box">{main_chart_html}</div>
  </section>

  {"<section><h2>K8s Pod Roles, GR State & " + ("Group Membership" if _is_horizontal_scale(timing) else "Node vCPUs" if _is_vertical_scale(timing) else "PVC Storage") + "</h2><p>" + ("Shows PRIMARY/SECONDARY role, Group Replication state, and GR member count over time." if _is_horizontal_scale(timing) else "Shows PRIMARY/SECONDARY role, Group Replication state, and vCPU count per pod as nodes are rolled to the new slug." if _is_vertical_scale(timing) else "Shows PRIMARY/SECONDARY role, Group Replication state, and PVC capacity per pod over time.") + "</p><div class='chart-box'>" + k8s_chart_html + "</div></section>" if k8s_chart_html else ""}
  {render_node_join_timeline(k8s_rows, timing)}
  {render_vertical_scale_timeline(k8s_rows, timing)}
  {render_pvc_timeline(k8s_rows)}
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
