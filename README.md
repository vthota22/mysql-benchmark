# mysql-benchmark

Harnesses, automation, and a control UI for measuring DigitalOcean Managed MySQL (Standard and Advanced) under realistic load.

The repo drives **sysbench TPC-C** against cluster VIPs, injects failover (and later backup/scaling) events on dedicated benchmark droplets, records time-series and KPI CSVs, and generates HTML reports. GitHub Actions schedules runs over SSH; an App Platform control UI browses results and can start failover runs interactively. Primary branch for automation is `main`.

| Area | Status |
|------|--------|
| Failover benchmarking | Live (harness + CI + UI) |
| Backup benchmarking | Live (harness + CI) |
| Scaling benchmarking | Live (harness + CI) |
| Control UI | Live on App Platform |
| GitHub Actions | Failover, backup, and scaling daily workflows live |

---

## Failover benchmarking

Failover runs apply continuous TPC-C load through the Advanced VIP while monitors watch client connectivity, Group Replication, pods, and HAProxy. At a configured wall time the harness triggers either an **unplanned** failover (for example primary pod delete) or a **planned** failover (`set_as_primary`), then keeps load running through recovery. KPIs such as time-to-detect, time-to-promote, RTO, and failed transactions are derived from monitor and sysbench timeseries and written under `results/failover_<timestamp>/`, with HTML reports per failover type. Entry point: `./run_failover_benchmark.sh` (config in `benchmark.conf`). Deeper methodology: [docs/FAILOVER_BENCHMARK_METHODOLOGY.md](docs/FAILOVER_BENCHMARK_METHODOLOGY.md).

---

## Backup benchmarking

Harness lives under `backup-benchmarking/`: run TPC-C while optionally profiling in-cluster backups (xtrabackup timing, pod resources, schedule patching).

- Entry: `backup-benchmarking/run_benchmark.sh` (config: `backup-benchmarking/benchmark.conf`)
- Droplet ctl: `scripts/backup_run_ctl.sh`
- CI: daily GHA via `scripts/ci_backup_benchmark.sh` (see Automated benchmarking below)
- Report: `backup_benchmark_report.html` + `benchmark_with_backup_status.csv` under each `results/run_*`

---

## Scaling benchmarking

Harness lives under `scaling-benchmarking/`: run TPC-C while triggering a DO Managed MySQL resize mid-test, then parse timeseries and optional K8s/write-probe metrics.

- Entry: `scaling-benchmarking/run_benchmark.sh` (config: `scaling-benchmarking/benchmark.conf`)
- Droplet ctl: `scripts/scaling_run_ctl.sh`
- CI: daily GHA via `scripts/ci_scaling_benchmark.sh` (see Automated benchmarking below)

---

## Viewing automated test reports

Automated and manually started runs land as HTML reports on the benchmark droplets. Browse them in the control UI:

**[Benchmark run reports](https://benchmarking-controller-drouo.ondigitalocean.app/#reports)**

Open the **Benchmark run reports** tab to list runs on the active droplet (SSH over the App Platform backend). Failover reports are labeled by mode (for example Unplanned failover / Planned failover). Use the **Feature** picker for Backup / Scaling when those result trees exist. Local UI docs: [ui/README.md](ui/README.md).

---

## Automated benchmarking (GitHub Actions)

GitHub Actions is the scheduler only. Each workflow builds a droplet matrix, then SSHes into each host and runs the feature CI script against the gitignored `benchmark.conf` already on that droplet.

```text
GitHub Actions (cron / workflow_dispatch)
        │
        ├─ prepare  → build droplet matrix JSON from repo variables
        │
        └─ matrix   → one job per droplet (fail-fast: false)
                        SSH → git sync → ci_*_benchmark.sh → *_run_ctl.sh → harness
                        results/ on droplet → browsable in control UI
```

### Workflows

| Workflow | File | Schedule | CI script | Notes |
|----------|------|----------|-----------|--------|
| Failover Benchmark (daily) | `.github/workflows/failover-benchmark-daily.yml` | `0 6 * * *` (+ manual) | `scripts/ci_failover_benchmark.sh` | Live |
| Scaling Benchmark (daily) | `.github/workflows/scaling-benchmark-daily.yml` | `0 8 * * *` (+ manual) | `scripts/ci_scaling_benchmark.sh` | Live |
| Backup Benchmark (daily) | `.github/workflows/backup-benchmark-daily.yml` | `0 10 * * *` (+ manual) | `scripts/ci_backup_benchmark.sh` | Live |

### Jobs (each workflow)

1. **`prepare`** — Parses the feature droplet map into a JSON matrix (`name` / `host`). Failover uses `BENCHMARK_DROPLET_MAP`; scaling prefers `SCALING_DROPLET_MAP` (fallback to failover map); backup prefers `BACKUP_DROPLET_MAP`.
2. **Matrix run job** — One parallel job per droplet. Syncs the configured branch (default `main`), runs the CI orchestrator, and leaves artifacts under that droplet’s `results/` tree. Concurrency groups wait for in-progress runs (`cancel-in-progress: false`).

Manual runs: **Actions → workflow → Run workflow**. Failover/scaling/backup dispatch can optionally pin a git branch and a single droplet name from the map.

### Required Actions configuration

| Kind | Name | Purpose |
|------|------|---------|
| Secret | `BENCHMARK_SSH_PRIVATE_KEY` | SSH access to all benchmark droplets |
| Variable | `BENCHMARK_DROPLET_MAP` | `name:host` pairs for failover (and map fallback) |
| Variable | `BENCHMARK_REMOTE_REPO` | Repo path on droplet (e.g. `/root/mysql-benchmark`) |
| Variable (optional) | `SCALING_DROPLET_MAP` / `BACKUP_DROPLET_MAP` | Feature-specific maps |
| Variable (optional) | `BENCHMARK_DROPLET_GIT_BRANCH` | Default branch sync (`main`) |

**Scaling droplet prerequisites:** `scaling-benchmarking/benchmark.conf` on the host (from `benchmark.conf.example`) with `CLUSTER_ID`, `DO_API_TOKEN`, and DB connection details. Harness entry: `scaling-benchmarking/run_benchmark.sh` via `scripts/scaling_run_ctl.sh`.

**Backup droplet prerequisites:** `backup-benchmarking/benchmark.conf` on the host (from `benchmark.conf.example`) with MySQL connection details; for profiling set `KUBECONFIG_PATH` / `KUBE_NAMESPACE` (and optional backup schedule fields). Harness entry: `backup-benchmarking/run_benchmark.sh` via `scripts/backup_run_ctl.sh`.

Droplet bootstrap: [bootstrap/README.md](bootstrap/README.md).
