"""Failover settings exposed in the local control UI."""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class FieldSpec:
    key: str
    label: str
    field_type: str  # text | number | select | checkbox
    help_text: str = ""
    options: tuple[str, ...] = ()
    section: str = "General"
    default: str = ""


FAILOVER_FIELDS: tuple[FieldSpec, ...] = (
    FieldSpec(
        "ADVANCED_MYSQL_HOST",
        "MySQL hostname",
        "text",
        "Advanced cluster endpoint (port 3306, user doadmin, database benchmark)",
        section="Advanced database",
    ),
    FieldSpec(
        "ADVANCED_MYSQL_PASSWORD",
        "MySQL password",
        "password",
        section="Advanced database",
    ),
    FieldSpec(
        "FAILOVER_SCENARIOS",
        "Scenarios",
        "text",
        'Default "mixed write_only"; use "mixed" only to skip write_only',
        section="Run matrix",
    ),
    FieldSpec(
        "FAILOVER_THREAD_MATRIX",
        "Thread matrix",
        "text",
        "Space-separated thread counts (empty = single FAILOVER_THREADS run)",
        section="Run matrix",
    ),
    FieldSpec("FAILOVER_THREADS", "Threads", "number", "Client concurrency when thread matrix is empty", section="Run matrix"),
    FieldSpec("FAILOVER_THREAD_DELAY_SEC", "Delay between thread counts (s)", "number", section="Run matrix"),
    FieldSpec("FAILOVER_SCENARIO_DELAY_SEC", "Delay between scenarios (s)", "number", section="Run matrix"),
    FieldSpec(
        "FAILOVER_ITERATIONS",
        "Back-to-back failover iterations",
        "number",
        "Repeat the full scenario loop N times; one combined report at end",
        section="Run matrix",
        default="1",
    ),
    FieldSpec(
        "FAILOVER_ITERATION_DELAY_SEC",
        "Delay between iterations (s)",
        "number",
        "Pause between back-to-back failovers for cluster recovery",
        section="Run matrix",
        default="120",
    ),
    FieldSpec("SKIP_PREPARE", "Skip TPC-C prepare", "checkbox", "1 = skip if tables already exist", section="Run matrix"),
    FieldSpec("FAILOVER_WARMUP_SEC", "Warmup (s)", "number", section="Timeline"),
    FieldSpec("FAILOVER_BASELINE_SEC", "Baseline before trigger (s)", "number", section="Timeline"),
    FieldSpec("FAILOVER_OBSERVE_SEC", "Observe after trigger (s)", "number", section="Timeline"),
    FieldSpec(
        "FAILOVER_TRIGGER_SECOND",
        "Trigger second override",
        "number",
        "Leave empty for warmup + baseline",
        section="Timeline",
    ),
    FieldSpec("FAILOVER_REPORT_INTERVAL", "Sysbench report interval (s)", "number", section="Timeline"),
    FieldSpec("FAILOVER_TRIGGER_ENABLED", "Enable failover trigger", "checkbox", section="Trigger"),
    FieldSpec(
        "FAILOVER_POD_DELETE",
        "Advanced: pod delete / API trigger",
        "checkbox",
        "0 = load-only control run",
        section="Trigger",
    ),
    FieldSpec(
        "FAILOVER_ADVANCED_TRIGGER_METHOD",
        "Trigger method",
        "select",
        options=("pod_delete", "mysqld_kill"),
        section="Trigger",
    ),
    FieldSpec("FAILOVER_POD_DELETE_FORCE", "Pod delete: force", "checkbox", section="Trigger"),
    FieldSpec("FAILOVER_POD_DELETE_GRACE_SEC", "Pod delete: grace period (s)", "number", section="Trigger"),
    FieldSpec("FAILOVER_MYSQLD_KILL_SIGNAL", "mysqld_kill signal", "number", section="Trigger"),
    FieldSpec("FAILOVER_TRIGGER_PREPARE_SEC", "Prepare kubeconfig before trigger (s)", "number", section="Trigger"),
    FieldSpec(
        "FAILOVER_REPLICA_WORKERS_GATE",
        "Replica workers gate (Advanced)",
        "checkbox",
        "SET PERSIST replica_parallel_workers on all pods before each iteration",
        section="Trigger",
    ),
    FieldSpec(
        "FAILOVER_REPLICA_PARALLEL_WORKERS",
        "Target replica_parallel_workers",
        "number",
        section="Trigger",
    ),
    FieldSpec(
        "FAILOVER_REPLICA_WORKERS_TIMEOUT_SEC",
        "Replica workers gate timeout (s)",
        "number",
        section="Trigger",
    ),
    FieldSpec("ADVANCED_CLUSTER_UUID", "Cluster UUID", "text", section="Cluster targets"),
    FieldSpec("ADVANCED_K8S_NAMESPACE", "K8s namespace", "text", section="Cluster targets"),
    FieldSpec(
        "ADVANCED_KUBECONFIG_PATH",
        "Advanced kubeconfig path (on droplet)",
        "text",
        section="Cluster targets",
    ),
    FieldSpec(
        "ADVANCED_PSMYSQL_CR_NAME",
        "Percona CR name (Advanced)",
        "text",
        "PerconaServerMySQL resource name, e.g. benchmark-failover2",
        section="HAProxy",
    ),
    FieldSpec(
        "HAPROXY_HEALTH_CHECK_INTERVAL_SEC",
        "HAProxy health check interval (s)",
        "number",
        "Backend check inter: 2–10 seconds (Percona default 10 → inter 10000 ms)",
        section="HAProxy",
        default="10",
    ),
    FieldSpec(
        "HAPROXY_HEALTH_CHECK_RISE",
        "HAProxy rise (good checks)",
        "number",
        "Consecutive good checks before backend up (Percona default 1)",
        section="HAProxy",
        default="1",
    ),
    FieldSpec(
        "HAPROXY_HEALTH_CHECK_FALL",
        "HAProxy fall (failed checks)",
        "number",
        "Consecutive failed checks before backend down (Percona default 2)",
        section="HAProxy",
        default="2",
    ),
    FieldSpec(
        "HAPROXY_APPLY_BEFORE_FAILOVER",
        "Apply HAProxy settings before run",
        "checkbox",
        "Patch Percona CR before Advanced failover benchmark starts",
        section="HAProxy",
        default="1",
    ),
    FieldSpec(
        "HAPROXY_APPLY_WAIT_SEC",
        "Wait for HAProxy reconcile (s)",
        "number",
        section="HAProxy",
        default="90",
    ),
    FieldSpec("FAILOVER_MONITOR_PRIMARY", "Monitor primary topology", "checkbox", section="Monitoring"),
    FieldSpec("FAILOVER_MONITOR_WRITE_PROBE", "Monitor write probe", "checkbox", section="Monitoring"),
    FieldSpec(
        "FAILOVER_PRIMARY_MONITOR_INTERVAL",
        "Primary (VIP) monitor interval (s)",
        "number",
        section="Monitoring",
        default="0.25",
    ),
    FieldSpec(
        "FAILOVER_CLUSTER_MONITOR_INTERVAL",
        "GR + K8s monitor interval (s)",
        "number",
        section="Monitoring",
        default="1",
    ),
    FieldSpec(
        "FAILOVER_MONITOR_INTERVAL",
        "Legacy monitor interval fallback (s)",
        "number",
        section="Monitoring",
        default="1",
    ),
    FieldSpec("FAILOVER_MONITOR_CONNECT_TIMEOUT", "Monitor connect timeout (s)", "number", section="Monitoring"),
    FieldSpec("FAILOVER_MONITOR_OP_TIMEOUT", "Monitor op timeout (s)", "number", section="Monitoring"),
    FieldSpec("FAILOVER_GR_POD_MONITOR", "GR pod monitor (Advanced)", "checkbox", section="Monitoring"),
    FieldSpec(
        "FAILOVER_HAPROXY_STATS_MONITOR",
        "HAProxy stats monitor (Advanced)",
        "checkbox",
        section="Monitoring",
        default="1",
    ),
    FieldSpec(
        "FAILOVER_HAPROXY_STATS_MONITOR_INTERVAL",
        "HAProxy stats poll interval (s)",
        "number",
        section="Monitoring",
        default="0.5",
    ),
    FieldSpec("FAILOVER_COLLECT_K8S_EVENTS", "Collect K8s events", "checkbox", section="Monitoring"),
    FieldSpec("FAILOVER_RUN_TPCC_CHECK", "Run TPC-C check after failover", "checkbox", section="Monitoring"),
    FieldSpec("FAILOVER_GENERATE_GRAPHS", "Generate graphs / HTML report", "checkbox", section="Monitoring"),
    FieldSpec("FAILOVER_RECOVERY_THRESHOLD", "RTO recovery threshold (0–1)", "text", section="RTO analysis"),
    FieldSpec("FAILOVER_RECOVERY_STABLE_SEC", "RTO stable seconds", "number", section="RTO analysis"),
    FieldSpec("FAILOVER_OUTAGE_TPS_RATIO", "Outage TPS ratio", "text", section="RTO analysis"),
    FieldSpec(
        "FAILOVER_MYSQL_IGNORE_ERRORS",
        "MySQL ignore errors",
        "text",
        "Comma-separated sysbench reconnect error codes",
        section="RTO analysis",
    ),
)

