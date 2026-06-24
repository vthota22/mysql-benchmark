#!/usr/bin/env python3
"""Generate failover PNG graphs and/or interactive HTML report from failover_timeseries.csv."""

from __future__ import annotations

import argparse
import csv
import html
import json
import os
import re
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


METRIC_HELP = {
    "detect": (
        "Seconds from failover trigger until the primary monitor reports the first "
        "connect failure (connect_ok=0), including timeouts when the monitor cannot connect."
    ),
    "promote": (
        "Seconds from the first connect failure until the new primary is fully promoted "
        "and accepting writes: GR PRIMARY role (Advanced) and write probe INSERT succeeds (write_ok=1)."
    ),
    "total_failover": (
        "Seconds from failover trigger until promotion completes (detection lag + promotion time)."
    ),
    "recovery": (
        "Seconds from trigger until TPS stays at or above 90% baseline for 30 consecutive seconds (RTO)."
    ),
    "data_loss": (
        "TPC-C consistency check after failover (warehouse/district/order invariants). "
        "PASSED means no detected data loss; SKIPPED if FAILOVER_RUN_TPCC_CHECK=0."
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
    edition_cfg = edition_dir.parent / "benchmark_config.env"
    if edition_cfg.exists():
        cfg.update(load_metadata(edition_cfg))
    timing = edition_dir / "sysbench_timing.txt"
    if timing.exists():
        cfg.update(load_metadata(timing))
    cfg.update(meta)
    return cfg


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
EDITION_NAMES = {"advanced", "standard"}
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
    trigger = float(meta.get("FAILOVER_TRIGGER_SECOND", "0"))
    baseline = float(parsed.get("BASELINE_TPS", "0"))
    recovery = float(parsed.get("RECOVERY_THRESHOLD", str(baseline * 0.9 if baseline else 0)))
    outage_start = float(parsed.get("OUTAGE_START", trigger))
    outage_end = float(parsed.get("OUTAGE_END", trigger))
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
        "trigger": trigger,
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
            "trigger_sec": trigger,
            "baseline_tps": baseline,
            "recovery_threshold": recovery,
            "outage_start": outage_start,
            "outage_end": outage_end,
        },
    }


def load_edition_benchmark_config(edition_dir: Path) -> dict[str, str]:
    return load_metadata(edition_dir / "benchmark_config.env")


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


