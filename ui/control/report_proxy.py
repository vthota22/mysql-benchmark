"""Fetch HTML reports from the droplet and serve them locally."""

from __future__ import annotations

import re
import shlex
from datetime import datetime, timezone
from pathlib import Path

from control.features import FeatureProfile, FEATURES, resolve_feature
from control.ssh_backend import SshBackend

CACHE_DIR = Path(__file__).resolve().parent / ".report_cache"

# Legacy failover constants (kept for callers that import them).
PRIMARY_REPORT_SUFFIX = FEATURES["failover"].primary_report_suffix
_RUN_TS_RE = re.compile(FEATURES["failover"].run_id_regex)

_ALLOWED_ROOT_PREFIXES = (
    "results/",
    "backup-benchmarking/results/",
    "scaling-benchmarking/results/",
)


def _feature_for_path(rel: str) -> FeatureProfile:
    """Infer feature from a validated relative results path."""
    if rel.startswith("backup-benchmarking/"):
        return FEATURES["backup"]
    if rel.startswith("scaling-benchmarking/"):
        return FEATURES["scaling"]
    return FEATURES["failover"]


def run_timestamp_meta(run_id: str, feature: FeatureProfile | None = None) -> dict[str, str]:
    """Parse run directory name into ISO + display strings (UTC)."""
    profile = feature or FEATURES["failover"]
    match = re.match(profile.run_id_regex, (run_id or "").strip())
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
    """True when run_id is min_run_id or a newer directory name (lexicographic)."""
    if not min_run_id:
        return True
    return run_id >= min_run_id


def validate_results_path(rel_path: str, feature: FeatureProfile | str | None = None) -> str:
    """Validate a relative path under an allowed results tree."""
    rel = rel_path.strip().lstrip("/").replace("\\", "/")
    parts = Path(rel).parts
    if not parts or ".." in parts:
        raise ValueError("Invalid path")
    if not any(rel == p.rstrip("/") or rel.startswith(p) for p in _ALLOWED_ROOT_PREFIXES):
        raise ValueError(
            "Path must be under results/, backup-benchmarking/results/, "
            "or scaling-benchmarking/results/"
        )

    profile: FeatureProfile | None
    if isinstance(feature, str):
        profile = resolve_feature(feature)
    else:
        profile = feature

    if profile is not None:
        prefix = profile.results_parent.rstrip("/") + "/"
        if rel != profile.results_parent.rstrip("/") and not rel.startswith(prefix):
            raise ValueError(f"Path must be under {profile.results_parent}/")
        # Run directory (or file under it) must match the feature's naming.
        if rel != profile.results_parent.rstrip("/"):
            run_part = parts[len(Path(profile.results_parent).parts)]
            if profile.id == "failover":
                if not run_part.startswith("failover_"):
                    raise ValueError("Path must be under results/failover_*")
            elif not run_part.startswith("run_"):
                raise ValueError(f"Path must be under {profile.results_parent}/run_*")
    else:
        # Untyped path: still require a recognized run directory segment.
        inferred = _feature_for_path(rel)
        prefix_parts = Path(inferred.results_parent).parts
        if len(parts) > len(prefix_parts):
            run_part = parts[len(prefix_parts)]
            if inferred.id == "failover" and not run_part.startswith("failover_"):
                raise ValueError("Path must be under results/failover_*")
            if inferred.id != "failover" and not run_part.startswith("run_"):
                raise ValueError(f"Path must be under {inferred.results_parent}/run_*")

    return rel


def is_allowed_report_path(rel_path: str) -> bool:
    try:
        validate_results_path(rel_path)
        return True
    except ValueError:
        return False


def report_view_url(rel_path: str) -> str:
    return f"/reports/{validate_results_path(rel_path)}"


_TRIGGER_METHOD_LABELS = {
    "pod_delete": ("unplanned", "Unplanned (pod_delete)"),
    "mysqld_kill": ("unplanned", "Unplanned (mysqld_kill)"),
    "set_as_primary": ("planned", "Planned (set_as_primary)"),
}