FAILOVER_KEYS: tuple[str, ...] = tuple(field.key for field in FAILOVER_FIELDS)

ADVANCED_CREDENTIAL_KEYS: frozenset[str] = frozenset(
    {
        "ADVANCED_MYSQL_HOST",
        "ADVANCED_MYSQL_PASSWORD",
    }
)

# Fixed Advanced MySQL settings (not editable in the UI).
ADVANCED_MYSQL_CONSTANTS: dict[str, str] = {
    "ADVANCED_MYSQL_PORT": "3306",
    "ADVANCED_MYSQL_USER": "doadmin",
    "ADVANCED_MYSQL_DB": "benchmark",
}

INSERT_MARKER = "# --- Failover benchmark ---"
ADVANCED_INSERT_MARKER = "# --- Advanced Edition"

# Always advanced-only in the control UI (Standard edition not exposed).
UI_CONTROL_DEFAULTS: dict[str, str] = {
    "FAILOVER_EDITIONS": "advanced",
}


def apply_config_defaults(values: dict[str, str]) -> dict[str, str]:
    """Fill empty keys with UI/schema defaults (e.g. Percona HAProxy defaults)."""
    out = dict(values)
    for key, default in UI_CONTROL_DEFAULTS.items():
        if not out.get(key, "").strip():
            out[key] = default
    for field in FAILOVER_FIELDS:
        if field.default and not out.get(field.key, "").strip():
            out[field.key] = field.default
    return out


