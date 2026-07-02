#!/usr/bin/env python3
"""Parse k8s_scaling_monitor.sh JSONL output into analysis-ready CSVs and a
human-readable timeline of scaling events.

Reads from:
  - k8s_snapshots.jsonl  (pod state + PXC CR status)
  - galera_status.jsonl   (per-pod Galera replication state)
  - k8s_events.jsonl      (Kubernetes events)
  - k8s_nodes.jsonl       (node state)
  - k8s_pvcs.jsonl        (PVC state)
  - k8s_timeline.jsonl    (high-level change events)

Produces:
  - pod_timeline.csv          per-poll pod phase/ready/node/restarts
  - galera_timeline.csv       per-poll Galera cluster size, state, primary
  - cluster_state_timeline.csv PXC CR status over time
  - scaling_events.csv        consolidated timeline of scaling-related events
  - k8s_analysis_summary.txt  human-readable narrative

Usage:
  python3 parse_k8s_events.py /path/to/k8s_monitor_output_dir
"""

from __future__ import annotations

import argparse
import csv
import json
import sys
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path


@dataclass
class PodState:
    ts: str
    epoch: int
    name: str
    phase: str
    ready: bool
    node: str
    restarts: int
    deletion_ts: str = ""


@dataclass
class GaleraState:
    ts: str
    epoch: int
    pod: str
    cluster_size: int
    cluster_status: str
    local_state: str
    local_state_num: int
    ready: str
    connected: str
    flow_control_paused: float
    read_only: str
    hostname: str
    incoming_addresses: str = ""


@dataclass
class ClusterCRState:
    ts: str
    epoch: int
    state: str
    spec_size: int
    pxc_ready: int
    pxc_size: int
    haproxy_ready: int
    resources_cpu: str
    resources_memory: str


@dataclass
class TimelineEvent:
    ts: str
    epoch: int
    event: str
    detail: str


@dataclass
class K8sEvent:
    ts: str
    event_type: str
    reason: str
    message: str
    object_kind: str
    object_name: str
    source: str


def load_jsonl(path: Path) -> list[dict]:
    if not path.is_file():
        return []
    records = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            records.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return records


def parse_pod_snapshots(records: list[dict]) -> list[PodState]:
    states: list[PodState] = []
    for rec in records:
        if rec.get("type") != "pod_snapshot":
            continue
        ts = rec["ts"]
        epoch = rec["epoch"]
        for pod in rec.get("pods", []):
            states.append(PodState(
                ts=ts, epoch=epoch,
                name=pod["name"], phase=pod["phase"],
                ready=pod["ready"], node=pod.get("node", ""),
                restarts=pod.get("restarts", 0),
                deletion_ts=pod.get("deletion_ts", ""),
            ))
    return states


def parse_galera_snapshots(records: list[dict]) -> list[GaleraState]:
    states: list[GaleraState] = []
    for rec in records:
        ts = rec["ts"]
        epoch = rec["epoch"]
        pod = rec["pod"]
        g = rec.get("replication", rec.get("galera", {}))
        repl_type = g.get("repl_type", "galera")

        if repl_type == "group_replication":
            states.append(GaleraState(
                ts=ts, epoch=epoch, pod=pod,
                cluster_size=_int(g.get("member_count", 0)),
                cluster_status=str(g.get("my_role", "")),
                local_state=str(g.get("my_state", "")),
                local_state_num=0,
                ready="ON" if g.get("my_state") == "ONLINE" else "OFF",
                connected="ON" if _int(g.get("online_count", 0)) > 0 else "OFF",
                flow_control_paused=0.0,
                read_only=str(g.get("read_only", "")),
                hostname=str(g.get("hostname", "")),
                incoming_addresses=str(g.get("primary_host", "")),
            ))
        else:
            states.append(GaleraState(
                ts=ts, epoch=epoch, pod=pod,
                cluster_size=_int(g.get("member_count", g.get("wsrep_cluster_size", 0))),
                cluster_status=str(g.get("cluster_status", g.get("wsrep_cluster_status", ""))),
                local_state=str(g.get("local_state", g.get("wsrep_local_state_comment", ""))),
                local_state_num=_int(g.get("local_state_num", g.get("wsrep_local_state", 0))),
                ready=str(g.get("wsrep_ready", g.get("ready", ""))),
                connected=str(g.get("wsrep_connected", g.get("connected", ""))),
                flow_control_paused=_float(g.get("flow_control_paused", g.get("wsrep_flow_control_paused", 0))),
                read_only=str(g.get("read_only", "")),
                hostname=str(g.get("hostname", "")),
                incoming_addresses=str(g.get("incoming_addresses", g.get("wsrep_incoming_addresses", ""))),
            ))
    return states


