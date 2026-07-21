"""Local HTTP server for failover benchmark control."""

from __future__ import annotations

import json
import mimetypes
import os
import shlex
import subprocess
import sys
import threading
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, quote, unquote, urlparse

UI_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(UI_ROOT))

from control.benchmark_config_io import (  # noqa: E402
    dedupe_config,
    get_keys,
    merge_keys,
    normalize_failover_value,
    parse_config,
)
from control.config_schema import (  # noqa: E402
    ADVANCED_CREDENTIAL_KEYS,
    ADVANCED_INSERT_MARKER,
    FAILOVER_FIELDS,
    FAILOVER_KEYS,
    INSERT_MARKER,
    PREPARE_FIELDS,
    PREPARE_KEYS,
    UI_CONTROL_DEFAULTS,
    apply_config_defaults,
    build_prepare_job_conf,
    prepare_estimate_payload,
    estimate_runtime_sec,
)
from control.features import FEATURES, features_payload, resolve_feature  # noqa: E402
from control.kpi_compare import build_compare_payload, filter_runs_for_compare  # noqa: E402
from control.report_proxy import (  # noqa: E402
    ReportProxy,
    is_allowed_report_path,
    pick_primary_report,
    report_label,
    report_view_url,
    run_timestamp_meta,
    validate_results_path,
)
from control.ssh_backend import DropletConfig, SshBackend, resolve_droplet_config  # noqa: E402

STATIC_DIR = Path(__file__).resolve().parent / "static"


def _field_specs_json(fields) -> list[dict]:
    return [
        {
            "key": field.key,
            "label": field.label,
            "type": field.field_type,
            "help": field.help_text,
            "options": list(field.options),
            "section": field.section,
            "default": field.default,
        }
        for field in fields
    ]


def _droplet_overrides_from_values(values: dict) -> dict[str, str]:
    droplet_keys = ("DROPLET_NAME", "DROPLET_HOST", "DROPLET_USER", "DROPLET_SSH_PORT", "REMOTE_REPO")
    return {k: str(values[k]).strip() for k in droplet_keys if values.get(k, "").strip()}


def _host_report_url(view_url: str, host: str) -> str:
    """Rewrite ``/reports/<path>`` into ``/reports/@<host>/<path>``.

    The host segment lives in the path (not a query string) so that relative
    asset links inside a report resolve back to the same droplet.
    """
    prefix = "/reports/"
    if not host or not view_url.startswith(prefix):
        return view_url
    # Idempotent: primary_report is the same dict object as one of the entries
    # in reports[], so it can be passed through here twice. Never double-prefix.
    if view_url.startswith(prefix + "@"):
        return view_url
    return f"{prefix}@{quote(host, safe='')}/{view_url[len(prefix):]}"


def _parse_feature(raw: str = "") -> str:
    fid = (raw or "failover").strip().lower() or "failover"
    resolve_feature(fid)  # raises if unknown/disabled
    return fid


def _annotate_runs_with_host(runs: list[dict], host: str) -> None:
    if not host:
        return
    for run in runs:
        for report in run.get("reports") or []:
            if report.get("view_url"):
                report["view_url"] = _host_report_url(report["view_url"], host)
        primary = run.get("primary_report")
        if primary and primary.get("view_url"):
            primary["view_url"] = _host_report_url(primary["view_url"], host)