def estimate_runtime_sec(values: dict[str, str]) -> int:
    def _int(key: str, default: int) -> int:
        raw = values.get(key, "").strip()
        if not raw:
            return default
        try:
            return int(raw)
        except ValueError:
            return default

    warmup = _int("FAILOVER_WARMUP_SEC", 300)
    baseline = _int("FAILOVER_BASELINE_SEC", 300)
    observe = _int("FAILOVER_OBSERVE_SEC", 600)
    per_scenario = warmup + baseline + observe

    scenarios = values.get("FAILOVER_SCENARIOS", "mixed write_only").split()
    scenario_count = max(len(scenarios), 1)
    scenario_delay = _int("FAILOVER_SCENARIO_DELAY_SEC", 120)

    matrix_raw = values.get("FAILOVER_THREAD_MATRIX", "").strip()
    thread_runs = len(matrix_raw.split()) if matrix_raw else 1
    thread_delay = _int("FAILOVER_THREAD_DELAY_SEC", 120)

    iterations = max(_int("FAILOVER_ITERATIONS", 1), 1)
    iteration_delay = _int("FAILOVER_ITERATION_DELAY_SEC", 120)

    editions = values.get("FAILOVER_EDITIONS", "advanced").split()
    edition_count = max(len(editions), 1)

    per_edition = iterations * thread_runs * scenario_count * per_scenario
    per_edition += max(0, thread_runs - 1) * iterations * thread_delay
    per_edition += max(0, scenario_count - 1) * thread_runs * iterations * scenario_delay
    per_edition += max(0, iterations - 1) * iteration_delay

    return per_edition * edition_count


# --- TPC-C data load (prepare) tab ---