def parse_cluster_cr_snapshots(records: list[dict]) -> list[ClusterCRState]:
    states: list[ClusterCRState] = []
    for rec in records:
        if rec.get("type") not in ("pxc_status", "cr_status"):
            continue
        ts = rec["ts"]
        epoch = rec["epoch"]
        s = rec.get("status", {})
        states.append(ClusterCRState(
            ts=ts, epoch=epoch,
            state=s.get("state", "unknown"),
            spec_size=_int(s.get("size", 0)),
            pxc_ready=_int(s.get("mysql_ready", s.get("pxc_ready", 0))),
            pxc_size=_int(s.get("mysql_size", s.get("pxc_size", 0))),
            haproxy_ready=_int(s.get("haproxy_ready", 0)),
            resources_cpu=s.get("resources_requests_cpu", ""),
            resources_memory=s.get("resources_requests_memory", ""),
        ))
    return states


def parse_timeline(records: list[dict]) -> list[TimelineEvent]:
    events: list[TimelineEvent] = []
    for rec in records:
        detail = rec.get("detail", "")
        if isinstance(detail, dict):
            detail = json.dumps(detail)
        events.append(TimelineEvent(
            ts=rec["ts"], epoch=rec["epoch"],
            event=rec["event"], detail=detail,
        ))
    return events


def parse_k8s_events(records: list[dict]) -> list[K8sEvent]:
    events: list[K8sEvent] = []
    for rec in records:
        events.append(K8sEvent(
            ts=rec.get("ts", ""),
            event_type=rec.get("type", ""),
            reason=rec.get("reason", ""),
            message=rec.get("message", ""),
            object_kind=rec.get("object_kind", ""),
            object_name=rec.get("object_name", ""),
            source=rec.get("source", ""),
        ))
    return events


SCALING_EVENT_REASONS = {
    "SuccessfulCreate", "SuccessfulDelete", "Killing", "Scheduled",
    "Pulled", "Created", "Started", "ScalingReplicaSet",
    "FailedScheduling", "Unhealthy", "BackOff", "Evicted",
    "NodeNotReady", "NodeReady", "RegisteredNode",
}


def filter_scaling_events(events: list[K8sEvent]) -> list[K8sEvent]:
    return [e for e in events if e.reason in SCALING_EVENT_REASONS
            or "pxc" in e.object_name.lower()
            or e.object_kind in ("PerconaXtraDBCluster", "StatefulSet", "Pod")]


def _int(v) -> int:
    try:
        return int(v)
    except (ValueError, TypeError):
        return 0


def _float(v) -> float:
    try:
        return float(v)
    except (ValueError, TypeError):
        return 0.0


def write_pod_csv(states: list[PodState], path: Path) -> None:
    with path.open("w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["timestamp", "epoch", "pod", "phase", "ready", "node",
                     "restarts", "terminating"])
        for s in states:
            w.writerow([s.ts, s.epoch, s.name, s.phase, s.ready, s.node,
                         s.restarts, bool(s.deletion_ts)])


def write_galera_csv(states: list[GaleraState], path: Path) -> None:
    with path.open("w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["timestamp", "epoch", "pod", "cluster_size",
                     "cluster_status", "local_state", "local_state_num",
                     "ready", "connected", "flow_control_paused",
                     "read_only", "hostname", "incoming_addresses"])
        for s in states:
            w.writerow([s.ts, s.epoch, s.pod, s.cluster_size,
                         s.cluster_status, s.local_state, s.local_state_num,
                         s.ready, s.connected, s.flow_control_paused,
                         s.read_only, s.hostname, s.incoming_addresses])


def write_cluster_csv(states: list[ClusterCRState], path: Path) -> None:
    with path.open("w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["timestamp", "epoch", "cr_state", "spec_size",
                     "pxc_ready", "pxc_size", "haproxy_ready",
                     "resources_cpu", "resources_memory"])
        for s in states:
            w.writerow([s.ts, s.epoch, s.state, s.spec_size,
                         s.pxc_ready, s.pxc_size, s.haproxy_ready,
                         s.resources_cpu, s.resources_memory])


