#!/usr/bin/env python3
"""Generate failover PNG graphs and/or interactive HTML report from failover_timeseries.csv."""

from __future__ import annotations

import argparse
import csv
import html
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
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


# Upper bound (seconds after the trigger) for treating a monitor connect failure
# as the failover detection (unplanned). Keeps a stray late connection blip from
# being picked up as the "first connect failure". Mirrors FAILOVER_DETECT_WINDOW_SEC.
_DETECT_WINDOW_SEC = 60.0
# Planned (set_as_primary): short window for first write/connect outage sample.
_PLANNED_DETECT_WINDOW_SEC = 10.0

METRIC_HELP = {
    "detect": (
        "Unplanned: seconds from trigger until first connect_ok=0. "
        "Planned (set_as_primary): N/A — use write-path downtime instead."
    ),
    "promote": (
        "Unplanned: first connect_ok=0 → new PRIMARY hostname + write_ok=1. "
        "Planned: first write_ok=0 (or connect_ok=0) → new PRIMARY hostname + write_ok=1 "
        "(total_failover_sec is that write-path downtime)."
    ),
}


def load_metadata(path: Path) -> dict[str, str]:
    meta: dict[str, str] = {}
    if not path.exists():
        return meta
    for line in path.read_text().splitlines():
        stripped = line.lstrip()
        if not stripped or stripped.startswith("#"):
            continue
        if "=" not in line:
            continue
        key, _, value = line.partition("=")
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in ('"', "'"):
            value = value[1:-1]
        meta[key.strip()] = value
    return meta


def load_benchmark_config(edition_dir: Path, meta: dict[str, str]) -> dict[str, str]:
    """Merge edition + scenario benchmark config for HTML metadata."""
    cfg: dict[str, str] = {}
    edition_root = parent_edition_dir(edition_dir) or edition_dir
    edition_cfg = edition_root / "benchmark_config.env"
    if edition_cfg.exists():
        cfg.update(load_metadata(edition_cfg))
    runtime_cfg = edition_root / "mysql_runtime.env"
    if runtime_cfg.exists():
        cfg.update(load_metadata(runtime_cfg))
    timing = edition_dir / "sysbench_timing.txt"
    if timing.exists():
        cfg.update(load_metadata(timing))
    cfg.update(meta)
    return cfg


def _display_cfg_gb(val: str) -> str:
    """Pretty-print GB values stored shell-safe as 85GB in mysql_runtime.env."""
    if val in ("", "N/A"):
        return "N/A"
    if val.endswith("GB") and " " not in val:
        return f"{val[:-2]} GB"
    return val


def _mysql_runtime_meta_rows(
    cfg: dict[str, str],
    edition_dir: Path | None = None,
) -> list[tuple[str, str]]:
    """Key InnoDB / GR settings captured before the run."""
    per_pod_workers = (
        _mysql_pod_replica_workers_meta_rows(edition_dir)
        if edition_dir is not None
        else []
    )
    rows: list[tuple[str, str]] = []
    mapping = (
        ("Buffer pool limit (VIP)", "BUFFER_POOL_GB"),
        ("Buffer pool used (VIP)", "BUFFER_POOL_USED_GB"),
        ("Buffer pool used % (VIP)", "BUFFER_POOL_USED_PCT"),
        ("Redo log capacity", "REDO_LOG_CAPACITY_GB"),
        ("Buffer pool hit % (at start)", "BUFFER_POOL_HIT_PCT"),
        ("Buffer pool / data ratio", "BUFFER_POOL_DATA_RATIO"),
        ("replica_parallel_workers (VIP)", "REPLICA_PARALLEL_WORKERS"),
        (
            "GR flow control certifier threshold",
            "GR_FLOW_CONTROL_CERTIFIER_THRESHOLD",
        ),
        (
            "GR flow control applier threshold",
            "GR_FLOW_CONTROL_APPLIER_THRESHOLD",
        ),
    )
    for label, key in mapping:
        if key == "REPLICA_PARALLEL_WORKERS" and per_pod_workers:
            continue
        val = _cfg_value(cfg, key)
        if key.endswith("_GB"):
            val = _display_cfg_gb(val)
        if val != "N/A":
            rows.append((label, val))
    rows.extend(per_pod_workers)
    return rows


def load_mysql_pod_buffer_pool(edition_dir: Path) -> list[dict[str, str]]:
    path = edition_dir / "mysql_pod_buffer_pool.tsv"
    if not path.exists():
        return []
    rows: list[dict[str, str]] = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("pod\t"):
            continue
        parts = line.split("\t")
        if len(parts) < 6:
            continue
        rows.append(
            {
                "pod": parts[0],
                "hostname": parts[1],
                "bp_limit_bytes": parts[2],
                "bp_data_bytes": parts[3],
                "bp_used_pct": parts[4],
                "gr_role": parts[5],
                "replica_parallel_workers": parts[6] if len(parts) > 6 else "",
                "workers_total": parts[7] if len(parts) > 7 else "",
                "workers_applying_now": parts[8] if len(parts) > 8 else "",
            }
        )
    return rows


def _pod_replica_parallel_workers_map(edition_dir: Path) -> dict[str, str]:
    """Per-pod replica_parallel_workers from mysql_pod_buffer_pool.tsv (start-of-run snapshot)."""
    out: dict[str, str] = {}
    for pod_row in load_mysql_pod_buffer_pool(edition_dir):
        pod = pod_row.get("pod", "").strip()
        workers = pod_row.get("replica_parallel_workers", "").strip()
        if pod and workers not in ("", "N/A"):
            out[pod] = workers
    if out:
        return out
    cfg: dict[str, str] = {}
    for path in (edition_dir / "benchmark_config.env", edition_dir / "mysql_runtime.env"):
        if path.exists():
            cfg.update(load_metadata(path))
    vip = cfg.get("REPLICA_PARALLEL_WORKERS", "").strip()
    if vip and vip != "N/A":
        return {"*": vip}
    return {}


def _replica_workers_for_pod(pod: str, workers_by_pod: dict[str, str]) -> str:
    return workers_by_pod.get(pod) or workers_by_pod.get("*") or ""


def _mysql_pod_replica_workers_meta_rows(edition_dir: Path) -> list[tuple[str, str]]:
    rows: list[tuple[str, str]] = []
    for pod_row in load_mysql_pod_buffer_pool(edition_dir):
        pod = pod_row.get("pod", "")
        workers = pod_row.get("replica_parallel_workers", "").strip()
        gr_role = pod_row.get("gr_role", "")
        if not pod or workers in ("", "N/A"):
            continue
        val = workers
        if gr_role and gr_role != "N/A":
            val += f" [{gr_role}]"
        rows.append((f"replica_parallel_workers ({pod})", val))
        workers_total = pod_row.get("workers_total", "").strip()
        workers_applying = pod_row.get("workers_applying_now", "").strip()
        if workers_total not in ("", "N/A") and workers_applying not in ("", "N/A"):
            rows.append((f"parallel workers in use ({pod})", f"{workers_applying}/{workers_total}"))
    return rows


def _fmt_bytes_gb(num_bytes: str | int | float | None) -> str:
    try:
        val = int(str(num_bytes).strip())
    except (TypeError, ValueError):
        return "N/A"
    if val <= 0:
        return "0 GB"
    gb = val / (1024**3)
    if abs(gb - round(gb)) < 0.05:
        return f"{int(round(gb))} GB"
    return f"{gb:.2f} GB"


def _mysql_pod_bp_meta_rows(edition_dir: Path) -> list[tuple[str, str]]:
    rows: list[tuple[str, str]] = []
    for pod_row in load_mysql_pod_buffer_pool(edition_dir):
        pod = pod_row.get("pod", "")
        limit_gb = _fmt_bytes_gb(pod_row.get("bp_limit_bytes"))
        used_gb = _fmt_bytes_gb(pod_row.get("bp_data_bytes"))
        used_pct = pod_row.get("bp_used_pct", "N/A")
        gr_role = pod_row.get("gr_role", "")
        if limit_gb == "N/A" and used_gb == "N/A":
            continue
        val = f"{used_gb} used / {limit_gb} limit"
        if used_pct not in ("", "N/A"):
            val += f" ({used_pct}%)"
        if gr_role and gr_role != "N/A":
            val += f" [{gr_role}]"
        rows.append((f"Buffer pool ({pod})", val))
    return rows


def _gr_pre_failover_applier_meta_rows(scenario_dir: Path) -> list[tuple[str, str]]:
    """Per-pod applier queue at trigger time (preferred) or 30s pre-trigger window."""
    rows: list[tuple[str, str]] = []
    env_path = scenario_dir / "gr_pre_failover_applier.env"
    tsv_path = scenario_dir / "gr_pre_failover_applier.tsv"

    if env_path.exists():
        env = load_metadata(env_path)
        captured = env.get("GR_PRE_FAILOVER_APPLIER_CAPTURED_UTC", "")
        if captured:
            rows.append(("Applier snapshot (UTC)", captured))
        lag_leader = env.get("GR_PRE_FAILOVER_LAG_LEADER_POD", "")
        if lag_leader:
            rows.append(("Pre-trigger lag leader", lag_leader))
        for key, val in sorted(env.items()):
            if not key.startswith("GR_PRE_FAILOVER_POD_APPLIER_"):
                continue
            pod = key.removeprefix("GR_PRE_FAILOVER_POD_APPLIER_")
            if not pod or val in ("", "N/A"):
                continue
            rows.append((f"Applier queue ({pod})", val))
        if rows:
            return rows

    if tsv_path.exists():
        for line in tsv_path.read_text(encoding="utf-8", errors="replace").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or line.startswith("pod\t"):
                continue
            parts = line.split("\t")
            if len(parts) < 7:
                continue
            pod, connect_ok, _host, role, state, _cert, applier = parts[:7]
            if connect_ok != "1":
                rows.append((f"Applier queue ({pod})", "unreachable"))
            else:
                suffix = f" [{role}/{state}]" if role not in ("", "ERROR", "N/A") else ""
                rows.append((f"Applier queue ({pod})", f"{applier}{suffix}"))
        if rows:
            return rows

    trigger = _scenario_trigger_wall_sec(scenario_dir)
    summary = build_gr_pre_failover_summary(scenario_dir, trigger)
    if not summary:
        return []
    lag_leader = str(summary.get("lag_leader_pod") or "")
    if lag_leader:
        rows.append(("Pre-trigger lag leader (30s window)", lag_leader))
    for pod_row in summary.get("pods") or []:
        pod = str(pod_row.get("pod") or "")
        max_a = pod_row.get("max_applier")
        if pod and max_a is not None:
            rows.append((f"Applier queue max ({pod})", str(max_a)))
    return rows


def _edition_metadata_rows(
    edition_dir: Path,
    bench: dict[str, str],
    scenario_dir: Path | None = None,
) -> list[tuple[str, str]]:
    edition_root = parent_edition_dir(edition_dir) or edition_dir
    rows = [
        *_mysql_runtime_meta_rows(bench, edition_root),
    ]
    if scenario_dir is not None:
        rows.extend(_gr_pre_failover_applier_meta_rows(scenario_dir))
    rows.extend(_mysql_pod_bp_meta_rows(edition_root))
    return rows


def _format_data_size(cfg: dict[str, str]) -> str:
    if cfg.get("DATA_SIZE"):
        return cfg["DATA_SIZE"]
    try:
        scale = float(cfg["TPCC_SCALE"])
        tables = float(cfg.get("TPCC_TABLES", "10"))
        gb = scale * tables * 0.1
        if gb == int(gb):
            return f"~{int(gb)} GB (tables={int(tables)}, scale={int(scale)})"
        return f"~{gb:.1f} GB (tables={int(tables)}, scale={int(scale)})"
    except (KeyError, TypeError, ValueError):
        return "N/A"


def _cfg_value(cfg: dict[str, str], *keys: str, default: str = "N/A") -> str:
    for key in keys:
        val = cfg.get(key, "")
        if val not in {"", "N/A"}:
            return str(val)
    return default


def find_benchmark_conf() -> Path | None:
    env = os.environ.get("BENCHMARK_CONF", "").strip()
    if env:
        path = Path(env)
        if path.is_file():
            return path
    repo_conf = Path(__file__).resolve().parent.parent / "benchmark.conf"
    if repo_conf.is_file():
        return repo_conf
    return None


def _resolve_from_file_cfg(file_cfg: dict[str, str], *keys: str) -> str:
    for key in keys:
        val = file_cfg.get(key, "")
        if val not in {"", "N/A"}:
            return str(val)
    return "N/A"


def enrich_cluster_metadata(cfg: dict[str, str], edition: str) -> None:
    """Fill slug/node metadata from benchmark.conf when absent in saved run files."""
    slug = _cfg_value(cfg, "SLUG_SIZE", "CLUSTER_SLUG")
    nodes = _cfg_value(cfg, "NUM_NODES", "CLUSTER_NUM_NODES")
    if slug != "N/A" and nodes != "N/A":
        return

    conf_path = find_benchmark_conf()
    if not conf_path:
        return

    file_cfg = load_metadata(conf_path)
    prefix = edition.upper()
    if slug == "N/A":
        resolved = _resolve_from_file_cfg(
            file_cfg,
            f"{prefix}_CLUSTER_SIZE_SLUG",
            "SLUG_SIZE",
            "MYSQL_CLUSTER_PLAN",
            "CLUSTER_SIZE_SLUG",
        )
        if resolved != "N/A":
            cfg["SLUG_SIZE"] = resolved
            cfg["CLUSTER_SLUG"] = resolved
    if nodes == "N/A":
        resolved = _resolve_from_file_cfg(
            file_cfg,
            f"{prefix}_CLUSTER_NUM_NODES",
            "NUM_NODES",
        )
        if resolved != "N/A":
            cfg["NUM_NODES"] = resolved


THREAD_DIR_RE = re.compile(r"^t(\d+)$")
ITER_DIR_RE = re.compile(r"^iter(\d+)$")
EDITION_NAMES = {"advanced", "standard"}
TRIGGER_METHODS = {"pod_delete", "mysqld_kill", "set_as_primary"}
DEFAULT_THREAD_MATRIX = (4, 8, 16, 32)
DEFAULT_SCENARIOS = ("mixed", "write_only")
VALID_SCENARIO_RE = re.compile(r"^[a-z][a-z0-9_]*$")


def resolve_edition_name(
    scenario_dir: Path,
    meta: dict[str, str],
    event: dict[str, str],
    kpi: dict[str, str],
    bench: dict[str, str],
) -> str:
    for src in (
        meta.get("FAILOVER_EDITION"),
        event.get("FAILOVER_EDITION"),
        kpi.get("edition"),
        bench.get("FAILOVER_EDITION"),
    ):
        if src and str(src).lower() not in {"", "unknown"}:
            return str(src)
    for parent in scenario_dir.parents:
        if parent.name in EDITION_NAMES:
            return parent.name
    return "advanced"


def infer_thread_count(scenario_dir: Path, meta: dict[str, str], bench: dict[str, str]) -> int:
    parent = scenario_dir.parent.name
    match = THREAD_DIR_RE.match(parent)
    if match:
        return int(match.group(1))
    for key in ("THREADS", "FAILOVER_THREADS"):
        if meta.get(key, "").isdigit():
            return int(meta[key])
        if bench.get(key, "").isdigit():
            return int(bench[key])
    return 0


def load_scenario_bundle(scenario_dir: Path) -> dict:
    rows = load_timeseries(scenario_dir / "failover_timeseries.csv")
    meta = load_metadata(scenario_dir / "failover_timeseries_meta.txt")
    parsed = load_metadata(scenario_dir / "failover_parsed.env")
    event = load_metadata(scenario_dir / "failover_event.txt")
    kpi = load_kpi(scenario_dir / "failover_kpi.csv")
    extended = _parse_extended_metrics(scenario_dir / "failover_extended_metrics.txt")
    primary = load_metadata(scenario_dir / "primary_change.env")
    bench = load_benchmark_config(scenario_dir, meta)
    edition = resolve_edition_name(scenario_dir, meta, event, kpi, bench)
    enrich_cluster_metadata(bench, edition)
    scenario = meta.get(
        "FAILOVER_SCENARIO",
        scenario_dir.name if scenario_dir.name in {"mixed", "write_only"} else "default",
    )
    trx_profile = meta.get("TPCC_TRX_PROFILE", kpi.get("trx_profile", "mixed"))
    threads = infer_thread_count(scenario_dir, meta, bench)
    trigger_log = _scenario_trigger_log_sec(scenario_dir)
    trigger_wall = _scenario_trigger_wall_sec(scenario_dir)
    baseline = float(parsed.get("BASELINE_TPS", "0"))
    recovery = float(parsed.get("RECOVERY_THRESHOLD", str(baseline * 0.9 if baseline else 0)))
    outage_start, outage_end = _derive_outage_bounds(rows, trigger_log, baseline)
    cluster_data = build_cluster_monitor_chart_data(scenario_dir, trigger_wall)
    return {
        "dir": str(scenario_dir),
        "edition": edition,
        "scenario": scenario,
        "trx_profile": trx_profile,
        "threads": threads,
        "rows": rows,
        "meta": meta,
        "parsed": parsed,
        "event": event,
        "kpi": kpi,
        "extended": extended,
        "primary": primary,
        "bench": bench,
        "trigger": trigger_log,
        "trigger_wall": trigger_wall,
        "baseline": baseline,
        "recovery": recovery,
        "outage_start": outage_start,
        "outage_end": outage_end,
        "chart_data": {
            "elapsed": [r["elapsed_sec"] for r in rows],
            "tps": [r["tps"] for r in rows],
            "qps": [r["qps"] for r in rows],
            "err": [r["err_per_sec"] for r in rows],
            "reconn": [r["reconn_per_sec"] for r in rows],
            "lat_p95": [r["lat_p95_ms"] for r in rows],
            "trigger_sec": trigger_log,
            "baseline_tps": baseline,
            "recovery_threshold": recovery,
            "outage_start": outage_start,
            "outage_end": outage_end,
        },
        "cluster_data": cluster_data,
    }


def load_edition_benchmark_config(edition_dir: Path) -> dict[str, str]:
    cfg = load_metadata(edition_dir / "benchmark_config.env")
    cfg.update(load_metadata(edition_dir / "mysql_runtime.env"))
    return cfg


def _parse_space_list(value: str) -> list[str]:
    parts: list[str] = []
    for part in value.split():
        token = part.strip().strip("\"'")
        if not token or token.startswith("#"):
            break
        if VALID_SCENARIO_RE.match(token):
            parts.append(token)
    return parts


def parent_edition_dir(scenario_dir: Path) -> Path | None:
    if scenario_dir.name in {"mixed", "write_only"}:
        parent = scenario_dir.parent
        if parent.name in EDITION_NAMES:
            return parent
    for parent in scenario_dir.parents:
        if parent.name in EDITION_NAMES:
            return parent
    return None


def _planned_from_conf_keys(edition_dir: Path, key: str, default: tuple) -> set:
    planned: set = set()
    bench = load_edition_benchmark_config(edition_dir)
    if bench.get(key, "").strip():
        if key == "FAILOVER_THREAD_MATRIX":
            planned.update(
                int(part)
                for part in _parse_space_list(bench[key])
                if part.isdigit()
            )
        else:
            planned.update(_parse_space_list(bench[key]))
    conf_path = find_benchmark_conf()
    if conf_path:
        conf = load_metadata(conf_path)
        if conf.get(key, "").strip():
            if key == "FAILOVER_THREAD_MATRIX":
                planned.update(
                    int(part)
                    for part in _parse_space_list(conf[key])
                    if part.isdigit()
                )
            else:
                planned.update(_parse_space_list(conf[key]))
    if not planned:
        planned = set(default)
    return planned


def resolve_thread_matrix(
    edition_dir: Path, thread_runs: dict[int, dict[str, Path]]
) -> list[int]:
    discovered = {t for t in thread_runs if t > 0}
    planned = _planned_from_conf_keys(
        edition_dir, "FAILOVER_THREAD_MATRIX", DEFAULT_THREAD_MATRIX
    )
    return sorted(planned | discovered)


def resolve_scenario_list(
    edition_dir: Path, thread_runs: dict[int, dict[str, Path]]
) -> list[str]:
    discovered: set[str] = set()
    for scenarios in thread_runs.values():
        discovered.update(scenarios.keys())
    if discovered:
        return sorted(discovered)
    planned = _planned_from_conf_keys(edition_dir, "FAILOVER_SCENARIOS", DEFAULT_SCENARIOS)
    return sorted(planned)


def _add_thread_scenario_run(
    runs: dict[int, dict[str, Path]],
    threads: int,
    label: str,
    scenario_dir: Path,
) -> None:
    runs.setdefault(threads, {})[label] = scenario_dir


def _collect_thread_runs_from_dir(
    parent: Path,
    runs: dict[int, dict[str, Path]],
    label_prefix: str = "",
) -> None:
    """Collect thread/scenario runs under parent, including trigger-method nesting."""
    if not parent.is_dir():
        return

    for child in sorted(parent.iterdir()):
        if not child.is_dir() or child.name == "graphs":
            continue
        match = THREAD_DIR_RE.match(child.name)
        if match:
            threads = int(match.group(1))
            for scenario_dir in sorted(child.iterdir()):
                if scenario_dir.is_dir() and (scenario_dir / "failover_timeseries.csv").exists():
                    if label_prefix:
                        label = f"{label_prefix}/{scenario_dir.name}"
                    else:
                        label = scenario_dir.name
                    _add_thread_scenario_run(runs, threads, label, scenario_dir)
            continue
        if child.name in TRIGGER_METHODS:
            prefix = f"{label_prefix}/{child.name}" if label_prefix else child.name
            _collect_thread_runs_from_dir(child, runs, prefix)
            continue
        if child.name in {"mixed", "write_only"} and (child / "failover_timeseries.csv").exists():
            bundle = load_scenario_bundle(child)
            threads = bundle["threads"] or 0
            label = f"{label_prefix}/{child.name}" if label_prefix else child.name
            _add_thread_scenario_run(runs, threads, label, child)


def discover_thread_runs(edition_dir: Path) -> dict[int, dict[str, Path]]:
    """Map thread count -> scenario label -> results dir."""
    runs: dict[int, dict[str, Path]] = {}
    _collect_thread_runs_from_dir(edition_dir, runs)
    return runs


def _collect_iteration_inner_runs(
    parent: Path,
    runs: dict[int, dict[str, Path]],
    iteration: int,
    label_prefix: str = "",
) -> None:
    for inner in sorted(parent.iterdir()):
        if not inner.is_dir() or inner.name == "graphs":
            continue
        thread_match = THREAD_DIR_RE.match(inner.name)
        if thread_match:
            for scenario_dir in sorted(inner.iterdir()):
                if scenario_dir.is_dir() and (scenario_dir / "failover_timeseries.csv").exists():
                    parts = [p for p in (label_prefix, inner.name, scenario_dir.name) if p]
                    label = "/".join(parts)
                    runs.setdefault(iteration, {})[label] = scenario_dir
            continue
        if inner.name in TRIGGER_METHODS:
            prefix = f"{label_prefix}/{inner.name}" if label_prefix else inner.name
            _collect_iteration_inner_runs(inner, runs, iteration, prefix)
            continue
        if (inner / "failover_timeseries.csv").exists():
            parts = [p for p in (label_prefix, inner.name) if p]
            label = "/".join(parts)
            runs.setdefault(iteration, {})[label] = inner