def discover_thread_runs(edition_dir: Path) -> dict[int, dict[str, Path]]:
    """Map thread count -> scenario name -> results dir."""
    runs: dict[int, dict[str, Path]] = {}
    if not edition_dir.is_dir():
        return runs

    for child in sorted(edition_dir.iterdir()):
        if not child.is_dir() or child.name == "graphs":
            continue
        match = THREAD_DIR_RE.match(child.name)
        if match:
            threads = int(match.group(1))
            for scenario_dir in sorted(child.iterdir()):
                if scenario_dir.is_dir() and (scenario_dir / "failover_timeseries.csv").exists():
                    runs.setdefault(threads, {})[scenario_dir.name] = scenario_dir
            continue
        if child.name in {"mixed", "write_only"} and (child / "failover_timeseries.csv").exists():
            bundle = load_scenario_bundle(child)
            threads = bundle["threads"] or 0
            runs.setdefault(threads, {})[child.name] = child

    return runs


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
    """Average healthy per-second metrics after promotion (or post-trigger fallback)."""
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
        if row["err_per_sec"] > 0 or row["tps"] <= 0:
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
    <p class="monitor-subhead">After failover: average of healthy seconds {html.escape(window_note)}.</p>
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
    threads = bundle["threads"]
    baseline_tps, baseline_qps, baseline_lat = _resolve_baseline_metrics(
        parsed, bundle.get("rows", []), trigger
    )
    return [
        ("Edition", bundle["edition"]),
        ("Scenario", bundle["scenario"]),
        ("TPC-C profile", bundle["trx_profile"]),
        ("Load threads", str(threads) if threads else _cfg_value(bench, "THREADS", "FAILOVER_THREADS")),
        ("Slug size", _cfg_value(bench, "SLUG_SIZE", "CLUSTER_SLUG", "MYSQL_CLUSTER_PLAN")),
        ("Num nodes", _cfg_value(bench, "NUM_NODES", "CLUSTER_NUM_NODES")),
        ("Data size", _format_data_size(bench)),
        ("TPCC_SCALE", _cfg_value(bench, "TPCC_SCALE")),
        ("TPCC_THREADS", _cfg_value(bench, "TPCC_THREADS", "PREP_THREADS")),
        ("Sysbench start (UTC)", meta.get("SYSBENCH_START_UTC", "N/A")),
        ("Failover trigger (UTC)", event.get("FAILOVER_TRIGGER_UTC", "N/A")),
        ("Trigger second", str(int(trigger)) if trigger else "N/A"),
        ("Trigger method", event.get("FAILOVER_METHOD", "N/A")),
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


def _short_pod_name(name: str) -> str:
    for prefix in ("benchmark-failover2-", "benchmark-"):
        if name.startswith(prefix):
            return name[len(prefix) :]
    return name


def _wall_hms(wall: str) -> str:
    if "T" in wall:
        return wall.split("T", 1)[1].rstrip("Z")
    return wall


def _is_promoted_monitor_row(row: dict[str, str | float], edition: str) -> bool:
    if row["connect_ok"] != "1" or row["write_ok"] != "1":
        return False
    if edition == "advanced":
        return row["gr_role"] == "PRIMARY" and row["gr_state"] in ("ONLINE", "PRIMARY")
    return True


def _select_monitor_transition_rows(
    monitor_rows: list[dict[str, str | float]],
    trigger: float,
    primary_before: str,
    event: dict[str, str],
) -> list[tuple[dict[str, str | float], str]]:
    """Curated polls: last pre-trigger, first post-trigger (delete), first connect fail, promotion."""
    ordered: list[tuple[dict[str, str | float], str]] = []
    seen: set[tuple[str, str]] = set()
    edition = event.get("FAILOVER_EDITION", "advanced")

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

    delete_row = post[0] if post else None
    if delete_row:
        add(delete_row, "← pod deleted")

    connect_fail_row: dict[str, str | float] | None = None
    for row in post:
        if row["connect_ok"] == "0":
            connect_fail_row = row
            break

    promote_row: dict[str, str | float] | None = None
    saw_failure = False
    for row in post:
        if row["connect_ok"] == "0" or row["write_ok"] == "0":
            saw_failure = True
        elif saw_failure and _is_promoted_monitor_row(row, edition):
            promote_row = row
            break

    failure_row = connect_fail_row
    if delete_row and failure_row and promote_row:
        delete_sb = float(delete_row["sysbench_sec"])
        failure_sb = float(failure_row["sysbench_sec"])
        promote_sb = float(promote_row["sysbench_sec"])
        for row in post:
            sb = float(row["sysbench_sec"])
            if sb <= delete_sb + 0.05 or sb >= promote_sb - 0.05:
                continue
            if failure_row and abs(sb - failure_sb) < 0.05:
                continue
            if primary_before and str(row["hostname"]) == primary_before:
                add(row)

    if connect_fail_row:
        add(connect_fail_row, "← first connect failure")

    if promote_row:
        add(promote_row, "← promotion")

    return ordered


def _monitor_trigger_table_html(scenario_dir: Path, bundle: dict) -> str:
    """HTML table: primary before / at delete / through promotion (per scenario panel)."""
    monitor_rows = load_primary_monitor(scenario_dir)
    trigger = float(bundle.get("trigger", 0))
    primary_before = bundle.get("primary", {}).get("PRIMARY_BEFORE", "")
    primary_after = bundle.get("primary", {}).get("PRIMARY_AFTER", "")
    scenario = bundle.get("scenario", "")
    event = bundle.get("event", {})
    trigger_utc = event.get("FAILOVER_TRIGGER_UTC") or event.get("FAILOVER_POD_DELETE_UTC", "")
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
    headline = (
        f'<p class="monitor-headline"><strong>{html.escape(scenario)}</strong> — pod '
        f"<code>{html.escape(_short_pod_name(target_pod))}</code> deleted at "
        f'<code>{html.escape(trigger_hms)}</code></p>'
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
        if note == "← pod deleted":
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
            f"<td>{sb:.1f}</td>"
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
    total_failover = kpi.get("total_failover_sec") or extended.get("total_failover_sec", "N/A")
    recovery = kpi.get("app_recovery_sec") or parsed.get("RTO_SEC") or extended.get("rto_sec", "N/A")
    data_loss = kpi.get("data_loss") or extended.get("tpcc_check", "N/A")

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
            sub=(
                f"Total from trigger: {_format_duration_sec(total_failover)} · "
                f"Primary: {before} → {after} ({changed})"
            ),
        ),
        _metric_row(
            "Time for application recovery",
            _format_duration_sec(recovery),
            METRIC_HELP["recovery"],
            sub=f"Interval after promotion: {_phase_gap_sec(recovery, total_failover)}",
        ),
    ]
    rows.append(
        _metric_row(
            "Data loss (if any)",
            str(data_loss),
            METRIC_HELP["data_loss"],
        )
    )

    return (
        '<table class="metrics">'
        "<thead><tr><th>Metric</th><th>Value</th></tr></thead>"
        f"<tbody>{''.join(rows)}</tbody></table>"
    )


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
    trigger = float(meta.get("FAILOVER_TRIGGER_SECOND", "0"))
    scenario = meta.get("FAILOVER_SCENARIO", edition_dir.name if edition_dir.name in {"mixed", "write_only"} else "default")
    trx_profile = meta.get("TPCC_TRX_PROFILE", kpi.get("trx_profile", "mixed"))
    edition = resolve_edition_name(edition_dir, meta, event, kpi, bench)
    enrich_cluster_metadata(bench, edition)
    baseline_tps, baseline_qps, baseline_lat = _resolve_baseline_metrics(parsed, rows, trigger)
    recovery = float(parsed.get("RECOVERY_THRESHOLD", str(baseline_tps * 0.9 if baseline_tps else 0)))
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

    meta_rows = [
        ("Edition", edition),
        ("Scenario", scenario),
        ("TPC-C profile", trx_profile),
        ("Load threads", str(infer_thread_count(edition_dir, meta, bench)) or _cfg_value(bench, "THREADS", "FAILOVER_THREADS")),
        ("Slug size", _cfg_value(bench, "SLUG_SIZE", "CLUSTER_SLUG", "MYSQL_CLUSTER_PLAN")),
        ("Num nodes", _cfg_value(bench, "NUM_NODES", "CLUSTER_NUM_NODES")),
        ("Data size", _format_data_size(bench)),
        ("TPCC_SCALE", _cfg_value(bench, "TPCC_SCALE")),
        ("TPCC_THREADS", _cfg_value(bench, "TPCC_THREADS", "PREP_THREADS")),
        ("Sysbench start (UTC)", meta.get("SYSBENCH_START_UTC", "N/A")),
        ("Failover trigger (UTC)", event.get("FAILOVER_TRIGGER_UTC", "N/A")),
        ("Trigger second", str(int(trigger)) if trigger else "N/A"),
        ("Trigger method", event.get("FAILOVER_METHOD", "N/A")),
        ("Target pod", event.get("FAILOVER_TARGET_POD", "N/A")),
        ("Baseline TPS", f"{baseline_tps:.2f}" if baseline_tps else "N/A"),
        ("Baseline QPS", f"{baseline_qps:.2f}" if baseline_qps else "N/A"),
        (
            "Baseline latency p95",
            _format_latency_ms(baseline_lat) if baseline_lat else "N/A",
        ),
    ]
    meta_html = _meta_table_html(meta_rows)

    out_path = edition_dir / "graphs" / "failover_report.html"
    out_path.parent.mkdir(exist_ok=True)

    page = f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Failover report — {html.escape(edition)} / {html.escape(scenario)}</title>
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
  </style>