def write_scaling_events_csv(
    timeline: list[TimelineEvent],
    k8s_events: list[K8sEvent],
    path: Path,
) -> None:
    with path.open("w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["timestamp", "source", "event", "detail"])

        for t in timeline:
            w.writerow([t.ts, "monitor", t.event, t.detail])

        for e in filter_scaling_events(k8s_events):
            detail = f"{e.object_kind}/{e.object_name}: {e.message}"
            w.writerow([e.ts, f"k8s-{e.event_type}", e.reason, detail])


def generate_summary(
    pod_states: list[PodState],
    galera_states: list[GaleraState],
    cluster_states: list[ClusterCRState],
    timeline: list[TimelineEvent],
    k8s_events: list[K8sEvent],
) -> str:
    lines: list[str] = []
    lines.append("=" * 72)
    lines.append("K8s Scaling Monitor — Analysis Summary")
    lines.append("=" * 72)

    if timeline:
        lines.append(f"\nMonitoring period: {timeline[0].ts} → {timeline[-1].ts}")
        total_sec = timeline[-1].epoch - timeline[0].epoch
        lines.append(f"Duration: {total_sec}s ({total_sec // 60}m {total_sec % 60}s)")

    lines.append("\n--- Timeline of Key Events ---")
    for t in timeline:
        lines.append(f"  [{t.ts}] {t.event}: {t.detail}")

    failovers = [t for t in timeline if t.event == "PRIMARY_FAILOVER"]
    lines.append(f"\n--- Primary Failovers: {len(failovers)} ---")
    for f_ in failovers:
        lines.append(f"  [{f_.ts}] {f_.detail}")

    size_changes = [t for t in timeline if t.event == "CLUSTER_SIZE_CHANGE"]
    lines.append(f"\n--- Cluster Size Changes: {len(size_changes)} ---")
    for sc in size_changes:
        lines.append(f"  [{sc.ts}] {sc.detail}")

    node_changes = [t for t in timeline if t.event == "NODE_COUNT_CHANGE"]
    lines.append(f"\n--- Node Count Changes: {len(node_changes)} ---")
    for nc in node_changes:
        lines.append(f"  [{nc.ts}] {nc.detail}")

    if galera_states:
        lines.append("\n--- Galera Cluster Size Over Time ---")
        prev_size = None
        for g in galera_states:
            if g.cluster_size != prev_size:
                lines.append(f"  [{g.ts}] {g.pod}: wsrep_cluster_size={g.cluster_size} "
                             f"state={g.local_state}")
                prev_size = g.cluster_size

        lines.append("\n--- Galera Node States ---")
        sst_donors = [g for g in galera_states if g.local_state == "Donor/Desynced"]
        sst_joiners = [g for g in galera_states if g.local_state == "Joined"]
        lines.append(f"  SST Donor events: {len(sst_donors)}")
        for d in sst_donors:
            lines.append(f"    [{d.ts}] {d.pod}: Donor/Desynced (sending SST)")
        lines.append(f"  IST/Join events: {len(sst_joiners)}")
        for j in sst_joiners:
            lines.append(f"    [{j.ts}] {j.pod}: Joined")

    if cluster_states:
        lines.append("\n--- PXC CR State Transitions ---")
        prev_state = None
        for cs in cluster_states:
            if cs.state != prev_state:
                lines.append(f"  [{cs.ts}] state={cs.state} size={cs.spec_size} "
                             f"pxc_ready={cs.pxc_ready}/{cs.pxc_size} "
                             f"cpu={cs.resources_cpu} mem={cs.resources_memory}")
                prev_state = cs.state

    scaling_k8s = filter_scaling_events(k8s_events)
    if scaling_k8s:
        lines.append(f"\n--- Relevant K8s Events: {len(scaling_k8s)} ---")
        for e in scaling_k8s[:50]:
            lines.append(f"  [{e.ts}] {e.event_type}/{e.reason}: "
                         f"{e.object_kind}/{e.object_name} — {e.message[:120]}")

    if pod_states:
        pods = set(s.name for s in pod_states)
        lines.append(f"\n--- Pods Observed: {len(pods)} ---")
        for p in sorted(pods):
            pod_records = [s for s in pod_states if s.name == p]
            nodes = set(s.node for s in pod_records if s.node)
            max_restarts = max(s.restarts for s in pod_records)
            lines.append(f"  {p}: nodes={nodes} max_restarts={max_restarts}")

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

    snapshots = load_jsonl(src / "k8s_snapshots.jsonl")
    galera_raw = load_jsonl(src / "replication_status.jsonl") or load_jsonl(src / "galera_status.jsonl")
    events_raw = load_jsonl(src / "k8s_events.jsonl")
    timeline_raw = load_jsonl(src / "k8s_timeline.jsonl")

    pod_states = parse_pod_snapshots(snapshots)
    galera_states = parse_galera_snapshots(galera_raw)
    cluster_states = parse_cluster_cr_snapshots(snapshots)
    timeline = parse_timeline(timeline_raw)
    k8s_events = parse_k8s_events(events_raw)

    write_pod_csv(pod_states, out / "pod_timeline.csv")
    write_galera_csv(galera_states, out / "galera_timeline.csv")
    write_cluster_csv(cluster_states, out / "cluster_state_timeline.csv")
    write_scaling_events_csv(timeline, k8s_events, out / "scaling_events.csv")

    summary = generate_summary(
        pod_states, galera_states, cluster_states, timeline, k8s_events
    )
    (out / "k8s_analysis_summary.txt").write_text(summary, encoding="utf-8")
    print(summary)

    print(f"\nCSVs written to {out}/")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