def discover_iteration_runs(edition_dir: Path) -> dict[int, dict[str, Path]]:
    """Map iteration number -> scenario label -> results dir (edition/iter<N>/...)."""
    runs: dict[int, dict[str, Path]] = {}
    if not edition_dir.is_dir():
        return runs

    for child in sorted(edition_dir.iterdir()):
        if not child.is_dir() or child.name == "graphs":
            continue
        match = ITER_DIR_RE.match(child.name)
        if not match:
            continue
        iteration = int(match.group(1))
        _collect_iteration_inner_runs(child, runs, iteration)

    return runs


def _iteration_kpi_comparison_html(iter_runs: dict[int, dict[str, Path]]) -> str:
    """Summary table: failure detection and promote election across iterations."""
    scenario_names: list[str] = []
    seen: set[str] = set()
    for scenarios in iter_runs.values():
        for name in sorted(scenarios):
            if name not in seen:
                seen.add(name)
                scenario_names.append(name)
    if not scenario_names:
        return ""

    blocks: list[str] = []
    for scenario in scenario_names:
        header = "".join(f"<th>Iteration {n}</th>" for n in sorted(iter_runs))
        detect_cells: list[str] = []
        promote_cells: list[str] = []
        for iteration in sorted(iter_runs):
            scenario_dir = iter_runs[iteration].get(scenario)
            if not scenario_dir:
                detect_cells.append("<td>—</td>")
                promote_cells.append("<td>—</td>")
                continue
            kpi = load_kpi(scenario_dir / "failover_kpi.csv")
            detect = kpi.get("failure_detection_sec", "—") or "—"
            promote = kpi.get("primary_election_sec", "—") or "—"
            detect_cells.append(f"<td>{html.escape(str(detect))}</td>")
            promote_cells.append(f"<td>{html.escape(str(promote))}</td>")
        blocks.append(
            f'<div class="card"><h2>KPI comparison — {html.escape(_humanize_scenario_path_label(scenario))}</h2>'
            f'<div class="table-scroll"><table class="throughput-compare">'
            f"<thead><tr><th>Metric</th>{header}</tr></thead>"
            f"<tbody>"
            f'<tr><th scope="row">Time to detect failure (s)</th>{"".join(detect_cells)}</tr>'
            f'<tr><th scope="row">Time to promote — election (s)</th>{"".join(promote_cells)}</tr>'
            f"</tbody></table></div></div>"
        )
    return "".join(blocks)


def _baseline_averages_before_trigger(
    rows: list[dict[str, float]], trigger_sec: float
) -> tuple[float, float, float]:
    """Average per-second metrics before trigger (seconds with err=0 and tps>0)."""
    tps_vals: list[float] = []
    qps_vals: list[float] = []
    lat_vals: list[float] = []
    for row in rows:
        if row["elapsed_sec"] >= trigger_sec:
            continue
        if row["err_per_sec"] > 0 or row["tps"] <= 0:
            continue
        tps_vals.append(row["tps"])
        qps_vals.append(row["qps"])
        if row["lat_p95_ms"] > 0:
            lat_vals.append(row["lat_p95_ms"])
    tps = sum(tps_vals) / len(tps_vals) if tps_vals else 0.0
    qps = sum(qps_vals) / len(qps_vals) if qps_vals else 0.0
    lat = sum(lat_vals) / len(lat_vals) if lat_vals else 0.0
    return tps, qps, lat


def _resolve_baseline_metrics(
    parsed: dict[str, str],
    rows: list[dict[str, float]],
    trigger_sec: float,
) -> tuple[float, float, float]:
    tps = float(parsed.get("BASELINE_TPS", "0") or 0)
    qps = float(parsed.get("BASELINE_QPS", "0") or 0)
    lat = float(parsed.get("BASELINE_LAT_P95_MS", "0") or 0)
    if rows and trigger_sec > 0:
        calc_tps, calc_qps, calc_lat = _baseline_averages_before_trigger(rows, trigger_sec)
        if tps <= 0:
            tps = calc_tps
        if qps <= 0:
            qps = calc_qps
        if lat <= 0:
            lat = calc_lat
    return tps, qps, lat


def _parse_kpi_sec(value: str | None) -> float | None:
    if not value or str(value).upper() in {"N/A", "NOT_DETECTED", "NOT_REACHED"}:
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _averages_after_failover(
    rows: list[dict[str, float]],
    trigger_sec: float,
    promote_sec: float | None,
) -> tuple[float, float, float, str]:
    """Average per-second metrics after promotion through end of run."""
    if promote_sec is not None and promote_sec >= 0:
        start = trigger_sec + promote_sec
        window_note = f"from promotion ({promote_sec:.2f}s after trigger) through end of run"
    else:
        start = trigger_sec + 5.0
        window_note = "from 5s after trigger through end of run (promote not detected)"

    tps_vals: list[float] = []
    qps_vals: list[float] = []
    lat_vals: list[float] = []
    for row in rows:
        if row["elapsed_sec"] < start:
            continue
        tps_vals.append(row["tps"])
        qps_vals.append(row["qps"])
        if row["lat_p95_ms"] > 0:
            lat_vals.append(row["lat_p95_ms"])

    tps = sum(tps_vals) / len(tps_vals) if tps_vals else 0.0
    qps = sum(qps_vals) / len(qps_vals) if qps_vals else 0.0
    lat = sum(lat_vals) / len(lat_vals) if lat_vals else 0.0
    return tps, qps, lat, window_note


def _fmt_compare_num(value: float, decimals: int = 2) -> str:
    if value <= 0:
        return "N/A"
    if value == int(value):
        return str(int(value))
    return f"{value:.{decimals}f}"


def _before_after_throughput_table_html(bundle: dict) -> str:
    rows = bundle.get("rows", [])
    trigger = float(bundle.get("trigger", 0))
    parsed = bundle.get("parsed", {})
    kpi = bundle.get("kpi", {})
    extended = bundle.get("extended", {})

    before_tps, before_qps, before_lat = _resolve_baseline_metrics(parsed, rows, trigger)
    promote_sec = _parse_kpi_sec(kpi.get("total_failover_sec")) or _parse_kpi_sec(
        extended.get("total_failover_sec")
    )
    after_tps, after_qps, after_lat, window_note = _averages_after_failover(
        rows, trigger, promote_sec
    )

    def row(label: str, before: float, after: float, *, latency: bool = False) -> str:
        if latency:
            b = _format_latency_ms(before) if before > 0 else "N/A"
            a = _format_latency_ms(after) if after > 0 else "N/A"
        else:
            b = _fmt_compare_num(before)
            a = _fmt_compare_num(after)
        return (
            f"<tr><th>{html.escape(label)}</th>"
            f"<td>{html.escape(b)}</td><td>{html.escape(a)}</td></tr>"
        )

    return f"""
    <p class="monitor-subhead">After failover: average of all seconds {html.escape(window_note)}.</p>
    <div class="table-scroll">
      <table class="throughput-compare">
        <thead>
          <tr>
            <th></th>
            <th>Baseline (before failover)</th>
            <th>After failover</th>
          </tr>
        </thead>
        <tbody>
          {row("TPS", before_tps, after_tps)}
          {row("QPS", before_qps, after_qps)}
          {row("Latency p95", before_lat, after_lat, latency=True)}
        </tbody>
      </table>
    </div>
    """


def _meta_rows_for_bundle(bundle: dict) -> list[tuple[str, str]]:
    bench = bundle["bench"]
    meta = bundle["meta"]
    event = bundle["event"]
    parsed = bundle["parsed"]
    trigger = bundle["trigger"]
    trigger_wall = float(bundle.get("trigger_wall", trigger))
    threads = bundle["threads"]
    baseline_tps, baseline_qps, baseline_lat = _resolve_baseline_metrics(
        parsed, bundle.get("rows", []), trigger
    )
    trigger_rows: list[tuple[str, str]] = []
    if trigger_wall != trigger:
        trigger_rows = [
            ("Trigger second (log)", str(int(trigger)) if trigger else "N/A"),
            ("Trigger second (wall)", str(int(trigger_wall)) if trigger_wall else "N/A"),
        ]
    else:
        trigger_rows = [("Trigger second", str(int(trigger)) if trigger else "N/A")]
    return [
        ("Edition", bundle["edition"]),
        ("Failover type", _failover_mode_info(event, Path(bundle["dir"]))["label"]),
        ("Scenario", bundle["scenario"]),
        ("TPC-C profile", bundle["trx_profile"]),
        ("Load threads", str(threads) if threads else _cfg_value(bench, "THREADS", "FAILOVER_THREADS")),
        ("Slug size", _cfg_value(bench, "SLUG_SIZE", "CLUSTER_SLUG", "MYSQL_CLUSTER_PLAN")),
        ("Num nodes", _cfg_value(bench, "NUM_NODES", "CLUSTER_NUM_NODES")),
        ("Data size", _format_data_size(bench)),
        ("TPCC_SCALE", _cfg_value(bench, "TPCC_SCALE")),
        ("TPCC_THREADS", _cfg_value(bench, "TPCC_THREADS", "PREP_THREADS")),
        *_edition_metadata_rows(Path(bundle["dir"]), bench, Path(bundle["dir"])),
        ("Sysbench start (UTC)", meta.get("SYSBENCH_START_UTC", "N/A")),
        ("Failover trigger (UTC)", event.get("FAILOVER_TRIGGER_UTC", "N/A")),
        *trigger_rows,
        ("Trigger method", event.get("FAILOVER_METHOD") or event.get("FAILOVER_ADVANCED_TRIGGER_METHOD") or "N/A"),
        ("Target pod", event.get("FAILOVER_TARGET_POD", "N/A")),
        ("Baseline TPS", f"{baseline_tps:.2f}" if baseline_tps else "N/A"),
        ("Baseline QPS", f"{baseline_qps:.2f}" if baseline_qps else "N/A"),
        (
            "Baseline latency p95",
            _format_latency_ms(baseline_lat) if baseline_lat else "N/A",
        ),
    ]


def _meta_table_html(meta_rows: list[tuple[str, str]]) -> str:
    return "".join(
        f"<tr><th>{html.escape(k)}</th><td>{html.escape(v)}</td></tr>" for k, v in meta_rows
    )


def _monitor_sysbench_offset(scenario_dir: Path) -> float:
    meta_path = scenario_dir / "primary_monitor_meta.txt"
    timing_path = scenario_dir / "sysbench_timing.txt"
    if not meta_path.exists() or not timing_path.exists():
        return 0.0
    meta = load_metadata(meta_path)
    timing = load_metadata(timing_path)
    try:
        monitor_start = float(meta.get("MONITOR_START_EPOCH", 0))
        sysbench_ready = float(timing.get("SYSBENCH_READY_EPOCH", 0))
        if monitor_start and sysbench_ready:
            return sysbench_ready - monitor_start
    except ValueError:
        pass
    return 0.0


def load_primary_monitor(scenario_dir: Path) -> list[dict[str, str | float]]:
    path = scenario_dir / "primary_monitor.tsv"
    if not path.exists():
        return []
    offset = _monitor_sysbench_offset(scenario_dir)
    rows: list[dict[str, str | float]] = []
    for line in path.read_text().splitlines()[1:]:
        if not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) < 8:
            continue
        elapsed = float(parts[1])
        rows.append(
            {
                "wall": parts[0],
                "elapsed": elapsed,
                "sysbench_sec": elapsed - offset,
                "connect_ok": parts[2],
                "hostname": parts[3],
                "gr_state": parts[6] if len(parts) > 6 else "",
                "gr_role": parts[7] if len(parts) > 7 else "",
                "write_ok": parts[8] if len(parts) > 8 else "",
            }
        )
    return rows


def _monitor_sysbench_offset_from_meta(
    scenario_dir: Path, meta_filename: str, start_key: str
) -> float:
    meta_path = scenario_dir / meta_filename
    timing_path = scenario_dir / "sysbench_timing.txt"
    if not meta_path.exists() or not timing_path.exists():
        return 0.0
    meta = load_metadata(meta_path)
    timing = load_metadata(timing_path)
    try:
        monitor_start = float(meta.get(start_key, 0))
        sysbench_ready = float(timing.get("SYSBENCH_READY_EPOCH", 0))
        if monitor_start and sysbench_ready:
            return sysbench_ready - monitor_start
    except ValueError:
        pass
    return 0.0


def load_gr_pod_monitor(scenario_dir: Path) -> list[dict[str, str | float]]:
    path = scenario_dir / "gr_pod_monitor.tsv"
    if not path.exists():
        return []
    offset = _monitor_sysbench_offset_from_meta(
        scenario_dir, "gr_pod_monitor_meta.txt", "GR_POD_MONITOR_START_EPOCH"
    )
    rows: list[dict[str, str | float]] = []
    for line in path.read_text().splitlines()[1:]:
        if not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) < 7:
            continue
        # New format (15 cols): ... gtid_seq, workers_total, workers_applying_now
        # Legacy (13 cols): ... conflicts, gtid_seq
        if len(parts) >= 15:
            gtid_idx = 12
            workers_total_idx = 13
            workers_applying_idx = 14
        elif len(parts) >= 14:
            gtid_idx = 13
            workers_total_idx = -1
            workers_applying_idx = -1
        else:
            gtid_idx = 12
            workers_total_idx = -1
            workers_applying_idx = -1
        elapsed = float(parts[1])
        rows.append(
            {
                "wall": parts[0],
                "elapsed": elapsed,
                "sysbench_sec": elapsed - offset,
                "pod": parts[2],
                "connect_ok": parts[3],
                "hostname": parts[4],
                "gr_role": parts[5],
                "gr_state": parts[6],
                "cert_queue": parts[7] if len(parts) > 7 else "-1",
                "applier_queue": parts[8] if len(parts) > 8 else "-1",
                "remote_applied": parts[9] if len(parts) > 9 else "-1",
                "tx_checked": parts[10] if len(parts) > 10 else "-1",
                "conflicts": parts[11] if len(parts) > 11 else "-1",
                "gtid_seq": parts[gtid_idx] if len(parts) > gtid_idx else "0",
                "workers_total": parts[workers_total_idx] if workers_total_idx >= 0 and len(parts) > workers_total_idx else "-1",
                "workers_applying_now": parts[workers_applying_idx] if workers_applying_idx >= 0 and len(parts) > workers_applying_idx else "-1",
            }
        )
    return rows


GR_PRE_FAILOVER_WINDOW_SEC = 30.0


def _monitor_float(val: object, default: float = -1.0) -> float:
    try:
        return float(val)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return default


def _flow_control_thresholds(scenario_dir: Path) -> dict[str, float | None]:
    edition_root = parent_edition_dir(scenario_dir) or scenario_dir
    cfg: dict[str, str] = {}
    for path in (
        edition_root / "mysql_runtime.env",
        edition_root / "benchmark_config.env",
        scenario_dir / "sysbench_timing.txt",
    ):
        if path.exists():
            cfg.update(load_metadata(path))
    out: dict[str, float | None] = {}
    for key, cfg_key in (
        ("certifier", "GR_FLOW_CONTROL_CERTIFIER_THRESHOLD"),
        ("applier", "GR_FLOW_CONTROL_APPLIER_THRESHOLD"),
    ):
        val = _monitor_float(cfg.get(cfg_key, ""), -1)
        out[key] = val if val >= 0 else None
    return out


def _promotion_event_markers(
    scenario_dir: Path, trigger: float, gr_rows: list[dict[str, str | float]]
) -> dict[str, object]:
    markers: dict[str, object] = {
        "gr_primary_sec": None,
        "write_ok_sec": None,
        "gr_primary_pod": "",
    }
    best: tuple[float, str] | None = None
    for row in gr_rows:
        sec = float(row["sysbench_sec"])
        if sec < trigger or row["connect_ok"] != "1":
            continue
        if row["gr_role"] == "PRIMARY" and row["gr_state"] in ("ONLINE", "PRIMARY"):
            if best is None or sec < best[0]:
                best = (sec, str(row["pod"]))
    if best:
        markers["gr_primary_sec"] = best[0]
        markers["gr_primary_pod"] = best[1]

    for row in load_primary_monitor(scenario_dir):
        sec = float(row["sysbench_sec"])
        if sec < trigger:
            continue
        if row.get("write_ok") == "1" and row.get("connect_ok") == "1":
            markers["write_ok_sec"] = sec
            break
    return markers


def _build_queue_point(
    row: dict[str, str | float],
    prev_row: dict[str, str | float] | None,
    queue_key: str,
    replica_parallel_workers: str = "",
) -> dict[str, object]:
    y = _monitor_float(row.get(queue_key))
    if y < 0:
        return {}
    sec = float(row["sysbench_sec"])
    pt: dict[str, object] = {
        "x": sec,
        "y": y,
        "role": str(row.get("gr_role", "")),
        "state": str(row.get("gr_state", "")),
        "cert_queue": _monitor_float(row.get("cert_queue")),
        "applier_queue": _monitor_float(row.get("applier_queue")),
        "conflicts": _monitor_float(row.get("conflicts")),
        "gtid_seq": _monitor_float(row.get("gtid_seq"), 0),
        "workers_total": _monitor_float(row.get("workers_total")),
        "workers_applying_now": _monitor_float(row.get("workers_applying_now")),
    }
    if replica_parallel_workers:
        pt["replica_parallel_workers"] = replica_parallel_workers
    if prev_row is not None:
        prev_y = _monitor_float(prev_row.get(queue_key))
        if prev_y >= 0:
            pt["delta_queue"] = round(y - prev_y, 1)
        prev_applied = _monitor_float(prev_row.get("remote_applied"))
        cur_applied = _monitor_float(row.get("remote_applied"))
        dt = sec - float(prev_row["sysbench_sec"])
        if prev_applied >= 0 and cur_applied >= 0 and dt > 0 and cur_applied >= prev_applied:
            pt["apply_rate"] = round((cur_applied - prev_applied) / dt, 2)
    return pt


def build_gr_pre_failover_summary(
    scenario_dir: Path, trigger: float, window: float = GR_PRE_FAILOVER_WINDOW_SEC
) -> dict[str, object]:
    gr_rows = load_gr_pod_monitor(scenario_dir)
    if not gr_rows:
        return {}

    primary_after = load_metadata(scenario_dir / "primary_change.env").get("PRIMARY_AFTER", "")
    t0 = trigger - window
    pre = [
        r
        for r in gr_rows
        if t0 <= float(r["sysbench_sec"]) < trigger and r["connect_ok"] == "1"
    ]
    by_pod: dict[str, list[dict[str, str | float]]] = {}
    for row in pre:
        by_pod.setdefault(str(row["pod"]), []).append(row)

    pods_summary: list[dict[str, object]] = []
    for pod, rows in sorted(by_pod.items()):
        appliers = [_monitor_float(r.get("applier_queue")) for r in rows]
        appliers_ok = [a for a in appliers if a >= 0]
        certs = [_monitor_float(r.get("cert_queue")) for r in rows]
        certs_ok = [c for c in certs if c >= 0]
        apply_rates: list[float] = []
        workers_applying_vals = [_monitor_float(r.get("workers_applying_now")) for r in rows]
        workers_applying_ok = [w for w in workers_applying_vals if w >= 0]
        sorted_rows = sorted(rows, key=lambda r: float(r["sysbench_sec"]))
        for i in range(1, len(sorted_rows)):
            prev = sorted_rows[i - 1]
            cur = sorted_rows[i]
            prev_applied = _monitor_float(prev.get("remote_applied"))
            cur_applied = _monitor_float(cur.get("remote_applied"))
            dt = float(cur["sysbench_sec"]) - float(prev["sysbench_sec"])
            if prev_applied >= 0 and cur_applied >= 0 and dt > 0 and cur_applied >= prev_applied:
                apply_rates.append((cur_applied - prev_applied) / dt)
        pods_summary.append(
            {
                "pod": pod,
                "samples": len(rows),
                "avg_applier": round(sum(appliers_ok) / len(appliers_ok), 2) if appliers_ok else None,
                "max_applier": max(appliers_ok) if appliers_ok else None,
                "avg_cert": round(sum(certs_ok) / len(certs_ok), 2) if certs_ok else None,
                "avg_apply_rate": round(sum(apply_rates) / len(apply_rates), 2) if apply_rates else None,
                "avg_workers_applying": round(sum(workers_applying_ok) / len(workers_applying_ok), 2) if workers_applying_ok else None,
                "max_workers_applying": max(workers_applying_ok) if workers_applying_ok else None,
            }
        )

    ranked = sorted(
        pods_summary,
        key=lambda p: (p["max_applier"] is None, -(p["max_applier"] or 0)),
    )
    for idx, pod_row in enumerate(ranked, 1):
        pod_row["rank"] = idx

    lag_leader = str(ranked[0]["pod"]) if ranked else ""
    promoted_was_lag_leader = bool(primary_after and lag_leader and primary_after == lag_leader)
    note = ""
    if promoted_was_lag_leader and lag_leader:
        max_a = ranked[0].get("max_applier")
        note = (
            f"Promoted primary {primary_after} had the highest pre-trigger applier queue "
            f"(max {max_a} in {window:.0f}s window). Apply backlog on the new primary may "
            f"contribute to slow VIP promotion even after GR election."
        )
    elif primary_after and lag_leader and not promoted_was_lag_leader:
        note = (
            f"Pre-trigger applier lag leader was {lag_leader}; promoted primary was {primary_after}. "
            f"Election may reflect operator primary label rather than lowest queue depth."
        )

    return {
        "window_sec": window,
        "trigger_sec": trigger,
        "pods": ranked,
        "lag_leader_pod": lag_leader,
        "promoted_primary": primary_after,
        "promoted_was_lag_leader": promoted_was_lag_leader,
        "note": note,
    }


def write_gr_pre_failover_artifacts(scenario_dir: Path, trigger: float | None = None) -> Path | None:
    if trigger is None:
        trigger = _scenario_trigger_wall_sec(scenario_dir)
    summary = build_gr_pre_failover_summary(scenario_dir, trigger)
    if not summary:
        return None

    txt_path = scenario_dir / "gr_pod_pre_failover_summary.txt"
    env_path = scenario_dir / "gr_pod_pre_failover.env"
    lines = [
        "=== GR pre-failover lag summary ===",
        f"Window: {summary['window_sec']:.0f}s before trigger (sysbench sec {summary['trigger_sec']:.0f})",
        f"Promoted primary (after): {summary.get('promoted_primary') or 'N/A'}",
        f"Pre-trigger applier lag leader: {summary.get('lag_leader_pod') or 'N/A'}",
        f"Promoted pod was lag leader: {'yes' if summary.get('promoted_was_lag_leader') else 'no'}",
        "",
        f"{'Rank':<5} {'Pod':<35} {'AvgAppl':<10} {'MaxAppl':<10} {'AvgCert':<10} {'ApplyRate':<10}",
    ]
    for pod_row in summary.get("pods") or []:
        lines.append(
            f"{pod_row.get('rank', ''):<5} "
            f"{str(pod_row.get('pod', '')):<35} "
            f"{pod_row.get('avg_applier', 'N/A')!s:<10} "
            f"{pod_row.get('max_applier', 'N/A')!s:<10} "
            f"{pod_row.get('avg_cert', 'N/A')!s:<10} "
            f"{pod_row.get('avg_apply_rate', 'N/A')!s:<10}"
        )
    if summary.get("note"):
        lines.extend(["", str(summary["note"])])
    txt_path.write_text("\n".join(lines) + "\n", encoding="utf-8")

    env_lines = [
        f"GR_PRE_FAILOVER_WINDOW_SEC={summary['window_sec']:.0f}",
        f"GR_PRE_FAILOVER_LAG_LEADER={summary.get('lag_leader_pod', '')}",
        f"GR_PROMOTED_WAS_LAG_LEADER={'yes' if summary.get('promoted_was_lag_leader') else 'no'}",
    ]
    if summary.get("note"):
        env_lines.append(f"GR_PRE_FAILOVER_NOTE={summary['note']}")
    env_path.write_text("\n".join(env_lines) + "\n", encoding="utf-8")

    promo_txt = scenario_dir / "failover_promotion_breakdown.txt"
    if promo_txt.exists() and summary.get("note"):
        existing = promo_txt.read_text(encoding="utf-8")
        marker = "--- Pre-failover GR applier lag ---"
        if marker not in existing:
            with promo_txt.open("a", encoding="utf-8") as f:
                f.write("\n" + marker + "\n")
                f.write(str(summary["note"]) + "\n")
    return txt_path


