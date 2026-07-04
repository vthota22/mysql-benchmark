#!/usr/bin/env python3
"""Parse k8s_scaling_monitor.sh TSV output into a human-readable analysis.

Reads:
  - k8s_monitor.tsv          (per-poll pod state with GR role, node, slug)
  - haproxy_monitor.tsv      (HAProxy/router pod state)
  - endpoints_monitor.tsv    (service endpoint changes)
  - k8s_events.tsv           (namespace K8s events)
  - k8s_monitor.log          (failover / node-change messages)

Produces:
  - k8s_analysis_summary.txt   human-readable narrative

Usage:
  python3 parse_k8s_events.py /path/to/k8s_monitor_output_dir
"""

from __future__ import annotations

import argparse
import csv
import sys
from dataclasses import dataclass, field
from pathlib import Path


@dataclass
class Row:
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
    gr_queue: str = "?"
    gr_applier_queue: str = "?"


@dataclass
class HaproxyRow:
    timestamp: str
    pod: str
    component: str
    phase: str
    ready: str
    node: str
    restarts: str
    reason: str


@dataclass
class EndpointRow:
    timestamp: str
    service: str
    state: str
    pod: str
    ip: str
    ports: str


@dataclass
class EventRow:
    poll_ts: str
    event_ts: str
    type: str
    kind: str
    object: str
    reason: str
    count: str
    message: str


def _get(rec: dict, key: str, default: str = "") -> str:
    """Get value from CSV record, treating None as the default."""
    val = rec.get(key)
    return val if val is not None else default


def load_tsv(path: Path) -> list[Row]:
    if not path.is_file():
        return []
    rows: list[Row] = []
    with path.open(encoding="utf-8", errors="replace") as f:
        reader = csv.DictReader(f, delimiter="\t")
        for rec in reader:
            ts = _get(rec, "timestamp")
            pod = _get(rec, "pod")
            if not ts or not pod or "T" not in ts:
                continue
            rows.append(Row(
                timestamp=_get(rec, "timestamp"),
                pod=_get(rec, "pod"),
                phase=_get(rec, "phase"),
                ready=_get(rec, "ready"),
                gr_role=_get(rec, "gr_role"),
                gr_state=_get(rec, "gr_state"),
                gr_detail=_get(rec, "gr_detail"),
                gr_members=_get(rec, "gr_members", "?"),
                gr_online=_get(rec, "gr_online", "?"),
                doks_node=_get(rec, "doks_node"),
                slug=_get(rec, "slug"),
                vcpus=_get(rec, "vcpus"),
                mem_gib=_get(rec, "mem_gib"),
                pvc_req=_get(rec, "pvc_req", "?"),
                pvc_cap=_get(rec, "pvc_cap", "?"),
                restarts=_get(rec, "restarts", "0"),
                deleting=_get(rec, "deleting"),
                read_only=_get(rec, "read_only", "?"),
                super_read_only=_get(rec, "super_read_only", "?"),
                gr_queue=_get(rec, "gr_queue", "?"),
                gr_applier_queue=_get(rec, "gr_applier_queue", "?"),
            ))
    return rows


def load_haproxy_tsv(path: Path) -> list[HaproxyRow]:
    if not path.is_file():
        return []
    rows: list[HaproxyRow] = []
    with path.open(encoding="utf-8", errors="replace") as f:
        reader = csv.DictReader(f, delimiter="\t")
        for rec in reader:
            rows.append(HaproxyRow(
                timestamp=rec.get("timestamp", ""),
                pod=rec.get("pod", ""),
                component=rec.get("component", ""),
                phase=rec.get("phase", ""),
                ready=rec.get("ready", ""),
                node=rec.get("node", ""),
                restarts=rec.get("restarts", "0"),
                reason=rec.get("reason", ""),
            ))
    return rows


def load_endpoints_tsv(path: Path) -> list[EndpointRow]:
    if not path.is_file():
        return []
    rows: list[EndpointRow] = []
    with path.open(encoding="utf-8", errors="replace") as f:
        reader = csv.DictReader(f, delimiter="\t")
        for rec in reader:
            rows.append(EndpointRow(
                timestamp=rec.get("timestamp", ""),
                service=rec.get("service", ""),
                state=rec.get("state", ""),
                pod=rec.get("pod", ""),
                ip=rec.get("ip", ""),
                ports=rec.get("ports", ""),
            ))
    return rows


