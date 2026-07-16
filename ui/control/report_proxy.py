"""Fetch failover HTML reports from the droplet and serve them locally."""

from __future__ import annotations

import re
import shlex
from datetime import datetime, timezone
from pathlib import Path

from control.ssh_backend import SshBackend

CACHE_DIR = Path(__file__).resolve().parent / ".report_cache"
PRIMARY_REPORT_SUFFIX = "advanced/graphs/failover_report.html"
_RUN_TS_RE = re.compile(r"^failover_(\d{8})_(\d{6})$")


def run_timestamp_meta(run_id: str) -> dict[str, str]:
    """Parse ``failover_YYYYMMDD_HHMMSS`` into ISO + display strings (UTC)."""
    match = _RUN_TS_RE.match((run_id or "").strip())
    if not match:
        return {"started_at": "", "started_display": ""}
    try:
        dt = datetime.strptime(f"{match.group(1)}{match.group(2)}", "%Y%m%d%H%M%S").replace(
            tzinfo=timezone.utc
        )
    except ValueError:
        return {"started_at": "", "started_display": ""}
    return {
        "started_at": dt.isoformat().replace("+00:00", "Z"),
        "started_display": dt.strftime("%Y-%m-%d %H:%M:%S UTC"),
    }


def run_id_at_or_after(run_id: str, min_run_id: str) -> bool:
    """True when run_id is min_run_id or a newer failover_* directory."""
    if not min_run_id:
        return True
    return run_id >= min_run_id


def validate_results_path(rel_path: str) -> str:
    rel = rel_path.strip().lstrip("/")
    parts = Path(rel).parts
    if not parts or parts[0] != "results":
        raise ValueError("Path must be under results/")
    if len(parts) < 2 or not parts[1].startswith("failover_"):
        raise ValueError("Path must be under results/failover_*")
    if ".." in parts:
        raise ValueError("Invalid path")
    return rel.replace("\\", "/")


def report_view_url(rel_path: str) -> str:
    return f"/reports/{validate_results_path(rel_path)}"


def report_label(rel_path: str) -> str:
    rel = validate_results_path(rel_path)
    marker = "/graphs/failover_report.html"
    if not rel.endswith(marker):
        return rel
    prefix = rel[: -len(marker)]
    run_dir = prefix.split("/")[1] if "/" in prefix else prefix
    tail = prefix.split("/", 2)[-1] if prefix.count("/") >= 2 else prefix.split("/", 1)[-1]
    if tail == run_dir or tail == prefix.split("/")[1]:
        return "Combined report"
    return tail.replace("/", " · ")


def pick_primary_report(reports: list[dict]) -> dict | None:
    if not reports:
        return None
    for report in reports:
        if report["path"].endswith(PRIMARY_REPORT_SUFFIX):
            return report
    for report in reports:
        if report["path"].endswith("/graphs/failover_report.html"):
            return report
    return reports[0]


def _report_entry(rel_path: str, mtime: int = 0) -> dict:
    path = validate_results_path(rel_path)
    return {
        "path": path,
        "label": report_label(path),
        "view_url": report_view_url(path),
        "mtime": mtime,
    }


