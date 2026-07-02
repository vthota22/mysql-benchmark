#!/usr/bin/env python3
"""Parse k8s_scaling_monitor.sh TSV output into a human-readable analysis.

Reads:
  - k8s_monitor.tsv   (per-poll pod state with GR role, node, slug)
  - k8s_monitor.log   (failover / node-change messages)

Produces:
  - k8s_analysis_summary.txt   human-readable narrative

Usage:
  python3 parse_k8s_events.py /path/to/k8s_monitor_output_dir
"""

from __future__ import annotations

import argparse
import csv
import sys
from dataclasses import dataclass
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


def load_tsv(path: Path) -> list[Row]:
    if not path.is_file():
        return []
    rows: list[Row] = []
    with path.open(encoding="utf-8", errors="replace") as f:
        reader = csv.DictReader(f, delimiter="\t")
        for rec in reader:
            rows.append(Row(
                timestamp=rec.get("timestamp", ""),
                pod=rec.get("pod", ""),
                phase=rec.get("phase", ""),
                ready=rec.get("ready", ""),
                gr_role=rec.get("gr_role", ""),
                gr_state=rec.get("gr_state", ""),
                gr_detail=rec.get("gr_detail", ""),
                gr_members=rec.get("gr_members", "?"),
                gr_online=rec.get("gr_online", "?"),
                doks_node=rec.get("doks_node", ""),
                slug=rec.get("slug", ""),
                vcpus=rec.get("vcpus", ""),
                mem_gib=rec.get("mem_gib", ""),
                pvc_req=rec.get("pvc_req", "?"),
                pvc_cap=rec.get("pvc_cap", "?"),
                restarts=rec.get("restarts", "0"),
                deleting=rec.get("deleting", ""),
            ))
    return rows


def load_log(path: Path) -> list[str]:
    if not path.is_file():
        return []
    return path.read_text(encoding="utf-8", errors="replace").splitlines()


def generate_summary(rows: list[Row], log_lines: list[str]) -> str:
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

    # --- Monitor log highlights ---
    highlights = [l for l in log_lines if any(kw in l for kw in
                  ("FAILOVER", "NODE CHANGE", "ERROR", "Initial primary"))]
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

    summary = generate_summary(rows, log_lines)
    (out / "k8s_analysis_summary.txt").write_text(summary, encoding="utf-8")
    print(summary)

    print(f"\nSummary written to {out / 'k8s_analysis_summary.txt'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