PREPARE_FIELDS: tuple[FieldSpec, ...] = (
    FieldSpec("DROPLET_NAME", "Droplet name", "text", "Label for this benchmark host", section="Droplet"),
    FieldSpec("DROPLET_HOST", "Droplet IP / hostname", "text", section="Droplet"),
    FieldSpec("DROPLET_USER", "SSH user", "text", section="Droplet", default="root"),
    FieldSpec("DROPLET_SSH_PORT", "SSH port", "number", section="Droplet", default="22"),
    FieldSpec(
        "REMOTE_REPO",
        "Repo path on droplet",
        "text",
        "Where mysql-benchmark is installed",
        section="Droplet",
        default="/root/mysql-benchmark",
    ),
    FieldSpec("MYSQL_HOST", "MySQL hostname", "text", "Port 3306, user doadmin, database benchmark", section="Advanced database"),
    FieldSpec("MYSQL_PASSWORD", "MySQL password", "password", section="Advanced database"),
    FieldSpec("TPCC_TABLES", "TPCC tables", "number", section="Dataset", default="10"),
    FieldSpec("TPCC_SCALE", "TPCC scale (warehouses)", "number", section="Dataset", default="100"),
    FieldSpec("PREP_THREADS", "Prepare threads", "number", section="Dataset", default="16"),
    FieldSpec(
        "TPCC_FORCE_PK",
        "Force primary keys",
        "checkbox",
        "Required for DO Advanced (sql_require_primary_key)",
        section="Dataset",
        default="1",
    ),
)

PREPARE_KEYS: tuple[str, ...] = tuple(field.key for field in PREPARE_FIELDS)


def tpcc_data_size_gb(tables: int, scale: int) -> float:
    return tables * scale * 0.1


def tpcc_data_size_label(tables: int, scale: int) -> str:
    gb = tpcc_data_size_gb(tables, scale)
    label = f"~{int(gb)} GB" if gb == int(gb) else f"~{gb:.1f} GB"
    return f"{label} (tables={tables}, scale={scale})"


def estimate_prepare_runtime_sec(values: dict[str, str]) -> int:
    """Rough prepare duration from dataset size (matches tpcc_approx_data_size_label in bash)."""
    try:
        tables = max(int(values.get("TPCC_TABLES", "10") or "10"), 1)
        scale = max(int(values.get("TPCC_SCALE", "100") or "100"), 1)
    except ValueError:
        return 45 * 60
    gb = tpcc_data_size_gb(tables, scale)
    # ~5 min floor; ~45–90 min at ~100 GB
    minutes = max(5, min(120, round(5 + gb * 0.75)))
    return minutes * 60


def prepare_estimate_payload(values: dict[str, str]) -> dict:
    try:
        tables = max(int(values.get("TPCC_TABLES", "10") or "10"), 1)
        scale = max(int(values.get("TPCC_SCALE", "100") or "100"), 1)
    except ValueError:
        tables, scale = 10, 100
    return {
        "estimated_prepare_sec": estimate_prepare_runtime_sec(values),
        "data_size_label": tpcc_data_size_label(tables, scale),
        "data_size_gb": round(tpcc_data_size_gb(tables, scale), 2),
    }


def build_prepare_job_conf(values: dict[str, str]) -> str:
    """Minimal benchmark.conf for a one-off TPC-C prepare job (Advanced edition)."""
    prefix = "ADVANCED"

    def _line(key: str, val: str) -> str:
        escaped = val.replace("\\", "\\\\").replace('"', '\\"')
        return f'{key}="{escaped}"'

    lines = [
        "# TPC-C prepare job — generated by control UI",
        "# Edition: advanced",
        "",
        _line(f"{prefix}_MYSQL_HOST", values.get("MYSQL_HOST", "")),
        _line(f"{prefix}_MYSQL_PORT", ADVANCED_MYSQL_CONSTANTS["ADVANCED_MYSQL_PORT"]),
        _line(f"{prefix}_MYSQL_USER", ADVANCED_MYSQL_CONSTANTS["ADVANCED_MYSQL_USER"]),
        _line(f"{prefix}_MYSQL_PASSWORD", values.get("MYSQL_PASSWORD", "")),
        _line(f"{prefix}_MYSQL_DB", ADVANCED_MYSQL_CONSTANTS["ADVANCED_MYSQL_DB"]),
        "",
        _line("TPCC_TABLES", values.get("TPCC_TABLES", "10")),
        _line("TPCC_SCALE", values.get("TPCC_SCALE", "100")),
        _line("PREP_THREADS", values.get("PREP_THREADS", "16")),
        _line("TPCC_FORCE_PK", values.get("TPCC_FORCE_PK", "1")),
        _line("TPCC_TRX_LEVEL", "RR"),
    ]
    return "\n".join(lines) + "\n"
