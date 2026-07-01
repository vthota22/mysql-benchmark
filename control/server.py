"""Local HTTP server for failover benchmark control."""

from __future__ import annotations

import json
import mimetypes
import subprocess
import sys
import threading
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

from control.config_schema import (  # noqa: E402
    FAILOVER_FIELDS,
    FAILOVER_KEYS,
    INSERT_MARKER,
    estimate_runtime_sec,
)
from control.ssh_backend import DropletConfig, SshBackend, load_droplet_config  # noqa: E402
from scripts.benchmark_config_io import get_keys, merge_keys, parse_config  # noqa: E402

STATIC_DIR = Path(__file__).resolve().parent / "static"


def _field_specs_json() -> list[dict]:
    return [
        {
            "key": field.key,
            "label": field.label,
            "type": field.field_type,
            "help": field.help_text,
            "options": list(field.options),
            "section": field.section,
        }
        for field in FAILOVER_FIELDS
    ]


class ControlServer:
    def __init__(self, droplet: DropletConfig) -> None:
        self.backend = SshBackend(droplet)
        self.droplet = droplet
        self._run_lock = threading.Lock()

    def get_failover_config(self) -> dict:
        text = self.backend.read_file(self.droplet.remote_conf_path)
        parsed = parse_config(text)
        values = get_keys(parsed, list(FAILOVER_KEYS))
        return {
            "values": values,
            "estimated_runtime_sec": estimate_runtime_sec(values),
            "remote_conf": self.droplet.remote_conf_path,
        }

    def save_failover_config(self, updates: dict[str, str]) -> dict:
        allowed = set(FAILOVER_KEYS)
        filtered = {k: str(v) for k, v in updates.items() if k in allowed}
        text = self.backend.read_file(self.droplet.remote_conf_path)
        merged = merge_keys(text, filtered, insert_after=INSERT_MARKER)
        self.backend.write_file(self.droplet.remote_conf_path, merged)
        return self.get_failover_config()

    def run_status(self) -> dict:
        result = self.backend.ctl("status")
        if result.returncode != 0:
            return {
                "running": False,
                "error": (result.stderr or result.stdout or "status failed").strip(),
            }
        data = self.backend.parse_ctl_status(result.stdout)
        running = data.get("running") == "1"
        values = {}
        try:
            values = self.get_failover_config()["values"]
        except Exception:
            pass
        return {
            "running": running,
            "pid": data.get("pid", ""),
            "results_dir": data.get("results_dir", ""),
            "started_utc": data.get("started_utc", ""),
            "log_path": data.get("log_path", ""),
            "report_path": data.get("report_path", ""),
            "estimated_runtime_sec": estimate_runtime_sec(values) if values else None,
        }

    def start_run(self) -> dict:
        with self._run_lock:
            status = self.run_status()
            if status.get("running"):
                return {"ok": False, "error": "A failover benchmark is already running on the droplet."}

            result = self.backend.ctl("start")
            if result.returncode != 0:
                message = (result.stderr or result.stdout or "start failed").strip()
                return {"ok": False, "error": message}

            return {"ok": True, "message": result.stdout.strip(), "status": self.run_status()}

    def run_log(self, lines: int = 100) -> dict:
        result = self.backend.ctl("log", str(lines))
        if result.returncode != 0:
            return {"ok": False, "error": (result.stderr or result.stdout).strip(), "log": ""}
        return {"ok": True, "log": result.stdout}


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

        def _serve_static(self, rel_path: str) -> None:
            safe = Path(rel_path).name if rel_path else "index.html"
            if safe != rel_path.strip("/"):
                safe = "index.html"
            path = STATIC_DIR / safe
            if not path.is_file():
                self.send_error(HTTPStatus.NOT_FOUND)
                return
            data = path.read_bytes()
            ctype = mimetypes.guess_type(str(path))[0] or "application/octet-stream"
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self) -> None:  # noqa: N802
            parsed = urlparse(self.path)
            path = parsed.path

            if path in ("/", "/index.html"):
                self._serve_static("index.html")
                return
            if path.startswith("/static/"):
                self._serve_static(path.removeprefix("/static/"))
                return

            try:
                if path == "/api/health":
                    ok, message = server.backend.test_connection()
                    self._send_json({"ok": ok, "message": message})
                    return
                if path == "/api/schema":
                    self._send_json({"fields": _field_specs_json(), "droplet": server.droplet.host})
                    return
                if path == "/api/config/failover":
                    self._send_json(server.get_failover_config())
                    return
                if path == "/api/run/status":
                    self._send_json(server.run_status())
                    return
                if path == "/api/run/log":
                    qs = parse_qs(parsed.query)
                    lines = int((qs.get("lines") or ["100"])[0])
                    self._send_json(server.run_log(lines=max(1, min(lines, 2000))))
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
                    result = server.save_failover_config(updates)
                    self._send_json({"ok": True, **result})
                    return
                if parsed.path == "/api/run/start":
                    self._send_json(server.start_run())
                    return
            except Exception as exc:  # noqa: BLE001
                self._send_json({"error": str(exc)}, HTTPStatus.INTERNAL_SERVER_ERROR)
                return
            self.send_error(HTTPStatus.NOT_FOUND)

    return Handler


def run_server(host: str, port: int, config_path: Path) -> None:
    droplet = load_droplet_config(config_path)
    server_impl = ControlServer(droplet)
    handler = make_handler(server_impl)
    httpd = ThreadingHTTPServer((host, port), handler)
    print(f"Failover control UI: http://{host}:{port}")
    print(f"Droplet: {droplet.user}@{droplet.host}:{droplet.remote_repo}")
    print("Press Ctrl+C to stop.")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")