def _scenario_trigger_epoch_rel(scenario_dir: Path) -> float | None:
    """Sub-second offset from sysbench-ready to the actual trigger fire epoch.

    Uses FAILOVER_TRIGGER_EPOCH (recorded at the real fire moment) minus
    SYSBENCH_READY_EPOCH so detection/marking align to when the trigger truly
    fired rather than the planned integer second. Returns None for older runs
    that predate either epoch (callers then fall back to the planned second).
    """
    trig_epoch: float | None = None
    for path in (
        scenario_dir / "failover_event.txt",
        scenario_dir / "failover_timeseries_meta.txt",
    ):
        val = load_metadata(path).get("FAILOVER_TRIGGER_EPOCH")
        if val:
            try:
                trig_epoch = float(val)
                break
            except ValueError:
                pass
    ready_epoch: float | None = None
    for path in (
        scenario_dir / "sysbench_timing.txt",
        scenario_dir / "failover_timeseries_meta.txt",
    ):
        val = load_metadata(path).get("SYSBENCH_READY_EPOCH")
        if val:
            try:
                ready_epoch = float(val)
                break
            except ValueError:
                pass
    if trig_epoch is None or ready_epoch is None:
        return None
    rel = trig_epoch - ready_epoch
    return rel if rel > 0 else None


def _scenario_warmup_sec(scenario_dir: Path) -> float:
    for path in (scenario_dir / "failover_timeseries_meta.txt", scenario_dir / "sysbench_timing.txt"):
        val = load_metadata(path).get("FAILOVER_WARMUP_SEC")
        if val:
            try:
                return float(val)
            except ValueError:
                pass
    return 0.0


def _scenario_trigger_wall_sec(scenario_dir: Path) -> float:
    """Wall-clock sysbench second when failover fires (warmup + baseline); aligns monitors."""
    rel = _scenario_trigger_epoch_rel(scenario_dir)
    if rel is not None:
        return rel
    for path in (scenario_dir / "failover_timeseries_meta.txt", scenario_dir / "sysbench_timing.txt"):
        timing = load_metadata(path)
        for key in ("FAILOVER_TRIGGER_WALL_SECOND", "FAILOVER_TRIGGER_SECOND"):
            val = timing.get(key)
            if val:
                try:
                    return float(val)
                except ValueError:
                    pass
    return 120.0


def _scenario_trigger_log_sec(scenario_dir: Path) -> float:
    """Sysbench report-interval second where the failover actually fires.

    The TPS/QPS log axis starts after the warmup phase, so the real fire lands at
    ``(trigger_epoch - sysbench_ready_epoch) - warmup`` on that axis. Deriving it
    from the recorded epochs — rather than the *planned* FAILOVER_TRIGGER_LOG_SECOND
    (which is just the baseline second) — keeps the marker correct even when the
    trigger is delayed past the plan, e.g. a GR readiness-gate wait between
    back-to-back iterations. The result may legitimately fall beyond the end of
    the sysbench window (trigger fired after the run stopped); callers handle
    that. Falls back to the planned second only for older runs missing epochs.
    """
    rel = _scenario_trigger_epoch_rel(scenario_dir)
    if rel is not None:
        log_sec = rel - _scenario_warmup_sec(scenario_dir)
        return log_sec if log_sec > 0 else rel
    for path in (scenario_dir / "failover_timeseries_meta.txt", scenario_dir / "sysbench_timing.txt"):
        timing = load_metadata(path)
        val = timing.get("FAILOVER_TRIGGER_LOG_SECOND")
        if val:
            try:
                return float(val)
            except ValueError:
                pass
        try:
            warmup = float(timing.get("FAILOVER_WARMUP_SEC", "0"))
            baseline = float(timing.get("FAILOVER_BASELINE_SEC", 120))
            if warmup > 0:
                return baseline
            wall_raw = timing.get("FAILOVER_TRIGGER_WALL_SECOND") or timing.get("FAILOVER_TRIGGER_SECOND")
            if wall_raw:
                wall = float(wall_raw)
                if wall > baseline:
                    return baseline
                return wall
        except ValueError:
            pass
        wall = timing.get("FAILOVER_TRIGGER_WALL_SECOND") or timing.get("FAILOVER_TRIGGER_SECOND")
        if wall:
            try:
                return float(wall)
            except ValueError:
                pass
    return 120.0


def _scenario_trigger_sec(scenario_dir: Path) -> float:
    """Log-axis trigger for throughput charts (backward-compatible alias)."""
    return _scenario_trigger_log_sec(scenario_dir)


def _derive_outage_bounds(
    rows: list[dict[str, float]],
    trigger_log: float,
    baseline_tps: float,
) -> tuple[float, float]:
    """Outage window (start, end) on the TPS log axis for chart shading.

    Anchors to the corrected trigger second and finds the throughput collapse
    that follows it, instead of trusting OUTAGE_START/OUTAGE_END from the KPI:
    those are keyed off the *planned* trigger second and get widened to end-of-run
    by low-level background err/s (the awk outage predicate includes ``err>0``).

    Returns ``(trigger_log, trigger_log)`` — a zero-width (invisible) box — when
    no collapse follows the trigger within a short window: a (near) zero-downtime
    failover, or a trigger that fired after the sysbench window closed. Only TPS
    is used (not err/s) so persistent background errors never inflate the box.
    """
    if not rows or baseline_tps <= 0:
        return trigger_log, trigger_log
    low = baseline_tps * 0.2
    recover = baseline_tps * 0.5
    ordered = sorted(rows, key=lambda r: r["elapsed_sec"])
    # A few seconds of slack before the trigger absorbs detection latency; cap
    # the forward search so an unrelated late stall is never mistaken for the
    # failover outage of a low-impact promotion.
    search_from = trigger_log - 3
    search_to = trigger_log + 60
    start: float | None = None
    for r in ordered:
        e = r["elapsed_sec"]
        if e < search_from:
            continue
        if e > search_to:
            break
        if r["tps"] <= low:
            start = e
            break
    if start is None:
        return trigger_log, trigger_log
    end = start
    for r in ordered:
        if r["elapsed_sec"] < start:
            continue
        if r["tps"] >= recover:
            break
        end = r["elapsed_sec"]
    return start, end


def load_k8s_pods_monitor(scenario_dir: Path) -> list[dict[str, str | float]]:
    path = scenario_dir / "k8s_pods_monitor.tsv"
    if not path.exists():
        return []
    offset = _monitor_sysbench_offset_from_meta(
        scenario_dir, "k8s_pods_monitor_meta.txt", "K8S_PODS_MONITOR_START_EPOCH"
    )
    rows: list[dict[str, str | float]] = []
    for line in path.read_text().splitlines()[1:]:
        if not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) < 8:
            continue
        elapsed = float(parts[1])
        rows.append(
            {
                "wall": parts[0],
                "elapsed": elapsed,
                "sysbench_sec": elapsed - offset,
                "pod": parts[2],
                "phase": parts[3],
                "ready_num": parts[4],
                "ready_den": parts[5],
                "restarts": parts[6],
                "deleting": parts[7],
                "is_target": parts[8] if len(parts) > 8 else "0",
            }
        )
    return rows


POD_CHART_COLORS = ("#60a5fa", "#34d399", "#fbbf24", "#c084fc", "#f87171", "#2dd4bf")


GR_STATE_LEVELS = (
    "unreachable",
    "ERROR",
    "OFFLINE",
    "RECOVERING",
    "ONLINE",
    "PRIMARY",
)
K8S_STATE_LEVELS = (
    "Not found",
    "Failed / Unknown",
    "Terminating",
    "Pending",
    "Running (partial ready)",
    "Running (ready)",
)
STATE_LANE_HEIGHT = 6


def _gr_state_level(role: str, state: str, connect_ok: str) -> float:
    if connect_ok != "1":
        return 0.0
    state_u = state.upper()
    role_u = role.upper()
    if state_u == "ERROR":
        return 1.0
    if state_u == "OFFLINE":
        return 2.0
    if state_u == "RECOVERING":
        return 3.0
    if role_u == "PRIMARY" and state_u in ("ONLINE", "PRIMARY"):
        return 5.0
    if state_u == "ONLINE":
        return 4.0
    return 2.0


def _gr_state_label(role: str, state: str, connect_ok: str) -> str:
    if connect_ok != "1":
        return "unreachable"
    role_u = role.strip().upper()
    state_u = state.strip().upper()
    if not role_u or role_u == "N/A":
        return state_u or "unknown"
    if not state_u or state_u == "N/A":
        return role_u
    return f"{role_u} / {state_u}"


def _k8s_readiness_level(phase: str, ready_num: str, ready_den: str, deleting: str) -> float:
    phase_u = phase.strip()
    if phase_u in ("NotFound", ""):
        return 0.0
    if phase_u in ("Failed", "Unknown"):
        return 1.0
    if deleting == "1" or phase_u == "Terminating":
        return 2.0
    if phase_u == "Pending":
        return 3.0
    if phase_u == "Running":
        try:
            num = int(ready_num)
            den = int(ready_den)
        except ValueError:
            return 4.0
        if den > 0 and num == den:
            return 5.0
        return 4.0
    return 3.0


def _k8s_state_label(phase: str, ready_num: str, ready_den: str, deleting: str) -> str:
    phase_u = phase.strip()
    if phase_u in ("NotFound", ""):
        return "Not found"
    if phase_u in ("Failed", "Unknown"):
        return phase_u
    if deleting == "1" or phase_u == "Terminating":
        return "Terminating"
    if phase_u == "Pending":
        return "Pending"
    if phase_u == "Running":
        try:
            num = int(ready_num)
            den = int(ready_den)
            if den > 0:
                return f"Running ({num}/{den} ready)"
        except ValueError:
            pass
        return "Running"
    return phase_u or "Unknown"


def _rows_at_trigger(
    rows: list[dict[str, str | float]], trigger: float, pod_key: str = "pod"
) -> dict[str, dict[str, str | float]]:
    by_pod: dict[str, list[dict[str, str | float]]] = {}
    for row in rows:
        by_pod.setdefault(str(row[pod_key]), []).append(row)
    out: dict[str, dict[str, str | float]] = {}
    for pod, pod_rows in by_pod.items():
        closest = min(pod_rows, key=lambda r: abs(float(r["sysbench_sec"]) - trigger))
        out[pod] = closest
    return out


def build_cluster_monitor_chart_data(scenario_dir: Path, trigger: float) -> dict:
    gr_rows = load_gr_pod_monitor(scenario_dir)
    k8s_rows = load_k8s_pods_monitor(scenario_dir)
    if not gr_rows and not k8s_rows:
        return {}

    event = load_metadata(scenario_dir / "failover_event.txt")
    target_pod = event.get("FAILOVER_TARGET_POD", "")
    edition_root = parent_edition_dir(scenario_dir) or scenario_dir
    replica_workers_by_pod = _pod_replica_parallel_workers_map(edition_root)

    gr_state_datasets: list[dict] = []
    applier_datasets: list[dict] = []
    workers_applying_datasets: list[dict] = []
    cert_datasets: list[dict] = []
    k8s_state_datasets: list[dict] = []

    gr_pods = sorted({str(r["pod"]) for r in gr_rows})
    for idx, pod in enumerate(gr_pods):
        color = POD_CHART_COLORS[idx % len(POD_CHART_COLORS)]
        pod_rows = sorted(
            (r for r in gr_rows if str(r["pod"]) == pod),
            key=lambda r: float(r["sysbench_sec"]),
        )
        state_points = []
        applier_points: list[dict] = []
        workers_applying_points: list[dict] = []
        cert_points: list[dict] = []
        prev_label: str | None = None
        prev_row: dict[str, str | float] | None = None
        pod_replica_workers = _replica_workers_for_pod(pod, replica_workers_by_pod)
        for row in pod_rows:
            sec = float(row["sysbench_sec"])
            applier_pt = _build_queue_point(
                row, prev_row, "applier_queue", pod_replica_workers
            )
            if applier_pt:
                applier_points.append(applier_pt)
            workers_pt = _build_queue_point(
                row, prev_row, "workers_applying_now", pod_replica_workers
            )
            if workers_pt:
                workers_applying_points.append(workers_pt)
            cert_pt = _build_queue_point(row, prev_row, "cert_queue", pod_replica_workers)
            if cert_pt:
                cert_points.append(cert_pt)
            prev_row = row

            role = str(row["gr_role"])
            gr_state = str(row["gr_state"])
            connect_ok = str(row["connect_ok"])
            level = _gr_state_level(role, gr_state, connect_ok)
            label = _gr_state_label(role, gr_state, connect_ok)
            pt: dict = {
                "x": sec,
                "y": idx * STATE_LANE_HEIGHT + level,
                "label": label,
            }
            if label != prev_label:
                pt["transition"] = True
            state_points.append(pt)
            prev_label = label
        gr_state_datasets.append(
            {
                "label": pod,
                "data": state_points,
                "borderColor": color,
                "backgroundColor": color,
                "borderWidth": 3 if pod == target_pod else 1.5,
            }
        )
        applier_datasets.append(
            {"label": pod, "data": applier_points, "borderColor": color, "backgroundColor": color}
        )
        workers_applying_datasets.append(
            {
                "label": pod,
                "data": workers_applying_points,
                "borderColor": color,
                "backgroundColor": color,
            }
        )
        cert_datasets.append(
            {"label": pod, "data": cert_points, "borderColor": color, "backgroundColor": color}
        )

    k8s_pods = sorted({str(r["pod"]) for r in k8s_rows})
    for idx, pod in enumerate(k8s_pods):
        color = POD_CHART_COLORS[idx % len(POD_CHART_COLORS)]
        pod_rows = sorted(
            (r for r in k8s_rows if str(r["pod"]) == pod),
            key=lambda r: float(r["sysbench_sec"]),
        )
        state_points = []
        prev_label: str | None = None
        for row in pod_rows:
            sec = float(row["sysbench_sec"])
            phase = str(row["phase"])
            ready_num = str(row["ready_num"])
            ready_den = str(row["ready_den"])
            deleting = str(row["deleting"])
            level = _k8s_readiness_level(phase, ready_num, ready_den, deleting)
            label = _k8s_state_label(phase, ready_num, ready_den, deleting)
            pt: dict = {
                "x": sec,
                "y": idx * STATE_LANE_HEIGHT + level,
                "label": label,
            }
            if label != prev_label:
                pt["transition"] = True
            state_points.append(pt)
            prev_label = label
        k8s_state_datasets.append(
            {
                "label": pod,
                "data": state_points,
                "borderColor": color,
                "backgroundColor": color,
                "borderWidth": 3 if pod == target_pod else 1.5,
            }
        )

    k8s_at_trigger = _rows_at_trigger(k8s_rows, trigger)
    k8s_state_table = []
    for pod in k8s_pods:
        row = k8s_at_trigger.get(pod)
        if not row:
            continue
        k8s_state_table.append(
            {
                "pod": pod,
                "phase": str(row.get("phase", "")),
                "ready": f"{row.get('ready_num', '')}/{row.get('ready_den', '')}",
                "restarts": str(row.get("restarts", "")),
                "is_target": str(row.get("is_target", "")) == "1" or pod == target_pod,
            }
        )

    pre_failover = build_gr_pre_failover_summary(scenario_dir, trigger)
    flow_thresholds = _flow_control_thresholds(scenario_dir)
    event_markers = _promotion_event_markers(scenario_dir, trigger, gr_rows)

    return {
        "has_gr": bool(gr_rows),
        "has_k8s": bool(k8s_rows),
        "trigger_sec": trigger,
        "target_pod": target_pod,
        "gr_state_datasets": gr_state_datasets,
        "applier_datasets": applier_datasets,
        "workers_applying_datasets": workers_applying_datasets,
        "cert_datasets": cert_datasets,
        "has_applier_queue": any(ds.get("data") for ds in applier_datasets),
        "has_workers_applying": any(ds.get("data") for ds in workers_applying_datasets),
        "has_cert_queue": any(ds.get("data") for ds in cert_datasets),
        "flow_thresholds": flow_thresholds,
        "event_markers": event_markers,
        "pre_failover_summary": pre_failover,
        "gr_state_lanes": gr_pods,
        "gr_state_levels": list(GR_STATE_LEVELS),
        "k8s_state_datasets": k8s_state_datasets,
        "k8s_state_lanes": k8s_pods,
        "k8s_state_levels": list(K8S_STATE_LEVELS),
        "state_lane_height": STATE_LANE_HEIGHT,
        "k8s_state_table": k8s_state_table,
    }


def _cluster_k8s_state_table_html(data: dict) -> str:
    rows = data.get("k8s_state_table") or []
    if not rows:
        return ""
    body = []
    for row in rows:
        target = " (target)" if row.get("is_target") else ""
        body.append(
            f"<tr><td>{html.escape(str(row.get('pod', '')) + target)}</td>"
            f"<td>{html.escape(str(row.get('phase', '')))}</td>"
            f"<td>{html.escape(str(row.get('ready', '')))}</td>"
            f"<td>{html.escape(str(row.get('restarts', '')))}</td></tr>"
        )
    return (
        '<table class="cluster-table"><thead><tr>'
        "<th>Pod</th><th>Phase</th><th>Ready</th><th>Restarts</th>"
        "</tr></thead><tbody>"
        + "".join(body)
        + "</tbody></table>"
    )


def _cluster_gr_pre_failover_table_html(data: dict) -> str:
    summary = data.get("pre_failover_summary") or {}
    pods = summary.get("pods") or []
    if not pods:
        return ""
    window = summary.get("window_sec", GR_PRE_FAILOVER_WINDOW_SEC)
    body = []
    for row in pods:
        promoted = summary.get("promoted_primary") == row.get("pod")
        leader = summary.get("lag_leader_pod") == row.get("pod")
        flags = []
        if promoted:
            flags.append("promoted")
        if leader:
            flags.append("lag leader")
        flag_txt = f" ({', '.join(flags)})" if flags else ""
        body.append(
            f"<tr><td>{html.escape(str(row.get('pod', '')) + flag_txt)}</td>"
            f"<td>{html.escape(str(row.get('rank', '')))}</td>"
            f"<td>{html.escape(str(row.get('avg_applier', 'N/A')))}</td>"
            f"<td>{html.escape(str(row.get('max_applier', 'N/A')))}</td>"
            f"<td>{html.escape(str(row.get('avg_cert', 'N/A')))}</td>"
            f"<td>{html.escape(str(row.get('avg_apply_rate', 'N/A')))}</td>"
            f"<td>{html.escape(str(row.get('avg_workers_applying', 'N/A')))}</td>"
            f"<td>{html.escape(str(row.get('max_workers_applying', 'N/A')))}</td></tr>"
        )
    note = summary.get("note")
    note_html = (
        f'<p class="monitor-subhead">{html.escape(str(note))}</p>' if note else ""
    )
    return (
        f'<p class="monitor-subhead">Pre-trigger window: {window:.0f}s before failover trigger. '
        f"Higher applier queue = slower apply vs siblings (same certified stream).</p>"
        + note_html
        + '<table class="cluster-table"><thead><tr>'
        "<th>Pod</th><th>Rank</th><th>Avg applier</th><th>Max applier</th>"
        "<th>Avg cert</th><th>Apply rate (txn/s)</th>"
        "<th>Avg workers applying</th><th>Max workers applying</th>"
        "</tr></thead><tbody>"
        + "".join(body)
        + "</tbody></table>"
    )


def _cluster_monitors_html(scenario_dir: Path, trigger: float, *, panel_id: str = "") -> str:
    write_gr_pre_failover_artifacts(scenario_dir, trigger)
    data = build_cluster_monitor_chart_data(scenario_dir, trigger)
    if not data:
        return (
            '<div class="card"><h2>Cluster internals</h2>'
            '<p class="muted">No GR pod or K8s readiness monitor data for this run. '
            "Advanced runs collect <code>gr_pod_monitor.tsv</code> and "
            "<code>k8s_pods_monitor.tsv</code> after kubeconfig prepare.</p></div>"
        )

    suffix = f"_{panel_id}" if panel_id else ""
    target = data.get("target_pod", "")
    target_note = (
        f' <span class="muted">(failover target: <code>{html.escape(target)}</code>)</span>'
        if target
        else ""
    )

    sections = [
        '<div class="card cluster-card"><h2>Cluster internals</h2>',
        f'<p class="monitor-subhead">Direct kubectl polls per mysql pod during the run.{target_note}</p>',
    ]

    if data.get("has_gr"):
        pre_table = _cluster_gr_pre_failover_table_html(data)
        if pre_table:
            sections.extend(
                [
                    "<h3>Pre-failover GR queue summary</h3>",
                    pre_table,
                ]
            )
        if data.get("has_cert_queue"):
            sections.extend(
                [
                    "<h3>GR certifier queue depth</h3>",
                    '<p class="monitor-subhead">Transactions waiting certification / conflict check '
                    "(<code>COUNT_TRANSACTIONS_IN_QUEUE</code>). Flow-control certifier threshold shown when configured.</p>",
                    '<div class="chart-wrap chart-wrap-sm">'
                    f'<canvas id="grCertQueueChart{suffix}"></canvas></div>',
                ]
            )
        if data.get("has_applier_queue"):
            sections.extend(
                [
                    "<h3>GR applier queue depth</h3>",
                    '<p class="monitor-subhead">Remote transactions waiting in the applier queue '
                    "(<code>COUNT_TRANSACTIONS_REMOTE_IN_APPLIER_QUEUE</code>). "
                    "Hover for role/state, cert queue, and apply rate.</p>",
                    '<div class="chart-wrap chart-wrap-sm">'
                    f'<canvas id="grApplierQueueChart{suffix}"></canvas></div>',
                ]
            )
        if data.get("has_workers_applying"):
            sections.extend(
                [
                    "<h3>Parallel replica workers in use</h3>",
                    '<p class="monitor-subhead">Count of GR applier workers with a non-empty '
                    "<code>APPLYING_TRANSACTION</code> per pod "
                    "(from <code>replication_applier_status_by_worker</code>). "
                    "Hover for configured <code>replica_parallel_workers</code> and worker totals.</p>",
                    '<div class="chart-wrap chart-wrap-sm">'
                    f'<canvas id="grWorkersApplyingChart{suffix}"></canvas></div>',
                ]
            )
        sections.extend(
            [
                "<h3>GR member state timeline</h3>",
                '<p class="monitor-subhead">One lane per pod. Hover any point for '
                "<code>ROLE / STATE</code> (e.g. <code>SECONDARY / ONLINE</code>, "
                "<code>PRIMARY / ONLINE</code>). Y-axis shows pod name and state bands.</p>",
                '<div class="chart-wrap">'
                f'<canvas id="grStateChart{suffix}"></canvas></div>',
            ]
        )

    if data.get("has_k8s"):
        sections.extend(
            [
                "<h3>K8s pod readiness timeline</h3>",
                '<p class="monitor-subhead">One lane per pod. Hover any point for phase and '
                "ready count (e.g. <code>Running (6/6 ready)</code>, "
                "<code>Terminating</code>). Y-axis shows pod name and state bands.</p>",
                '<div class="chart-wrap">'
                f'<canvas id="k8sPodChart{suffix}"></canvas></div>',
                '<p class="monitor-subhead">Pod status at trigger</p>',
                _cluster_k8s_state_table_html(data),
            ]
        )

    sections.append("</div>")
    return "".join(sections)