</head>
<body>
  <h1>Failover benchmark report</h1>
  <p class="subtitle">{html.escape(edition)} · {html.escape(scenario)} ({html.escape(trx_profile)}) · {html.escape(edition_dir.name)}</p>

  <div class="grid">
    <div class="sidebar">
      <div class="card sidebar-meta">
        <h2>Run metadata</h2>
        <table><tbody>{meta_html}</tbody></table>
      </div>
      {"<div class=\"card\"><h2>PNG exports</h2><ul>" + png_links + "</ul></div>" if png_links else ""}
    </div>
    <div class="main-column">
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
        {_monitor_trigger_table_html(edition_dir, {"trigger": trigger, "primary": primary, "event": event, "scenario": scenario})}
      </div>
      <div class="card">
        <h2>Metrics before vs after failover</h2>
        {_before_after_throughput_table_html({"rows": rows, "trigger": trigger, "parsed": parsed, "kpi": kpi})}
      </div>
      <div class="card">
        <h2>Failover metrics</h2>
        {_metrics_summary_html(kpi, extended, primary, parsed)}
      </div>
      <div class="card">
        <h2>Errors &amp; reconnects</h2>
        <div class="chart-wrap"><canvas id="errorsChart"></canvas></div>
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


def generate_combined_thread_html_report(edition_dir: Path, thread_runs: dict[int, dict[str, Path]]) -> Path:
    """Single HTML with thread + scenario toggle buttons."""
    bundles: dict[str, dict] = {}
    thread_counts = resolve_thread_matrix(edition_dir, thread_runs)
    scenario_list = resolve_scenario_list(edition_dir, thread_runs)
    edition = "advanced"

    for threads, scenarios in thread_runs.items():
        for scenario, scenario_dir in sorted(scenarios.items()):
            key = f"{threads}:{scenario}"
            bundle = load_scenario_bundle(scenario_dir)
            bundles[key] = bundle
            edition = bundle["edition"]

    default_threads = next((t for t in thread_counts if any(f"{t}:{s}" in bundles for s in scenario_list)), thread_counts[0])
    default_scenario = next(
        (s for s in scenario_list if f"{default_threads}:{s}" in bundles),
        scenario_list[0],
    )

    panels: list[str] = []
    chart_payload: dict[str, dict] = {}
    for threads in thread_counts:
        for scenario in scenario_list:
            key = f"{threads}:{scenario}"
            panel_id = f"panel_t{threads}_{scenario}"
            hidden = "" if (threads == default_threads and scenario == default_scenario) else ' style="display:none"'
            bundle = bundles.get(key)
            if bundle:
                meta_html = _meta_table_html(_meta_rows_for_bundle(bundle))
                metrics_html = _metrics_summary_html(
                    bundle["kpi"], bundle["extended"], bundle["primary"], bundle["parsed"]
                )
                monitor_html = _monitor_trigger_table_html(Path(bundle["dir"]), bundle)
                compare_html = _before_after_throughput_table_html(bundle)
                chart_payload[key] = bundle["chart_data"]
                panels.append(
                    f'<div class="run-panel" id="{panel_id}" data-threads="{threads}" '
                    f'data-scenario="{html.escape(scenario)}"{hidden}>'
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
                    f"</div></div></div>"
                )
            else:
                panels.append(
                    f'<div class="run-panel run-panel-empty" id="{panel_id}" data-threads="{threads}" '
                    f'data-scenario="{html.escape(scenario)}"{hidden}>'
                    f'<div class="card empty-state">'
                    f"<h2>No data</h2>"
                    f"<p>No failover results for <strong>{threads} threads</strong> · "
                    f"<strong>{html.escape(scenario)}</strong> in this run.</p>"
                    f"</div></div>"
                )

    thread_buttons = "".join(
        f'<button type="button" class="toggle-btn{" active" if t == default_threads else ""}" '
        f'data-threads="{t}">{t} threads</button>'
        for t in thread_counts
    )
    scenario_buttons = "".join(
        f'<button type="button" class="toggle-btn scenario-btn{" active" if s == default_scenario else ""}" '
        f'data-scenario="{html.escape(s)}">{html.escape(s)}</button>'
        for s in scenario_list
    )

    out_path = edition_dir / "graphs" / "failover_report.html"
    out_path.parent.mkdir(exist_ok=True)

    page = f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Failover report — {html.escape(edition)} (thread comparison)</title>
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
    .subtitle {{ color: var(--muted); margin-bottom: 1rem; }}
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
  </style>