def load_events_tsv(path: Path) -> list[EventRow]:
    if not path.is_file():
        return []
    rows: list[EventRow] = []
    with path.open(encoding="utf-8", errors="replace") as f:
        reader = csv.DictReader(f, delimiter="\t")
        for rec in reader:
            rows.append(EventRow(
                poll_ts=rec.get("poll_ts", ""),
                event_ts=rec.get("event_ts", ""),
                type=rec.get("type", ""),
                kind=rec.get("kind", ""),
                object=rec.get("object", ""),
                reason=rec.get("reason", ""),
                count=rec.get("count", ""),
                message=rec.get("message", ""),
            ))
    return rows


def load_log(path: Path) -> list[str]:
    if not path.is_file():
        return []
    return path.read_text(encoding="utf-8", errors="replace").splitlines()


def generate_summary(
    rows: list[Row],
    log_lines: list[str],
    haproxy_rows: list[HaproxyRow] | None = None,
    endpoint_rows: list[EndpointRow] | None = None,
    event_rows: list[EventRow] | None = None,
) -> str:
    lines: list[str] = []
    lines.append("=" * 72)
    lines.append("K8s Scaling Monitor — Analysis Summary")
    lines.append("=" * 72)

    if not rows:
        lines.append("\nNo monitoring data found.")
        return "\n".join(lines)

    timestamps = sorted(set(r.timestamp for r in rows))
    lines.append(f"\nMonitoring period: {timestamps[0]} → {timestamps[-1]}")
    lines.append(f"Poll cycles: {len(timestamps)}")

    pods = sorted(set(r.pod for r in rows))
    lines.append(f"Pods observed: {len(pods)} — {', '.join(pods)}")

    # --- Primary tracking ---
    lines.append("\n--- Primary Role Over Time ---")
    prev_primary = ""
    failover_count = 0
    for ts in timestamps:
        cycle = [r for r in rows if r.timestamp == ts]
        primary = next((r.pod for r in cycle if r.gr_role == "PRIMARY"), None)
        if primary and primary != prev_primary:
            if prev_primary:
                failover_count += 1
                lines.append(f"  [{ts}] FAILOVER: {prev_primary} → {primary}")
            else:
                lines.append(f"  [{ts}] initial primary: {primary}")
            prev_primary = primary
    lines.append(f"  Total failovers: {failover_count}")

    # --- GR state transitions per pod ---
    lines.append("\n--- GR Member State Transitions ---")
    for pod in pods:
        pod_rows = [r for r in rows if r.pod == pod]
        prev_state = ""
        transitions: list[str] = []
        for r in pod_rows:
            state_key = f"{r.gr_role}/{r.gr_state}"
            if r.gr_detail and r.gr_detail not in ("-", "_"):
                state_key += f" ({r.gr_detail})"
            if state_key != prev_state:
                transitions.append(f"[{r.timestamp}] {state_key}")
                prev_state = state_key
        lines.append(f"  {pod}: {len(transitions)} transition(s)")
        for t in transitions:
            lines.append(f"    {t}")

    # --- GR errors / non-ONLINE states ---
    error_rows = [r for r in rows if r.gr_state not in ("ONLINE", "Synced", "?", "")]
    if error_rows:
        lines.append(f"\n--- Non-ONLINE GR States: {len(error_rows)} occurrence(s) ---")
        seen: set[str] = set()
        for r in error_rows:
            key = f"{r.pod}:{r.gr_state}:{r.gr_detail}"
            if key not in seen:
                detail = f" — {r.gr_detail}" if r.gr_detail else ""
                lines.append(f"  [{r.timestamp}] {r.pod}: {r.gr_state}{detail}")
                seen.add(key)

    # --- Pod phase transitions ---
    lines.append("\n--- Pod Phase Transitions ---")
    for pod in pods:
        pod_rows = [r for r in rows if r.pod == pod]
        prev_phase = ""
        transitions: list[str] = []
        for r in pod_rows:
            phase_key = f"{r.phase} ready={r.ready}"
            if r.deleting == "yes":
                phase_key += " (deleting)"
            if phase_key != prev_phase:
                transitions.append(f"[{r.timestamp}] {phase_key}")
                prev_phase = phase_key
        lines.append(f"  {pod}: {len(transitions)} transition(s)")
        for t in transitions:
            lines.append(f"    {t}")

    # --- Node / slug migrations ---
    lines.append("\n--- Node Binding & Slug Changes ---")
    for pod in pods:
        pod_rows = [r for r in rows if r.pod == pod]
        prev_node = ""
        migrations: list[str] = []
        for r in pod_rows:
            node_key = f"{r.doks_node} ({r.slug}, {r.vcpus}vcpu, {r.mem_gib}GiB)"
            if node_key != prev_node:
                migrations.append(f"[{r.timestamp}] → {node_key}")
                prev_node = node_key
        nodes_seen = set(r.doks_node for r in pod_rows if r.doks_node)
        slugs_seen = set(r.slug for r in pod_rows if r.slug and r.slug != "?")
        lines.append(f"  {pod}: {len(nodes_seen)} node(s), {len(slugs_seen)} slug(s), {len(migrations)} change(s)")
        for m in migrations:
            lines.append(f"    {m}")

    # --- Slug summary ---
    lines.append("\n--- Slug Summary ---")
    slug_first: dict[str, str] = {}
    slug_last: dict[str, str] = {}
    for r in rows:
        if r.slug and r.slug != "?":
            if r.slug not in slug_first:
                slug_first[r.slug] = r.timestamp
            slug_last[r.slug] = r.timestamp
    for slug in sorted(slug_first.keys()):
        lines.append(f"  {slug}: first seen {slug_first[slug]}, last seen {slug_last[slug]}")

    # --- GR group size (horizontal scaling) ---
    lines.append("\n--- GR Group Size (Horizontal Scaling) ---")
    prev_members = ""
    member_changes: list[str] = []
    for ts in timestamps:
        cycle = [r for r in rows if r.timestamp == ts]
        if cycle:
            members = cycle[0].gr_members
            online = cycle[0].gr_online
            key = f"{members}/{online}"
            if key != prev_members:
                member_changes.append(f"[{ts}] members={members} online={online}")
                prev_members = key
    for m in member_changes:
        lines.append(f"  {m}")
    if not member_changes:
        lines.append("  no changes")

    # --- PVC / Storage (storage scaling) ---
    lines.append("\n--- PVC Storage (Storage Scaling) ---")
    for pod in pods:
        pod_rows = [r for r in rows if r.pod == pod]
        prev_pvc = ""
        pvc_changes: list[str] = []
        for r in pod_rows:
            pvc_key = f"req={r.pvc_req} cap={r.pvc_cap}"
            if pvc_key != prev_pvc:
                pvc_changes.append(f"[{r.timestamp}] {pvc_key}")
                prev_pvc = pvc_key
        lines.append(f"  {pod}: {len(pvc_changes)} change(s)")
        for c in pvc_changes:
            lines.append(f"    {c}")

    # --- Restarts ---
    lines.append("\n--- Restarts ---")
    for pod in pods:
        pod_rows = [r for r in rows if r.pod == pod]
        restart_vals = []
        for r in pod_rows:
            try:
                restart_vals.append(int(r.restarts))
            except ValueError:
                restart_vals.append(0)
        if restart_vals:
            lines.append(f"  {pod}: min={min(restart_vals)} max={max(restart_vals)}")
        else:
            lines.append(f"  {pod}: no data")

    # --- read_only / super_read_only transitions (failover timeline) ---
    lines.append("\n--- Read-Only Status Transitions (Failover Indicator) ---")
    for pod in pods:
        pod_rows = [r for r in rows if r.pod == pod]
        prev_ro = ""
        transitions: list[str] = []
        for r in pod_rows:
            ro_key = f"ro={r.read_only} sro={r.super_read_only}"
            if ro_key != prev_ro and r.read_only != "?":
                transitions.append(f"[{r.timestamp}] {ro_key} (role={r.gr_role})")
                prev_ro = ro_key
        if transitions:
            lines.append(f"  {pod}: {len(transitions)} transition(s)")
            for t in transitions:
                lines.append(f"    {t}")
        else:
            lines.append(f"  {pod}: no read_only data")

    # Highlight periods where PRIMARY was read_only (failover in progress)
    ro_primary_periods = [
        r for r in rows
        if r.gr_role == "PRIMARY" and r.read_only == "1"
    ]
    if ro_primary_periods:
        lines.append(f"\n  WARNING: PRIMARY was read_only in {len(ro_primary_periods)} poll(s):")
        seen_pods: set[str] = set()
        for r in ro_primary_periods:
            key = f"{r.pod}:{r.timestamp}"
            if key not in seen_pods:
                lines.append(f"    [{r.timestamp}] {r.pod} — read_only=1, super_read_only={r.super_read_only}")
                seen_pods.add(key)
                if len(seen_pods) >= 20:
                    lines.append(f"    ... ({len(ro_primary_periods) - 20} more)")
                    break

    # --- GR Apply Queue (replication lag) ---
    lines.append("\n--- GR Replication Queue (Transaction Lag) ---")
    for pod in pods:
        pod_rows = [r for r in rows if r.pod == pod]
        queue_vals = []
        applier_vals = []
        for r in pod_rows:
            try:
                queue_vals.append(int(r.gr_queue))
            except (ValueError, TypeError):
                pass
            try:
                applier_vals.append(int(r.gr_applier_queue))
            except (ValueError, TypeError):
                pass
        if queue_vals:
            max_q = max(queue_vals)
            max_a = max(applier_vals) if applier_vals else 0
            lines.append(
                f"  {pod}: cert_queue max={max_q} avg={sum(queue_vals)/len(queue_vals):.1f}"
                f" | applier_queue max={max_a} avg={sum(applier_vals)/len(applier_vals):.1f}" if applier_vals else
                f"  {pod}: cert_queue max={max_q} avg={sum(queue_vals)/len(queue_vals):.1f}"
            )
            # Flag high queue (potential lag during failover)
            high_queue = [(r.timestamp, r.gr_queue) for r in pod_rows
                          if r.gr_queue not in ("?", "") and int(r.gr_queue) > 100]
            if high_queue:
                lines.append(f"    HIGH QUEUE (>100 txns): {len(high_queue)} occurrence(s)")
                for ts, q in high_queue[:5]:
                    lines.append(f"      [{ts}] queue={q}")
        else:
            lines.append(f"  {pod}: no queue data")

    # --- HAProxy / Router Pod State ---
    if haproxy_rows:
        lines.append("\n--- HAProxy / Router Pod State ---")
        ha_pods = sorted(set(r.pod for r in haproxy_rows))
        lines.append(f"  Proxy pods observed: {len(ha_pods)} — {', '.join(ha_pods)}")
        for pod in ha_pods:
            pod_data = [r for r in haproxy_rows if r.pod == pod]
            prev_state = ""
            transitions = []
            for r in pod_data:
                state_key = f"{r.phase} ready={r.ready}"
                if r.reason and r.reason != "-":
                    state_key += f" ({r.reason})"
                if state_key != prev_state:
                    transitions.append(f"[{r.timestamp}] {state_key}")
                    prev_state = state_key
            lines.append(f"  {pod} ({pod_data[0].component if pod_data else '?'}):")
            lines.append(f"    {len(transitions)} state transition(s)")
            for t in transitions:
                lines.append(f"      {t}")

            # Flag HAProxy not-ready periods
            not_ready = [r for r in pod_data if r.ready == "false"]
            if not_ready:
                lines.append(f"    NOT READY for {len(not_ready)} poll(s) — traffic may have been interrupted")
                lines.append(f"      first: [{not_ready[0].timestamp}]  last: [{not_ready[-1].timestamp}]")

    # --- Service Endpoint Changes (HAProxy failover detection) ---
    if endpoint_rows:
        lines.append("\n--- Service Endpoint Changes (HAProxy Failover Detection) ---")
        services = sorted(set(r.service for r in endpoint_rows))
        for svc in services:
            svc_rows = [r for r in endpoint_rows if r.service == svc]
            timestamps_ep = sorted(set(r.timestamp for r in svc_rows))
            prev_state_key = ""
            changes: list[str] = []
            for ts in timestamps_ep:
                cycle = sorted(
                    [r for r in svc_rows if r.timestamp == ts],
                    key=lambda x: (x.state, x.pod)
                )
                state_key = "|".join(f"{r.state}:{r.pod}" for r in cycle)
                if state_key != prev_state_key:
                    ready_pods = [r.pod for r in cycle if r.state == "ready"]
                    not_ready_pods = [r.pod for r in cycle if r.state == "not_ready"]
                    desc = f"ready=[{','.join(ready_pods)}]"
                    if not_ready_pods:
                        desc += f" not_ready=[{','.join(not_ready_pods)}]"
                    changes.append(f"[{ts}] {desc}")
                    prev_state_key = state_key
            lines.append(f"  {svc}: {len(changes)} endpoint change(s)")
            for c in changes:
                lines.append(f"    {c}")

    # --- K8s Events (warnings and notable events) ---
    if event_rows:
        lines.append("\n--- K8s Events (Warnings & Notable) ---")
        warnings = [e for e in event_rows if e.type == "Warning"]
        notable_reasons = {"Killing", "Unhealthy", "FailedScheduling",
                           "Evicted", "OOMKilling", "BackOff", "Failed",
                           "FailedMount", "NodeNotReady"}
        notable = [e for e in event_rows
                   if e.reason in notable_reasons or e.type == "Warning"]
        if notable:
            lines.append(f"  Total warning/notable events: {len(notable)}")
            # Group by object
            by_obj: dict[str, list[EventRow]] = {}
            for e in notable:
                key = f"{e.kind}/{e.object}"
                by_obj.setdefault(key, []).append(e)
            for obj_key in sorted(by_obj.keys()):
                obj_events = by_obj[obj_key]
                lines.append(f"  {obj_key}: {len(obj_events)} event(s)")
                # Show unique reasons with first occurrence
                seen_reasons: dict[str, str] = {}
                for e in obj_events:
                    if e.reason not in seen_reasons:
                        seen_reasons[e.reason] = e.event_ts
                for reason, first_ts in sorted(seen_reasons.items(), key=lambda x: x[1]):
                    count = sum(1 for e in obj_events if e.reason == reason)
                    sample_msg = next(
                        (e.message for e in obj_events if e.reason == reason), ""
                    )
                    lines.append(f"    [{first_ts}] {reason} (x{count}): {sample_msg[:120]}")
        else:
            lines.append("  No warning/notable events captured.")

    # --- Monitor log highlights ---
    highlights = [l for l in log_lines if any(kw in l for kw in
                  ("FAILOVER", "NODE CHANGE", "ERROR", "Initial primary",
                   "ENDPOINT CHANGE", "READ_ONLY on PRIMARY", "K8S_EVENT"))]
    if highlights:
        lines.append("\n--- Key Log Messages ---")
        for h in highlights:
            lines.append(f"  {h}")

    lines.append("\n" + "=" * 72)
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("monitor_dir", type=Path,
                        help="Directory containing k8s_scaling_monitor.sh output")
    parser.add_argument("-o", "--output-dir", type=Path, default=None)
    args = parser.parse_args()

    src = args.monitor_dir.resolve()
    out = (args.output_dir or src).resolve()
    out.mkdir(parents=True, exist_ok=True)

    rows = load_tsv(src / "k8s_monitor.tsv")
    log_lines = load_log(src / "k8s_monitor.log")
    haproxy_rows = load_haproxy_tsv(src / "haproxy_monitor.tsv")
    endpoint_rows = load_endpoints_tsv(src / "endpoints_monitor.tsv")
    event_rows = load_events_tsv(src / "k8s_events.tsv")

    summary = generate_summary(
        rows, log_lines,
        haproxy_rows=haproxy_rows or None,
        endpoint_rows=endpoint_rows or None,
        event_rows=event_rows or None,
    )
    (out / "k8s_analysis_summary.txt").write_text(summary, encoding="utf-8")
    print(summary)

    print(f"\nSummary written to {out / 'k8s_analysis_summary.txt'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
