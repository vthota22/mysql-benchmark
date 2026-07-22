# Plan: Automate backup + scaling benchmarks alongside failover

Extend the current GitHub Actions failover automation on `main` to also run **backup** and **scaling** benchmarks after merging their feature branches.

---

## Overall architecture (post-merge)

```text
                    GitHub Actions (scheduler only)
        ┌──────────────────┬──────────────────┬──────────────────┐
        │ Failover WF      │ Backup WF        │ Scaling WF       │
        │ cron 0 */3       │ cron 0 */3       │ cron 0 */3       │  (all every 3h; stubs for backup/scaling)
        └────────┬─────────┴────────┬─────────┴────────┬─────────┘
                 │                  │                  │
                 │  SSH (secret)    │                  │
                 ▼                  ▼                  ▼
           ┌──────────────────────────────────────────────┐
           │  Droplet(s)  /root/mysql-benchmark           │
           │  ci_* → *_run_ctl.sh → feature harness       │
           │  results/  (failover_*, backup run_*, …)     │
           └───────────────────────┬──────────────────────┘
                                   │ SSH :2222
                                   ▼
                         App Platform control UI
                         (browse reports live)
```

| Layer | Failover (live) | Backup / Scaling (after merge) |
|-------|-----------------|--------------------------------|
| Workflow | `failover-benchmark-daily.yml` | `backup-benchmark-daily.yml` / `scaling-benchmark-daily.yml` (live; every 3h) |
| CI orchestrator | `scripts/ci_failover_benchmark.sh` | `ci_backup_benchmark.sh` / `ci_scaling_benchmark.sh` (**stubs exit 0**) |
| Droplet ctl | `scripts/failover_run_ctl.sh` | `backup_run_ctl.sh` / `scaling_run_ctl.sh` (**stubs**) |
| Harness | `run_failover_benchmark.sh` | `backup-benchmarking/run_benchmark.sh` / `scaling-benchmarking/run_benchmark.sh` |
| Conf on droplet | root `benchmark.conf` | feature subdir `benchmark.conf` |
| UI | App Platform reads droplet `results/` | Same pattern once paths are wired |

**Stubs / workflows on `main`:**

- `scripts/ci_backup_benchmark.sh`, `scripts/ci_scaling_benchmark.sh` — exit **0** immediately (write `stub_status.env`)
- `scripts/backup_run_ctl.sh`, `scripts/scaling_run_ctl.sh` — ctl stubs for post-merge wiring
- `.github/workflows/backup-benchmark-daily.yml`, `scaling-benchmark-daily.yml` — cron `0 */3 * * *` (same as failover)

After feature merge: replace stub CI with real SSH orchestration (clone failover CI); keep the workflows.

---

## How many GHA jobs?

Each workflow has:

1. **`prepare`** — 1 job (build droplet matrix JSON)
2. **matrix job** — **1 job per droplet** in that feature’s map (`fail-fast: false`)

### Per trigger (one workflow fire)

| Map size | Jobs this workflow |
|----------|--------------------|
| 1 droplet | 1 prepare + 1 matrix = **2** |
| 2 droplets (e.g. high2 + multi) | 1 + 2 = **3** |
| 3 droplets | 1 + 3 = **4** |

### All three features enabled (recommended: separate maps + staggered cron)

Example fleet:

- Failover map: `high2`, `multi` (2)
- Backup map: `multi` (1)
- Scaling map: `high2` (1)

| When | Failover jobs | Backup jobs | Scaling jobs | **Total GHA jobs** |
|------|---------------|-------------|--------------|--------------------|
| One failover cron tick | 3 | — | — | **3** |
| One backup cron tick | — | 2 | — | **2** |
| One scaling cron tick | — | — | 2 | **2** |
| Worst overlap (all fire same hour) | 3 | 2 | 2 | **7** |

**Per calendar day** (all three every 3h = 8 triggers each; example maps above):

| Workflow | Cron | Triggers/day | Jobs/trigger | Jobs/day |
|----------|------|--------------|--------------|----------|
| Failover | `0 */3 * * *` | 8 | 3 (2 droplets) | **24** |
| Backup (stub) | `0 */3 * * *` | 8 | 2 (1 droplet) | **16** |
| Scaling (stub) | `0 */3 * * *` | 8 | 2 (1 droplet) | **16** |
| **Total** | | | | **~56** |