def failover_mode_from_path(rel_path: str) -> str:
    """Return 'planned', 'unplanned', or '' from a results path."""
    try:
        rel = validate_results_path(rel_path)
    except ValueError:
        rel = rel_path.strip().lstrip("/").replace("\\", "/")
    for part in Path(rel).parts:
        mode = _TRIGGER_METHOD_LABELS.get(part, ("", ""))[0]
        if mode:
            return mode
    return ""


def _humanize_path_part(part: str) -> str:
    labeled = _TRIGGER_METHOD_LABELS.get(part)
    if labeled:
        return labeled[1]
    return part


def report_label(rel_path: str) -> str:
    rel = validate_results_path(rel_path)
    feature = _feature_for_path(rel)

    # Failover: label by path under the run dir, e.g.
    #   .../advanced/graphs/failover_report.html              → Combined report
    #   .../advanced/iter1/t16/mixed/graphs/failover_report.html → advanced · iter1 · t16 · mixed
    #   .../advanced/pod_delete/mixed/graphs/... → advanced · Unplanned (pod_delete) · mixed
    if feature.id == "failover" and rel.endswith("/graphs/failover_report.html"):
        prefix = rel[: -len("/graphs/failover_report.html")]
        parts = Path(prefix).parts  # results / failover_TS / advanced [/ iter…]
        if len(parts) <= 2:
            return "Combined report"
        scenario = parts[2:]
        if scenario == ("advanced",):
            return "Combined report"
        return " · ".join(_humanize_path_part(p) for p in scenario)

    if rel.endswith(feature.primary_report_suffix) or Path(rel).name == feature.report_html_name:
        return "Primary report"
    return Path(rel).name


def pick_primary_report(reports: list[dict], feature: FeatureProfile | None = None) -> dict | None:
    if not reports:
        return None
    profile = feature or _feature_for_path(reports[0]["path"])
    suffix = profile.primary_report_suffix
    for report in reports:
        if report["path"].endswith(suffix):
            return report
    if profile.id == "failover":
        # Prefer combined advanced/graphs report; else first iter report.
        for report in reports:
            if report["path"].endswith("/advanced/graphs/failover_report.html"):
                return report
        for report in reports:
            if report["path"].endswith("/graphs/failover_report.html"):
                return report
    return reports[0]


def _report_entry(rel_path: str, mtime: int = 0) -> dict:
    path = validate_results_path(rel_path)
    mode = failover_mode_from_path(path)
    entry = {
        "path": path,
        "label": report_label(path),
        "view_url": report_view_url(path),
        "mtime": mtime,
    }
    if mode:
        entry["failover_mode"] = mode
        entry["failover_mode_label"] = "Planned" if mode == "planned" else "Unplanned"
    return entry


