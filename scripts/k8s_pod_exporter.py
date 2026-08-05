#!/usr/bin/env python3
"""Prometheus exporter for Kubernetes pod-level longevity signals.

PMM only scrapes the MySQL + node exporters *inside* the DB pods, so it has no
Kubernetes-level view (pod restarts, phase, CrashLoop/OOM, operator health).
This exporter fills that gap: it periodically runs `kubectl` against the Percona
namespace and exposes the results at /metrics, where vmagent scrapes it and
remote-writes into PMM's VictoriaMetrics.

Env:
  KUBECONFIG          path to kubeconfig (required)
  K8S_NAMESPACE       default "percona"
  CLUSTER             label value for the cluster (default "longevity-am-n3")
  LISTEN              host:port to serve (default 127.0.0.1:9111)
  REFRESH_SEC         kubectl refresh interval (default 15)
  OPERATOR_LOG_LINES  operator log tail to scan for errors (default 300)

Run:
  KUBECONFIG=/root/.kube/config CLUSTER=longevity-am-n3 python3 k8s_pod_exporter.py
"""
import json
import os
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

KUBECONFIG = os.environ.get("KUBECONFIG", "")
NS = os.environ.get("K8S_NAMESPACE", "percona")
CLUSTER = os.environ.get("CLUSTER", "longevity-am-n3")
LISTEN = os.environ.get("LISTEN", "127.0.0.1:9111")
REFRESH_SEC = int(os.environ.get("REFRESH_SEC", "15"))
OP_LOG_LINES = os.environ.get("OPERATOR_LOG_LINES", "300")
# Containers to collect cgroup memory from via kubectl exec.
# do-agent is a scratch image (no shell), so it's excluded.
MEMORY_CONTAINERS = os.environ.get(
    "MEMORY_CONTAINERS", "mysql,mysqld-exporter,slow-log-tailer,pmm-client,xtrabackup"
).split(",")

_HOST, _PORT = LISTEN.split(":")
_PORT = int(_PORT)
_lock = threading.Lock()
_payload = "# exporter starting\n"


def _kubectl(*args, timeout=25):
    cmd = ["kubectl", "--kubeconfig", KUBECONFIG, "-n", NS, *args]
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


def _esc(v):
    return str(v).replace("\\", "\\\\").replace('"', '\\"')


def _lbl(**kw):
    kw["cluster"] = CLUSTER
    inner = ",".join(f'{k}="{_esc(v)}"' for k, v in kw.items() if v is not None)
    return "{" + inner + "}"


def _read_container_memory(pod, container, timeout=10):
    """Read cgroup memory usage via kubectl exec. Returns bytes or -1."""
    try:
        r = _kubectl("exec", pod, "-c", container, "--",
                     "sh", "-c",
                     "cat /sys/fs/cgroup/memory.current 2>/dev/null "
                     "|| cat /sys/fs/cgroup/memory/memory.usage_in_bytes 2>/dev/null "
                     "|| echo -1",
                     timeout=timeout)
        if r.returncode == 0:
            return int(r.stdout.strip())
    except Exception:
        pass
    return -1


