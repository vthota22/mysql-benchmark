"""Feature profiles for the control UI (failover now; backup/scaling later)."""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class FeatureProfile:
    id: str
    label: str
    results_glob_prefix: str
    primary_report_suffix: str
    ctl_script: str
    conf_relative: str
    enabled: bool = True


FEATURES: dict[str, FeatureProfile] = {
    "failover": FeatureProfile(
        id="failover",
        label="Failover",
        results_glob_prefix="results/failover_",
        primary_report_suffix="advanced/graphs/failover_report.html",
        ctl_script="scripts/failover_run_ctl.sh",
        conf_relative="benchmark.conf",
        enabled=True,
    ),
    # Stubs — enable after harness merge + ctl wrappers exist on droplets.
    "backup": FeatureProfile(
        id="backup",
        label="Backup",
        results_glob_prefix="backup-benchmarking/results/run_",
        primary_report_suffix="backup_benchmark_report.html",
        ctl_script="scripts/backup_run_ctl.sh",
        conf_relative="backup-benchmarking/benchmark.conf",
        enabled=False,
    ),
    "scaling": FeatureProfile(
        id="scaling",
        label="Scaling",
        results_glob_prefix="scaling-benchmarking/results/run_",
        primary_report_suffix="scaling_report.html",
        ctl_script="scripts/scaling_run_ctl.sh",
        conf_relative="scaling-benchmarking/benchmark.conf",
        enabled=False,
    ),
}


def active_feature(feature_id: str | None = None) -> FeatureProfile:
    fid = (feature_id or "failover").strip().lower() or "failover"
    profile = FEATURES.get(fid) or FEATURES["failover"]
    if not profile.enabled and fid != "failover":
        return FEATURES["failover"]
    return profile


def features_payload() -> list[dict]:
    return [
        {
            "id": f.id,
            "label": f.label,
            "enabled": f.enabled,
            "results_glob_prefix": f.results_glob_prefix,
        }
        for f in FEATURES.values()
    ]