</head>
<body>
  <h1>Failover benchmark report</h1>
  <p class="subtitle">{html.escape(edition)} · thread sweep · select load threads and scenario below</p>

  <div class="toolbar">
    <span class="toolbar-label">Threads:</span>
    {thread_buttons}
  </div>
  <div class="toolbar">
    <span class="toolbar-label">Scenario:</span>
    {scenario_buttons}
  </div>

  {''.join(panels)}

  <script>
    const RUNS = {json.dumps(chart_payload)};
    let activeThreads = {default_threads};
    let activeScenario = {json.dumps(default_scenario)};
    let charts = {{}};

    Chart.defaults.color = "#94a3b8";
    Chart.defaults.borderColor = "#334155";

    function runKey(threads, scenario) {{
      return threads + ":" + scenario;
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

    function renderCharts(threads, scenario) {{
      const key = runKey(threads, scenario);
      const DATA = RUNS[key];
      if (!DATA) return;
      destroyCharts();
      const panelId = "panel_t" + threads + "_" + scenario;
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
          plugins: triggerAnnotations(DATA),
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
          plugins: triggerAnnotations(DATA), scales: baseScales("Rate (/s)")
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
          plugins: triggerAnnotations(DATA), scales: baseScales("Latency p95 (ms)")
        }}
      }});
    }}

    function showPanel(threads, scenario) {{
      document.querySelectorAll(".run-panel").forEach(el => {{
        const match = String(el.dataset.threads) === String(threads) && el.dataset.scenario === scenario;
        el.style.display = match ? "" : "none";
      }});
      destroyCharts();
      if (RUNS[runKey(threads, scenario)]) {{
        renderCharts(threads, scenario);
      }}
    }}

    function setActiveButtons(threads, scenario) {{
      document.querySelectorAll(".toggle-btn[data-threads]").forEach(btn => {{
        btn.classList.toggle("active", String(btn.dataset.threads) === String(threads));
      }});
      document.querySelectorAll(".toggle-btn[data-scenario]").forEach(btn => {{
        btn.classList.toggle("active", btn.dataset.scenario === scenario);
      }});
    }}

    document.querySelectorAll(".toggle-btn[data-threads]").forEach(btn => {{
      btn.addEventListener("click", () => {{
        activeThreads = btn.dataset.threads;
        setActiveButtons(activeThreads, activeScenario);
        showPanel(activeThreads, activeScenario);
      }});
    }});

    document.querySelectorAll(".toggle-btn[data-scenario]").forEach(btn => {{
      btn.addEventListener("click", () => {{
        activeScenario = btn.dataset.scenario;
        setActiveButtons(activeThreads, activeScenario);
        showPanel(activeThreads, activeScenario);
      }});
    }});

    setActiveButtons(activeThreads, activeScenario);
    showPanel(activeThreads, activeScenario);
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
        if not (parent_ed and discover_thread_runs(parent_ed)):
            html_path = generate_html_report(
                edition_dir, rows, meta, parsed, event, kpi, png_files, extended, primary
            )
            outputs.append(html_path)

    return outputs


def _collect_scenario_dirs(parent: Path) -> list[Path]:
    """Scenario dirs under an edition or thread parent (flat or tN/scenario layout)."""
    found: list[Path] = []
    for child in sorted(parent.iterdir()):
        if not child.is_dir() or child.name == "graphs":
            continue
        if (child / "failover_timeseries.csv").exists():
            found.append(child)
        elif THREAD_DIR_RE.match(child.name):
            for scenario_dir in sorted(child.iterdir()):
                if scenario_dir.is_dir() and (scenario_dir / "failover_timeseries.csv").exists():
                    found.append(scenario_dir)
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
    args = parser.parse_args()
    path: Path = args.path

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