class ControlServer:
    def __init__(self, droplet: DropletConfig) -> None:
        self.backend = SshBackend(droplet)
        self.droplet = droplet
        self.reports = ReportProxy(self.backend)
        self.compare_runs_limit = droplet.compare_runs_limit
        self._run_locks: dict[str, threading.Lock] = {}
        self._run_lock_guard = threading.Lock()
        self._prepare_lock = threading.Lock()
        self._prepare_backend: SshBackend | None = None
        # Union of all feature maps (for prepare / legacy host name lookup).
        self.droplet_options = self._build_droplet_options("failover")
        all_hosts: dict[str, str] = {}
        for feature in ("failover", "backup", "scaling"):
            for name, host in droplet.droplets_for_feature(feature):
                all_hosts.setdefault(host, name)
        if droplet.host:
            all_hosts.setdefault(droplet.host, droplet.name or droplet.host)
        self._host_names = all_hosts

    def _run_lock_for(self, host: str) -> threading.Lock:
        with self._run_lock_guard:
            if host not in self._run_locks:
                self._run_locks[host] = threading.Lock()
            return self._run_locks[host]

    def _build_droplet_options(self, feature: str = "failover") -> list[dict]:
        mapped = list(self.droplet.droplets_for_feature(feature))
        # Prefer configured DROPLET_HOST as the locked default when it appears in this feature's map.
        if feature == "failover" and self.droplet.host:
            preferred = self.droplet.host
            for idx, (name, host) in enumerate(mapped):
                if host == preferred:
                    if idx != 0:
                        mapped.insert(0, mapped.pop(idx))
                    break
        options: list[dict] = []
        seen: set[str] = set()
        for name, host in mapped:
            if host in seen:
                continue
            seen.add(host)
            options.append({"name": name, "host": host, "default": len(options) == 0})
        # Failover only: if map empty, keep the configured default host so UI still works.
        if not options and feature == "failover":
            options.append(
                {
                    "name": self.droplet.name or self.droplet.host,
                    "host": self.droplet.host,
                    "default": True,
                }
            )
        return options

    def droplet_options_payload(self, feature: str = "failover") -> dict:
        options = self._build_droplet_options(feature)
        default_host = options[0]["host"] if options else ""
        return {
            "droplets": options,
            "default_host": default_host,
            "compare_runs_limit": self.compare_runs_limit,
            "feature": feature,
            "map_empty": len(options) == 0,
            "map_hint": (
                ""
                if options
                else (
                    f"No droplets configured for {feature}. "
                    f"Set {feature.upper()}_DROPLET_MAP in control.local.conf "
                    f"(or BENCHMARK_{feature.upper()}_DROPLET_MAP)."
                )
            ),
        }

    def _hosts_for_feature(self, feature: str = "failover") -> set[str]:
        return {host for _, host in self.droplet.droplets_for_feature(feature)} | (
            {self.droplet.host} if feature == "failover" else set()
        )

    def _resolve_report_target(
        self, host: str = "", feature: str = "failover"
    ) -> tuple[SshBackend, ReportProxy, DropletConfig]:
        """Return (backend, reports, droplet) for a report browsing host.

        Only hosts listed in the feature's droplet map (plus the failover default)
        are allowed, to avoid using this endpoint to SSH into arbitrary hosts.
        """
        profile = resolve_feature(feature)
        allowed = self._hosts_for_feature(feature)
        host = (host or "").strip()
        if not host:
            options = self._build_droplet_options(feature)
            if options:
                host = options[0]["host"]
            elif feature == "failover":
                host = self.droplet.host
            else:
                raise ValueError(
                    f"No droplets configured for {feature}. "
                    f"Set {feature.upper()}_DROPLET_MAP in control.local.conf."
                )
        if host not in allowed:
            # Name lookup from any known map entry for clearer errors.
            names = {h: n for n, h in self.droplet.droplets_for_feature(feature)}
            raise ValueError(
                f"Droplet {host} is not in the {feature} map"
                + (f" ({names.get(host)})" if host in names else "")
                + f". Configure {feature.upper()}_DROPLET_MAP."
            )
        name_by_host = {h: n for n, h in self.droplet.droplets_for_feature(feature)}
        if feature == "failover" and self.droplet.host not in name_by_host:
            name_by_host[self.droplet.host] = self.droplet.name or self.droplet.host
        if host == self.droplet.host and feature == "failover":
            return self.backend, ReportProxy(self.backend, profile), self.droplet
        cfg = self.droplet.with_overrides(
            {"DROPLET_HOST": host, "DROPLET_NAME": name_by_host.get(host, host)}
        )
        backend = SshBackend(cfg)
        return backend, ReportProxy(backend, profile), cfg

    def _backend_for_droplet(self, overrides: dict[str, str] | None = None) -> SshBackend:
        if not overrides:
            return self.backend
        cfg = self.droplet.with_overrides(overrides)
        return SshBackend(cfg)

    def _failover_values(self, backend: SshBackend, droplet: DropletConfig) -> dict:
        text = backend.read_file(droplet.remote_conf_path)
        deduped, changed = dedupe_config(text)
        if changed:
            backend.write_file(droplet.remote_conf_path, deduped)
            text = deduped
        parsed = parse_config(text)
        values = get_keys(parsed, list(FAILOVER_KEYS))
        return apply_config_defaults(values)

    def get_failover_config(self, host: str = "") -> dict:
        backend, _, droplet = self._resolve_report_target(host)
        values = self._failover_values(backend, droplet)
        return {
            "values": values,
            "estimated_runtime_sec": estimate_runtime_sec(values),
            "remote_conf": droplet.remote_conf_path,
            "host": droplet.host,
            "droplet_name": droplet.name or droplet.host,
        }

    def save_failover_config(self, updates: dict[str, str], host: str = "") -> dict:
        backend, _, droplet = self._resolve_report_target(host)
        allowed = set(FAILOVER_KEYS) | set(UI_CONTROL_DEFAULTS.keys())
        filtered = {
            k: normalize_failover_value(k, str(v))
            for k, v in updates.items()
            if k in allowed
        }
        if not filtered.get("ADVANCED_MYSQL_PASSWORD", "").strip():
            filtered.pop("ADVANCED_MYSQL_PASSWORD", None)
        filtered["FAILOVER_EDITIONS"] = UI_CONTROL_DEFAULTS["FAILOVER_EDITIONS"]

        credential_updates = {k: v for k, v in filtered.items() if k in ADVANCED_CREDENTIAL_KEYS}
        failover_updates = {k: v for k, v in filtered.items() if k not in ADVANCED_CREDENTIAL_KEYS}

        text = backend.read_file(droplet.remote_conf_path)
        deduped, _ = dedupe_config(text)
        merged = deduped
        if credential_updates:
            merged = merge_keys(merged, credential_updates, insert_after=ADVANCED_INSERT_MARKER)
        if failover_updates:
            merged = merge_keys(merged, failover_updates, insert_after=INSERT_MARKER)
        merged, _ = dedupe_config(merged)
        backend.write_file(droplet.remote_conf_path, merged)
        return self.get_failover_config(host)

    def _reports_for_status(self, reports: ReportProxy, results_dir: str, running: bool) -> dict:
        if not results_dir:
            return {"reports": [], "primary_report": None}
        try:
            report_list = reports.discover_reports(results_dir)
        except Exception:
            report_list = []
        primary = pick_primary_report(report_list, reports.feature)
        return {"reports": report_list, "primary_report": primary}

    def run_status(
        self,
        backend: SshBackend | None = None,
        reports: ReportProxy | None = None,
        droplet: DropletConfig | None = None,
    ) -> dict:
        backend = backend or self.backend
        reports = reports or self.reports
        droplet = droplet or self.droplet
        # Run status / start / log are failover-only for Option A.
        if getattr(reports, "feature", None) and reports.feature.id != "failover":
            return {
                "running": False,
                "completed": False,
                "pid": "",
                "results_dir": "",
                "started_utc": "",
                "log_path": "",
                "report_path": "",
                "report_url": "",
                "reports": [],
                "primary_report": None,
                "estimated_runtime_sec": None,
                "host": droplet.host,
                "droplet_name": droplet.name or droplet.host,
                "feature": reports.feature.id,
                "browse_only": True,
            }
        result = backend.ctl("status")
        if result.returncode != 0:
            return {
                "running": False,
                "error": (result.stderr or result.stdout or "status failed").strip(),
            }
        data = backend.parse_ctl_status(result.stdout)
        running = data.get("running") == "1"
        results_dir = data.get("results_dir", "")
        values = {}
        try:
            values = self._failover_values(backend, droplet)
        except Exception:
            pass
        report_info = self._reports_for_status(reports, results_dir, running)
        primary = report_info["primary_report"]
        legacy_report = data.get("report_path", "")
        if not primary and legacy_report:
            try:
                path = validate_results_path(legacy_report)
                primary = {
                    "path": path,
                    "label": report_label(path),
                    "view_url": report_view_url(legacy_report),
                    "mtime": 0,
                }
                report_info["reports"] = [primary, *report_info["reports"]]
            except ValueError:
                pass
        if droplet.host != self.droplet.host:
            _annotate_runs_with_host(
                [{"reports": report_info["reports"], "primary_report": primary}],
                droplet.host,
            )
            primary = report_info["primary_report"]
        return {
            "running": running,
            "completed": data.get("completed") == "1",
            "pid": data.get("pid", ""),
            "results_dir": results_dir,
            "started_utc": data.get("started_utc", ""),
            "log_path": data.get("log_path", ""),
            "report_path": primary["path"] if primary else "",
            "report_url": primary["view_url"] if primary else "",
            "reports": report_info["reports"],
            "primary_report": primary,
            "estimated_runtime_sec": estimate_runtime_sec(values) if values else None,
            "host": droplet.host,
            "droplet_name": droplet.name or droplet.host,
            "feature": "failover",
        }

    def list_report_runs(self, limit: int = 25, host: str = "", feature: str = "failover") -> dict:
        profile = resolve_feature(feature)
        backend, reports, droplet = self._resolve_report_target(host, feature=feature)
        results_dir = ""
        running = False
        runs_min_id = droplet.runs_min_id if profile.id == "failover" else ""
        if profile.list_mode == "ctl":
            status = self.run_status(backend, reports, droplet)
            results_dir = status.get("results_dir", "")
            running = bool(status.get("running"))
            runs = reports.list_runs(
                limit,
                latest_results_dir=results_dir,
                running_results_dir=results_dir if running else "",
                running=running,
                runs_min_id=runs_min_id,
            )
        else:
            runs = reports.list_runs(limit, runs_min_id=runs_min_id)
            if runs:
                results_dir = runs[0].get("results_dir", "")
                runs[0]["is_latest"] = True
        for run in runs:
            meta = run_timestamp_meta(run.get("run_id", ""), profile)
            run["started_at"] = meta["started_at"]
            run["started_display"] = meta["started_display"]
            mtimes = [int(r.get("mtime") or 0) for r in run.get("reports") or []]
            newest = max(mtimes) if mtimes else 0
            run["mtime"] = newest
            if newest and not run["started_display"]:
                run["started_display"] = datetime.fromtimestamp(newest, tz=timezone.utc).strftime(
                    "%Y-%m-%d %H:%M:%S UTC"
                )
        if droplet.host != self.droplet.host:
            _annotate_runs_with_host(runs, droplet.host)
        return {
            "runs": runs,
            "latest_results_dir": results_dir,
            "running": running,
            "runs_min_id": runs_min_id,
            "host": droplet.host,
            "droplet_name": droplet.name or droplet.host,
            "feature": profile.id,
            "feature_label": profile.label,
            "browse_only": not profile.can_start,
            "can_generate": profile.id == "failover",
        }

    def compare_runs(self, limit: int | None = None, host: str = "", feature: str = "failover") -> dict:
        profile = resolve_feature(feature)
        if not profile.can_compare:
            return {
                "runs": [],
                "slices": [],
                "error": f"KPI compare is not available for {profile.label} yet.",
                "feature": profile.id,
                "host": host or self.droplet.host,
            }
        if limit is None:
            limit = self.compare_runs_limit
        backend, _, droplet = self._resolve_report_target(host, feature=feature)
        list_data = self.list_report_runs(limit=100, host=host, feature=feature)
        runs = filter_runs_for_compare(list_data["runs"], droplet.runs_min_id)
        payload = build_compare_payload(runs, backend, limit=limit)
        payload["runs_min_id"] = droplet.runs_min_id
        payload["host"] = droplet.host
        payload["droplet_name"] = droplet.name or droplet.host
        payload["feature"] = profile.id
        if droplet.host != self.droplet.host:
            _annotate_runs_with_host(payload["runs"], droplet.host)
        return payload

    def generate_run_reports(self, results_dir: str, host: str = "", feature: str = "failover") -> dict:
        profile = resolve_feature(feature)
        _, reports, droplet = self._resolve_report_target(host, feature=feature)
        reports.generate_html_reports(results_dir)
        report_list = reports.discover_reports(results_dir)
        primary = pick_primary_report(report_list, profile)
        result = {
            "ok": True,
            "results_dir": validate_results_path(results_dir, profile),
            "reports": report_list,
            "primary_report": primary,
            "host": droplet.host,
            "feature": profile.id,
        }
        if droplet.host != self.droplet.host:
            _annotate_runs_with_host(
                [{"reports": report_list, "primary_report": primary}], droplet.host
            )
        return result

    def start_run(self, host: str = "") -> dict:
        backend, reports, droplet = self._resolve_report_target(host)
        with self._run_lock_for(droplet.host):
            status = self.run_status(backend, reports, droplet)
            if status.get("running"):
                return {"ok": False, "error": "A failover benchmark is already running on the droplet."}

            result = backend.ctl("start")
            if result.returncode != 0:
                message = (result.stderr or result.stdout or "start failed").strip()
                return {"ok": False, "error": message}

            return {
                "ok": True,
                "message": result.stdout.strip(),
                "status": self.run_status(backend, reports, droplet),
            }

    def run_log(self, lines: int = 100, host: str = "") -> dict:
        backend, _, _ = self._resolve_report_target(host)
        result = backend.ctl("log", str(lines))
        if result.returncode != 0:
            return {"ok": False, "error": (result.stderr or result.stdout).strip(), "log": ""}
        return {"ok": True, "log": result.stdout}

    def get_prepare_defaults(self) -> dict:
        values: dict[str, str] = {
            "DROPLET_NAME": self.droplet.name or self.droplet.host,
            "DROPLET_HOST": self.droplet.host,
            "DROPLET_USER": self.droplet.user,
            "DROPLET_SSH_PORT": str(self.droplet.ssh_port),
            "REMOTE_REPO": self.droplet.remote_repo,
            "TPCC_TABLES": "10",
            "TPCC_SCALE": "100",
            "PREP_THREADS": "16",
            "TPCC_FORCE_PK": "1",
        }
        for field in PREPARE_FIELDS:
            if field.default and not values.get(field.key):
                values[field.key] = field.default
        try:
            text = self.backend.read_file(self.droplet.remote_conf_path)
            parsed = parse_config(text)
            remote = get_keys(parsed, list(FAILOVER_KEYS) + list(PREPARE_KEYS))
            for ui_key, remote_key in (
                ("MYSQL_HOST", "ADVANCED_MYSQL_HOST"),
                ("MYSQL_PASSWORD", "ADVANCED_MYSQL_PASSWORD"),
            ):
                if remote.get(remote_key):
                    values[ui_key] = remote[remote_key]
            for key in ("TPCC_TABLES", "TPCC_SCALE", "PREP_THREADS", "TPCC_FORCE_PK"):
                if remote.get(key):
                    values[key] = remote[key]
        except Exception:
            pass
        return {
            "values": values,
            **prepare_estimate_payload(values),
        }

    def _parse_prepare_status(self, stdout: str) -> dict[str, str]:
        return self.backend.parse_ctl_status(stdout)

    def prepare_status(self, droplet_overrides: dict[str, str] | None = None) -> dict:
        if droplet_overrides:
            backend = self._backend_for_droplet(droplet_overrides)
        else:
            backend = self._prepare_backend or self.backend
        result = backend.prepare_ctl("status")
        if result.returncode != 0:
            return {
                "running": False,
                "error": (result.stderr or result.stdout or "status failed").strip(),
            }
        data = self._parse_prepare_status(result.stdout)
        running = data.get("running") == "1"
        completed = data.get("completed") == "1"
        success = data.get("success") == "1"
        host = ""
        if droplet_overrides:
            host = droplet_overrides.get("DROPLET_HOST", "")
        elif backend.config.host:
            host = backend.config.host
        return {
            "running": running,
            "completed": completed,
            "success": success,
            "failed": completed and not success,
            "pid": data.get("pid", ""),
            "results_dir": data.get("results_dir", ""),
            "started_utc": data.get("started_utc", ""),
            "droplet_name": data.get("droplet_name", ""),
            "droplet_host": host,
            "log_path": data.get("log_path", ""),
            "check_ok": data.get("check_ok", ""),
        }

    def prepare_log(self, lines: int = 120, droplet_overrides: dict[str, str] | None = None) -> dict:
        if droplet_overrides:
            backend = self._backend_for_droplet(droplet_overrides)
        else:
            backend = self._prepare_backend or self.backend
        result = backend.prepare_ctl("log", str(lines))
        if result.returncode != 0:
            return {"ok": False, "error": (result.stderr or result.stdout).strip(), "log": ""}
        return {"ok": True, "log": result.stdout}

    def start_prepare(self, payload: dict) -> dict:
        values = payload.get("values") or payload
        droplet_overrides = _droplet_overrides_from_values(values)

        required = ["DROPLET_HOST", "MYSQL_HOST", "MYSQL_PASSWORD"]
        missing = [k for k in required if not str(values.get(k, "")).strip()]
        if missing:
            return {"ok": False, "error": f"Missing required fields: {', '.join(missing)}"}

        backend = self._backend_for_droplet(droplet_overrides)
        cfg = backend.config

        with self._prepare_lock:
            status = self.prepare_status(droplet_overrides)
            if status.get("running"):
                return {"ok": False, "error": "A TPC-C prepare job is already running on this droplet."}

            timestamp = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
            job_dir = f"{cfg.remote_repo.rstrip('/')}/results/prepare_jobs/{timestamp}"
            job_conf = f"{job_dir}/prepare.conf"
            conf_text = build_prepare_job_conf(values)

            mkdir_cmd = f"mkdir -p {shlex.quote(job_dir)}"
            backend.run(mkdir_cmd)

            local_tmp = Path(os.environ.get("TMPDIR", "/tmp")) / f"prepare_conf_{timestamp}.tmp"
            local_tmp.write_text(conf_text, encoding="utf-8")
            remote_tmp = f"{job_conf}.upload"
            scp_cmd = backend._base_scp() + [
                str(local_tmp),
                f"{cfg.user}@{cfg.host}:{remote_tmp}",
            ]
            subprocess.run(scp_cmd, capture_output=True, text=True, check=True)
            backend.run(f"mv {shlex.quote(remote_tmp)} {shlex.quote(job_conf)}")

            edition = "advanced"
            droplet_name = str(values.get("DROPLET_NAME", cfg.host)).strip()

            result = backend.prepare_ctl("start", job_conf, edition, droplet_name)
            if result.returncode != 0:
                message = (result.stderr or result.stdout or "start failed").strip()
                return {"ok": False, "error": message}

            self._prepare_backend = backend
            return {
                "ok": True,
                "message": result.stdout.strip(),
                **prepare_estimate_payload(values),
                "status": self.prepare_status(droplet_overrides),
            }

    def test_prepare_droplet(self, values: dict) -> dict:
        overrides = _droplet_overrides_from_values(values)
        backend = self._backend_for_droplet(overrides)
        ok, message = backend.test_connection()
        return {"ok": ok, "message": message}


