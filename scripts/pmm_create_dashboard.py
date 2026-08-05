#!/usr/bin/env python3
"""Create/refresh a native PMM (Grafana) dashboard for longevity benchmarking.

Uses the Grafana HTTP API (PMM is Grafana under /graph) + the service-account
token to push a curated dashboard into a dedicated folder. Panels query the
VictoriaMetrics datasource with PromQL and are driven by a SINGLE `cluster`
template variable: pick a cluster and every panel (MySQL, GR, node, pods)
filters to it. Works for all clusters (incl. the 6-cluster matrix).

Env:
  PMM_HOST        default 138.197.18.113
  PMM_TOKEN       required (glsa_ service-account token)
  CLUSTER_DEFAULT default selected cluster (default longevity-am-n3)
  FOLDER_TITLE    default "Longevity Benchmarking"

Usage:
  PMM_TOKEN=glsa_xxx python3 scripts/pmm_create_dashboard.py
"""
import json
import os
import ssl
import sys
import urllib.request

PMM_HOST = os.environ.get("PMM_HOST", "138.197.18.113")
PMM_TOKEN = os.environ.get("PMM_TOKEN", "")
CLUSTER_DEFAULT = os.environ.get("CLUSTER_DEFAULT", "longevity-am-n3")
FOLDER_TITLE = os.environ.get("FOLDER_TITLE", "Longevity Benchmarking")
FOLDER_UID = os.environ.get("FOLDER_UID", "longevity-bench")
DASH_UID = os.environ.get("DASH_UID", "longevity-bench-main")
DASH_TITLE = os.environ.get("DASH_TITLE", "Longevity Benchmark — MySQL / GR / Node")

if not PMM_TOKEN:
    sys.exit("ERROR: set PMM_TOKEN")

_SSL = ssl.create_default_context()
_SSL.check_hostname = False
_SSL.verify_mode = ssl.CERT_NONE
BASE = f"https://{PMM_HOST}/graph/api"