Backup/scaling jobs are cheap while stubs (seconds). After real harnesses land, expect long matrix jobs again — consider staggering crons then.

Notes:

- Matrix jobs on the **same droplet name** use concurrency groups (`failover-high2-…`, `backup-multi-…`) so a second fire **waits**, it does not kill the in-progress run.
- Avoid putting the **same cluster** in failover + scaling maps at the same time unless intentional.
- App Platform is **not** a GHA job count — it only SSHs to droplets to show reports.

---

## Goal

| Feature | Branch today | Target on `main` |
|---------|--------------|--------------------|
| Failover | `main` (done) | Keep current GHA every 3h |
| Backup | `origin/backup-benchmarking` | Merge + automate like failover |
| Scaling | `origin/added-scale-benchmarking` | Merge + automate like failover |

**Pattern to reuse:** GHA matrix → SSH orchestrator (`ci_*.sh`) → `*_run_ctl.sh` → harness → fetch HTML/KPI artifacts.

---

## Feasibility

**Yes — possible.** Backup and scaling already look like sibling harnesses (own `benchmark.conf`, `results/`, HTML reports). They lack the CI control layer failover already has.

| Concern | Failover (`main`) | Backup / Scaling (other branches) |
|---------|---------------------|-----------------------------------|
| Entrypoint | `run_failover_benchmark.sh` | `*/run_benchmark.sh` |
| Config | root `benchmark.conf` | `backup-benchmarking/benchmark.conf`, `scaling-benchmarking/benchmark.conf` |
| Results | `results/failover_<ts>/` | `*/results/run_<ts>_…/` |
| HTML report | yes | yes |
| `*_run_ctl` start/status | yes | **missing** |
| `ci_*` + GHA workflow | yes | **missing** |

Sources of truth for merge:

- **Backup:** `origin/backup-benchmarking` → `backup-benchmarking/`
- **Scaling:** `origin/added-scale-benchmarking` → `scaling-benchmarking/` (prefer this tip; newer than backup branch’s scale tree)

Same SSH secret / droplet map model can be reused; each feature keeps its **own** conf on the droplet (not shared root `benchmark.conf`).

---

## Effort estimate

| Phase | Scope | Effort |
|-------|--------|--------|
| **A. Merge into `main`** | Bring in both subdirs; resolve conflicts in shared root scripts | **1–2 days** |
| **B. CTL wrappers** | `backup_run_ctl.sh` / `scaling_run_ctl.sh` | **0.5–1 day** |
| **C. CI orchestrators** | Clone `ci_failover_benchmark.sh` per feature | **1–2 days** |
| **D. Workflows** | New workflows or one multi-feature workflow | **0.5–1 day** |
| **E. Secrets / droplet readiness** | Feature confs, kubeconfig, DO token, smoke runs | **1–3 days** |
| **F. (Optional) UI** | Control UI tabs for backup/scaling | **+2–5 days** |

| Delivery level | Calendar effort |
|----------------|-----------------|
| **MVP** (automate both, no UI) | ~**3–5 engineering days** after a clean merge |
| **Production-like** (schedules, maps, secrets, flake fixes) | ~**1–2 weeks** |

Scaling is heavier (DigitalOcean resize API + optional k8s monitor + larger report stack).

---

## Change list

### 1. Merge branches into `main`

- [ ] Merge or cherry-pick `backup-benchmarking/` from `origin/backup-benchmarking`
- [ ] Merge or cherry-pick `scaling-benchmarking/` from `origin/added-scale-benchmarking`
- [ ] Resolve conflicts in shared root scripts (`bootstrap/setup_benchmark.sh`, `run_tpcc.sh`, TPCC patches, etc.)
- [ ] Keep feature confs **gitignored** per droplet; commit only `*.example`
- [ ] Sync target droplets to `main` after merge

### 2. Add ctl wrappers (mirror failover)