def make_handler(server: ControlServer):
    class Handler(BaseHTTPRequestHandler):
        server_version = "FailoverControl/1.0"

        def log_message(self, fmt: str, *args) -> None:  # noqa: D401
            sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

        def _send_json(self, payload: dict, status: HTTPStatus = HTTPStatus.OK) -> None:
            body = json.dumps(payload).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _read_json(self) -> dict:
            length = int(self.headers.get("Content-Length", "0"))
            raw = self.rfile.read(length) if length else b"{}"
            return json.loads(raw.decode("utf-8") or "{}")

        def _serve_bytes(self, data: bytes, content_type: str) -> None:
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def _serve_report_file(self, rel_path: str, host: str = "") -> None:
            feature = "failover"
            if rel_path.startswith("backup-benchmarking/"):
                feature = "backup"
            elif rel_path.startswith("scaling-benchmarking/"):
                feature = "scaling"
            _, reports, _ = server._resolve_report_target(host, feature=feature)
            rel = validate_results_path(rel_path, feature)
            cache_path = reports.fetch_to_cache(rel)
            data = cache_path.read_bytes()
            ctype = mimetypes.guess_type(str(cache_path))[0] or "application/octet-stream"
            self._serve_bytes(data, ctype)

        def _serve_static(self, rel_path: str) -> None:
            path = STATIC_DIR / Path(rel_path).name
            if not path.is_file():
                self.send_error(HTTPStatus.NOT_FOUND)
                return
            data = path.read_bytes()
            ctype = mimetypes.guess_type(str(path))[0] or "application/octet-stream"
            self._serve_bytes(data, ctype)

        def do_GET(self) -> None:  # noqa: N802
            parsed = urlparse(self.path)
            path = parsed.path

            if path in ("/", "/index.html"):
                self._serve_static("index.html")
                return
            if path in ("/runs", "/runs.html"):
                self.send_response(HTTPStatus.MOVED_PERMANENTLY)
                self.send_header("Location", "/#reports")
                self.end_headers()
                return
            if path.startswith("/static/"):
                self._serve_static(path.removeprefix("/static/"))
                return

            if path.startswith("/reports/"):
                rel_path = path.removeprefix("/reports/")
                host = ""
                if rel_path.startswith("@"):
                    segment, _, remainder = rel_path.partition("/")
                    host = unquote(segment[1:])
                    rel_path = remainder
                if is_allowed_report_path(rel_path):
                    try:
                        self._serve_report_file(rel_path, host)
                    except ValueError:
                        self.send_error(HTTPStatus.NOT_FOUND)
                    return
                self.send_error(HTTPStatus.NOT_FOUND)
                return

            try:
                if path == "/api/ping":
                    self._send_json({"ok": True, "service": "mysql-benchmark-ui"})
                    return
                if path == "/api/features":
                    self._send_json({"features": features_payload(), "active": "failover"})
                    return
                if path == "/api/health":
                    qs = parse_qs(parsed.query)
                    host = (qs.get("host") or [""])[0]
                    backend, _, droplet = server._resolve_report_target(host)
                    ok, message = backend.test_connection()
                    self._send_json(
                        {
                            "ok": ok,
                            "message": message,
                            "host": droplet.host,
                            "droplet_name": droplet.name or droplet.host,
                        }
                    )
                    return
                if path == "/api/schema":
                    qs = parse_qs(parsed.query)
                    host = (qs.get("host") or [""])[0]
                    _, _, droplet = server._resolve_report_target(host)
                    self._send_json(
                        {
                            "fields": _field_specs_json(FAILOVER_FIELDS),
                            "droplet": droplet.host,
                            "droplet_name": droplet.name or droplet.host,
                        }
                    )
                    return
                if path == "/api/droplets":
                    qs = parse_qs(parsed.query)
                    feature = _parse_feature((qs.get("feature") or ["failover"])[0])
                    self._send_json(server.droplet_options_payload(feature=feature))
                    return
                if path == "/api/prepare/schema":
                    self._send_json({"fields": _field_specs_json(PREPARE_FIELDS)})
                    return
                if path == "/api/prepare/defaults":
                    self._send_json(server.get_prepare_defaults())
                    return
                if path == "/api/config/failover":
                    qs = parse_qs(parsed.query)
                    host = (qs.get("host") or [""])[0]
                    self._send_json(server.get_failover_config(host=host))
                    return
                if path == "/api/run/status":
                    qs = parse_qs(parsed.query)
                    host = (qs.get("host") or [""])[0]
                    backend, reports, droplet = server._resolve_report_target(host)
                    self._send_json(server.run_status(backend, reports, droplet))
                    return
                if path == "/api/run/log":
                    qs = parse_qs(parsed.query)
                    lines = int((qs.get("lines") or ["100"])[0])
                    host = (qs.get("host") or [""])[0]
                    self._send_json(server.run_log(lines=max(1, min(lines, 2000)), host=host))
                    return
                if path == "/api/reports":
                    qs = parse_qs(parsed.query)
                    limit = int((qs.get("limit") or ["25"])[0])
                    host = (qs.get("host") or [""])[0]
                    feature = _parse_feature((qs.get("feature") or ["failover"])[0])
                    self._send_json(
                        server.list_report_runs(
                            limit=max(1, min(limit, 100)),
                            host=host,
                            feature=feature,
                        )
                    )
                    return
                if path == "/api/runs/compare":
                    qs = parse_qs(parsed.query)
                    limit_raw = (qs.get("limit") or [""])[0]
                    limit = int(limit_raw) if limit_raw else None
                    host = (qs.get("host") or [""])[0]
                    feature = _parse_feature((qs.get("feature") or ["failover"])[0])
                    if limit is not None:
                        limit = max(1, min(limit, 12))
                    self._send_json(server.compare_runs(limit=limit, host=host, feature=feature))
                    return
            except ValueError as exc:
                self._send_json({"error": str(exc)}, HTTPStatus.BAD_REQUEST)
                return
            except subprocess.CalledProcessError as exc:
                detail = (exc.stderr or exc.stdout or str(exc)).strip()
                self._send_json({"error": detail}, HTTPStatus.BAD_GATEWAY)
                return
            except Exception as exc:  # noqa: BLE001
                self._send_json({"error": str(exc)}, HTTPStatus.INTERNAL_SERVER_ERROR)
                return

            self.send_error(HTTPStatus.NOT_FOUND)

        def do_POST(self) -> None:  # noqa: N802
            parsed = urlparse(self.path)
            try:
                if parsed.path == "/api/config/failover":
                    payload = self._read_json()
                    updates = payload.get("values") or payload
                    host = payload.get("host", "")
                    result = server.save_failover_config(updates, host=host)
                    self._send_json({"ok": True, **result})
                    return
                if parsed.path == "/api/run/start":
                    payload = self._read_json()
                    host = payload.get("host", "")
                    self._send_json(server.start_run(host=host))
                    return
                if parsed.path == "/api/runs/generate-report":
                    payload = self._read_json()
                    results_dir = payload.get("results_dir", "")
                    host = payload.get("host", "")
                    feature = _parse_feature(payload.get("feature", "failover"))
                    if not results_dir:
                        self._send_json({"error": "results_dir required"}, HTTPStatus.BAD_REQUEST)
                        return
                    self._send_json(
                        server.generate_run_reports(results_dir, host=host, feature=feature)
                    )
                    return
                if parsed.path == "/api/prepare/status":
                    payload = self._read_json()
                    values = payload.get("values") or {}
                    overrides = _droplet_overrides_from_values(values) or None
                    self._send_json(server.prepare_status(overrides))
                    return
                if parsed.path == "/api/prepare/log":
                    payload = self._read_json()
                    values = payload.get("values") or {}
                    overrides = _droplet_overrides_from_values(values) or None
                    lines = int(payload.get("lines") or 120)
                    self._send_json(server.prepare_log(max(1, min(lines, 2000)), overrides))
                    return
                if parsed.path == "/api/prepare/start":
                    payload = self._read_json()
                    self._send_json(server.start_prepare(payload))
                    return
                if parsed.path == "/api/prepare/test":
                    payload = self._read_json()
                    values = payload.get("values") or payload
                    self._send_json(server.test_prepare_droplet(values))
                    return
                if parsed.path == "/api/prepare/estimate":
                    payload = self._read_json()
                    values = payload.get("values") or payload
                    self._send_json(prepare_estimate_payload(values))
                    return
            except Exception as exc:  # noqa: BLE001
                self._send_json({"error": str(exc)}, HTTPStatus.INTERNAL_SERVER_ERROR)
                return
            self.send_error(HTTPStatus.NOT_FOUND)

    return Handler


