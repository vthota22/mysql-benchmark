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
_SCENARIO_NAMES = frozenset({"mixed", "write_only"})
_EDITION_NAMES = frozenset({"advanced", "standard"})
_ITER_DIR_RE = re.compile(r"^iter\d+$")
_THREAD_DIR_RE = re.compile(r"^t\d+$")


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


def is_combined_failover_report(rel_path: str) -> bool:
    """True for type-specific combined reports only (not iter/thread leaf mirrors).

    Accepted layouts under results/failover_<ts>/:
      advanced/graphs/failover_report.html                  (legacy mega-combined)
      advanced/<scenario>/graphs/failover_report.html
      advanced/<trigger>/<scenario>/graphs/failover_report.html
    """
    try:
        rel = validate_results_path(rel_path)
    except ValueError:
        return False
    if not rel.endswith("/graphs/failover_report.html"):
        return False
    prefix = rel[: -len("/graphs/failover_report.html")]
    parts = Path(prefix).parts
    if any(_ITER_DIR_RE.match(p) or _THREAD_DIR_RE.match(p) for p in parts):
        return False
    # results / failover_* / ...
    if len(parts) < 3 or parts[0] != "results" or not parts[1].startswith("failover_"):
        return False
    rest = parts[2:]
    if len(rest) == 1 and rest[0] in _EDITION_NAMES:
        return True  # legacy edition/graphs
    if len(rest) == 2 and rest[0] in _EDITION_NAMES and rest[1] in _SCENARIO_NAMES:
        return True
    if (
        len(rest) == 3
        and rest[0] in _EDITION_NAMES
        and rest[1] in _TRIGGER_METHOD_LABELS
        and rest[2] in _SCENARIO_NAMES
    ):
        return True
    return False


def report_label(rel_path: str, *, include_scenario: bool | None = None) -> str:
    rel = validate_results_path(rel_path)
    feature = _feature_for_path(rel)

    # Failover: type-specific combined report labels (no "Combined" prefix).
    if feature.id == "failover" and rel.endswith("/graphs/failover_report.html"):
        prefix = rel[: -len("/graphs/failover_report.html")]
        parts = Path(prefix).parts  # results / failover_TS / advanced [/ …]
        if len(parts) <= 2:
            return "Failover report"
        rest = parts[2:]
        if rest in (("advanced",), ("standard",)):
            return "Failover report"

        trigger = ""
        scenario = ""
        for part in rest:
            if part in _TRIGGER_METHOD_LABELS and not trigger:
                trigger = part
            if part in _SCENARIO_NAMES and not scenario:
                scenario = part

        mode = _TRIGGER_METHOD_LABELS.get(trigger, ("", ""))[0] if trigger else ""
        if mode == "planned":
            label = "Planned failover"
        elif mode == "unplanned":
            label = "Unplanned failover"
        else:
            label = "Failover report"

        if include_scenario is not False and scenario and include_scenario is True:
            label = f"{label} · {scenario}"
        elif include_scenario is None and scenario:
            # Caller didn't decide yet; keep scenario only when explicitly requested later
            # via _relabel_reports_for_scenarios. Default path: omit until relabel.
            pass
        return label

    if rel.endswith(feature.primary_report_suffix) or Path(rel).name == feature.report_html_name:
        return "Primary report"
    return Path(rel).name


def _scenarios_in_reports(reports: list[dict]) -> set[str]:
    found: set[str] = set()
    for report in reports:
        for part in Path(report.get("path", "")).parts:
            if part in _SCENARIO_NAMES:
                found.add(part)
    return found


def _relabel_reports_for_scenarios(reports: list[dict]) -> list[dict]:
    """Omit load-type from labels when the run only has one scenario."""
    include_scenario = len(_scenarios_in_reports(reports)) > 1
    for report in reports:
        report["label"] = report_label(report["path"], include_scenario=include_scenario)
    return reports


def pick_primary_report(reports: list[dict], feature: FeatureProfile | None = None) -> dict | None:
    if not reports:
        return None
    profile = feature or _feature_for_path(reports[0]["path"])
    suffix = profile.primary_report_suffix
    for report in reports:
        if report["path"].endswith(suffix):
            return report
    if profile.id == "failover":
        # Prefer type-specific combined reports; legacy mega-combined last.
        preferred_suffixes = (
            "/pod_delete/mixed/graphs/failover_report.html",
            "/set_as_primary/mixed/graphs/failover_report.html",
            "/mysqld_kill/mixed/graphs/failover_report.html",
            "/mixed/graphs/failover_report.html",
            "/write_only/graphs/failover_report.html",
            "/advanced/graphs/failover_report.html",
        )
        for suffix_path in preferred_suffixes:
            for report in reports:
                if report["path"].endswith(suffix_path):
                    return report
        for report in reports:
            if report["path"].endswith("/graphs/failover_report.html"):
                return report
    return reports[0]


def _report_entry(rel_path: str, mtime: int = 0, *, include_scenario: bool | None = None) -> dict:
    path = validate_results_path(rel_path)
    mode = failover_mode_from_path(path)
    entry = {
        "path": path,
        "label": report_label(path, include_scenario=include_scenario),
        "view_url": report_view_url(path),
        "mtime": mtime,
    }
    if mode:
        entry["failover_mode"] = mode
        entry["failover_mode_label"] = "Planned" if mode == "planned" else "Unplanned"
    return entry


def _listed_report_entry(
    rel_path: str, mtime: int = 0, *, include_scenario: bool | None = None
) -> dict | None:
    """Build a report entry for UI listing, or None if it should be hidden."""
    try:
        path = validate_results_path(rel_path)
    except ValueError:
        return None
    feature = _feature_for_path(path)
    if feature.id == "failover" and not is_combined_failover_report(path):
        return None
    return _report_entry(path, mtime, include_scenario=include_scenario)


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
                entry = _listed_report_entry(path, mtime)
                if entry:
                    reports.append(entry)
            except ValueError:
                continue
        return _relabel_reports_for_scenarios(reports)

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
                entry = _listed_report_entry(report_path, mtime)
                if entry:
                    by_run[results_dir]["reports"].append(entry)
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
            run["reports"] = _relabel_reports_for_scenarios(unique_reports)
            run["primary_report"] = pick_primary_report(run["reports"], self.feature)
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