- [ ] Add `scripts/backup_run_ctl.sh` — start/status for `backup-benchmarking/run_benchmark.sh`
- [ ] Add `scripts/scaling_run_ctl.sh` — start/status for `scaling-benchmarking/run_benchmark.sh`
- [ ] Lock files + completion markers (same idea as `=== Failover benchmark complete ===`)
- [ ] Emit stable `results_dir=` on start so CI tracks the exact run

### 3. Add CI SSH scripts

- [ ] Add `scripts/ci_backup_benchmark.sh`
- [ ] Add `scripts/ci_scaling_benchmark.sh`

Reuse failover structure:

1. Preflight (SSH, repo, conf, scripts)
2. Git sync (skip if run in progress)
3. Start or attach via ctl
4. Poll until complete
5. SCP HTML / KPI / logs into `ci-artifacts/`

Adapt per feature: working directory, conf path, result glob, artifact names, completion grep.

### 4. Add / extend GitHub Actions

Choose one:

| Option | Description |
|--------|-------------|
| **A (simplest)** | Three workflows: failover / backup / scaling — each with its own cron + droplet map |
| **B** | One workflow with `feature: failover\|backup\|scaling\|all` + separate schedules |

- [ ] Implement chosen option under `.github/workflows/`
- [ ] Stagger schedules so jobs do not stampede the same droplet/cluster (failover already every 3h)
- [ ] Upload artifacts with clear names (`backup-report-<droplet>-<run_id>`, etc.)

### 5. GitHub configuration

| Item | Notes |
|------|--------|
| Reuse `BENCHMARK_SSH_PRIVATE_KEY` | Same private key; public key on all droplets |
| `BACKUP_DROPLET_MAP` / `SCALING_DROPLET_MAP` (or one map + feature filter) | Which hosts run which job |
| `BENCHMARK_REMOTE_REPO` | Usually `/root/mysql-benchmark` |
| Scaling secret: `DO_API_TOKEN` (+ doctl on droplet) | Required for mid-run resize |
| Per-droplet feature `benchmark.conf` | Hosts, kubeconfig, sizes, durations — **never** commit |

### 6. Droplet prerequisites (per feature)

- [ ] Repo on `main` with both feature subdirs present
- [ ] Feature `benchmark.conf` filled in under the subdir
- [ ] Valid kubeconfig where backup profiler / scaling k8s paths need it
- [ ] Scaling: doctl installed and authenticated (or token available to the harness)
- [ ] Avoid overlapping destructive runs on the same cluster unless intentional

### 7. Docs / ops

- [ ] Extend `docs/FAILOVER_BENCHMARK_FILES.md` (or rename) to cover all three features
- [ ] Document schedules, maps, and “don’t run failover + scale on the same cluster at once”
- [ ] Note artifact locations in Actions vs on-droplet `results/`

### 8. Optional later

- [ ] Control UI tabs for backup / scaling
- [ ] Shared generic `ci_remote_benchmark.sh` parameterized by feature (less duplication)
- [ ] KPI regression gates on uploaded artifacts

---

## Recommended sequence

1. **Merge code** into `main`; prove manual `run_benchmark.sh` for backup and scaling on at least one droplet each.
2. Add **ctl + `ci_*` + workflow** for **backup** first (closest clone of failover CI).
3. Repeat for **scaling** (extra DO / k8s secrets and readiness).
4. Unify or stagger schedules and droplet maps once both are green.

---

## Risks

| Risk | Mitigation |
|------|------------|
| Merge conflicts in shared setup / TPC-C scripts | Merge early; smoke-test failover after merge |
| Scaling DO API / doctl missing on droplet | Add secret + install/auth check in CI preflight |
| Schedule collisions on shared droplets | Separate maps and/or staggered crons; per-droplet concurrency |
| Feature conf drift vs failover root conf | Document clearly; keep confs in feature subdirs |
| Long runtimes vs cron interval | Keep `cancel-in-progress: false`; size cron to worst-case duration |

---

## Bottom line

Merging is straightforward. Automation is **medium effort**: port the existing failover GHA wrapper layer (`ctl` → `ci_*` → workflow), do not rewrite the backup/scaling harnesses. Biggest work is merge hygiene, scaling’s DO dependency, and schedule/capacity planning on shared droplets.