def api(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BASE + path, data=data, method=method,
                                 headers={"Authorization": f"Bearer {PMM_TOKEN}",
                                          "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, context=_SSL, timeout=30) as r:
            return r.status, json.load(r)
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


def datasource_uid():
    _, ds = api("GET", "/datasources")
    for d in ds:
        if d.get("type") == "prometheus":
            return d["uid"]
    sys.exit("no prometheus datasource found")


DS = datasource_uid()
DSREF = {"type": "prometheus", "uid": DS}

# panel spec: (title, unit, [(expr, legend), ...])
# ONE cluster filter drives everything: the k8s cluster name (e.g. longevity-am-n3)
# maps to the PMM service/node prefix percona-<cluster>-*, so we derive both from $cluster.
S = 'service_name=~"percona-$cluster.*"'
N = 'node_name=~"percona-$cluster.*"'
PANELS = [
    ("QPS (queries/s)", "short",
     [(f"sum by (service_name) (rate(mysql_global_status_queries{{{S}}}[$__rate_interval]))", "{{service_name}}")]),
    ("TPS (commits/s)", "short",
     [(f'sum by (service_name) (rate(mysql_global_status_commands_total{{{S},command="commit"}}[$__rate_interval]))', "{{service_name}}")]),
    ("Threads Running", "short",
     [(f"mysql_global_status_threads_running{{{S}}}", "{{service_name}}")]),
    # Open client connections per node. On GR the client load lands on the PRIMARY,
    # so its series tracks the sysbench --threads value (secondaries stay ~5).
    # (Threads Running stays low here because the load is rate-capped: Little's Law.)
    ("Threads Connected", "short",
     [(f"mysql_global_status_threads_connected{{{S}}}", "{{service_name}}")]),
    ("InnoDB Row Ops/s (by type)", "short",
     [(f"sum by (operation) (rate(mysql_global_status_innodb_row_ops_total{{{S}}}[$__rate_interval]))", "{{operation}}")]),
    ("InnoDB History List Length", "short",
     [(f"max by (service_name) (mysql_info_schema_innodb_metrics_transaction_trx_rseg_history_len{{{S}}})", "{{service_name}}")]),
    ("Row Lock Waits/s", "short",
     [(f"sum by (service_name) (rate(mysql_global_status_innodb_row_lock_waits{{{S}}}[$__rate_interval]))", "{{service_name}}")]),
    ("GR Members ONLINE", "short",
     [(f'count(mysql_perf_schema_replication_group_member_info{{{S},member_state="ONLINE"}})', "online members")]),
    ("GR Replication Lag (applier queue)", "short",
     [(f"max by (service_name) (mysql_perf_schema_transactions_remote_in_applier_queue{{{S}}})", "{{service_name}}")]),
    ("GR Flow Control Active", "short",
     [(f"max by (service_name) (mysql_global_status_group_replication_flow_control_active{{{S}}})", "{{service_name}}")]),
    ("CPU Utilisation %", "percent",
     [(f'100 * (1 - avg by (node_name) (rate(node_cpu_seconds_total{{{N},mode="idle"}}[$__rate_interval])))', "{{node_name}}")]),
    ("Memory Used %", "percent",
     [(f"100 * (1 - sum by (node_name)(node_memory_MemAvailable_bytes{{{N}}}) / sum by (node_name)(node_memory_MemTotal_bytes{{{N}}}))", "{{node_name}}")]),
    # Disk busy = fraction of wall-clock the busiest device spent doing I/O.
    # Use max (not sum) across devices so it stays a clean 0-100% saturation gauge
    # (summing sda+vda+vdb can exceed 100 and hides which disk is the bottleneck).
    ("Disk Busy % (max device = saturation)", "percent",
     [(f"100 * max by (node_name) (rate(node_disk_io_time_seconds_total{{{N}}}[$__rate_interval]))", "{{node_name}}")]),
    ("Disk Throughput (read/write)", "MBs",
     [(f"sum by (node_name) (rate(node_disk_read_bytes_total{{{N}}}[$__rate_interval])) / 1048576", "read {{node_name}}"),
      (f"sum by (node_name) (rate(node_disk_written_bytes_total{{{N}}}[$__rate_interval])) / 1048576", "write {{node_name}}")]),
    ("Disk IOPS (read/write)", "iops",
     [(f"sum by (node_name) (rate(node_disk_reads_completed_total{{{N}}}[$__rate_interval]))", "read {{node_name}}"),
      (f"sum by (node_name) (rate(node_disk_writes_completed_total{{{N}}}[$__rate_interval]))", "write {{node_name}}")]),
    ("Avg Query Latency (server-side)", "s",
     [(f"sum by (service_name) (rate(mysql_perf_schema_events_statements_latency_sum{{{S}}}[$__rate_interval])) "
       f"/ clamp_min(sum by (service_name) (rate(mysql_perf_schema_events_statements_latency_count{{{S}}}[$__rate_interval])), 1)",
       "{{service_name}}")]),
    ("Network Traffic", "MBs",
     [(f"sum by (node_name) (rate(node_network_receive_bytes_total{{{N}}}[$__rate_interval])) / 1048576", "rx {{node_name}}"),
      (f"sum by (node_name) (rate(node_network_transmit_bytes_total{{{N}}}[$__rate_interval])) / 1048576", "tx {{node_name}}")]),
    ("Binlog Size (disk growth)", "decmbytes",
     [(f"sum by (service_name) (mysql_binlog_size_bytes{{{S}}}) / 1048576", "{{service_name}}")]),
    ("Buffer Pool Dirty Pages %", "percent",
     [(f"100 * sum by (service_name) (mysql_global_status_buffer_pool_dirty_pages{{{S}}}) "
       f'/ clamp_min(sum by (service_name) (mysql_global_status_buffer_pool_pages{{{S},state="total"}}), 1)',
       "{{service_name}}")]),
    ("Aborted Connections/s (errors)", "short",
     [(f"sum by (service_name) (rate(mysql_global_status_aborted_connects{{{S}}}[$__rate_interval]))", "{{service_name}}")]),
]

# Kubernetes / pod-level panels (fed by k8s_pod_exporter -> vmagent -> PMM).
# These use the $cluster variable and the custom longevity_k8s_* metrics.
C = 'cluster=~"$cluster"'
POD_PANELS = [
    ("Container Restarts (step up = restart)", "short",
     [(f"longevity_k8s_container_restarts_total{{{C}}}", "{{pod}}/{{container}}")]),
    ("Pods Ready vs Total", "short",
     [(f"sum(longevity_k8s_pod_ready{{{C}}})", "ready"),
      (f"count(longevity_k8s_pod_ready{{{C}}})", "total")]),
    ("Pods by Phase", "short",
     [(f"longevity_k8s_pods_total{{{C}}}", "{{phase}}")]),
    ("Containers Not Ready", "short",
     [(f"count(longevity_k8s_container_ready{{{C}}}) - sum(longevity_k8s_container_ready{{{C}}})", "not ready")]),
    ("Containers Waiting (CrashLoop etc.)", "short",
     [(f"longevity_k8s_container_waiting{{{C}}}", "{{pod}}/{{container}} {{reason}}")]),
    ("Last Termination Reason (OOMKilled/Error)", "short",
     [(f"longevity_k8s_container_last_terminated{{{C}}}", "{{pod}}/{{container}} {{reason}}")]),
    ("Operator Log Errors (tail window)", "short",
     [(f"longevity_k8s_operator_log_errors{{{C}}}", "errors")]),
    ("Pod Exporter Scrape Health", "short",
     [(f"longevity_k8s_scrape_success{{{C}}}", "success (1=ok)"),
      (f"longevity_k8s_scrape_duration_seconds{{{C}}}", "duration s")]),
]

# Sidecar memory panels (fed by k8s_pod_exporter container_memory_bytes).
SIDECAR_PANELS = [
    ("Sidecar Memory — mysqld-exporter (limit 256Mi)", "decmbytes",
     [(f'longevity_k8s_container_memory_bytes{{{C},container="mysqld-exporter"}} / 1048576', "{{pod}}")]),
    ("Sidecar Memory — slow-log-tailer (limit 32Mi)", "decmbytes",
     [(f'longevity_k8s_container_memory_bytes{{{C},container="slow-log-tailer"}} / 1048576', "{{pod}}")]),
    ("Sidecar Memory — pmm-client (no limit)", "decmbytes",
     [(f'longevity_k8s_container_memory_bytes{{{C},container="pmm-client"}} / 1048576', "{{pod}}")]),
    ("Sidecar Memory — xtrabackup (no limit)", "decmbytes",
     [(f'longevity_k8s_container_memory_bytes{{{C},container="xtrabackup"}} / 1048576', "{{pod}}")]),
    ("MySQL Container Memory (limit ~13.6Gi)", "decmbytes",
     [(f'longevity_k8s_container_memory_bytes{{{C},container="mysql"}} / 1048576', "{{pod}}")]),
    ("All Sidecar Memory Combined (excl mysql)", "decmbytes",
     [(f'sum by (pod) (longevity_k8s_container_memory_bytes{{{C},container!="mysql"}}) / 1048576', "{{pod}}")]),
]

# build panels with 3-per-row layout; K8s section starts on a fresh row
W, H, COLS = 8, 8, 3
panels = []


def _row_panel(title, y):
    return {"type": "row", "title": title, "collapsed": False,
            "gridPos": {"h": 1, "w": 24, "x": 0, "y": y}, "panels": []}


def _add_section(specs, start_id, y0):
    for i, (title, unit, targets) in enumerate(specs):
        x = (i % COLS) * W
        y = y0 + (i // COLS) * H
        panels.append({
            "id": start_id + i,
            "type": "timeseries",
            "title": title,
            "datasource": DSREF,
            "gridPos": {"h": H, "w": W, "x": x, "y": y},
            "fieldConfig": {"defaults": {"unit": unit, "custom": {"drawStyle": "line",
                            "lineWidth": 1, "fillOpacity": 8, "showPoints": "never"}}, "overrides": []},
            "options": {"legend": {"displayMode": "list", "placement": "bottom"},
                        "tooltip": {"mode": "multi", "sort": "desc"}},
            "targets": [{"expr": e, "legendFormat": lf, "refId": chr(65 + j), "datasource": DSREF}
                        for j, (e, lf) in enumerate(targets)],
        })
    rows_used = (len(specs) + COLS - 1) // COLS
    return y0 + rows_used * H


panels.append(_row_panel("MySQL / Group Replication / Node", 0))
next_y = _add_section(PANELS, 1, 1)
panels.append(_row_panel("Kubernetes / Pods", next_y))
next_y = _add_section(POD_PANELS, 101, next_y + 1)
panels.append(_row_panel("Sidecar Container Memory", next_y))
_add_section(SIDECAR_PANELS, 201, next_y + 1)


def cluster_var(default_val):
    """Single-select cluster picker — the one and only filter for the whole dashboard."""
    return {
        "name": "cluster", "label": "Cluster", "type": "query", "datasource": DSREF,
        "definition": "label_values(longevity_k8s_scrape_success, cluster)",
        "query": {"query": "label_values(longevity_k8s_scrape_success, cluster)",
                  "refId": "StandardVariableQuery"},
        "includeAll": False, "multi": False, "refresh": 2, "sort": 1, "regex": "",
        "current": {"text": default_val, "value": default_val},
    }


dashboard = {
    "uid": DASH_UID,
    "title": DASH_TITLE,
    "tags": ["longevity", "benchmark", "mysql", "group-replication"],
    "timezone": "browser",
    "schemaVersion": 39,
    "refresh": "10s",
    "time": {"from": "now-6h", "to": "now"},
    "templating": {"list": [
        cluster_var(CLUSTER_DEFAULT),
    ]},
    "panels": panels,
}

# ensure folder
st, r = api("POST", "/folders", {"uid": FOLDER_UID, "title": FOLDER_TITLE})
if st in (200, 201):
    print(f"folder created: {FOLDER_TITLE}")
elif st in (409, 412):
    print(f"folder exists: {FOLDER_TITLE}")
else:
    print(f"folder resp {st}: {r}")

st, r = api("POST", "/dashboards/db", {"dashboard": dashboard, "folderUid": FOLDER_UID, "overwrite": True})
if st in (200, 201):
    print(f"DASHBOARD OK -> https://{PMM_HOST}{r.get('url')}")
else:
    print(f"ERROR {st}: {json.dumps(r)}")
    sys.exit(1)
