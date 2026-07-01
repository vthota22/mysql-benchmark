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


FAILOVER_FIELDS: tuple[FieldSpec, ...] = (
    FieldSpec(
        "FAILOVER_EDITIONS",
        "Editions",
        "text",
        'Space-separated: "standard", "advanced", or both',
        section="Run matrix",
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
        "FAILOVER_STANDARD_TRIGGER_METHOD",
        "Standard trigger method",
        "select",
        options=("power_off", "install_update", "storage_resize", "manual"),
        section="Trigger",
    ),
    FieldSpec(
        "FAILOVER_ADVANCED_TRIGGER_METHOD",
        "Advanced trigger method",
        "select",
        options=("pod_delete", "mysqld_kill"),
        section="Trigger",
    ),
    FieldSpec("FAILOVER_POD_DELETE_FORCE", "Pod delete: force", "checkbox", section="Trigger"),
    FieldSpec("FAILOVER_POD_DELETE_GRACE_SEC", "Pod delete: grace period (s)", "number", section="Trigger"),
    FieldSpec("FAILOVER_MYSQLD_KILL_SIGNAL", "mysqld_kill signal", "number", section="Trigger"),
    FieldSpec("FAILOVER_TRIGGER_PREPARE_SEC", "Prepare kubeconfig before trigger (s)", "number", section="Trigger"),
    FieldSpec("STANDARD_CLUSTER_UUID", "Standard cluster UUID", "text", section="Cluster targets"),
    FieldSpec("ADVANCED_CLUSTER_UUID", "Advanced cluster UUID", "text", section="Cluster targets"),
    FieldSpec("ADVANCED_K8S_NAMESPACE", "Advanced K8s namespace", "text", section="Cluster targets"),
    FieldSpec(
        "ADVANCED_KUBECONFIG_PATH",
        "Advanced kubeconfig path (on droplet)",
        "text",
        section="Cluster targets",
    ),
    FieldSpec("FAILOVER_MONITOR_PRIMARY", "Monitor primary topology", "checkbox", section="Monitoring"),
    FieldSpec("FAILOVER_MONITOR_WRITE_PROBE", "Monitor write probe", "checkbox", section="Monitoring"),
    FieldSpec("FAILOVER_MONITOR_INTERVAL", "Monitor poll interval (s)", "number", section="Monitoring"),
    FieldSpec("FAILOVER_MONITOR_CONNECT_TIMEOUT", "Monitor connect timeout (s)", "number", section="Monitoring"),
    FieldSpec("FAILOVER_MONITOR_OP_TIMEOUT", "Monitor op timeout (s)", "number", section="Monitoring"),
    FieldSpec("FAILOVER_GR_POD_MONITOR", "GR pod monitor (Advanced)", "checkbox", section="Monitoring"),
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

INSERT_MARKER = "# --- Failover benchmark ---"


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

    editions = values.get("FAILOVER_EDITIONS", "standard advanced").split()
    edition_count = max(len(editions), 1)

    per_edition = thread_runs * scenario_count * per_scenario
    per_edition += max(0, thread_runs - 1) * thread_delay
    per_edition += max(0, scenario_count - 1) * thread_runs * scenario_delay

    return per_edition * edition_count