CLUSTER_CHARTS_CSS = """
    .cluster-card h3 { font-size: 0.92rem; color: var(--text); margin: 1.25rem 0 0.5rem; }
    .cluster-card h3:first-of-type { margin-top: 0.5rem; }
    .chart-wrap-sm { height: 220px; }
    table.cluster-table { width: 100%; border-collapse: collapse; font-size: 0.82rem; margin: 0.5rem 0 1rem; }
    table.cluster-table th, table.cluster-table td {
      padding: 0.35rem 0.5rem; border-bottom: 1px solid var(--border); text-align: left;
    }
    table.cluster-table th { color: var(--muted); font-weight: 500; }
"""

FAILOVER_SUMMARY_CSS = """
    .report-header {
      background: linear-gradient(135deg, #1e293b 0%, #0f172a 100%);
      border: 1px solid var(--border); border-radius: 12px;
      padding: 1.35rem 1.5rem; margin-bottom: 1.25rem;
    }
    .header-top { display: flex; justify-content: space-between; gap: 1.25rem; flex-wrap: wrap; }
    .header-eyebrow {
      margin: 0 0 0.3rem; font-size: 0.72rem; font-weight: 700;
      text-transform: uppercase; letter-spacing: 0.08em; color: var(--muted);
    }
    .header-title {
      margin: 0; font-size: 1.65rem; font-weight: 750; letter-spacing: -0.03em;
      line-height: 1.15; color: var(--text);
    }
    .header-subtitle { margin: 0.4rem 0 0; font-size: 0.95rem; font-weight: 600; color: var(--accent); }
    .header-primary-row {
      display: flex; align-items: center; gap: 0.55rem; flex-wrap: wrap; margin-top: 0.7rem;
    }
    .primary-chip {
      display: inline-flex; align-items: center; padding: 0.3rem 0.65rem; border-radius: 8px;
      font-size: 0.82rem; font-weight: 600; font-variant-numeric: tabular-nums;
    }
    .primary-chip.from { background: rgba(148, 163, 184, 0.12); color: var(--muted); border: 1px solid var(--border); }
    .primary-chip.to { background: rgba(56, 189, 248, 0.15); color: #7dd3fc; border: 1px solid rgba(56, 189, 248, 0.35); }
    .primary-arrow { font-size: 1rem; color: var(--muted); font-weight: 600; }
    .header-meta { display: flex; flex-direction: column; align-items: flex-end; gap: 0.45rem; min-width: 180px; }
    .header-run, .header-generated { text-align: right; font-size: 0.8rem; color: var(--muted); }
    .meta-label {
      display: block; font-size: 0.66rem; font-weight: 700;
      text-transform: uppercase; letter-spacing: 0.06em; color: #64748b; margin-bottom: 2px;
    }
    .badge {
      display: inline-block; padding: 0.2rem 0.6rem; border-radius: 999px;
      font-size: 0.74rem; font-weight: 700; letter-spacing: 0.04em;
    }
    .badge-ok { background: rgba(34, 197, 94, 0.18); color: #4ade80; border: 1px solid rgba(74, 222, 128, 0.35); }
    .badge-warn { background: rgba(251, 191, 36, 0.15); color: #fbbf24; border: 1px solid rgba(251, 191, 36, 0.35); }
    .badge-fail { background: rgba(248, 113, 113, 0.15); color: #f87171; border: 1px solid rgba(248, 113, 113, 0.35); }
    .badge-mode-planned {
      background: rgba(56, 189, 248, 0.18); color: #7dd3fc; border: 1px solid rgba(56, 189, 248, 0.4);
    }
    .badge-mode-unplanned {
      background: rgba(251, 146, 60, 0.18); color: #fdba74; border: 1px solid rgba(251, 146, 60, 0.4);
    }
    .header-mode-banner {
      display: inline-flex; align-items: center; gap: 0.45rem; margin: 0.55rem 0 0;
      padding: 0.4rem 0.75rem; border-radius: 8px; font-size: 0.86rem; font-weight: 700;
      letter-spacing: 0.02em;
    }
    .header-mode-banner.mode-planned {
      background: rgba(56, 189, 248, 0.14); color: #7dd3fc; border: 1px solid rgba(56, 189, 248, 0.35);
    }
    .header-mode-banner.mode-unplanned {
      background: rgba(251, 146, 60, 0.14); color: #fdba74; border: 1px solid rgba(251, 146, 60, 0.35);
    }
    .header-badges { display: flex; flex-wrap: wrap; gap: 0.4rem; justify-content: flex-end; }
    .impact-section {
      background: var(--card); border: 1px solid var(--border); border-radius: 12px;
      padding: 1.25rem 1.35rem 1.1rem; margin-bottom: 1.25rem;
    }
    .impact-hero { margin-bottom: 1rem; }
    .impact-hero-row { display: flex; align-items: stretch; gap: 0.85rem; flex-wrap: wrap; }
    .impact-hero-card {
      display: inline-block; min-width: 200px;
      border-radius: 10px; padding: 1rem 1.35rem;
      box-shadow: 0 2px 10px rgba(15, 23, 42, 0.35);
    }
    .impact-hero-card.hero-ok {
      background: linear-gradient(135deg, #0369a1 0%, #0ea5e9 100%); color: #f0f9ff;
    }
    .impact-hero-card.hero-warn {
      background: linear-gradient(135deg, #b45309 0%, #f59e0b 100%); color: #fffbeb;
    }
    .impact-hero-card.hero-bad {
      background: linear-gradient(135deg, #b91c1c 0%, #ef4444 100%); color: #fef2f2;
    }
    .impact-hero-value {
      font-size: 2rem; font-weight: 800; letter-spacing: -0.02em; line-height: 1;
      font-variant-numeric: tabular-nums;
    }
    .impact-hero-label { margin-top: 0.35rem; font-size: 0.78rem; font-weight: 600; opacity: 0.92; }
    .impact-hero-secondary { display: flex; align-items: center; }
    .hero-chip {
      display: inline-flex; align-items: center; padding: 0.55rem 0.85rem; border-radius: 8px;
      background: rgba(148, 163, 184, 0.1); border: 1px solid var(--border);
      font-size: 0.82rem; font-weight: 600; color: var(--text); font-variant-numeric: tabular-nums;
    }
    .impact-group { margin-top: 1rem; }
    .impact-group-title {
      margin: 0 0 0.55rem; font-size: 0.88rem; font-weight: 650; color: var(--text);
    }
    .impact-group-hint { font-weight: 500; color: var(--muted); font-size: 0.78rem; }
    .metric-kpi-grid {
      display: grid; grid-template-columns: repeat(auto-fit, minmax(155px, 1fr)); gap: 0.65rem;
    }
    .metric-kpi-grid-4 { grid-template-columns: repeat(auto-fit, minmax(140px, 1fr)); }
    .metric-kpi {
      background: rgba(15, 23, 42, 0.45); border: 1px solid var(--border); border-radius: 10px;
      padding: 0.85rem 0.9rem; text-align: center;
    }
    .metric-kpi-alert { background: rgba(248, 113, 113, 0.08); border-color: rgba(248, 113, 113, 0.35); }
    .metric-kpi-value {
      min-height: 1.85rem; display: flex; align-items: center; justify-content: center;
    }
    .metric-kpi-number {
      font-size: 1.55rem; font-weight: 800; color: var(--accent);
      font-variant-numeric: tabular-nums; letter-spacing: -0.02em;
    }
    .metric-kpi-unit { font-size: 0.9rem; font-weight: 700; margin-left: 2px; opacity: 0.85; }
    .metric-kpi-label { font-size: 0.76rem; font-weight: 650; color: var(--muted); margin-top: 0.35rem; }
    .metric-kpi-sub { font-size: 0.7rem; color: #64748b; margin-top: 0.25rem; font-variant-numeric: tabular-nums; }
    .delta-badge {
      display: inline-flex; align-items: center; gap: 3px;
      font-size: 1.2rem; font-weight: 800; letter-spacing: -0.02em; font-variant-numeric: tabular-nums;
    }
    .delta-arrow { font-size: 0.9rem; opacity: 0.9; }
    .delta-good { color: #4ade80; }
    .delta-bad { color: #f87171; }
    .delta-neutral { color: var(--muted); }
    .phase-strip-wrap { margin-top: 0.25rem; }
    .phase-strip {
      display: flex; height: 18px; border-radius: 6px; overflow: hidden;
      background: rgba(15, 23, 42, 0.6); border: 1px solid var(--border);
    }
    .phase-seg { min-width: 3px; transition: width 0.2s; }
    .phase-legend {
      display: flex; flex-wrap: wrap; gap: 0.65rem 1rem; margin-top: 0.55rem; font-size: 0.76rem; color: var(--muted);
    }
    .phase-legend-item { display: inline-flex; align-items: center; gap: 0.35rem; }
    .phase-swatch { width: 10px; height: 10px; border-radius: 2px; flex-shrink: 0; }
    .impact-details { margin-top: 0.85rem; }
    .impact-details summary {
      cursor: pointer; font-size: 0.82rem; font-weight: 600; color: var(--accent); user-select: none;
    }
    .impact-details .details-body { margin-top: 0.65rem; }
    table.summary-phase-table {
      width: 100%; border-collapse: collapse; font-size: 0.82rem; margin-top: 0.35rem;
    }
    table.summary-phase-table th, table.summary-phase-table td {
      padding: 0.4rem 0.55rem; border-bottom: 1px solid var(--border); text-align: left;
    }
    table.summary-phase-table th { color: var(--muted); font-weight: 500; }
    table.summary-phase-table td.num { font-variant-numeric: tabular-nums; white-space: nowrap; }
"""


CLUSTER_CHARTS_JS = """
    function clusterChartAnnotations(triggerSec, clusterData, thresholdKey) {
      const ann = {
        trigger: {
          type: "line", xMin: triggerSec, xMax: triggerSec,
          borderColor: "#f87171", borderWidth: 2, borderDash: [6, 4],
          label: { display: true, content: "failover trigger", color: "#fca5a5", backgroundColor: "rgba(30,41,59,0.8)" }
        }
      };
      const markers = (clusterData && clusterData.event_markers) || {};
      if (markers.gr_primary_sec != null) {
        ann.gr_primary = {
          type: "line", xMin: markers.gr_primary_sec, xMax: markers.gr_primary_sec,
          borderColor: "#34d399", borderWidth: 2, borderDash: [4, 3],
          label: {
            display: true,
            content: "GR PRIMARY" + (markers.gr_primary_pod ? (" " + markers.gr_primary_pod) : ""),
            color: "#6ee7b7", backgroundColor: "rgba(30,41,59,0.85)"
          }
        };
      }
      if (markers.write_ok_sec != null) {
        ann.write_ok = {
          type: "line", xMin: markers.write_ok_sec, xMax: markers.write_ok_sec,
          borderColor: "#60a5fa", borderWidth: 2, borderDash: [2, 2],
          label: { display: true, content: "VIP write_ok", color: "#93c5fd", backgroundColor: "rgba(30,41,59,0.85)" }
        };
      }
      const thresholds = (clusterData && clusterData.flow_thresholds) || {};
      const thVal = thresholds[thresholdKey];
      if (thVal != null && thVal >= 0) {
        ann.flow_threshold = {
          type: "line", yMin: thVal, yMax: thVal,
          borderColor: "#fbbf24", borderWidth: 1.5, borderDash: [8, 4],
          label: { display: true, content: "flow control " + thresholdKey, color: "#fcd34d", backgroundColor: "rgba(30,41,59,0.8)" }
        };
      }
      return { annotation: { annotations: ann } };
    }

    function queueChartTooltip() {
      return {
        mode: "nearest",
        intersect: false,
        callbacks: {
          title: function(items) {
            if (!items || !items.length) return "";
            return "t = " + Number(items[0].parsed.x).toFixed(1) + " s";
          },
          label: function(ctx) {
            const pt = ctx.raw || {};
            const valLabel = (pt.workers_applying_now >= 0 && pt.y === pt.workers_applying_now)
              ? (pt.y + " applying")
              : ("queue " + pt.y);
            const lines = [(ctx.dataset.label || "") + ": " + valLabel];
            if (pt.role) lines.push("  " + pt.role + " / " + pt.state);
            if (pt.replica_parallel_workers) lines.push("  replica_parallel_workers: " + pt.replica_parallel_workers);
            if (pt.cert_queue >= 0) lines.push("  cert queue: " + pt.cert_queue);
            if (pt.applier_queue >= 0) lines.push("  applier queue: " + pt.applier_queue);
            if (pt.workers_applying_now >= 0) lines.push("  workers applying: " + pt.workers_applying_now);
            if (pt.workers_total >= 0) lines.push("  workers total: " + pt.workers_total);
            if (pt.delta_queue != null) lines.push("  delta queue: " + pt.delta_queue);
            if (pt.apply_rate != null) lines.push("  apply rate: " + pt.apply_rate + " txn/s");
            if (pt.conflicts >= 0) lines.push("  conflicts: " + pt.conflicts);
            if (pt.gtid_seq >= 0) lines.push("  gtid seq tail: " + pt.gtid_seq);
            return lines;
          }
        }
      };
    }

    function stateTimelineYTicks(lanes, levelNames, laneHeight) {
      laneHeight = laneHeight || 6;
      return {
        autoSkip: false,
        callback: function(value) {
          if (!Number.isFinite(value)) return "";
          const lane = Math.floor(value / laneHeight);
          const frac = value - lane * laneHeight;
          const level = Math.round(frac);
          if (Math.abs(frac - 2.5) < 0.35) {
            return lanes[lane] || "";
          }
          if (Math.abs(frac - level) < 0.05 && level >= 0 && level < levelNames.length) {
            return lane === 0 ? levelNames[level] : "";
          }
          return "";
        }
      };
    }

    function stateTimelineTooltip() {
      return {
        mode: "nearest",
        intersect: false,
        callbacks: {
          title: function(items) {
            if (!items || !items.length) return "";
            return "t = " + Number(items[0].parsed.x).toFixed(1) + " s";
          },
          label: function(ctx) {
            const pod = ctx.dataset.label || "";
            const pt = ctx.raw || {};
            const state = pt.label || "";
            return pod + (state ? ": " + state : "");
          }
        }
      };
    }

    function renderClusterCharts(clusterData, suffix, chartStore) {
      if (!clusterData || (!clusterData.has_gr && !clusterData.has_k8s)) return;
      suffix = suffix || "";
      chartStore = chartStore || null;
      const triggerSec = clusterData.trigger_sec;
      const laneHeight = clusterData.state_lane_height || 6;

      function lineOpts(yTitle, lanes, levelNames, clusterData, thresholdKey) {
        const scales = {
          x: { type: "linear", title: { display: true, text: "Elapsed time (s from sysbench start)" } },
          y: { title: { display: true, text: yTitle }, beginAtZero: true }
        };
        if (lanes && lanes.length) {
          scales.y.min = -0.5;
          scales.y.max = lanes.length * laneHeight - 0.5;
          scales.y.ticks = stateTimelineYTicks(lanes, levelNames || [], laneHeight);
        }
        const plugins = Object.assign(
          {},
          clusterChartAnnotations(triggerSec, clusterData, thresholdKey),
          chartZoomPlugin()
        );
        return {
          responsive: true, maintainAspectRatio: false, interaction: { mode: "nearest", intersect: false },
          plugins,
          scales
        };
      }

      function makeLineChart(id, datasets, yTitle, lanes, levelNames, stateTimeline, clusterData, thresholdKey) {
        const el = document.getElementById(id);
        if (!el || !datasets || !datasets.length) return;
        datasets.forEach(ds => {
          if (stateTimeline) {
            ds.pointRadius = function(ctx) {
              const pt = ctx.raw || {};
              return pt.transition ? 4 : 0;
            };
            ds.pointHoverRadius = 6;
            ds.pointBackgroundColor = ds.borderColor;
          } else {
            ds.pointRadius = 0;
            ds.pointHoverRadius = 5;
          }
          ds.borderWidth = ds.borderWidth || 1.5;
          ds.stepped = stateTimeline ? "before" : false;
          ds.fill = false;
          ds.tension = 0;
        });
        const opts = lineOpts(yTitle, lanes, levelNames, clusterData, thresholdKey);
        if (stateTimeline) {
          opts.plugins.tooltip = stateTimelineTooltip();
        } else {
          opts.plugins.tooltip = queueChartTooltip();
        }
        const chart = new Chart(el, {
          type: "line",
          data: { datasets },
          options: opts
        });
        if (chartStore) chartStore[id] = chart;
      }

      if (clusterData.has_gr) {
        if (clusterData.has_cert_queue) {
          makeLineChart(
            "grCertQueueChart" + suffix,
            clusterData.cert_datasets,
            "Certifier queue depth",
            null, null, false, clusterData, "certifier"
          );
        }
        if (clusterData.has_applier_queue) {
          makeLineChart(
            "grApplierQueueChart" + suffix,
            clusterData.applier_datasets,
            "Applier queue depth",
            null, null, false, clusterData, "applier"
          );
        }
        if (clusterData.has_workers_applying) {
          makeLineChart(
            "grWorkersApplyingChart" + suffix,
            clusterData.workers_applying_datasets,
            "Parallel workers applying (count)",
            null, null, false, clusterData, null
          );
        }
        makeLineChart(
          "grStateChart" + suffix,
          clusterData.gr_state_datasets,
          "GR role/state (one lane per pod)",
          clusterData.gr_state_lanes,
          clusterData.gr_state_levels,
          true, clusterData, null
        );
      }
      if (clusterData.has_k8s) {
        makeLineChart(
          "k8sPodChart" + suffix,
          clusterData.k8s_state_datasets,
          "Pod phase/readiness (one lane per pod)",
          clusterData.k8s_state_lanes,
          clusterData.k8s_state_levels,
          true, clusterData, null
        );
      }
    }
"""


def _short_pod_name(name: str) -> str:
    for prefix in ("benchmark-failover2-", "benchmark-"):
        if name.startswith(prefix):
            return name[len(prefix) :]
    return name


def _wall_hms(wall: str) -> str:
    if "T" in wall:
        return wall.split("T", 1)[1].rstrip("Z")
    return wall


def _is_planned_trigger(event: dict[str, str]) -> bool:
    method = _trigger_method_from_event(event)
    return method in ("set_as_primary", "group_replication_set_as_primary")


def _trigger_method_from_event(event: dict[str, str]) -> str:
    return (
        event.get("FAILOVER_ADVANCED_TRIGGER_METHOD")
        or event.get("FAILOVER_METHOD")
        or ""
    ).strip()


def _trigger_method_from_path(scenario_dir: Path | None) -> str:
    if scenario_dir is None:
        return ""
    for part in scenario_dir.parts:
        if part in TRIGGER_METHODS:
            return part
    return ""


def _normalize_trigger_method(method: str) -> str:
    method = (method or "").strip()
    if method == "group_replication_set_as_primary":
        return "set_as_primary"
    return method


def _failover_mode_info(
    event: dict[str, str] | None = None,
    scenario_dir: Path | None = None,
) -> dict[str, str]:
    """Classify a run as planned / unplanned for report headers and labels."""
    event = event or {}
    method = _normalize_trigger_method(_trigger_method_from_event(event))
    if not method:
        method = _normalize_trigger_method(_trigger_method_from_path(scenario_dir))

    if method == "set_as_primary":
        return {
            "mode": "planned",
            "label": "Planned failover",
            "short": "Planned",
            "method": method,
            "badge_class": "badge-mode-planned",
            "eyebrow": "Planned failover benchmark",
            "title": "Planned Failover Impact Summary",
        }
    if method in {"pod_delete", "mysqld_kill"}:
        method_note = "pod delete" if method == "pod_delete" else "mysqld kill"
        return {
            "mode": "unplanned",
            "label": f"Unplanned failover ({method_note})",
            "short": "Unplanned",
            "method": method,
            "badge_class": "badge-mode-unplanned",
            "eyebrow": "Unplanned failover benchmark",
            "title": "Unplanned Failover Impact Summary",
        }
    return {
        "mode": "unknown",
        "label": "Failover",
        "short": "",
        "method": method,
        "badge_class": "",
        "eyebrow": "Failover benchmark",
        "title": "Failover Impact Summary",
    }


def _humanize_scenario_path_label(label: str) -> str:
    """Turn pod_delete/mixed into 'Unplanned (pod_delete) · mixed' for UI toggles."""
    parts = [p for p in str(label).split("/") if p]
    if not parts:
        return label
    out: list[str] = []
    for part in parts:
        info = _failover_mode_info({"FAILOVER_ADVANCED_TRIGGER_METHOD": part})
        if info["mode"] == "planned":
            out.append("Planned (set_as_primary)")
        elif info["mode"] == "unplanned":
            out.append(f"Unplanned ({part})")
        else:
            out.append(part)
    return " · ".join(out)


def _is_promoted_monitor_row(
    row: dict[str, str | float],
    edition: str,
    primary_before: str = "",
) -> bool:
    if row["connect_ok"] != "1" or row["write_ok"] != "1":
        return False
    if edition == "advanced":
        if not (row["gr_role"] == "PRIMARY" and row["gr_state"] in ("ONLINE", "PRIMARY")):
            return False
    host = str(row.get("hostname") or "")
    if primary_before and host and host != "ERROR" and host != primary_before:
        return True
    if not primary_before:
        return edition != "advanced" or row["gr_role"] == "PRIMARY"
    return False


def _select_monitor_transition_rows(
    monitor_rows: list[dict[str, str | float]],
    trigger: float,
    primary_before: str,
    event: dict[str, str],
) -> list[tuple[dict[str, str | float], str]]:
    """Curated polls around trigger: failure marker + promotion (planned vs unplanned)."""
    ordered: list[tuple[dict[str, str | float], str]] = []
    seen: set[tuple[str, str]] = set()
    edition = event.get("FAILOVER_EDITION", "advanced")
    planned = _is_planned_trigger(event)
    detect_window = _PLANNED_DETECT_WINDOW_SEC if planned else _DETECT_WINDOW_SEC

    def add(row: dict[str, str | float], note: str = "") -> None:
        key = (str(row["wall"]), str(row["hostname"]))
        if key in seen:
            return
        seen.add(key)
        ordered.append((row, note))

    pre = [r for r in monitor_rows if float(r["sysbench_sec"]) < trigger]
    post = [r for r in monitor_rows if float(r["sysbench_sec"]) >= trigger]

    if pre:
        add(pre[-1])

    trigger_row = post[0] if post else None
    if trigger_row:
        add(trigger_row, "← switchover triggered" if planned else "← pod deleted")

    failure_row: dict[str, str | float] | None = None
    for row in post:
        if float(row["sysbench_sec"]) - trigger > detect_window:
            break
        if planned:
            if row["connect_ok"] == "0" or row["write_ok"] == "0":
                failure_row = row
                break
        elif row["connect_ok"] == "0":
            failure_row = row
            break

    promote_row: dict[str, str | float] | None = None
    saw_failure = False
    for row in post:
        if planned and float(row["sysbench_sec"]) - trigger > detect_window and not saw_failure:
            # Allow zero-downtime planned promote within the short window only.
            break
        if row["connect_ok"] == "0" or row["write_ok"] == "0":
            if (not planned) or float(row["sysbench_sec"]) - trigger <= detect_window:
                saw_failure = True
        elif saw_failure and _is_promoted_monitor_row(row, edition, primary_before):
            promote_row = row
            break
        elif (
            planned
            and not saw_failure
            and _is_promoted_monitor_row(row, edition, primary_before)
            and float(row["sysbench_sec"]) - trigger <= detect_window
        ):
            # Zero-downtime: hostname moved with continuous write_ok.
            promote_row = row
            break

    # Add annotated failure/promote before intermediates so notes are not dropped by seen[].
    if failure_row:
        note = "← first write failure" if planned else "← first connect failure"
        add(failure_row, note)

    if promote_row:
        add(promote_row, "← promotion")

    if trigger_row and failure_row and promote_row:
        delete_sb = float(trigger_row["sysbench_sec"])
        failure_sb = float(failure_row["sysbench_sec"])
        promote_sb = float(promote_row["sysbench_sec"])
        for row in post:
            sb = float(row["sysbench_sec"])
            if sb <= delete_sb + 0.05 or sb >= promote_sb - 0.05:
                continue
            if abs(sb - failure_sb) < 0.05:
                continue
            if primary_before and str(row["hostname"]) == primary_before:
                add(row)

    return ordered