class ReportProxy:
    def __init__(self, backend: SshBackend) -> None:
        self.backend = backend

    def _remote_path(self, rel_path: str) -> str:
        rel = validate_results_path(rel_path)
        return f"{self.backend.config.remote_repo.rstrip('/')}/{rel}"

    def _cache_root(self) -> Path:
        # Keep each droplet's reports in a separate subtree so run dirs with the
        # same name on different droplets never collide in the local cache.
        host = self.backend.config.host or "default"
        return CACHE_DIR / host

    def remote_mtime(self, rel_path: str) -> int:
        remote = self._remote_path(rel_path)
        result = self.backend.run(
            f"stat -c %Y {shlex.quote(remote)} 2>/dev/null || echo 0",
            check=False,
        )
        try:
            return int((result.stdout or "0").strip().splitlines()[-1])
        except ValueError:
            return 0

    def fetch_to_cache(self, rel_path: str) -> Path:
        rel = validate_results_path(rel_path)
        cache_path = self._cache_root() / rel
        meta_path = cache_path.with_suffix(cache_path.suffix + ".remote_mtime")

        remote_mtime = self.remote_mtime(rel)
        if cache_path.is_file() and meta_path.is_file():
            try:
                if int(meta_path.read_text(encoding="utf-8").strip()) == remote_mtime:
                    return cache_path
            except ValueError:
                pass

        cache_path.parent.mkdir(parents=True, exist_ok=True)
        self.backend.scp_download(self._remote_path(rel), cache_path)
        meta_path.write_text(str(remote_mtime), encoding="utf-8")
        return cache_path

    def discover_reports(self, results_dir: str) -> list[dict]:
        results_dir = validate_results_path(results_dir)
        repo = shlex.quote(self.backend.config.remote_repo)
        script = (
            f"cd {repo} && find {shlex.quote(results_dir)} -name failover_report.html 2>/dev/null | sort | "
            r'while IFS= read -r f; do '
            r'ts=$(stat -c %Y "$f" 2>/dev/null || echo 0); '
            r'printf "REPORT|%s|%s\n" "$f" "$ts"; '
            r"done"
        )
        result = self.backend.run(script, check=False)
        reports: list[dict] = []
        for line in (result.stdout or "").splitlines():
            if not line.startswith("REPORT|"):
                continue
            _, path, mtime_raw = line.split("|", 2)
            try:
                mtime = int(mtime_raw.strip())
            except ValueError:
                mtime = 0
            try:
                reports.append(_report_entry(path, mtime))
            except ValueError:
                continue
        return reports

    def list_runs(
        self,
        limit: int = 25,
        *,
        latest_results_dir: str = "",
        running_results_dir: str = "",
        running: bool = False,
        runs_min_id: str = "",
    ) -> list[dict]:
        limit = max(1, min(limit, 100))
        fetch_limit = 100 if runs_min_id else limit
        result = self.backend.ctl("list", str(fetch_limit))
        if result.returncode != 0:
            return []

        by_run: dict[str, dict] = {}
        if latest_results_dir:
            try:
                latest_results_dir = validate_results_path(latest_results_dir)
            except ValueError:
                latest_results_dir = ""
        if running_results_dir:
            try:
                running_results_dir = validate_results_path(running_results_dir)
            except ValueError:
                running_results_dir = ""

        for line in (result.stdout or "").splitlines():
            if line.startswith("RUN|"):
                results_dir = line.split("|", 1)[1].strip()
                try:
                    validate_results_path(results_dir)
                except ValueError:
                    continue
                run_id = Path(results_dir).name
                by_run[results_dir] = {
                    "run_id": run_id,
                    "results_dir": results_dir,
                    "is_latest": results_dir == latest_results_dir,
                    "running": running and results_dir == running_results_dir,
                    "completed": False,
                    "reports": [],
                    "primary_report": None,
                }
                continue
            if line.startswith("STATE|"):
                _, results_dir, completed_raw = line.split("|", 2)
                if results_dir not in by_run:
                    continue
                by_run[results_dir]["completed"] = completed_raw.strip() == "1"
                continue
            if not line.startswith("REPORT|"):
                continue
            _, results_dir, report_path, mtime_raw = line.split("|", 3)
            if results_dir not in by_run:
                continue
            try:
                mtime = int(mtime_raw.strip())
            except ValueError:
                mtime = 0
            try:
                by_run[results_dir]["reports"].append(_report_entry(report_path, mtime))
            except ValueError:
                continue

        runs: list[dict] = []
        for run in by_run.values():
            if not run_id_at_or_after(run["run_id"], runs_min_id):
                continue
            run["primary_report"] = pick_primary_report(run["reports"])
            runs.append(run)
        return runs[:limit]

    def generate_html_reports(self, results_dir: str) -> None:
        results_dir = validate_results_path(results_dir)
        repo = shlex.quote(self.backend.config.remote_repo)
        target = shlex.quote(results_dir)
        script = f"cd {repo} && ./generate_failover_graphs.sh --html-only {target}"
        result = self.backend.run(script, check=False)
        if result.returncode != 0:
            detail = (result.stderr or result.stdout or "generate_failover_graphs failed").strip()
            raise RuntimeError(detail)