def build_metrics():
    lines = []
    ok = 1
    t0 = time.time()

    # ---- pods ----
    lines.append("# HELP longevity_k8s_container_restarts_total container restart count")
    lines.append("# TYPE longevity_k8s_container_restarts_total counter")
    try:
        r = _kubectl("get", "pods", "-o", "json")
        if r.returncode != 0:
            raise RuntimeError(r.stderr.strip()[:200])
        pods = json.loads(r.stdout)["items"]
        phase_counts = {}
        for p in pods:
            name = p["metadata"]["name"]
            phase = p.get("status", {}).get("phase", "Unknown")
            phase_counts[phase] = phase_counts.get(phase, 0) + 1
            lines.append(f'longevity_k8s_pod_phase{_lbl(pod=name, phase=phase)} 1')

            cs = p.get("status", {}).get("containerStatuses", []) or []
            all_ready = 1 if cs else 0
            for c in cs:
                cn = c.get("name")
                ready = 1 if c.get("ready") else 0
                if not ready:
                    all_ready = 0
                restarts = c.get("restartCount", 0)
                lines.append(f'longevity_k8s_container_restarts_total{_lbl(pod=name, container=cn)} {restarts}')
                lines.append(f'longevity_k8s_container_ready{_lbl(pod=name, container=cn)} {ready}')
                st = c.get("state", {}) or {}
                if "waiting" in st:
                    reason = st["waiting"].get("reason", "Waiting")
                    lines.append(f'longevity_k8s_container_waiting{_lbl(pod=name, container=cn, reason=reason)} 1')
                last = c.get("lastState", {}) or {}
                if "terminated" in last:
                    reason = last["terminated"].get("reason", "Terminated")
                    lines.append(f'longevity_k8s_container_last_terminated{_lbl(pod=name, container=cn, reason=reason)} 1')
            lines.append(f'longevity_k8s_pod_ready{_lbl(pod=name)} {all_ready}')

        for ph, n in phase_counts.items():
            lines.append(f'longevity_k8s_pods_total{_lbl(phase=ph)} {n}')
    except Exception as e:
        ok = 0
        lines.append(f'# pods error: {_esc(e)}')

    # ---- operator log error count (best-effort) ----
    try:
        rp = _kubectl("get", "pods", "-o",
                      "jsonpath={.items[?(@.metadata.labels.app\\.kubernetes\\.io/name==\"percona-server-mysql-operator\")].metadata.name}")
        op = (rp.stdout or "").split()
        if not op:  # fallback by name match
            rp = _kubectl("get", "pods", "--no-headers", "-o", "custom-columns=:metadata.name")
            op = [n for n in rp.stdout.split() if "operator" in n]
        if op:
            rl = _kubectl("logs", op[0], f"--tail={OP_LOG_LINES}", timeout=25)
            logtxt = (rl.stdout or "") + (rl.stderr or "")
            errs = sum(1 for ln in logtxt.splitlines()
                       if any(k in ln.lower() for k in ("error", "reconcile.*fail", "failed")))
            lines.append("# HELP longevity_k8s_operator_log_errors error/failed lines in operator log tail")
            lines.append("# TYPE longevity_k8s_operator_log_errors gauge")
            lines.append(f'longevity_k8s_operator_log_errors{_lbl(window_lines=OP_LOG_LINES)} {errs}')
    except Exception as e:
        lines.append(f'# operator log error: {_esc(e)}')

    # ---- sidecar container memory (cgroup via kubectl exec) ----
    try:
        lines.append("# HELP longevity_k8s_container_memory_bytes cgroup memory usage per container")
        lines.append("# TYPE longevity_k8s_container_memory_bytes gauge")
        mysql_pods = [p["metadata"]["name"] for p in pods
                      if "mysql-" in p["metadata"]["name"]
                      and "haproxy" not in p["metadata"]["name"]
                      and "binlog" not in p["metadata"]["name"]
                      and "operator" not in p["metadata"]["name"]
                      and p.get("status", {}).get("phase") == "Running"]
        for pod_name in mysql_pods:
            for ctr in MEMORY_CONTAINERS:
                mem = _read_container_memory(pod_name, ctr)
                if mem >= 0:
                    lines.append(
                        f'longevity_k8s_container_memory_bytes'
                        f'{_lbl(pod=pod_name, container=ctr)} {mem}')
    except Exception as e:
        lines.append(f'# container memory error: {_esc(e)}')

    lines.append(f'longevity_k8s_scrape_success{_lbl()} {ok}')
    lines.append(f'longevity_k8s_scrape_duration_seconds{_lbl()} {time.time() - t0:.3f}')
    return "\n".join(lines) + "\n"


def refresher():
    global _payload
    while True:
        try:
            text = build_metrics()
        except Exception as e:
            text = f'longevity_k8s_scrape_success{_lbl()} 0\n# fatal: {_esc(e)}\n'
        with _lock:
            _payload = text
        time.sleep(REFRESH_SEC)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        with _lock:
            body = _payload.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    if not KUBECONFIG:
        raise SystemExit("ERROR: set KUBECONFIG")
    threading.Thread(target=refresher, daemon=True).start()
    time.sleep(1)
    print(f"serving pod metrics at http://{LISTEN}/metrics (cluster={CLUSTER}, ns={NS})")
    HTTPServer((_HOST, _PORT), Handler).serve_forever()