class ReportProxy:
    def __init__(self, backend: SshBackend, feature: FeatureProfile | None = None) -> None:
        self.backend = backend
        self.feature = feature or FEATURES["failover"]

    def _remote_path(self, rel_path: str) -> str:
        rel = validate_results_path(rel_path, self.feature)
        return f"{self.backend.config.remote_repo.rstrip('/')}/{rel}"

    def _cache_root(self) -> Path:
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
        self.backend.scp_download(
            f"{self.backend.config.remote_repo.rstrip('/')}/{rel}",
            cache_path,
        )
        meta_path.write_text(str(remote_mtime), encoding="utf-8")
        return cache_path

    def discover_reports(self, results_dir: str) -> list[dict]:
        results_dir = validate_results_path(results_dir, self.feature)
        repo = shlex.quote(self.backend.config.remote_repo)
        report_name = shlex.quote(self.feature.report_html_name)
        script = (
            f"cd {repo} && find {shlex.quote(results_dir)} -name {report_name} 2>/dev/null | sort | "
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

    def list_runs_via_find(
        self,
        limit: int = 25,
        *,
        runs_min_id: str = "",
    ) -> list[dict]:
        """Discover run directories by filesystem find (backup/scaling)."""
        limit = max(1, min(limit, 100))
        fetch_limit = 100 if runs_min_id else limit
        report_name = self.feature.report_html_name
        if "/" in report_name or report_name.startswith(".") or ".." in report_name:
            raise ValueError(f"Invalid report HTML name: {report_name}")
        repo = shlex.quote(self.backend.config.remote_repo)
        parent = shlex.quote(self.feature.results_parent)
        name_glob = shlex.quote(self.feature.run_dir_name_glob)
        report_q = shlex.quote(report_name)
        script = f"""
set +e
cd {repo} || exit 0
if [ ! -d {parent} ]; then exit 0; fi
find {parent} -mindepth 1 -maxdepth 1 -type d -name {name_glob} 2>/dev/null | sort -r | head -n {int(fetch_limit)} | while IFS= read -r d; do
  printf 'RUN|%s\\n' "$d"
  if [ -f "$d"/{report_q} ]; then
    ts=$(stat -c %Y "$d"/{report_q} 2>/dev/null || echo 0)
    printf 'REPORT|%s|%s|%s\\n' "$d" "$d"/{report_q} "$ts"
  fi
  find "$d" -mindepth 2 -name {report_q} 2>/dev/null | while IFS= read -r f; do
    ts=$(stat -c %Y "$f" 2>/dev/null || echo 0)
    printf 'REPORT|%s|%s|%s\\n' "$d" "$f" "$ts"
  done
done
"""
        result = self.backend.run(script, check=False)
        return self._parse_run_listing(
            result.stdout or "",
            limit=limit,
            runs_min_id=runs_min_id,
            latest_results_dir="",
            running_results_dir="",
            running=False,
        )

    def list_runs(
        self,
        limit: int = 25,
        *,
        latest_results_dir: str = "",
        running_results_dir: str = "",
        running: bool = False,
        runs_min_id: str = "",
    ) -> list[dict]:
        if self.feature.list_mode == "find":
            return self.list_runs_via_find(limit, runs_min_id=runs_min_id)

        limit = max(1, min(limit, 100))
        fetch_limit = 100 if runs_min_id else limit
        result = self.backend.ctl("list", str(fetch_limit))
        if result.returncode != 0:
            return []
        return self._parse_run_listing(
            result.stdout or "",
            limit=limit,
            runs_min_id=runs_min_id,
            latest_results_dir=latest_results_dir,
            running_results_dir=running_results_dir,
            running=running,
        )

    def _parse_run_listing(
        self,
        stdout: str,
        *,
        limit: int,
        runs_min_id: str,
        latest_results_dir: str,
        running_results_dir: str,
        running: bool,
    ) -> list[dict]:
        by_run: dict[str, dict] = {}
        if latest_results_dir:
            try:
                latest_results_dir = validate_results_path(latest_results_dir, self.feature)
            except ValueError:
                latest_results_dir = ""
        if running_results_dir:
            try:
                running_results_dir = validate_results_path(running_results_dir, self.feature)
            except ValueError:
                running_results_dir = ""

        for line in stdout.splitlines():
            if line.startswith("RUN|"):
                results_dir = line.split("|", 1)[1].strip()
                try:
                    validate_results_path(results_dir, self.feature)
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
            parts = line.split("|")
            if len(parts) < 4:
                continue
            _, results_dir, report_path, mtime_raw = parts[0], parts[1], parts[2], parts[3]
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
            # Deduplicate report paths
            seen: set[str] = set()
            unique_reports = []
            for report in run["reports"]:
                if report["path"] in seen:
                    continue
                seen.add(report["path"])
                unique_reports.append(report)
            run["reports"] = unique_reports
            run["primary_report"] = pick_primary_report(unique_reports, self.feature)
            if unique_reports or self.feature.list_mode == "find":
                # find-mode: mark completed when a primary report exists
                if self.feature.list_mode == "find":
                    run["completed"] = bool(run["primary_report"])
            runs.append(run)
        return runs[:limit]

    def generate_html_reports(self, results_dir: str) -> None:
        if self.feature.id != "failover":
            raise RuntimeError(
                f"HTML regeneration is only supported for failover runs "
                f"(got feature={self.feature.id})."
            )
        results_dir = validate_results_path(results_dir, self.feature)
        repo = shlex.quote(self.backend.config.remote_repo)
        target = shlex.quote(results_dir)
        script = f"cd {repo} && ./generate_failover_graphs.sh --html-only {target}"
        result = self.backend.run(script, check=False)
        if result.returncode != 0:
            detail = (result.stderr or result.stdout or "generate_failover_graphs failed").strip()
            raise RuntimeError(detail)