def run_server(host: str, port: int, config_path: Path | None = None) -> None:
    droplet = resolve_droplet_config(config_path)
    server_impl = ControlServer(droplet)
    handler = make_handler(server_impl)
    httpd = ThreadingHTTPServer((host, port), handler)
    print(f"Failover control UI: http://{host}:{port}")
    failover_opts = server_impl._build_droplet_options("failover")
    default = failover_opts[0] if failover_opts else None
    if default:
        print(f"Default droplet (failover): {default['name']}={default['host']}")
    else:
        print(f"Default droplet: {droplet.user}@{droplet.host}:{droplet.remote_repo}")
    if droplet.droplets:
        mapped = ", ".join(f"{n}={h}" for n, h in droplet.droplets)
        print(f"Failover map: {mapped}")
    if droplet.backup_droplets:
        print(f"Backup map: {', '.join(f'{n}={h}' for n, h in droplet.backup_droplets)}")
    if droplet.scaling_droplets:
        print(f"Scaling map: {', '.join(f'{n}={h}' for n, h in droplet.scaling_droplets)}")
    if droplet.ssh_key:
        print(f"SSH key: {droplet.ssh_key}")
    print(f"Features: {', '.join(f.id for f in FEATURES.values() if f.enabled)}")
    print("Health: GET /api/ping  |  Droplet check: GET /api/health")
    print("Press Ctrl+C to stop.")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")
