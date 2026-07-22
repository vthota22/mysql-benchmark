# mysql-benchmark

Harnesses, automation, and a control UI for measuring DigitalOcean Managed MySQL (Standard and Advanced) under realistic load.

The repo drives **sysbench TPC-C** against cluster VIPs, injects failover (and later backup/scaling) events on dedicated benchmark droplets, records time-series and KPI CSVs, and generates HTML reports. GitHub Actions schedules runs over SSH; an App Platform control UI browses results and can start failover runs interactively. Primary branch for automation is `main`.

| Area | Status |
|------|--------|
| Failover benchmarking | Live (harness + CI + UI) |
| Backup benchmarking | Planned / stubbed |
| Scaling benchmarking | Planned / stubbed |
| Control UI | Live on App Platform |
| GitHub Actions | Failover live; backup & scaling workflows present as stubs |

---

## Failover benchmarking

Failover runs apply continuous TPC-C load through the Advanced VIP while monitors watch client connectivity, Group Replication, pods, and HAProxy. At a configured wall time the harness triggers either an **unplanned** failover (for example primary pod delete) or a **planned** failover (`set_as_primary`), then keeps load running through recovery. KPIs such as time-to-detect, time-to-promote, RTO, and failed transactions are derived from monitor and sysbench timeseries and written under `results/failover_<timestamp>/`, with HTML reports per failover type. Entry point: `./run_failover_benchmark.sh` (config in `benchmark.conf`). Deeper methodology: [docs/FAILOVER_BENCHMARK_METHODOLOGY.md](docs/FAILOVER_BENCHMARK_METHODOLOGY.md).

---

## Backup benchmarking

*To be updated.*

Backup workload measurement, harness layout, KPIs, and report paths will be documented here once the backup feature branch is merged and CI is unstubbed. Workflow stub: `.github/workflows/backup-benchmark-daily.yml`. Multi-feature plan: [docs/MULTI_FEATURE_AUTOMATION_PLAN.md](docs/MULTI_FEATURE_AUTOMATION_PLAN.md).

---

## Scaling benchmarking

*To be updated.*

Scaling / resize workload measurement, harness layout, KPIs, and report paths will be documented here once the scaling feature branch is merged and CI is unstubbed. Workflow stub: `.github/workflows/scaling-benchmark-daily.yml`. Multi-feature plan: [docs/MULTI_FEATURE_AUTOMATION_PLAN.md](docs/MULTI_FEATURE_AUTOMATION_PLAN.md).

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
| Failover Benchmark (every 3h) | `.github/workflows/failover-benchmark-daily.yml` | `0 */3 * * *` (+ manual) | `scripts/ci_failover_benchmark.sh` | Live |
| Backup Benchmark (every 3h) | `.github/workflows/backup-benchmark-daily.yml` | `0 */3 * * *` (+ manual) | `scripts/ci_backup_benchmark.sh` | Stub (exits 0) |
| Scaling Benchmark (every 3h) | `.github/workflows/scaling-benchmark-daily.yml` | `0 */3 * * *` (+ manual) | `scripts/ci_scaling_benchmark.sh` | Stub (exits 0) |

### Jobs (each workflow)

1. **`prepare`** — Parses the feature droplet map into a JSON matrix (`name` / `host`). Failover uses `BENCHMARK_DROPLET_MAP`; backup/scaling prefer `BACKUP_DROPLET_MAP` / `SCALING_DROPLET_MAP` with fallback to the failover map.
2. **Matrix run job** — One parallel job per droplet. Syncs the configured branch (default `main`), runs the CI orchestrator, and leaves artifacts under that droplet’s `results/` tree. Concurrency groups wait for in-progress runs (`cancel-in-progress: false`).

Manual runs: **Actions → workflow → Run workflow**. Failover dispatch can optionally pin a git branch and a single droplet name from the map.

### Required Actions configuration

| Kind | Name | Purpose |
|------|------|---------|
| Secret | `BENCHMARK_SSH_PRIVATE_KEY` | SSH access to all benchmark droplets |
| Variable | `BENCHMARK_DROPLET_MAP` | `name:host` pairs for failover (and map fallback) |
| Variable | `BENCHMARK_REMOTE_REPO` | Repo path on droplet (e.g. `/root/mysql-benchmark`) |
| Variable (optional) | `BACKUP_DROPLET_MAP` / `SCALING_DROPLET_MAP` | Feature-specific maps |
| Variable (optional) | `BENCHMARK_DROPLET_GIT_BRANCH` | Default branch sync (`main`) |

Droplet bootstrap: [bootstrap/README.md](bootstrap/README.md).
