"""Build failover KPI comparisons across recent runs."""

from __future__ import annotations

import csv
import io
from typing import Any

from control.report_proxy import run_id_at_or_after
from control.ssh_backend import SshBackend

KPI_METRICS: tuple[tuple[str, str], ...] = (
    ("failure_detection_sec", "Time to detect failure (s)"),
    ("primary_election_sec", "Time to promote — election (s)"),
)

KPI_COLUMNS = frozenset(
    {
        "edition",
        "scenario",
        "trx_profile",
        "failure_detection_sec",
        "primary_election_sec",
        "total_failover_sec",
        "app_recovery_sec",
        "tps_dip_duration_sec",
        "peak_latency_failover_ms",
        "transactions_failed_during_failover",
        "writes_failed_during_failover",
        "peak_write_err_per_sec",
        "data_loss",
    }
)


def parse_kpi_csv(text: str) -> list[dict[str, str]]:
    """Parse a run-level or scenario-level failover_kpi.csv."""
    rows: list[dict[str, str]] = []
    reader = csv.DictReader(io.StringIO(text.strip()))
    if not reader.fieldnames:
        return rows
    for raw in reader:
        row = {k: (raw.get(k) or "").strip() for k in raw.keys() if k in KPI_COLUMNS}
        if row.get("edition") or row.get("scenario"):
            rows.append(row)
    return rows


def slice_key(row: dict[str, str]) -> tuple[str, str]:
    edition = row.get("edition") or "unknown"
    scenario = row.get("scenario") or "default"
    return edition, scenario


def slice_label(edition: str, scenario: str) -> str:
    return f"{edition} · {scenario}"


def fetch_run_kpi(backend: SshBackend, results_dir: str) -> list[dict[str, str]]:
    remote = f"{backend.config.remote_repo.rstrip('/')}/{results_dir}/failover_kpi.csv"
    try:
        text = backend.read_file(remote)
    except Exception:
        return []
    return parse_kpi_csv(text)


def build_compare_payload(
    runs: list[dict[str, Any]],
    backend: SshBackend,
    *,
    limit: int = 6,
) -> dict[str, Any]:
    """Compare KPI metrics for the last `limit` runs (newest first)."""
    selected = runs[:limit]
    run_entries: list[dict[str, Any]] = []
    kpi_by_run: dict[str, list[dict[str, str]]] = {}

    for run in selected:
        run_id = run["run_id"]
        results_dir = run["results_dir"]
        rows = fetch_run_kpi(backend, results_dir) if run.get("completed") else []
        kpi_by_run[run_id] = rows
        run_entries.append(
            {
                "run_id": run_id,
                "results_dir": results_dir,
                "completed": bool(run.get("completed")),
                "running": bool(run.get("running")),
                "primary_report": run.get("primary_report"),
                "has_kpi": bool(rows),
            }
        )

    slice_order: list[tuple[str, str]] = []
    seen_slices: set[tuple[str, str]] = set()
    for run in selected:
        for row in kpi_by_run.get(run["run_id"], []):
            key = slice_key(row)
            if key not in seen_slices:
                seen_slices.add(key)
                slice_order.append(key)

    slices: list[dict[str, Any]] = []
    for edition, scenario in slice_order:
        metric_rows: list[dict[str, Any]] = []
        for metric_key, metric_label in KPI_METRICS:
            values: dict[str, str] = {}
            for run in selected:
                run_id = run["run_id"]
                match = next(
                    (r for r in kpi_by_run.get(run_id, []) if slice_key(r) == (edition, scenario)),
                    None,
                )
                if match:
                    raw = match.get(metric_key, "")
                    values[run_id] = raw if raw and raw.upper() != "N/A" else "—"
                elif run.get("running"):
                    values[run_id] = "…"
                else:
                    values[run_id] = "—"
            metric_rows.append(
                {
                    "metric": metric_key,
                    "label": metric_label,
                    "values": values,
                }
            )
        slices.append(
            {
                "edition": edition,
                "scenario": scenario,
                "label": slice_label(edition, scenario),
                "rows": metric_rows,
            }
        )

    return {
        "runs": run_entries,
        "slices": slices,
        "limit": limit,
    }


def filter_runs_for_compare(runs: list[dict[str, Any]], runs_min_id: str) -> list[dict[str, Any]]:
    return [run for run in runs if run_id_at_or_after(run.get("run_id", ""), runs_min_id)]