def _monitor_trigger_table_html(scenario_dir: Path, bundle: dict) -> str:
    """HTML table: primary before / at delete / through promotion (per scenario panel)."""
    monitor_rows = load_primary_monitor(scenario_dir)
    trigger = float(bundle.get("trigger_wall", bundle.get("trigger", 0)))
    primary_before = bundle.get("primary", {}).get("PRIMARY_BEFORE", "")
    primary_after = bundle.get("primary", {}).get("PRIMARY_AFTER", "")
    scenario = bundle.get("scenario", "")
    event = bundle.get("event", {})
    trigger_utc = event.get("FAILOVER_TRIGGER_UTC") or event.get("FAILOVER_POD_DELETE_UTC") or event.get("FAILOVER_MYSQLD_KILL_UTC", "")
    target_pod = event.get("FAILOVER_TARGET_POD", primary_before)

    if not monitor_rows:
        return '<p class="muted">No primary_monitor.tsv for this scenario.</p>'

    if trigger <= 0:
        return '<p class="muted">Trigger second unknown — cannot align monitor polls.</p>'

    post = [r for r in monitor_rows if float(r["sysbench_sec"]) >= trigger]
    connect0 = sum(1 for r in post if r["connect_ok"] == "0")
    write0 = sum(1 for r in post if r["write_ok"] == "0")

    transition = _select_monitor_transition_rows(monitor_rows, trigger, primary_before, event)
    if not transition:
        return '<p class="muted">No monitor polls around trigger.</p>'

    trigger_hms = _wall_hms(trigger_utc) if trigger_utc else "N/A"
    planned = _is_planned_trigger(event)
    if planned:
        headline = (
            f'<p class="monitor-headline"><strong>{html.escape(scenario)}</strong> — planned '
            f"switchover (<code>set_as_primary</code>) at "
            f"<code>{html.escape(trigger_hms)}</code> "
            f"(from <code>{html.escape(_short_pod_name(target_pod))}</code>)</p>"
        )
    else:
        headline = (
            f'<p class="monitor-headline"><strong>{html.escape(scenario)}</strong> — pod '
            f"<code>{html.escape(_short_pod_name(target_pod))}</code> deleted at "
            f"<code>{html.escape(trigger_hms)}</code></p>"
        )
    if primary_before:
        headline += (
            f'<p class="monitor-subhead">Primary before trigger: '
            f"<code>{html.escape(_short_pod_name(primary_before))}</code>"
        )
        if primary_after and primary_after != primary_before:
            headline += (
                f" · after promotion: <code>{html.escape(_short_pod_name(primary_after))}</code>"
            )
        headline += (
            f' · post-trigger <span class="{"cell-bad" if connect0 else ""}">connect_ok=0: {connect0}</span>'
            f' · <span class="{"cell-bad" if write0 else ""}">write_ok=0: {write0}</span></p>'
        )

    body_rows: list[str] = []
    for row, note in transition:
        sb = float(row["sysbench_sec"])
        row_classes: list[str] = []
        if note in ("← pod deleted", "← switchover triggered"):
            row_classes.append("row-at-trigger")
        elif note in ("← promotion", "← hostname change"):
            row_classes.append("row-promotion")
        if row["connect_ok"] == "0" or row["write_ok"] == "0":
            row_classes.append("row-fail")
        cls = f' class="{" ".join(row_classes)}"' if row_classes else ""

        connect_cell = html.escape(str(row["connect_ok"]))
        write_cell = html.escape(str(row["write_ok"]))
        if row["connect_ok"] == "0":
            connect_cell = f'<span class="cell-bad">{connect_cell}</span>'
        if row["write_ok"] == "0":
            write_cell = f'<span class="cell-bad">{write_cell}</span>'

        role = html.escape(str(row["gr_role"]))
        if note:
            role += f' <span class="monitor-note">{html.escape(note)}</span>'

        body_rows.append(
            f"<tr{cls}>"
            f"<td>{sb:.3f}</td>"
            f"<td>{html.escape(_wall_hms(str(row['wall'])))}</td>"
            f"<td>{connect_cell}</td>"
            f"<td>{write_cell}</td>"
            f"<td>{html.escape(_short_pod_name(str(row['hostname'])))}</td>"
            f"<td>{role}</td>"
            f"</tr>"
        )

    return f"""
    {headline}
    <div class="table-scroll">
      <table class="monitor-trigger">
        <thead>
          <tr>
            <th>Sysbench sec</th>
            <th>Wall time</th>
            <th>connect</th>
            <th>write_ok</th>
            <th>Hostname</th>
            <th>GR role</th>
          </tr>
        </thead>
        <tbody>{"".join(body_rows)}</tbody>
      </table>
    </div>
    """


def load_kpi(path: Path) -> dict[str, str]:
    if not path.exists():
        return {}
    with path.open(newline="") as fh:
        reader = csv.DictReader(fh)
        for row in reader:
            return dict(row)
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
        trigger = float(
            meta.get("FAILOVER_TRIGGER_LOG_SECOND")
            or meta.get("FAILOVER_TRIGGER_SECOND", "0")
        )
        if trigger <= 0:
            trigger = _scenario_trigger_log_sec(edition_dir)
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


def _parse_extended_metrics(path: Path) -> dict[str, str]:
    if not path.exists():
        return {}
    text = path.read_text(encoding="utf-8", errors="replace")
    patterns = {
        "failure_detect_sec": r"Time to detect failure:\s+([\d.]+)\s+s\b",
        "promote_sec": r"Time to promote primary:\s+([\d.]+)\s+s\b",
        "total_failover_sec": r"Total failover time:\s+([\d.]+)\s+s\b",
        "rto_sec": r"Application recovery RTO:\s+([\d.]+)\s+s\b",
        "primary_before": r"Primary before:\s+(\S+)",
        "primary_after": r"Primary after:\s+(\S+)",
        "primary_changed": r"Primary changed:\s+(\S+)",
        "min_tps_post": r"Min TPS post-trigger:\s+([\d.]+)",
        "max_tps_drop_pct": r"Max TPS drop:\s+([\d.]+)%",
        "min_qps_post": r"Min QPS post-trigger:\s+([\d.]+)",
        "peak_lat_post_ms": r"Peak p95 latency post-trigger:\s+([\d.]+)\s+ms",
        "tpcc_check": r"TPC-C consistency check:\s+(\S+)",
    }
    out: dict[str, str] = {}
    for key, pattern in patterns.items():
        match = re.search(pattern, text)
        if match:
            out[key] = match.group(1)
    return out


def _format_duration_sec(value: str | float | int | None) -> str:
    if value is None or value == "" or str(value).upper() in {"N/A", "NOT_DETECTED", "NOT_REACHED"}:
        return "N/A"
    try:
        sec = float(value)
    except (TypeError, ValueError):
        return html.escape(str(value))
    ms = int(round(sec * 1000))
    if sec >= 60:
        minutes = sec / 60
        return f"{sec:.2f} s ({ms:,} ms · {minutes:.2f} min)"
    if sec < 1:
        return f"{ms:,} ms ({sec:.3f} s)"
    if sec == int(sec):
        return f"{int(sec)} s ({ms:,} ms)"
    return f"{sec:.2f} s ({ms:,} ms)"


def _parse_metric_sec(value: str | float | int | None) -> float | None:
    if value is None or value == "" or str(value).upper() in {"N/A", "NOT_DETECTED", "NOT_REACHED"}:
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _phase_gap_sec(end: str | float | int | None, start: str | float | int | None) -> str:
    end_sec = _parse_metric_sec(end)
    start_sec = _parse_metric_sec(start)
    if end_sec is None or start_sec is None or end_sec < start_sec:
        return "N/A"
    return _format_duration_sec(end_sec - start_sec)


def _format_latency_ms(value: str | float | int | None) -> str:
    if value is None or value == "" or str(value).upper() == "N/A":
        return "N/A"
    try:
        ms = float(value)
    except (TypeError, ValueError):
        return html.escape(str(value))
    sec = ms / 1000
    if ms >= 1000:
        return f"{ms:,.2f} ms ({sec:.2f} s · {sec / 60:.3f} min)"
    return f"{ms:.2f} ms ({sec:.3f} s)"


def _metric_row(title: str, value: str, help_text: str, *, sub: str = "", raw_value: bool = False) -> str:
    sub_html = f'<div class="metric-sub">{html.escape(sub)}</div>' if sub else ""
    value_html = value if raw_value else html.escape(value)
    return (
        f"<tr>"
        f'<td class="metric-name-cell">'
        f'<div class="metric-title">{html.escape(title)}</div>'
        f'<div class="metric-help">{html.escape(help_text)}</div>'
        f"</td>"
        f'<td class="metric-value-cell">'
        f'<div class="metric-value">{value_html}</div>'
        f"{sub_html}"
        f"</td>"
        f"</tr>"
    )


def _metrics_summary_html(
    kpi: dict[str, str],
    extended: dict[str, str],
    primary: dict[str, str],
    parsed: dict[str, str],
) -> str:
    if not kpi and not extended:
        return '<p class="muted">No failover_kpi.csv or failover_extended_metrics.txt found.</p>'

    detect = kpi.get("failure_detection_sec") or extended.get("failure_detect_sec", "N/A")
    promote = kpi.get("primary_election_sec") or extended.get("promote_sec", "N/A")

    before = primary.get("PRIMARY_BEFORE") or extended.get("primary_before", "N/A")
    after = primary.get("PRIMARY_AFTER") or extended.get("primary_after", "N/A")
    changed = primary.get("PRIMARY_CHANGED") or extended.get("primary_changed", "N/A")

    rows = [
        _metric_row(
            "Time to detect failure",
            _format_duration_sec(detect),
            METRIC_HELP["detect"],
        ),
        _metric_row(
            "Time to promote new primary",
            _format_duration_sec(promote),
            METRIC_HELP["promote"],
            sub=f"Primary: {before} → {after} ({changed})",
        ),
    ]

    return (
        '<table class="metrics">'
        "<thead><tr><th>Metric</th><th>Value</th></tr></thead>"
        f"<tbody>{''.join(rows)}</tbody></table>"
    )


def _metrics_with_promote_split_html(
    kpi: dict[str, str],
    extended: dict[str, str],
    primary: dict[str, str],
    parsed: dict[str, str],
    scenario_dir: Path,
) -> str:
    return _metrics_summary_html(kpi, extended, primary, parsed) + _promote_three_phase_html(scenario_dir)


def load_promotion_breakdown(path: Path) -> list[dict[str, str]]:
    if not path.exists():
        return []
    rows: list[dict[str, str]] = []
    with path.open(newline="", encoding="utf-8", errors="replace") as fh:
        reader = csv.DictReader(fh)
        for row in reader:
            rows.append(dict(row))
    return rows


def _breakdown_cell_time(raw: str) -> str:
    if raw in {"", "N/A", "NOT_DETECTED", "NOT_REACHED"}:
        return "N/A"
    return _format_duration_sec(raw)


def _breakdown_cell_duration(raw: str) -> str:
    if raw in {"", "N/A", "NOT_DETECTED", "NOT_REACHED"}:
        return "N/A"
    if raw in {"0", "0.0", "0.00", "0.000"}:
        return "0 s"
    return _format_duration_sec(raw)


OPERATOR_LOG_TS_RE = re.compile(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z)")
OPERATOR_POLL_PATTERNS = (
    re.compile(r"not all members are online", re.I),
    re.compile(r"only \d+/\d+ members are online", re.I),
    re.compile(r"member is not online", re.I),
)
OPERATOR_LABEL_PATTERN = re.compile(r"assigning primary label", re.I)


@dataclass(frozen=True)
class PromoteSplitRow:
    phase: str
    duration_sec: float
    notes: str


DB_CONSENSUS_TITLE = "Database consensus promotion"
DB_CONSENSUS_DEFINITION = (
    "Time for MySQL nodes to detect the failure and elect a new primary node. "
    "Nothing else can happen until the database agrees who is in charge."
)
HA_CONVERGENCE_TITLE = "HAProxy convergence"
HA_CONVERGENCE_DEFINITION = (
    "Time for HAProxy to probe the new primary and update the routing pool. "
    "Traffic cannot resume until the proxy sees the new primary is ready."
)
PROMOTE_PHASE_DEFINITIONS: list[tuple[str, str, str]] = [
    (
        "promote_gr_election_after_ttd",
        "GR election",
        "mysqld log: A new primary was elected (fallback: gr_pod_monitor PRIMARY+ONLINE)",
    ),
    (
        "promote_ha_routing_after_ttd",
        "HAProxy routable",
        "GR elected → mysql-primary UP on elected server (applier/read_only wait + health check; stats socket, VIP hostname fallback)",
    ),
    (
        "promote_client_path_restore_after_ttd",
        "Client path restore",
        "HA backend UP → first write probe OK on client VIP",
    ),
    (
        "promote_total",
        "Time to promote (total)",
        "TTD → write probe OK (sum of three phases above)",
    ),
]


def _promote_three_phase_html(scenario_dir: Path) -> str:
    breakdown_rows = load_promotion_breakdown(scenario_dir / "failover_promotion_breakdown.csv")
    if not breakdown_rows:
        return ""
    by_phase = {row.get("phase", ""): row for row in breakdown_rows}
    total_row = by_phase.get("promote_total", {})
    total_dur = _breakdown_cell_duration(total_row.get("duration_from_ttd_sec", "N/A"))
    if total_dur == "N/A":
        return ""

    env = load_metadata(scenario_dir / "gr_election_internal.env")
    ha_env = load_metadata(scenario_dir / "haproxy_primary_up.env")
    sources: list[str] = []
    if env.get("GR_ELECTION_SOURCE") == "mysql_pod_logs":
        sources.append("GR election: mysqld pod logs (A new primary was elected)")
    elif (scenario_dir / "gr_pod_monitor.tsv").exists():
        sources.append("GR election: gr_pod_monitor.tsv fallback")
    if env.get("GR_WRITABLE_SOURCE") == "mysql_pod_logs":
        sources.append("Apply lag note: mysqld working-as-primary log on elected pod")
    if ha_env.get("HAPROXY_PRIMARY_UP_SOURCE") == "haproxy_stats_monitor":
        server = ha_env.get("HAPROXY_PRIMARY_UP_SERVER", "elected server")
        sources.append(f"HAProxy routable: haproxy_stats_monitor ({server} UP in mysql-primary backend)")
    else:
        sources.append("HAProxy routable: primary_monitor.tsv hostname fallback")
    internal_apply_note = ""
    election_sec = _parse_metric_sec(env.get("GR_ELECTION_FROM_TRIGGER_SEC"))
    writable_sec = _parse_metric_sec(env.get("GR_WRITABLE_FROM_TRIGGER_SEC"))
    if election_sec is not None and writable_sec is not None and writable_sec > election_sec:
        internal_apply_note = (
            f'<p class="muted" style="margin:0.5rem 0 0;font-size:0.82rem">'
            f"<strong>Internal apply lag (mysqld logs):</strong> "
            f"{html.escape(_format_duration_sec(writable_sec - election_sec))} "
            f"(elected → working-as-primary on {html.escape(env.get('GR_ELECTION_POD', 'elected pod'))})."
            f"</p>"
        )
    source_note = " · ".join(sources)

    body: list[str] = []
    accounted = 0.0
    for phase_key, title, help_text in PROMOTE_PHASE_DEFINITIONS:
        row = by_phase.get(phase_key, {})
        if not row and phase_key == "promote_client_path_restore_after_ttd":
            row = by_phase.get("promote_replication_lag_after_ttd", {})
        dur_raw = row.get("duration_from_ttd_sec", "N/A")
        dur = _breakdown_cell_duration(dur_raw)
        at_trig = _breakdown_cell_time(row.get("time_from_trigger_sec", "N/A"))
        row_class = ' class="row-total"' if phase_key == "promote_total" else ""
        if phase_key != "promote_total":
            parsed = _parse_metric_sec(dur_raw)
            if parsed is not None:
                accounted += max(0.0, parsed)
        body.append(
            f"<tr{row_class}><td class=\"phase-name-cell\"><div class=\"metric-title\">{html.escape(title)}</div>"
            f'<div class="metric-help">{html.escape(help_text)}</div></td>'
            f'<td class="num">{html.escape(dur)}</td>'
            f'<td class="num">{html.escape(at_trig)}</td></tr>'
        )

    return f"""
      <h3 style="font-size:0.92rem;color:var(--accent);margin:1rem 0 0.5rem">Time to promote and accept writes</h3>
      <p class="muted" style="margin:0 0 0.75rem;font-size:0.85rem">
        Three phases from first connect failure (TTD) to write probe OK on the client VIP.
      </p>
      <table class="metrics promotion-breakdown" style="margin-bottom:0.75rem">
        <thead><tr><th>Phase</th><th>Duration (from TTD)</th><th>At (from trigger)</th></tr></thead>
        <tbody>{''.join(body)}</tbody>
      </table>
      <p class="muted" style="margin:0;font-size:0.82rem"><strong>Sources:</strong> {html.escape(source_note)}</p>
      {internal_apply_note}
    """


PHASE_STRIP_COLORS = ("#22c55e", "#38bdf8", "#a78bfa")


def _failover_run_id(scenario_dir: Path) -> str:
    if scenario_dir.name in {"mixed", "write_only"}:
        return scenario_dir.parent.name
    return scenario_dir.name


def _hero_duration_short(value: str | float | int | None) -> str:
    sec = _parse_metric_sec(value)
    if sec is None:
        return "N/A"
    if sec >= 60:
        return f"{sec:.1f}s"
    if sec < 1:
        return f"{sec:.2f}s"
    if sec == int(sec):
        return f"{int(sec)}s"
    return f"{sec:.1f}s"


def _delta_badge_html(before: float, after: float, *, lower_is_better: bool = False) -> str:
    if before <= 0 or after <= 0:
        return '<span class="delta-badge delta-neutral">—</span>'
    pct = (after - before) / before * 100.0
    if abs(pct) < 0.05:
        return '<span class="delta-badge delta-neutral">0%</span>'
    is_good = (pct < 0) if lower_is_better else (pct > 0)
    cls = "delta-good" if is_good else "delta-bad"
    arrow = "↓" if pct < 0 else "↑"
    sign = "+" if pct > 0 else ""
    return (
        f'<span class="delta-badge {cls}">'
        f'<span class="delta-arrow">{arrow}</span>{sign}{pct:.1f}%</span>'
    )


def _promotion_phases_by_key(scenario_dir: Path) -> dict[str, dict[str, str]]:
    return {row.get("phase", ""): row for row in load_promotion_breakdown(scenario_dir / "failover_promotion_breakdown.csv")}


def _applier_at_trigger_for_pod(scenario_dir: Path, pod: str) -> str | None:
    if not pod:
        return None
    env = load_metadata(scenario_dir / "gr_pre_failover_applier.env")
    direct = env.get(f"GR_PRE_FAILOVER_POD_APPLIER_{pod}", "")
    if direct not in {"", "N/A"}:
        return direct
    short = pod.split("-")[-1] if "-" in pod else pod
    for key, val in env.items():
        if not key.startswith("GR_PRE_FAILOVER_POD_APPLIER_"):
            continue
        if key.endswith(f"_{short}") or key.removeprefix("GR_PRE_FAILOVER_POD_APPLIER_").endswith(short):
            if val not in {"", "N/A"}:
                return val
    return None


def _promoted_apply_context(scenario_dir: Path, primary: dict[str, str], trigger_wall: float) -> dict[str, object]:
    promoted = (
        primary.get("PRIMARY_AFTER", "")
        or load_metadata(scenario_dir / "gr_election_internal.env").get("GR_ELECTION_POD", "")
    )
    by_phase = _promotion_phases_by_key(scenario_dir)
    ha_row = by_phase.get("promote_ha_routing_after_ttd", {})
    ha_dur_raw = ha_row.get("duration_from_ttd_sec", "")

    gr_env = load_metadata(scenario_dir / "gr_election_internal.env")
    election_sec = _parse_metric_sec(gr_env.get("GR_ELECTION_FROM_TRIGGER_SEC"))
    writable_sec = _parse_metric_sec(gr_env.get("GR_WRITABLE_FROM_TRIGGER_SEC"))
    internal_apply_sec: float | None = None
    if election_sec is not None and writable_sec is not None and writable_sec > election_sec:
        internal_apply_sec = writable_sec - election_sec

    applier_raw = _applier_at_trigger_for_pod(scenario_dir, str(promoted))
    apply_rate: float | None = None
    summary = build_gr_pre_failover_summary(scenario_dir, trigger_wall)
    for pod_row in summary.get("pods") or []:
        if str(pod_row.get("pod") or "") == promoted:
            rate = pod_row.get("avg_apply_rate")
            if rate is not None:
                apply_rate = float(rate)
            break

    estimated_drain: float | None = None
    if applier_raw and apply_rate and apply_rate > 0:
        try:
            estimated_drain = float(applier_raw) / apply_rate
        except (TypeError, ValueError):
            estimated_drain = None

    return {
        "promoted_pod": str(promoted) if promoted else "",
        "applier_at_trigger": applier_raw,
        "apply_rate": apply_rate,
        "estimated_drain_sec": estimated_drain,
        "internal_apply_sec": internal_apply_sec,
        "ha_routable_sec": _parse_metric_sec(ha_dur_raw),
    }


