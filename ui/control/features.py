"""Feature profiles for the control UI (failover, backup, scaling)."""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class FeatureProfile:
    id: str
    label: str
    results_glob_prefix: str
    primary_report_suffix: str
    report_html_name: str
    ctl_script: str
    conf_relative: str
    # Directory under remote repo that holds run_* / failover_* folders.
    results_parent: str
    # Shell glob for run directories (relative to results_parent basename find -name).
    run_dir_name_glob: str
    # Regex for run directory names (timestamp capture groups 1=date, 2=time).
    run_id_regex: str
    enabled: bool = True
    # Option A: backup/scaling are browse-only until ctl wrappers are real.
    can_start: bool = True
    can_configure: bool = True
    can_compare: bool = True
    can_prepare: bool = True
    # How Benchmark run reports discovers runs: ctl list | find on disk.
    list_mode: str = "ctl"


FEATURES: dict[str, FeatureProfile] = {
    "failover": FeatureProfile(
        id="failover",
        label="Failover",
        results_glob_prefix="results/failover_",
        primary_report_suffix="advanced/graphs/failover_report.html",
        report_html_name="failover_report.html",
        ctl_script="scripts/failover_run_ctl.sh",
        conf_relative="benchmark.conf",
        results_parent="results",
        run_dir_name_glob="failover_*",
        run_id_regex=r"^failover_(\d{8})_(\d{6})$",
        enabled=True,
        can_start=True,
        can_configure=True,
        can_compare=True,
        can_prepare=True,
        list_mode="ctl",
    ),
    "backup": FeatureProfile(
        id="backup",
        label="Backup",
        results_glob_prefix="backup-benchmarking/results/run_",
        primary_report_suffix="backup_benchmark_report.html",
        report_html_name="backup_benchmark_report.html",
        ctl_script="scripts/backup_run_ctl.sh",
        conf_relative="backup-benchmarking/benchmark.conf",
        results_parent="backup-benchmarking/results",
        run_dir_name_glob="run_*",
        run_id_regex=r"^run_(\d{8})_(\d{6})(?:_.*)?$",
        enabled=True,
        can_start=False,
        can_configure=False,
        can_compare=False,
        can_prepare=False,
        list_mode="find",
    ),
    "scaling": FeatureProfile(
        id="scaling",
        label="Scaling",
        results_glob_prefix="scaling-benchmarking/results/run_",
        primary_report_suffix="scaling_report.html",
        report_html_name="scaling_report.html",
        ctl_script="scripts/scaling_run_ctl.sh",
        conf_relative="scaling-benchmarking/benchmark.conf",
        results_parent="scaling-benchmarking/results",
        run_dir_name_glob="run_*",
        run_id_regex=r"^run_(\d{8})_(\d{6})(?:_.*)?$",
        enabled=True,
        can_start=False,
        can_configure=False,
        can_compare=False,
        can_prepare=False,
        list_mode="find",
    ),
}


def resolve_feature(feature_id: str | None = None) -> FeatureProfile:
    """Return an enabled feature profile; default failover."""
    fid = (feature_id or "failover").strip().lower() or "failover"
    profile = FEATURES.get(fid)
    if profile is None or not profile.enabled:
        raise ValueError(f"Unknown or disabled feature: {fid}")
    return profile


def active_feature(feature_id: str | None = None) -> FeatureProfile:
    """Resolve feature; fall back to failover if id is missing/disabled."""
    try:
        return resolve_feature(feature_id)
    except ValueError:
        return FEATURES["failover"]


def features_payload() -> list[dict]:
    return [
        {
            "id": f.id,
            "label": f.label,
            "enabled": f.enabled,
            "can_start": f.can_start,
            "can_configure": f.can_configure,
            "can_compare": f.can_compare,
            "can_prepare": f.can_prepare,
            "results_glob_prefix": f.results_glob_prefix,
            "conf_relative": f.conf_relative,
        }
        for f in FEATURES.values()
    ]