def _phase_strip_html(by_phase: dict[str, dict[str, str]]) -> str:
    segments: list[tuple[str, float, str]] = []
    titles = (
        ("promote_gr_election_after_ttd", "GR election"),
        ("promote_ha_routing_after_ttd", "HAProxy routable"),
        ("promote_client_path_restore_after_ttd", "Client path restore"),
    )
    for idx, (key, title) in enumerate(titles):
        row = by_phase.get(key, {})
        if not row and key == "promote_client_path_restore_after_ttd":
            row = by_phase.get("promote_replication_lag_after_ttd", {})
        dur = _parse_metric_sec(row.get("duration_from_ttd_sec"))
        if dur is not None and dur >= 0:
            segments.append((title, dur, PHASE_STRIP_COLORS[idx % len(PHASE_STRIP_COLORS)]))

    total_row = by_phase.get("promote_total", {})
    total = _parse_metric_sec(total_row.get("duration_from_ttd_sec"))
    if not segments:
        return '<p class="muted" style="margin:0;font-size:0.82rem">Promotion breakdown not available.</p>'
    denom = total if total and total > 0 else sum(d for _, d, _ in segments)
    if denom <= 0:
        denom = 1.0

    bar_parts: list[str] = []
    legend_parts: list[str] = []
    for title, dur, color in segments:
        pct = max(2.0, dur / denom * 100.0)
        bar_parts.append(
            f'<div class="phase-seg" style="width:{pct:.1f}%;background:{color}" '
            f'title="{html.escape(title)}: {_hero_duration_short(dur)}"></div>'
        )
        legend_parts.append(
            f'<span class="phase-legend-item">'
            f'<span class="phase-swatch" style="background:{color}"></span>'
            f'{html.escape(title)} <strong>{html.escape(_hero_duration_short(dur))}</strong>'
            f"</span>"
        )
    total_label = _hero_duration_short(total) if total else _hero_duration_short(denom)
    legend_parts.append(f'<span class="phase-legend-item"><strong>Total {html.escape(total_label)}</strong></span>')
    return (
        '<div class="phase-strip-wrap">'
        f'<div class="phase-strip">{"".join(bar_parts)}</div>'
        f'<div class="phase-legend">{"".join(legend_parts)}</div>'
        "</div>"
    )


def _summary_phase_details_html(by_phase: dict[str, dict[str, str]]) -> str:
    if not by_phase:
        return ""
    rows: list[str] = []
    for phase_key, title, _help in PROMOTE_PHASE_DEFINITIONS:
        row = by_phase.get(phase_key, {})
        if not row and phase_key == "promote_client_path_restore_after_ttd":
            row = by_phase.get("promote_replication_lag_after_ttd", {})
        dur = _breakdown_cell_duration(row.get("duration_from_ttd_sec", "N/A"))
        at_trig = _breakdown_cell_time(row.get("time_from_trigger_sec", "N/A"))
        weight = ' style="font-weight:600"' if phase_key == "promote_total" else ""
        rows.append(
            f"<tr{weight}><td>{html.escape(title)}</td>"
            f'<td class="num">{html.escape(dur)}</td>'
            f'<td class="num">{html.escape(at_trig)}</td></tr>'
        )
    return (
        '<table class="summary-phase-table">'
        "<thead><tr><th>Phase</th><th>Duration (from TTD)</th><th>At (from trigger)</th></tr></thead>"
        f"<tbody>{''.join(rows)}</tbody></table>"
    )


def _throughput_kpi_cards_html(bundle: dict) -> str:
    rows = bundle.get("rows", [])
    trigger = float(bundle.get("trigger", 0))
    parsed = bundle.get("parsed", {})
    kpi = bundle.get("kpi", {})
    extended = bundle.get("extended", {})

    before_tps, before_qps, before_lat = _resolve_baseline_metrics(parsed, rows, trigger)
    promote_sec = _parse_kpi_sec(kpi.get("primary_election_sec")) or _parse_kpi_sec(
        extended.get("promote_sec")
    )
    after_tps, after_qps, after_lat, _note = _averages_after_failover(rows, trigger, promote_sec)

    cards = [
        (
            "TPS",
            _delta_badge_html(before_tps, after_tps),
            f"{_fmt_compare_num(after_tps)} after · {_fmt_compare_num(before_tps)} before",
        ),
        (
            "QPS",
            _delta_badge_html(before_qps, after_qps),
            f"{_fmt_compare_num(after_qps)} after · {_fmt_compare_num(before_qps)} before",
        ),
        (
            "Latency p95",
            _delta_badge_html(before_lat, after_lat, lower_is_better=True),
            (
                f"{_format_latency_ms(after_lat)} after · {_format_latency_ms(before_lat)} before"
                if after_lat > 0 and before_lat > 0
                else "N/A"
            ),
        ),
    ]
    parts: list[str] = []
    for label, badge, sub in cards:
        parts.append(
            f'<div class="metric-kpi">'
            f'<div class="metric-kpi-value">{badge}</div>'
            f'<div class="metric-kpi-label">{html.escape(label)}</div>'
            f'<div class="metric-kpi-sub">{html.escape(sub)}</div>'
            f"</div>"
        )
    return "".join(parts)


def _promoted_kpi_cards_html(ctx: dict[str, object]) -> str:
    promoted = str(ctx.get("promoted_pod") or "")
    if not promoted:
        return '<p class="muted" style="margin:0;font-size:0.82rem">Promoted primary not recorded.</p>'

    applier = ctx.get("applier_at_trigger")
    apply_rate = ctx.get("apply_rate")
    drain = ctx.get("estimated_drain_sec")
    internal = ctx.get("internal_apply_sec")
    ha_sec = ctx.get("ha_routable_sec")

    def num_card(label: str, value_html: str, sub: str = "", *, alert: bool = False) -> str:
        cls = " metric-kpi-alert" if alert else ""
        sub_html = f'<div class="metric-kpi-sub">{html.escape(sub)}</div>' if sub else ""
        return (
            f'<div class="metric-kpi{cls}">'
            f'<div class="metric-kpi-value metric-kpi-number">{value_html}</div>'
            f'<div class="metric-kpi-label">{html.escape(label)}</div>'
            f"{sub_html}"
            f"</div>"
        )

    applier_val = html.escape(str(applier)) if applier not in (None, "", "N/A") else "N/A"
    try:
        applier_alert = float(applier) >= 1000 if applier not in (None, "", "N/A") else False
    except (TypeError, ValueError):
        applier_alert = False

    rate_sub = ""
    if apply_rate and float(apply_rate) > 0:
        rate_sub = f"{float(apply_rate):.1f} tx/s pre-trigger avg"
        if drain:
            rate_sub += f" · est. drain {_hero_duration_short(drain)}"

    cards = [
        num_card("Applier queue @ trigger", applier_val, "on promoted pod", alert=applier_alert),
        num_card(
            "Pre-trigger apply rate",
            f"{float(apply_rate):.1f}" if apply_rate else "N/A",
            rate_sub or "30s window before trigger",
        ),
        num_card(
            "Internal apply (mysqld)",
            _hero_duration_short(internal) if internal is not None else "N/A",
            "elected → working-as-primary",
        ),
        num_card(
            "HAProxy routable",
            _hero_duration_short(ha_sec) if ha_sec is not None else "N/A",
            "GR elected → stats UP",
        ),
    ]
    return f'<div class="metric-kpi-grid metric-kpi-grid-4">{"".join(cards)}</div>'


def _failover_status_badge(promote_raw: str) -> tuple[str, str]:
    sec = _parse_metric_sec(promote_raw)
    if sec is None:
        return "badge-fail", "INCOMPLETE"
    if sec <= 5:
        return "badge-ok", "SUCCESS"
    if sec <= 30:
        return "badge-warn", "DEGRADED"
    return "badge-warn", "SLOW"


def _failover_impact_summary_html(bundle: dict) -> str:
    scenario_dir = Path(bundle["dir"])
    kpi = bundle.get("kpi", {})
    extended = bundle.get("extended", {})
    primary = bundle.get("primary", {})
    event = bundle.get("event", {})
    edition = bundle.get("edition", "advanced")
    scenario = bundle.get("scenario", "default")
    trx_profile = bundle.get("trx_profile", "mixed")
    threads = bundle.get("threads", "")
    mode_info = _failover_mode_info(event, scenario_dir)

    promote_raw = kpi.get("primary_election_sec") or extended.get("promote_sec", "N/A")
    detect_raw = kpi.get("failure_detection_sec") or extended.get("failure_detect_sec", "N/A")
    before = primary.get("PRIMARY_BEFORE") or extended.get("primary_before", "N/A")
    after = primary.get("PRIMARY_AFTER") or extended.get("primary_after", "N/A")

    badge_cls, badge_text = _failover_status_badge(str(promote_raw))
    promote_sec = _parse_metric_sec(promote_raw)
    if promote_sec is not None and promote_sec <= 5:
        hero_cls = "hero-ok"
    elif promote_sec is not None and promote_sec <= 30:
        hero_cls = "hero-warn"
    else:
        hero_cls = "hero-bad"

    trigger_utc = event.get("FAILOVER_TRIGGER_UTC", "N/A")
    trigger_method = (
        mode_info.get("method")
        or event.get("FAILOVER_METHOD")
        or event.get("FAILOVER_ADVANCED_TRIGGER_METHOD")
        or "N/A"
    )
    target_pod = event.get("FAILOVER_TARGET_POD", "N/A")
    run_id = _failover_run_id(scenario_dir)
    generated = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")

    trigger_line = f"{trigger_utc}"
    if trigger_method not in {"", "N/A"} or target_pod not in {"", "N/A"}:
        trigger_line += f" · {trigger_method} · {target_pod}"

    by_phase = _promotion_phases_by_key(scenario_dir)
    trigger_wall = float(bundle.get("trigger_wall", bundle.get("trigger", 0)))
    apply_ctx = _promoted_apply_context(scenario_dir, primary, trigger_wall)
    promoted_pod = str(apply_ctx.get("promoted_pod") or after or "N/A")

    primary_row = ""
    if before not in {"", "N/A"} or after not in {"", "N/A"}:
        primary_row = (
            '<div class="header-primary-row">'
            f'<span class="primary-chip from">{html.escape(before)}</span>'
            '<span class="primary-arrow" aria-hidden="true">→</span>'
            f'<span class="primary-chip to">{html.escape(after)}</span>'
            "</div>"
        )

    details_html = ""
    if by_phase:
        details_html = (
            '<details class="impact-details">'
            "<summary>Full promote breakdown</summary>"
            f'<div class="details-body">{_summary_phase_details_html(by_phase)}</div>'
            "</details>"
        )

    threads_label = f"{threads} threads" if threads else "threads N/A"
    mode_banner = ""
    mode_badge = ""
    if mode_info["mode"] in {"planned", "unplanned"}:
        mode_banner = (
            f'<p class="header-mode-banner mode-{html.escape(mode_info["mode"])}">'
            f'{html.escape(mode_info["label"])}'
            f'</p>'
        )
        mode_badge = (
            f'<span class="badge {html.escape(mode_info["badge_class"])}">'
            f'{html.escape(mode_info["short"].upper())}</span>'
        )

    return f"""
<header class="report-header">
  <div class="header-top">
    <div class="header-titles">
      <p class="header-eyebrow">{html.escape(mode_info["eyebrow"])}</p>
      <h1 class="header-title">{html.escape(mode_info["title"])}</h1>
      {mode_banner}
      <p class="header-subtitle">{html.escape(edition)} · {html.escape(scenario)} ({html.escape(trx_profile)}) · {html.escape(threads_label)}</p>
      {primary_row}
    </div>
    <div class="header-meta">
      <div class="header-badges">
        {mode_badge}
        <span class="badge {badge_cls}">{badge_text}</span>
      </div>
      <div class="header-run"><span class="meta-label">Run</span>{html.escape(run_id)}</div>
      <div class="header-run"><span class="meta-label">Trigger</span>{html.escape(trigger_line)}</div>
      <div class="header-generated"><span class="meta-label">Generated</span>{html.escape(generated)}</div>
    </div>
  </div>
</header>
<section class="impact-section">
  <div class="impact-hero">
    <div class="impact-hero-row">
      <div class="impact-hero-card {hero_cls}">
        <div class="impact-hero-value">{html.escape(_hero_duration_short(promote_raw))}</div>
        <div class="impact-hero-label">Time to promote (TTD → write OK)</div>
      </div>
      <div class="impact-hero-secondary">
        <span class="hero-chip">Time to detect: {html.escape(_hero_duration_short(detect_raw))}</span>
      </div>
    </div>
  </div>
  <div class="impact-group">
    <h3 class="impact-group-title">Throughput impact <span class="impact-group-hint">before vs after failover</span></h3>
    <div class="metric-kpi-grid">{_throughput_kpi_cards_html(bundle)}</div>
  </div>
  <div class="impact-group">
    <h3 class="impact-group-title">Promote breakdown <span class="impact-group-hint">from TTD</span></h3>
    {_phase_strip_html(by_phase)}
  </div>
  <div class="impact-group">
    <h3 class="impact-group-title">Promoted primary <span class="impact-group-hint">({html.escape(promoted_pod)})</span></h3>
    {_promoted_kpi_cards_html(apply_ctx)}
  </div>
  {details_html}
</section>
"""


def _parse_utc_timestamp(raw: str) -> datetime | None:
    if not raw:
        return None
    text = raw.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        return datetime.fromisoformat(text)
    except ValueError:
        return None


def _resolve_kubeconfig(scenario_dir: Path, bench: dict[str, str]) -> Path | None:
    local = scenario_dir / "kubeconfig"
    if local.exists():
        return local
    configured = bench.get("ADVANCED_KUBECONFIG_PATH", "").strip()
    if configured:
        path = Path(configured)
        if path.exists():
            return path
    return None


def _read_operator_log_text(scenario_dir: Path, trigger_utc: str, bench: dict[str, str]) -> str:
    log_path = scenario_dir / "operator_failover.log"
    if log_path.exists():
        text = log_path.read_text(encoding="utf-8", errors="replace")
        if OPERATOR_LOG_TS_RE.search(text):
            return text

    kubeconfig = _resolve_kubeconfig(scenario_dir, bench)
    if not kubeconfig or not trigger_utc:
        return log_path.read_text(encoding="utf-8", errors="replace") if log_path.exists() else ""

    ns = bench.get("ADVANCED_K8S_NAMESPACE", "percona")
    context = bench.get("ADVANCED_K8S_CONTEXT", "").strip()
    label = "app.kubernetes.io/name=percona-server-mysql-operator"
    kubectl = ["kubectl", f"--kubeconfig={kubeconfig}"]
    if context:
        kubectl.extend(["--context", context])

    for args in (
        ["logs", "-n", ns, "-l", label, f"--since-time={trigger_utc}", "--timestamps"],
        ["logs", "-A", "-l", label, f"--since-time={trigger_utc}", "--timestamps", "--max-log-requests=5"],
    ):
        try:
            proc = subprocess.run(
                [*kubectl, *args],
                capture_output=True,
                text=True,
                timeout=45,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired):
            continue
        if proc.stdout.strip():
            return proc.stdout
    return log_path.read_text(encoding="utf-8", errors="replace") if log_path.exists() else ""


def _parse_operator_log_events(log_text: str, trigger_utc: str) -> dict[str, float]:
    trigger = _parse_utc_timestamp(trigger_utc)
    if not trigger or not log_text:
        return {}

    poll_ts: datetime | None = None
    label_ts: datetime | None = None
    for line in log_text.splitlines():
        match = OPERATOR_LOG_TS_RE.match(line)
        if not match:
            continue
        ts = _parse_utc_timestamp(match.group(1))
        if ts is None or ts < trigger:
            continue
        if poll_ts is None and any(pattern.search(line) for pattern in OPERATOR_POLL_PATTERNS):
            poll_ts = ts
        if label_ts is None and OPERATOR_LABEL_PATTERN.search(line):
            label_ts = ts

    events: dict[str, float] = {}
    if poll_ts is not None:
        events["poll_from_trigger"] = (poll_ts - trigger).total_seconds()
    if label_ts is not None:
        events["label_from_trigger"] = (label_ts - trigger).total_seconds()
    return events


def _gr_election_after_ttd(by_phase: dict[str, dict[str, str]], ttd_sec: float, scenario_dir: Path | None = None) -> tuple[float, str]:
    gr_after = _parse_metric_sec(by_phase.get("promote_gr_election_after_ttd", {}).get("duration_from_ttd_sec"))
    if gr_after is not None:
        source = by_phase.get("gr_election_internal", {}).get("description", "")
        note = "From gr_pod_monitor.tsv"
        if "mysql_pod_logs" in source:
            note = "From mysql pod GR logs (sub-second)"
        elif "gr_pod_monitor" in source:
            note = "From gr_pod_monitor.tsv"
        return max(0.0, gr_after), note

    gr_internal = _parse_metric_sec(by_phase.get("gr_election_internal", {}).get("time_from_trigger_sec"))
    if gr_internal is not None and gr_internal > ttd_sec:
        source = by_phase.get("gr_election_internal", {}).get("description", "")
        note = "From gr_pod_monitor.tsv"
        if "mysql_pod_logs" in source:
            note = "From mysql pod GR logs (sub-second)"
        return gr_internal - ttd_sec, note

    if scenario_dir is not None:
        env_path = scenario_dir / "gr_election_internal.env"
        if env_path.exists():
            env = load_metadata(env_path)
            rel = _parse_metric_sec(env.get("GR_ELECTION_FROM_TRIGGER_SEC"))
            if rel is not None:
                after = max(0.0, rel - ttd_sec)
                ms = env.get("GR_ELECTION_FROM_TRIGGER_MS", "")
                note = "From mysql pod GR logs"
                if ms:
                    note = f"From mysql pod GR logs ({int(ms):,} ms from trigger)"
                return after, note

    return 0.0, "GR election timing not collected"


def compute_promote_window_split(scenario_dir: Path) -> tuple[float | None, list[PromoteSplitRow], str]:
    breakdown_rows = load_promotion_breakdown(scenario_dir / "failover_promotion_breakdown.csv")
    if not breakdown_rows:
        return None, [], "Re-run analysis or ./reanalyze_failover.sh to populate promotion metrics."

    by_phase = {row.get("phase", ""): row for row in breakdown_rows}
    promote_total = _parse_metric_sec(by_phase.get("promote_total", {}).get("duration_from_ttd_sec"))
    if promote_total is None:
        kpi = load_kpi(scenario_dir / "failover_kpi.csv")
        promote_total = _parse_metric_sec(kpi.get("primary_election_sec"))
    if promote_total is None:
        return None, [], "Promote window not detected in this run."

    ttd_sec = _parse_metric_sec(by_phase.get("failure_detection_ttd", {}).get("time_from_trigger_sec")) or 0.0
    db_consensus, _db_source = _gr_election_after_ttd(by_phase, ttd_sec, scenario_dir)
    db_from_csv = _parse_metric_sec(by_phase.get("promote_gr_election_after_ttd", {}).get("duration_from_ttd_sec"))
    if db_from_csv is not None:
        db_consensus = max(0.0, db_from_csv)

    ha_convergence = max(0.0, promote_total - db_consensus)

    meta = load_metadata(scenario_dir / "failover_timeseries_meta.txt")
    bench = load_benchmark_config(scenario_dir, meta)
    event = load_metadata(scenario_dir / "failover_event.txt")
    trigger_utc = (
        event.get("FAILOVER_TRIGGER_UTC")
        or event.get("FAILOVER_POD_DELETE_UTC")
        or event.get("FAILOVER_MYSQLD_KILL_UTC")
        or ""
    )

    has_gr_pod_monitor = (scenario_dir / "gr_pod_monitor.tsv").exists()
    has_mysql_gr_logs = bool(list(scenario_dir.glob("mysql_gr_election*.log"))) or (
        scenario_dir / "gr_election_internal.env"
    ).exists()
    operator_events = _parse_operator_log_events(
        _read_operator_log_text(scenario_dir, trigger_utc, bench), trigger_utc
    )
    has_operator_logs = bool(operator_events)

    source_lines = [
        (
            "Database consensus: "
            + (
                "gr_pod_monitor.tsv (kubectl exec GR role poll on each mysql pod during the run). "
                if has_gr_pod_monitor
                else (
                    "mysql pod GR logs (group_replication plugin; mysql_gr_election_*.log). "
                    if has_mysql_gr_logs
                    else "not collected (enable FAILOVER_GR_POD_MONITOR=1 or reanalyze with kubectl). "
                )
            )
        ),
        (
            "HAProxy convergence: client VIP primary monitor — residual from internal GR ready "
            "to write probe OK on MYSQL_HOST."
        ),
    ]
    if has_operator_logs:
        source_lines.append(
            "Operator logs (operator_failover.log) corroborate label timing only; "
            "HAProxy container logs are not collected."
        )
    else:
        source_lines.append("HAProxy container logs are not collected by this benchmark.")
    source_lines.append("1 s monitor grid quantizes sub-second steps.")
    footnote = " ".join(source_lines)

    rows = [
        PromoteSplitRow(DB_CONSENSUS_TITLE, db_consensus, DB_CONSENSUS_DEFINITION),
        PromoteSplitRow(HA_CONVERGENCE_TITLE, ha_convergence, HA_CONVERGENCE_DEFINITION),
    ]
    return promote_total, rows, footnote


def _mysqld_kill_no_failover_callout(scenario_dir: Path) -> str:
    """Note when mysqld_kill did not cause GR failover (same pod throughout)."""
    event = load_metadata(scenario_dir / "failover_event.txt")
    primary = load_metadata(scenario_dir / "primary_change.env")
    kpi = load_kpi(scenario_dir / "failover_kpi.csv")

    method = " ".join(
        (
            event.get("FAILOVER_METHOD", ""),
            event.get("FAILOVER_ADVANCED_TRIGGER_METHOD", ""),
        )
    ).lower()
    if "mysqld" not in method and "kill" not in method:
        return ""
    if primary.get("PRIMARY_CHANGED", "").lower() not in {"no", "0", "false"}:
        return ""

    detect = _parse_metric_sec(kpi.get("failure_detection_sec"))
    promote = _parse_metric_sec(kpi.get("primary_election_sec"))
    pod = primary.get("PRIMARY_BEFORE", primary.get("PRIMARY_AFTER", "N/A"))
    if detect is None or promote is None or detect < 5:
        return ""

    return f"""
      <p class="muted" style="margin:0 0 0.75rem;padding:0.6rem 0.75rem;border-left:3px solid #60a5fa;background:rgba(96,165,250,0.06);">
        <strong>mysqld_kill without GR failover:</strong> VIP stayed on
        <code>{html.escape(pod)}</code> for {html.escape(_format_duration_sec(detect))} after kill
        (no primary change). The long detection time reflects continued VIP connectivity while
        mysqld restarted in-place, not operator promotion delay. After a brief connect blip,
        recovery took {html.escape(_format_duration_sec(promote))}.
      </p>
    """


def _promote_window_split_html(scenario_dir: Path) -> str:
    promote_total, rows, footnote = compute_promote_window_split(scenario_dir)
    if promote_total is None or not rows:
        return f'<p class="muted">{html.escape(footnote)}</p>'

    callout = _mysqld_kill_no_failover_callout(scenario_dir)
    body_rows: list[str] = []
    accounted = 0.0
    for row in rows:
        accounted += row.duration_sec
        pct = (row.duration_sec / promote_total * 100.0) if promote_total > 0 else 0.0
        body_rows.append(
            "<tr>"
            f'<td class="phase-name-cell"><div class="metric-title">{html.escape(row.phase)}</div>'
            f'<div class="metric-help">{html.escape(row.notes)}</div></td>'
            f'<td class="num">{html.escape(_format_duration_sec(row.duration_sec))}</td>'
            f'<td class="num">~{pct:.0f}%</td>'
            "</tr>"
        )

    total_pct = (accounted / promote_total * 100.0) if promote_total > 0 else 100.0
    body_rows.append(
        '<tr class="row-total">'
        '<td class="phase-name-cell"><div class="metric-title">Time to promote new primary (total)</div>'
        '<div class="metric-help">First connect failure on client VIP → write probe OK '
        "(same as <em>Time to promote new primary</em> in Failover metrics)</div></td>"
        f'<td class="num">{html.escape(_format_duration_sec(promote_total))}</td>'
        f'<td class="num">~{total_pct:.0f}%</td>'
        "</tr>"
    )

    window_label = _format_duration_sec(promote_total)
    return f"""
      {callout}
      <p class="muted" style="margin:0 0 0.75rem">
        Breakdown of the <strong>{html.escape(window_label)}</strong> window from first client connect
        failure to write probe OK on the VIP.
      </p>
      <table class="metrics promotion-breakdown">
        <thead>
          <tr>
            <th>Phase</th>
            <th>Duration</th>
            <th>% of window</th>
          </tr>
        </thead>
        <tbody>{''.join(body_rows)}</tbody>
      </table>
      <p class="muted" style="margin:0.75rem 0 0;font-size:0.85rem"><strong>Data sources:</strong> {html.escape(footnote)}</p>
    """


# Ordered phases for the HTML promotion breakdown table.
PROMOTION_BREAKDOWN_PHASES: list[tuple[str, str, str]] = [
    (
        "stale_ha_routing",
        "Stale HA routing",
        "VIP still served writes from old primary after trigger (before sustained outage)",
    ),
    (
        "failure_detection_ttd",
        "Time to detect failure (TTD)",
        "First connect failure on client VIP (connect_ok=0)",
    ),
    (
        "gr_election_internal",
        "GR election (internal)",
        "First GR PRIMARY+ONLINE on any mysql pod (direct pod poll, bypasses VIP)",
    ),
    (
        "operator_ha_lag_after_gr",
        "Operator + HAProxy lag",
        "VIP connect restored after internal GR election (operator endpoint + HA routing)",
    ),
    (
        "vip_outage",
        "Client VIP outage",
        "Client path down: connect_ok=0 on HA endpoint (blackout after TTD)",
    ),
    (
        "vip_connect_restored",
        "VIP connect restored",
        "First successful TCP/MySQL connect on client VIP after TTD",
    ),
    (
        "ha_routes_new_host",
        "HA routes to new pod",
        "Client VIP session lands on new mysql pod (hostname changed)",
    ),
    (
        "gr_primary_on_vip",
        "GR PRIMARY on VIP",
        "GR PRIMARY+ONLINE visible through client VIP path",
    ),
    (
        "write_probe_ok",
        "Accept new writes",
        "Write probe INSERT succeeds on client VIP (promotion complete)",
    ),
    (
        "promote_total",
        "Time to promote new primary (total)",
        "TTD → write probe OK (same as Failover metrics KPI)",
    ),
]


def _promotion_split_summary_html(by_phase: dict[str, str]) -> str:
    """Two-part promote split: GR election (after TTD) + HA routing = total promote."""
    gr_row = by_phase.get("promote_gr_election_after_ttd", {})
    ha_row = by_phase.get("promote_ha_routing_to_primary", {})
    total_row = by_phase.get("promote_total", {})
    gr_dur = gr_row.get("duration_from_ttd_sec", "")
    ha_dur = ha_row.get("duration_from_ttd_sec", "")
    total_dur = total_row.get("duration_from_ttd_sec", "")
    gr_internal = by_phase.get("gr_election_internal", {}).get("time_from_trigger_sec", "")

    if gr_dur in {"", "NOT_REACHED", "NOT_DETECTED"} or ha_dur in {"", "NOT_REACHED", "NOT_DETECTED"}:
        vip_dur = by_phase.get("vip_outage", {}).get("duration_from_ttd_sec", total_dur)
        return f"""
      <p class="muted" style="margin:0 0 0.75rem">
        <strong>Promote = GR election (internal) + HA routing</strong> requires
        <code>gr_pod_monitor.tsv</code> (Advanced runs with <code>FAILOVER_GR_POD_MONITOR=1</code>).
        Reanalyze after a new run, or see VIP-only window below.
      </p>
      <table class="metrics promotion-breakdown">
        <thead><tr><th>Component</th><th>Duration (from TTD)</th></tr></thead>
        <tbody>
          <tr><td class="phase-name-cell"><div class="metric-title">Client VIP promote window</div>
            <div class="metric-help">Full promote time without GR/HA split (connect failure → write OK)</div></td>
            <td class="num">{html.escape(_breakdown_cell_duration(vip_dur if vip_dur not in {"", "NOT_REACHED"} else total_dur))}</td></tr>
        </tbody>
      </table>
        """

    gr_at = _breakdown_cell_time(gr_internal)
    rows = [
        (
            "GR election (internal)",
            "Wait for GR PRIMARY+ONLINE on a mysql pod (direct pod poll). "
            "0 s if GR finished before TTD.",
            _breakdown_cell_duration(gr_dur),
            gr_at,
        ),
        (
            "HA routing to writable primary",
            "Operator + HAProxy: GR ready → client VIP sees PRIMARY + write probe OK.",
            _breakdown_cell_duration(ha_dur),
            "—",
        ),
        (
            "Time to promote (total)",
            "Sum of above (= KPI primary_election_sec).",
            _breakdown_cell_duration(total_dur),
            _breakdown_cell_time(total_row.get("time_from_trigger_sec", "N/A")),
        ),
    ]
    body = []
    for i, (title, help_text, dur, at_trig) in enumerate(rows):
        cls = ' class="row-total"' if i == len(rows) - 1 else ""
        if i == 0:
            body.append(
                f"<tr{cls}><td class=\"phase-name-cell\"><div class=\"metric-title\">{html.escape(title)}</div>"
                f'<div class="metric-help">{html.escape(help_text)}</div></td>'
                f'<td class="num">{html.escape(dur)}</td>'
                f'<td class="num">{html.escape(at_trig)}</td></tr>'
            )
        else:
            body.append(
                f"<tr{cls}><td class=\"phase-name-cell\"><div class=\"metric-title\">{html.escape(title)}</div>"
                f'<div class="metric-help">{html.escape(help_text)}</div></td>'
                f'<td class="num">{html.escape(dur)}</td>'
                f'<td class="num">—</td></tr>'
            )
    return f"""
      <p class="muted" style="margin:0 0 0.5rem">
        <strong>Promote (from TTD)</strong> = GR election (internal) + HA routing to writable primary on VIP.
      </p>
      <table class="metrics promotion-breakdown" style="margin-bottom:1.25rem">
        <thead><tr><th>Component</th><th>Duration (from TTD)</th><th>GR at (from trigger)</th></tr></thead>
        <tbody>{''.join(body)}</tbody>
      </table>
    """


def _promotion_breakdown_html(scenario_dir: Path) -> str:
    breakdown_rows = load_promotion_breakdown(scenario_dir / "failover_promotion_breakdown.csv")
    if not breakdown_rows:
        return (
            '<p class="muted">No promotion breakdown yet. Re-run analysis or '
            '<code>./reanalyze_failover.sh</code> on this scenario.</p>'
        )

    by_phase = {row.get("phase", ""): row for row in breakdown_rows}
    summary_html = _promotion_split_summary_html(by_phase)

    detail_phases = [
        k for k, _, _ in PROMOTION_BREAKDOWN_PHASES
        if k not in {
            "promote_gr_election_after_ttd",
            "promote_ha_routing_to_primary",
            "operator_ha_lag_after_gr",
            "host_switch_after_connect",
            "write_accept_after_gr",
            "vip_connect_restored",
            "write_probe_ok",
        }
    ]
    body_rows: list[str] = []
    for phase_key in detail_phases:
        title_help = next((t, h) for k, t, h in PROMOTION_BREAKDOWN_PHASES if k == phase_key)
        title, help_text = title_help
        row = by_phase.get(phase_key, {})
        anchor = row.get("anchor", "")
        anchor_label = "Failover trigger" if anchor == "trigger" else "First connect failure (TTD)"
        at_trigger = _breakdown_cell_time(row.get("time_from_trigger_sec", "N/A"))
        dur_ttd = _breakdown_cell_duration(row.get("duration_from_ttd_sec", "N/A"))
        if phase_key in ("failure_detection_ttd", "stale_ha_routing"):
            dur_ttd = "—"
        row_class = ' class="row-total"' if phase_key == "promote_total" else ""
        body_rows.append(
            f"<tr{row_class}>"
            f'<td class="phase-name-cell"><div class="metric-title">{html.escape(title)}</div>'
            f'<div class="metric-help">{html.escape(help_text)}</div></td>'
            f'<td>{html.escape(anchor_label)}</td>'
            f'<td class="num">{html.escape(at_trigger)}</td>'
            f'<td class="num">{html.escape(dur_ttd)}</td>'
            f"</tr>"
        )

    return f"""
      {summary_html}
      <h3 style="font-size:0.92rem;color:var(--accent);margin:0 0 0.5rem">Detail timeline</h3>
      <table class="metrics promotion-breakdown">
        <thead>
          <tr>
            <th>Phase</th>
            <th>Anchor</th>
            <th>At (from trigger)</th>
            <th>Duration (from TTD)</th>
          </tr>
        </thead>
        <tbody>{''.join(body_rows)}</tbody>
      </table>
      <p class="muted" style="margin:0.75rem 0 0">
        Full log: <code>failover_promotion_breakdown.txt</code>
        · 1s monitor grid quantizes sub-second steps.
      </p>
    """


CHARTJS_ZOOM_CDN = """  <script src="https://cdn.jsdelivr.net/npm/hammerjs@2.0.8"></script>
  <script src="https://cdn.jsdelivr.net/npm/chartjs-plugin-zoom@2.2.0/dist/chartjs-plugin-zoom.min.js"></script>"""

CHART_ZOOM_CSS = """    .chart-hint-global { color: var(--muted); font-size: 0.8rem; margin: 0 0 1rem; }"""

CHART_ZOOM_HINT = (
    "Scroll or pinch to zoom · drag to select a time range · Shift+drag to pan · double-click a chart to reset"
)

CHART_ZOOM_JS = """
    function chartZoomPlugin() {
      return {
        zoom: {
          pan: {
            enabled: true,
            mode: "x",
            modifierKey: "shift",
          },
          zoom: {
            wheel: { enabled: true, speed: 0.1 },
            pinch: { enabled: true },
            drag: {
              enabled: true,
              backgroundColor: "rgba(56,189,248,0.12)",
              borderColor: "rgba(56,189,248,0.45)",
              borderWidth: 1,
            },
            mode: "x",
          },
          limits: {
            x: { min: "original", max: "original" },
          },
        },
      };
    }

    document.addEventListener("dblclick", (e) => {
      const canvas = e.target.closest(".chart-wrap canvas");
      if (!canvas) return;
      const chart = Chart.getChart(canvas);
      if (chart) chart.resetZoom();
    });
"""


def generate_html_report(
    edition_dir: Path,
    rows: list[dict[str, float]],
    meta: dict[str, str],
    parsed: dict[str, str],
    event: dict[str, str],
    kpi: dict[str, str],
    png_files: list[Path],
    extended: dict[str, str] | None = None,
    primary: dict[str, str] | None = None,
) -> Path:
    extended = extended or {}
    primary = primary or {}
    bench = load_benchmark_config(edition_dir, meta)
    trigger_log = _scenario_trigger_log_sec(edition_dir)
    trigger_wall = _scenario_trigger_wall_sec(edition_dir)
    if not meta.get("FAILOVER_TRIGGER_LOG_SECOND"):
        meta.setdefault("FAILOVER_TRIGGER_LOG_SECOND", str(int(trigger_log)))
    if not meta.get("FAILOVER_TRIGGER_WALL_SECOND"):
        meta.setdefault("FAILOVER_TRIGGER_WALL_SECOND", str(int(trigger_wall)))
    scenario = meta.get("FAILOVER_SCENARIO", edition_dir.name if edition_dir.name in {"mixed", "write_only"} else "default")
    trx_profile = meta.get("TPCC_TRX_PROFILE", kpi.get("trx_profile", "mixed"))
    edition = resolve_edition_name(edition_dir, meta, event, kpi, bench)
    enrich_cluster_metadata(bench, edition)
    baseline_tps, baseline_qps, baseline_lat = _resolve_baseline_metrics(parsed, rows, trigger_log)
    recovery = float(parsed.get("RECOVERY_THRESHOLD", str(baseline_tps * 0.9 if baseline_tps else 0)))
    outage_start, outage_end = _derive_outage_bounds(rows, trigger_log, baseline_tps)

    elapsed = [r["elapsed_sec"] for r in rows]
    chart_data = {
        "elapsed": elapsed,
        "tps": [r["tps"] for r in rows],
        "qps": [r["qps"] for r in rows],
        "err": [r["err_per_sec"] for r in rows],
        "reconn": [r["reconn_per_sec"] for r in rows],
        "lat_p95": [r["lat_p95_ms"] for r in rows],
        "trigger_sec": trigger_log,
        "baseline_tps": baseline_tps,
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

    if trigger_wall != trigger_log:
        trigger_meta_rows = [
            ("Trigger second (log)", str(int(trigger_log)) if trigger_log else "N/A"),
            ("Trigger second (wall)", str(int(trigger_wall)) if trigger_wall else "N/A"),
        ]
    else:
        trigger_meta_rows = [("Trigger second", str(int(trigger_log)) if trigger_log else "N/A")]
    meta_rows = [
        ("Edition", edition),
        ("Failover type", _failover_mode_info(event, edition_dir)["label"]),
        ("Scenario", scenario),
        ("TPC-C profile", trx_profile),
        ("Load threads", str(infer_thread_count(edition_dir, meta, bench)) or _cfg_value(bench, "THREADS", "FAILOVER_THREADS")),
        ("Slug size", _cfg_value(bench, "SLUG_SIZE", "CLUSTER_SLUG", "MYSQL_CLUSTER_PLAN")),
        ("Num nodes", _cfg_value(bench, "NUM_NODES", "CLUSTER_NUM_NODES")),
        ("Data size", _format_data_size(bench)),
        ("TPCC_SCALE", _cfg_value(bench, "TPCC_SCALE")),
        ("TPCC_THREADS", _cfg_value(bench, "TPCC_THREADS", "PREP_THREADS")),
        *_edition_metadata_rows(edition_dir, bench, edition_dir),
        ("Sysbench start (UTC)", meta.get("SYSBENCH_START_UTC", "N/A")),
        ("Failover trigger (UTC)", event.get("FAILOVER_TRIGGER_UTC", "N/A")),
        *trigger_meta_rows,
        ("Trigger method", event.get("FAILOVER_METHOD") or event.get("FAILOVER_ADVANCED_TRIGGER_METHOD") or "N/A"),
        ("Target pod", event.get("FAILOVER_TARGET_POD", "N/A")),
        ("Baseline TPS", f"{baseline_tps:.2f}" if baseline_tps else "N/A"),
        ("Baseline QPS", f"{baseline_qps:.2f}" if baseline_qps else "N/A"),
        (
            "Baseline latency p95",
            _format_latency_ms(baseline_lat) if baseline_lat else "N/A",
        ),
    ]
    meta_html = _meta_table_html(meta_rows)
    cluster_data = build_cluster_monitor_chart_data(edition_dir, trigger_wall)
    cluster_html = _cluster_monitors_html(edition_dir, trigger_wall)
    monitor_bundle = {
        "trigger": trigger_log,
        "trigger_wall": trigger_wall,
        "primary": primary,
        "event": event,
        "scenario": scenario,
    }
    summary_bundle = {
        "dir": str(edition_dir),
        "edition": edition,
        "scenario": scenario,
        "trx_profile": trx_profile,
        "threads": infer_thread_count(edition_dir, meta, bench),
        "rows": rows,
        "parsed": parsed,
        "event": event,
        "kpi": kpi,
        "extended": extended,
        "primary": primary,
        "trigger": trigger_log,
        "trigger_wall": trigger_wall,
    }
    impact_summary_html = _failover_impact_summary_html(summary_bundle)
    mode_info = _failover_mode_info(event, edition_dir)
    page_title = (
        f"{mode_info['short']} failover report — {edition} / {scenario}"
        if mode_info["short"]
        else f"Failover report — {edition} / {scenario}"
    )

    out_path = edition_dir / "graphs" / "failover_report.html"
    out_path.parent.mkdir(exist_ok=True)

    page = f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{html.escape(page_title)}</title>
  <script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.1/dist/chart.umd.min.js"></script>
  <script src="https://cdn.jsdelivr.net/npm/chartjs-plugin-annotation@3.0.1/dist/chartjs-plugin-annotation.min.js"></script>
{CHARTJS_ZOOM_CDN}
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
{CHART_ZOOM_CSS}
    .grid {{ display: grid; gap: 1rem; grid-template-columns: 1fr; align-items: stretch; }}
    @media (min-width: 960px) {{
      .grid {{ grid-template-columns: 360px 1fr; }}
    }}
    .sidebar {{ display: flex; flex-direction: column; gap: 1rem; min-height: 100%; }}
    .card.sidebar-meta {{ flex: 1; }}
    .main-column {{ display: flex; flex-direction: column; gap: 1.25rem; }}
    .card {{
      background: var(--card); border: 1px solid var(--border);
      border-radius: 8px; padding: 1rem 1.25rem;
    }}
    .card h2 {{ font-size: 1rem; margin: 0 0 0.75rem; color: var(--accent); }}
    table {{ width: 100%; border-collapse: collapse; font-size: 0.9rem; }}
    th {{ text-align: left; color: var(--muted); font-weight: 500; padding: 0.35rem 0.5rem 0.35rem 0; }}
    td {{ padding: 0.35rem 0; }}
    table.metrics {{ font-size: 0.9rem; }}
    table.metrics thead th {{
      color: var(--muted); font-weight: 500; padding: 0.35rem 0.65rem 0.5rem 0;
      border-bottom: 1px solid var(--border);
    }}
    table.metrics tbody td {{
      padding: 0.65rem 0.65rem 0.65rem 0; border-bottom: 1px solid var(--border);
      vertical-align: top;
    }}
    table.metrics tbody tr:last-child td {{ border-bottom: none; }}
    table.metrics td.metric-name-cell {{ width: 55%; padding-right: 1rem; }}
    table.metrics td.metric-value-cell {{ font-variant-numeric: tabular-nums; }}
    table.promotion-breakdown td.phase-name-cell {{ width: 42%; }}
    table.promotion-breakdown td.num {{ font-variant-numeric: tabular-nums; white-space: nowrap; }}
    table.promotion-breakdown tr.row-total td {{
      background: rgba(56, 189, 248, 0.10); font-weight: 600;
    }}
    table.promotion-breakdown tr.row-total .metric-title {{ color: #38bdf8; }}
    .metric-title {{ font-weight: 600; color: var(--accent); margin-bottom: 0.25rem; }}
    .metric-value {{ font-size: 1.05rem; color: var(--text); margin-bottom: 0.15rem; }}
    .metric-sub {{ color: var(--muted); font-size: 0.82rem; margin-bottom: 0.2rem; }}
    .metric-help {{ color: var(--muted); font-size: 0.78rem; line-height: 1.35; }}
    .chart-wrap {{ position: relative; height: 320px; margin-bottom: 1rem; }}
    .muted {{ color: var(--muted); font-size: 0.9rem; }}
    ul {{ margin: 0.25rem 0 0; padding-left: 1.25rem; }}
    a {{ color: var(--accent); }}
    .monitor-summary {{ font-size: 0.88rem; margin: 0 0 0.35rem; }}
    .monitor-headline {{ font-size: 0.92rem; margin: 0 0 0.35rem; }}
    .monitor-subhead {{ color: var(--muted); font-size: 0.82rem; margin: 0 0 0.75rem; }}
    table.monitor-trigger {{ width: 100%; border-collapse: collapse; font-size: 0.8rem; min-width: 520px; }}
    table.monitor-trigger th, table.monitor-trigger td {{
      padding: 0.35rem 0.5rem; text-align: left; border-bottom: 1px solid var(--border);
    }}
    table.monitor-trigger th {{ color: var(--muted); font-weight: 500; white-space: nowrap; }}
    table.monitor-trigger td {{ font-variant-numeric: tabular-nums; }}
    table.monitor-trigger tr.row-at-trigger {{ background: rgba(248, 113, 113, 0.12); }}
    table.monitor-trigger tr.row-promotion {{ background: rgba(56, 189, 248, 0.10); }}
    table.monitor-trigger tr.row-fail {{ background: rgba(248, 113, 113, 0.18); }}
    .cell-bad {{ color: #f87171; font-weight: 600; }}
    .monitor-note {{ color: var(--accent); font-size: 0.78rem; }}
    table.throughput-compare {{ width: 100%; border-collapse: collapse; font-size: 0.88rem; }}
    table.throughput-compare th, table.throughput-compare td {{
      padding: 0.5rem 0.65rem; text-align: left; border-bottom: 1px solid var(--border);
    }}
    table.throughput-compare thead th {{ color: var(--muted); font-weight: 500; }}
    table.throughput-compare tbody th {{ color: var(--text); font-weight: 500; width: 28%; }}
    table.throughput-compare td {{ font-variant-numeric: tabular-nums; }}
    .table-scroll {{ overflow-x: auto; }}
{FAILOVER_SUMMARY_CSS}
{CLUSTER_CHARTS_CSS}
  </style>
</head>
<body>
  {impact_summary_html}

  <div class="grid">
    <div class="sidebar">
      <div class="card sidebar-meta">
        <h2>Run metadata</h2>
        <table><tbody>{meta_html}</tbody></table>
      </div>
      {"<div class=\"card\"><h2>PNG exports</h2><ul>" + png_links + "</ul></div>" if png_links else ""}
    </div>
    <div class="main-column">
      <p class="chart-hint-global">{html.escape(CHART_ZOOM_HINT)}</p>
      <div class="card">
        <h2>TPS &amp; QPS</h2>
        <div class="chart-wrap"><canvas id="tpsQpsChart"></canvas></div>
      </div>
      <div class="card">
        <h2>Latency p95 (ms)</h2>
        <div class="chart-wrap"><canvas id="latencyChart"></canvas></div>
      </div>
      <div class="card">
        <h2>Primary transition at trigger</h2>
        {_monitor_trigger_table_html(edition_dir, monitor_bundle)}
      </div>
      <div class="card">
        <h2>Metrics before vs after failover</h2>
        {_before_after_throughput_table_html({"rows": rows, "trigger": trigger_log, "parsed": parsed, "kpi": kpi, "extended": extended})}
      </div>
      <div class="card">
        <h2>Failover metrics</h2>
        {_metrics_with_promote_split_html(kpi, extended, primary, parsed, edition_dir)}
      </div>
      <div class="card">
        <h2>Errors &amp; reconnects</h2>
        <div class="chart-wrap"><canvas id="errorsChart"></canvas></div>
      </div>
      {cluster_html}
    </div>
  </div>

  <script>
    const DATA = {json.dumps(chart_data)};
    const CLUSTER = {json.dumps(cluster_data)};
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
{CHART_ZOOM_JS}

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
        plugins: Object.assign({{}}, triggerAnnotations(), chartZoomPlugin()),
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
        plugins: Object.assign({{}}, triggerAnnotations(), chartZoomPlugin()), scales: baseScales("Rate (/s)")
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
        plugins: Object.assign({{}}, triggerAnnotations(), chartZoomPlugin()), scales: baseScales("Latency p95 (ms)")
      }}
    }});
{CLUSTER_CHARTS_JS}
    renderClusterCharts(CLUSTER, "");
  </script>
</body>
</html>
"""
    out_path.write_text(page, encoding="utf-8")
    return out_path


def generate_combined_sweep_html_report(
    edition_dir: Path,
    sweep_runs: dict[int, dict[str, Path]],
    *,
    sweep_kind: str = "threads",
) -> Path:
    """Single HTML with sweep + scenario toggle buttons (threads or back-to-back iterations)."""
    if sweep_kind == "iteration":
        sweep_attr = "iteration"
        panel_prefix = "i"
        toolbar_label = "Iteration:"
        title_suffix = "iteration comparison"
        subtitle_sweep = "back-to-back failover iterations"

        def sweep_button_text(value: int) -> str:
            return f"Iteration {value}"
    else:
        sweep_attr = "threads"
        panel_prefix = "t"
        toolbar_label = "Threads:"
        title_suffix = "thread comparison"
        subtitle_sweep = "thread sweep"

        def sweep_button_text(value: int) -> str:
            return f"{value} threads"

    bundles: dict[str, dict] = {}
    sweep_values = sorted(sweep_runs.keys())
    scenario_list = sorted(
        {
            scenario
            for scenarios in sweep_runs.values()
            for scenario in scenarios
        }
    )
    edition = "advanced"

    for sweep_id, scenarios in sweep_runs.items():
        for scenario, scenario_dir in sorted(scenarios.items()):
            key = f"{sweep_id}:{scenario}"
            bundle = load_scenario_bundle(scenario_dir)
            bundles[key] = bundle
            edition = bundle["edition"]

    active_sweep_values = sorted({int(key.split(":", 1)[0]) for key in bundles})
    active_scenarios = sorted({key.split(":", 1)[1] for key in bundles})
    if not active_sweep_values:
        active_sweep_values = sweep_values
    if not active_scenarios:
        active_scenarios = scenario_list

    default_sweep = active_sweep_values[0]
    default_scenario = active_scenarios[0]

    panels: list[str] = []
    chart_payload: dict[str, dict] = {}
    cluster_payload: dict[str, dict] = {}
    for key in sorted(bundles):
        sweep_s, scenario = key.split(":", 1)
        sweep_id = int(sweep_s)
        scenario_safe = scenario.replace("/", "_")
        panel_id = f"panel_{panel_prefix}{sweep_id}_{scenario_safe}"
        hidden = "" if (sweep_id == default_sweep and scenario == default_scenario) else ' style="display:none"'
        bundle = bundles[key]
        meta_html = _meta_table_html(_meta_rows_for_bundle(bundle))
        metrics_html = _metrics_with_promote_split_html(
            bundle["kpi"], bundle["extended"], bundle["primary"], bundle["parsed"], Path(bundle["dir"])
        )
        monitor_html = _monitor_trigger_table_html(Path(bundle["dir"]), bundle)
        compare_html = _before_after_throughput_table_html(bundle)
        cluster_html = _cluster_monitors_html(
            Path(bundle["dir"]), float(bundle.get("trigger_wall", bundle["trigger"])), panel_id=panel_id
        )
        impact_summary_html = _failover_impact_summary_html(bundle)
        chart_payload[key] = bundle["chart_data"]
        cluster_payload[key] = bundle.get("cluster_data") or {}
        panels.append(
            f'<div class="run-panel" id="{panel_id}" data-sweep="{sweep_id}" '
            f'data-scenario="{html.escape(scenario)}"{hidden}>'
            f"{impact_summary_html}"
            f'<div class="grid"><div class="sidebar">'
            f'<div class="card sidebar-meta"><h2>Run metadata</h2><table><tbody>{meta_html}</tbody></table></div>'
            f"</div><div class=\"main-column\">"
            f'<div class="card"><h2>TPS &amp; QPS</h2><div class="chart-wrap">'
            f'<canvas id="tpsQps_{panel_id}"></canvas></div></div>'
            f'<div class="card"><h2>Latency p95 (ms)</h2><div class="chart-wrap">'
            f'<canvas id="latency_{panel_id}"></canvas></div></div>'
            f'<div class="card"><h2>Primary transition at trigger</h2>{monitor_html}</div>'
            f'<div class="card"><h2>Metrics before vs after failover</h2>{compare_html}</div>'
            f'<div class="card"><h2>Failover metrics</h2>{metrics_html}</div>'
            f'<div class="card"><h2>Errors &amp; reconnects</h2><div class="chart-wrap">'
            f'<canvas id="errors_{panel_id}"></canvas></div></div>'
            f"{cluster_html}"
            f"</div></div></div>"
        )

    sweep_buttons = "".join(
        f'<button type="button" class="toggle-btn{" active" if value == default_sweep else ""}" '
        f'data-sweep="{value}">{html.escape(sweep_button_text(value))}</button>'
        for value in active_sweep_values
    )
    scenario_buttons = "".join(
        f'<button type="button" class="toggle-btn scenario-btn{" active" if s == default_scenario else ""}" '
        f'data-scenario="{html.escape(s)}">{html.escape(_humanize_scenario_path_label(s))}</button>'
        for s in active_scenarios
    )
    sweep_toolbar = (
        f'<div class="toolbar"><span class="toolbar-label">{html.escape(toolbar_label)}</span>{sweep_buttons}</div>'
        if len(active_sweep_values) > 1
        else ""
    )
    scenario_toolbar = (
        f'<div class="toolbar"><span class="toolbar-label">Scenario:</span>{scenario_buttons}</div>'
        if len(active_scenarios) > 1
        else ""
    )
    if len(active_sweep_values) > 1:
        subtitle = f"{html.escape(edition)} · {html.escape(subtitle_sweep)} · select run and scenario below"
    elif len(active_scenarios) > 1:
        subtitle = f"{html.escape(edition)} · select scenario below"
    else:
        scenario_label = html.escape(active_scenarios[0])
        subtitle = f"{html.escape(edition)} · {scenario_label}"

    kpi_summary_html = ""
    if sweep_kind == "iteration":
        kpi_summary_html = _iteration_kpi_comparison_html(sweep_runs)

    out_path = edition_dir / "graphs" / "failover_report.html"
    out_path.parent.mkdir(exist_ok=True)

    page = f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Failover report — {html.escape(edition)} ({html.escape(title_suffix)})</title>
  <script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.1/dist/chart.umd.min.js"></script>
  <script src="https://cdn.jsdelivr.net/npm/chartjs-plugin-annotation@3.0.1/dist/chartjs-plugin-annotation.min.js"></script>
{CHARTJS_ZOOM_CDN}
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
    .subtitle {{ color: var(--muted); margin-bottom: 1rem; }}
{CHART_ZOOM_CSS}
    .toolbar {{ display: flex; flex-wrap: wrap; gap: 0.5rem; margin-bottom: 1rem; align-items: center; }}
    .toolbar-label {{ color: var(--muted); font-size: 0.85rem; margin-right: 0.25rem; }}
    .toggle-btn {{
      background: var(--card); color: var(--text); border: 1px solid var(--border);
      border-radius: 6px; padding: 0.45rem 0.85rem; cursor: pointer; font-size: 0.9rem;
    }}
    .toggle-btn:hover {{ border-color: var(--accent); }}
    .toggle-btn.active {{ background: var(--accent); color: #0f172a; border-color: var(--accent); font-weight: 600; }}
    .grid {{ display: grid; gap: 1rem; grid-template-columns: 1fr; align-items: stretch; }}
    @media (min-width: 960px) {{ .grid {{ grid-template-columns: 360px 1fr; }} }}
    .sidebar {{ display: flex; flex-direction: column; gap: 1rem; min-height: 100%; }}
    .card.sidebar-meta {{ flex: 1; }}
    .main-column {{ display: flex; flex-direction: column; gap: 1.25rem; }}
    .card {{
      background: var(--card); border: 1px solid var(--border);
      border-radius: 8px; padding: 1rem 1.25rem;
    }}
    .card h2 {{ font-size: 1rem; margin: 0 0 0.75rem; color: var(--accent); }}
    table {{ width: 100%; border-collapse: collapse; font-size: 0.9rem; }}
    th {{ text-align: left; color: var(--muted); font-weight: 500; padding: 0.35rem 0.5rem 0.35rem 0; }}
    td {{ padding: 0.35rem 0; }}
    table.metrics {{ font-size: 0.9rem; }}
    table.metrics thead th {{
      color: var(--muted); font-weight: 500; padding: 0.35rem 0.65rem 0.5rem 0;
      border-bottom: 1px solid var(--border);
    }}
    table.metrics tbody td {{
      padding: 0.65rem 0.65rem 0.65rem 0; border-bottom: 1px solid var(--border);
      vertical-align: top;
    }}
    table.metrics tbody tr:last-child td {{ border-bottom: none; }}
    table.metrics td.metric-name-cell {{ width: 55%; padding-right: 1rem; }}
    table.metrics td.metric-value-cell {{ font-variant-numeric: tabular-nums; }}
    table.promotion-breakdown td.phase-name-cell {{ width: 42%; }}
    table.promotion-breakdown td.num {{ font-variant-numeric: tabular-nums; white-space: nowrap; }}
    table.promotion-breakdown tr.row-total td {{
      background: rgba(56, 189, 248, 0.10); font-weight: 600;
    }}
    table.promotion-breakdown tr.row-total .metric-title {{ color: #38bdf8; }}
    .metric-title {{ font-weight: 600; color: var(--accent); margin-bottom: 0.25rem; }}
    .metric-value {{ font-size: 1.05rem; color: var(--text); margin-bottom: 0.15rem; }}
    .metric-sub {{ color: var(--muted); font-size: 0.82rem; margin-bottom: 0.2rem; }}
    .metric-help {{ color: var(--muted); font-size: 0.78rem; line-height: 1.35; }}
    .chart-wrap {{ position: relative; height: 320px; margin-bottom: 1rem; }}
    .empty-state {{ text-align: center; padding: 2.5rem 1.5rem; color: var(--muted); }}
    .empty-state h2 {{ color: var(--text); margin: 0 0 0.5rem; font-size: 1.1rem; }}
    .empty-state p {{ margin: 0; }}
    .monitor-headline {{ font-size: 0.92rem; margin: 0 0 0.35rem; }}
    .monitor-subhead {{ color: var(--muted); font-size: 0.82rem; margin: 0 0 0.75rem; }}
    table.monitor-trigger {{ width: 100%; border-collapse: collapse; font-size: 0.8rem; min-width: 520px; }}
    table.monitor-trigger th, table.monitor-trigger td {{
      padding: 0.35rem 0.5rem; text-align: left; border-bottom: 1px solid var(--border);
    }}
    table.monitor-trigger th {{ color: var(--muted); font-weight: 500; white-space: nowrap; }}
    table.monitor-trigger td {{ font-variant-numeric: tabular-nums; }}
    table.monitor-trigger tr.row-at-trigger {{ background: rgba(248, 113, 113, 0.12); }}
    table.monitor-trigger tr.row-promotion {{ background: rgba(56, 189, 248, 0.10); }}
    table.monitor-trigger tr.row-fail {{ background: rgba(248, 113, 113, 0.18); }}
    .cell-bad {{ color: #f87171; font-weight: 600; }}
    .monitor-note {{ color: var(--accent); font-size: 0.78rem; }}
    table.throughput-compare {{ width: 100%; border-collapse: collapse; font-size: 0.88rem; }}
    table.throughput-compare th, table.throughput-compare td {{
      padding: 0.5rem 0.65rem; text-align: left; border-bottom: 1px solid var(--border);
    }}
    table.throughput-compare thead th {{ color: var(--muted); font-weight: 500; }}
    table.throughput-compare tbody th {{ color: var(--text); font-weight: 500; width: 28%; }}
    table.throughput-compare td {{ font-variant-numeric: tabular-nums; }}
    .table-scroll {{ overflow-x: auto; }}
{FAILOVER_SUMMARY_CSS}
{CLUSTER_CHARTS_CSS}
  </style>
</head>
<body>
  <h1 style="font-size:1.35rem;margin:0 0 0.25rem">Failover benchmark report</h1>
  <p class="subtitle">{subtitle}</p>

  {kpi_summary_html}
  {sweep_toolbar}
  {scenario_toolbar}

  <p class="chart-hint-global">{html.escape(CHART_ZOOM_HINT)}</p>

  {''.join(panels)}

  <script>
    const RUNS = {json.dumps(chart_payload)};
    const CLUSTER_RUNS = {json.dumps(cluster_payload)};
    let activeSweep = {default_sweep};
    let activeScenario = {json.dumps(default_scenario)};
    let charts = {{}};

    Chart.defaults.color = "#94a3b8";
    Chart.defaults.borderColor = "#334155";

    function runKey(sweep, scenario) {{
      return sweep + ":" + scenario;
    }}

    function destroyCharts() {{
      Object.values(charts).forEach(c => c.destroy());
      charts = {{}};
    }}

    function triggerAnnotations(DATA) {{
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
{CHART_ZOOM_JS}

    function renderCharts(sweep, scenario) {{
      const key = runKey(sweep, scenario);
      const DATA = RUNS[key];
      if (!DATA) return;
      destroyCharts();
      const panel = document.querySelector(
        '.run-panel[data-sweep="' + sweep + '"][data-scenario="' + scenario.replace(/"/g, '\\"') + '"]'
      );
      if (!panel) return;
      const panelId = panel.id;
      charts.tps = new Chart(document.getElementById("tpsQps_" + panelId), {{
        type: "line",
        data: {{
          labels: DATA.elapsed,
          datasets: [
            {{ label: "TPS", data: DATA.tps, borderColor: "#60a5fa", borderWidth: 1.5, pointRadius: 0, yAxisID: "y" }},
            {{ label: "QPS", data: DATA.qps, borderColor: "#34d399", borderWidth: 1.2, pointRadius: 0, yAxisID: "y1" }},
          ]
        }},
        options: {{
          responsive: true, maintainAspectRatio: false, interaction: {{ mode: "index", intersect: false }},
          plugins: Object.assign({{}}, triggerAnnotations(DATA), chartZoomPlugin()),
          scales: {{
            x: {{ title: {{ display: true, text: "Elapsed time (s)" }} }},
            y: {{ type: "linear", position: "left", title: {{ display: true, text: "TPS" }}, beginAtZero: true }},
            y1: {{ type: "linear", position: "right", title: {{ display: true, text: "QPS" }}, beginAtZero: true, grid: {{ drawOnChartArea: false }} }}
          }}
        }}
      }});
      charts.err = new Chart(document.getElementById("errors_" + panelId), {{
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
          plugins: Object.assign({{}}, triggerAnnotations(DATA), chartZoomPlugin()), scales: baseScales("Rate (/s)")
        }}
      }});
      charts.lat = new Chart(document.getElementById("latency_" + panelId), {{
        type: "line",
        data: {{
          labels: DATA.elapsed,
          datasets: [
            {{ label: "p95 latency (ms)", data: DATA.lat_p95, borderColor: "#2dd4bf", borderWidth: 1.5, pointRadius: 0 }},
          ]
        }},
        options: {{
          responsive: true, maintainAspectRatio: false, interaction: {{ mode: "index", intersect: false }},
          plugins: Object.assign({{}}, triggerAnnotations(DATA), chartZoomPlugin()), scales: baseScales("Latency p95 (ms)")
        }}
      }});
      renderClusterCharts(CLUSTER_RUNS[key], "_" + panelId, charts);
    }}
{CLUSTER_CHARTS_JS}

    function showPanel(sweep, scenario) {{
      document.querySelectorAll(".run-panel").forEach(el => {{
        const match = String(el.dataset.sweep) === String(sweep) && el.dataset.scenario === scenario;
        el.style.display = match ? "" : "none";
      }});
      destroyCharts();
      if (RUNS[runKey(sweep, scenario)]) {{
        renderCharts(sweep, scenario);
      }}
    }}

    function setActiveButtons(sweep, scenario) {{
      document.querySelectorAll(".toggle-btn[data-sweep]").forEach(btn => {{
        btn.classList.toggle("active", String(btn.dataset.sweep) === String(sweep));
      }});
      document.querySelectorAll(".toggle-btn[data-scenario]").forEach(btn => {{
        btn.classList.toggle("active", btn.dataset.scenario === scenario);
      }});
    }}

    document.querySelectorAll(".toggle-btn[data-sweep]").forEach(btn => {{
      btn.addEventListener("click", () => {{
        activeSweep = btn.dataset.sweep;
        setActiveButtons(activeSweep, activeScenario);
        showPanel(activeSweep, activeScenario);
      }});
    }});

    document.querySelectorAll(".toggle-btn[data-scenario]").forEach(btn => {{
      btn.addEventListener("click", () => {{
        activeScenario = btn.dataset.scenario;
        setActiveButtons(activeSweep, activeScenario);
        showPanel(activeSweep, activeScenario);
      }});
    }});

    setActiveButtons(activeSweep, activeScenario);
    showPanel(activeSweep, activeScenario);
  </script>
</body>
</html>
"""
    out_path.write_text(page, encoding="utf-8")
    return out_path


def generate_combined_thread_html_report(edition_dir: Path, thread_runs: dict[int, dict[str, Path]]) -> Path:
    return generate_combined_sweep_html_report(edition_dir, thread_runs, sweep_kind="threads")


def generate_combined_iteration_html_report(edition_dir: Path, iter_runs: dict[int, dict[str, Path]]) -> Path:
    return generate_combined_sweep_html_report(edition_dir, iter_runs, sweep_kind="iteration")


def generate_png_for_edition(
    edition_dir: Path,
    rows: list[dict[str, float]],
    meta: dict[str, str],
    parsed: dict[str, str],
) -> list[Path]:
    # Authoritative log-axis trigger (epoch-derived); the recorded
    # FAILOVER_TRIGGER_LOG_SECOND in meta is only the planned second.
    trigger = _scenario_trigger_log_sec(edition_dir)
    edition = meta.get("FAILOVER_EDITION", edition_dir.name)
    baseline = float(parsed.get("BASELINE_TPS", "0"))
    recovery = float(parsed.get("RECOVERY_THRESHOLD", str(baseline * 0.9)))
    outage_start, outage_end = _derive_outage_bounds(rows, trigger, baseline)
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
    extended = _parse_extended_metrics(edition_dir / "failover_extended_metrics.txt")
    primary = load_metadata(edition_dir / "primary_change.env")

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
        parent_ed = parent_edition_dir(edition_dir)
        skip_combined = False
        if parent_ed:
            iter_runs = discover_iteration_runs(parent_ed)
            thread_runs = discover_thread_runs(parent_ed)
            if iter_runs and len(iter_runs) > 1:
                skip_combined = True
            elif thread_runs:
                skip_combined = True
        if not skip_combined:
            html_path = generate_html_report(
                edition_dir, rows, meta, parsed, event, kpi, png_files, extended, primary
            )
            outputs.append(html_path)

    return outputs


def _collect_scenario_dirs(parent: Path) -> list[Path]:
    """Scenario dirs under an edition or nested iter/trigger/thread parent."""
    found: list[Path] = []
    if not parent.is_dir():
        return found
    for child in sorted(parent.iterdir()):
        if not child.is_dir() or child.name == "graphs":
            continue
        if (child / "failover_timeseries.csv").exists():
            found.append(child)
        elif THREAD_DIR_RE.match(child.name) or ITER_DIR_RE.match(child.name) or child.name in TRIGGER_METHODS:
            found.extend(_collect_scenario_dirs(child))
    return found


def discover_edition_dirs(path: Path) -> tuple[list[Path], Path]:
    """Find result dirs containing failover_timeseries.csv (edition/scenario or edition/tN/scenario)."""
    if (path / "failover_timeseries.csv").exists():
        return [path], path.parent

    dirs: list[Path] = []
    if path.is_dir():
        if path.name in EDITION_NAMES:
            dirs.extend(_collect_scenario_dirs(path))
        else:
            for child in sorted(path.iterdir()):
                if not child.is_dir() or child.name == "graphs":
                    continue
                if (child / "failover_timeseries.csv").exists():
                    dirs.append(child)
                    continue
                if child.name in EDITION_NAMES:
                    dirs.extend(_collect_scenario_dirs(child))
                    continue
                if THREAD_DIR_RE.match(child.name):
                    dirs.extend(_collect_scenario_dirs(child))
                    continue
                if ITER_DIR_RE.match(child.name):
                    dirs.extend(_collect_scenario_dirs(child))
                    continue
                if child.name in TRIGGER_METHODS:
                    dirs.extend(_collect_scenario_dirs(child))
                    continue
                for scenario_dir in sorted(child.iterdir()):
                    if scenario_dir.is_dir() and (scenario_dir / "failover_timeseries.csv").exists():
                        dirs.append(scenario_dir)

    return dirs, path


def maybe_generate_combined_reports(results_root: Path, *, do_html: bool) -> None:
    if not do_html:
        return
    edition_dirs: list[Path]
    if results_root.name in EDITION_NAMES:
        edition_dirs = [results_root]
    else:
        edition_dirs = sorted(
            d for d in results_root.iterdir() if d.is_dir() and d.name in EDITION_NAMES
        )
    for edition_dir in edition_dirs:
        iter_runs = discover_iteration_runs(edition_dir)
        if iter_runs and len(iter_runs) > 1:
            out = generate_combined_iteration_html_report(edition_dir, iter_runs)
            print(f"Wrote {out}")
            html_content = out.read_text(encoding="utf-8")
            mirrored: set[Path] = set()
            for scenarios in iter_runs.values():
                for scenario_dir in scenarios.values():
                    if scenario_dir in mirrored:
                        continue
                    mirrored.add(scenario_dir)
                    mirror_out = scenario_dir / "graphs" / "failover_report.html"
                    mirror_out.parent.mkdir(exist_ok=True)
                    mirror_out.write_text(html_content, encoding="utf-8")
                    print(f"Wrote {mirror_out}")
            continue
        thread_runs = discover_thread_runs(edition_dir)
        if not thread_runs:
            continue
        out = generate_combined_thread_html_report(edition_dir, thread_runs)
        print(f"Wrote {out}")
        html_content = out.read_text(encoding="utf-8")
        mirrored: set[Path] = set()
        for scenarios in thread_runs.values():
            for scenario_dir in scenarios.values():
                if scenario_dir in mirrored:
                    continue
                mirrored.add(scenario_dir)
                mirror_out = scenario_dir / "graphs" / "failover_report.html"
                mirror_out.parent.mkdir(exist_ok=True)
                mirror_out.write_text(html_content, encoding="utf-8")
                print(f"Wrote {mirror_out}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate failover benchmark graphs and HTML report")
    parser.add_argument(
        "path",
        type=Path,
        help="Scenario dir, edition dir, or failover_<timestamp> root (standard/ advanced/ or nested mixed/ write_only/)",
    )
    parser.add_argument("--png-only", action="store_true", help="Generate PNG files only")
    parser.add_argument("--html-only", action="store_true", help="Generate HTML report only")
    parser.add_argument(
        "--gr-pre-failover",
        action="store_true",
        help="Write gr_pod_pre_failover_summary.txt for a scenario dir (requires gr_pod_monitor.tsv)",
    )
    args = parser.parse_args()
    path: Path = args.path

    if args.gr_pre_failover:
        if (path / "gr_pod_monitor.tsv").exists():
            out = write_gr_pre_failover_artifacts(path)
            if out:
                print(f"Wrote {out}")
                return 0
            print(f"No GR pre-failover summary for {path}", file=sys.stderr)
            return 1
        print(f"ERROR: missing gr_pod_monitor.tsv under {path}", file=sys.stderr)
        return 1

    do_png = not args.html_only
    do_html = not args.png_only

    edition_dirs, results_root = discover_edition_dirs(path)

    if not edition_dirs:
        print(f"ERROR: no failover_timeseries.csv found under {path}", file=sys.stderr)
        return 1

    for edition_dir in edition_dirs:
        for out in generate_for_edition(edition_dir, png=do_png, html=do_html):
            print(f"Wrote {out}")

    maybe_generate_combined_reports(results_root, do_html=do_html)

    if do_png and len(edition_dirs) >= 2 and _ensure_mpl():
        comp_path = results_root / "graphs" / "failover_tps_comparison.png"
        comp_path.parent.mkdir(exist_ok=True)
        plot_comparison(edition_dirs, comp_path)
        print(f"Wrote {comp_path}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
