# Failover Benchmark Methodology

How Advanced failover runs are executed, what is monitored in the foreground, and how KPIs (TTD, time-to-promote, promotion breakdown) are computed.

Entry point: `./run_failover_benchmark.sh` (config from `benchmark.conf`).

---

## 1. High-level run flow

```text
prepare / gates
    → start VIP primary monitor (+ watchers)
    → start sysbench TPC-C load (warmup + baseline + observe wall)
    → Advanced: prepare trigger (kubeconfig, primary pod)
    → start cluster monitors (GR pods, K8s pods, HAProxy stats)
    → sleep until near trigger second
    → refresh primary (+ promote target if planned)
    → replica workers gate + GR readiness gate
    → fire trigger (record FAILOVER_TRIGGER_EPOCH)
    → observe FAILOVER_OBSERVE_SEC
    → stop load / monitors
    → analyze KPIs, promotion breakdown, HTML report
```

Default timeline (seconds of sysbench wall after workers start):

| Phase | Config | Role |
|-------|--------|------|
| Warmup | `FAILOVER_WARMUP_SEC` (often 300) | Load ramp; stats often disabled in sysbench |
| Baseline | `FAILOVER_BASELINE_SEC` (e.g. 120) | Steady load before trigger |
| Trigger | warmup + baseline (or override) | Failover action fires |
| Observe | `FAILOVER_OBSERVE_SEC` (e.g. 240) | Keep load running while cluster recovers |

Optional matrices nest results under `iterN/`, trigger method (`pod_delete` / `set_as_primary`), and `tN/` thread counts.

---

## 2. Foreground load (sysbench TPC-C)

- Binary: repo `sysbench-1.1` + `TPCC/sysbench-tpcc`.
- Target: Advanced VIP (`ADVANCED_MYSQL_HOST`), database `benchmark`.
- Continuous run covering warmup + baseline + observe (`--time` / wall aligned by harness).
- Per-second TPS/QPS/latency/err/reconn → `sysbench_run.log` → `failover_timeseries.csv`.
- Reconnect through failover errors via `FAILOVER_MYSQL_IGNORE_ERRORS`.

Sysbench ready time is recorded as `SYSBENCH_READY_EPOCH` in `sysbench_timing.txt`. All “wall seconds” for KPIs are relative to that epoch unless noted.

---

## 3. Monitors

Monitors run as background processes writing TSVs under the scenario directory. They do **not** drive the failover; they observe the client VIP and (Advanced) the K8s/GR/HAProxy path.

### 3.1 Primary (VIP) monitor — `primary_monitor.tsv`

| | |
|--|--|
| **When** | Started with failover watchers (before / with load) |
| **Path** | Client → DO VIP → HAProxy → MySQL (same path as app/sysbench) |
| **Interval** | `FAILOVER_PRIMARY_MONITOR_INTERVAL` (default **0.25s** fixed grid) |
| **Timeouts** | Connect / op default **1s** each (a poll can take up to ~1s; overruns skip grid ticks) |
| **Per tick** | One mysql session: optional write probe `INSERT` + topology (`@@hostname`, `read_only`, GR role/state) |

Columns used heavily in KPIs:

- `connect_ok` — TCP/MySQL session succeeded
- `write_ok` — write probe succeeded
- `hostname` — which mysql pod the VIP landed on
- `gr_member_role` / `gr_member_state` — as seen **through the VIP**

### 3.2 GR pod monitor — `gr_pod_monitor.tsv`

| | |
|--|--|
| **When** | After Advanced trigger **prepare** (kubeconfig available) |
| **Path** | `kubectl exec` into each `mysql-*` pod (bypasses VIP) |
| **Interval** | `FAILOVER_CLUSTER_MONITOR_INTERVAL` (default **1s**) |
| **What** | Per-pod connect, GR role/state, cert/applier queues, etc. |

Used for internal GR view and lag context; election timing prefers mysqld logs when available.

### 3.3 K8s pods monitor — `k8s_pods_monitor.tsv`

| | |
|--|--|
| **When** | With Advanced cluster monitors |
| **What** | `mysql-*` phase, ready containers, restarts, deleting |
| **Interval** | Same cluster monitor interval (~1s) |

Also used by the **GR readiness gate** (expected member count + pods Ready).

### 3.4 HAProxy stats monitor — `haproxy_stats_monitor.tsv`

| | |
|--|--|
| **When** | With Advanced cluster monitors |
| **What** | `show stat` on each HAProxy pod for backend `mysql-primary` |
| **Interval** | `FAILOVER_HAPROXY_STATS_MONITOR_INTERVAL` (default **0.5s**) |
| **What we record** | Per-server `UP` / `DOWN` / `UP 1/2`, etc. |

Used to mark when the **new** primary’s backend becomes UP (not when the old one goes DOWN).

### 3.5 Other artifacts (snapshots, not continuous)

- K8s events, operator logs, mysqld GR election log snippets
- Parsed into `gr_election_internal.env`, `haproxy_primary_up.env`, etc.

---

## 4. Trigger timing: `FAILOVER_TRIGGER_EPOCH`

At **fire**, `trigger_failover.sh` writes:

```text
FAILOVER_TRIGGER_EPOCH=<unix time.time() with ms>
FAILOVER_TRIGGER_UTC=...
```

Recorded **immediately before** the action (`kubectl delete`, mysqld kill, or `group_replication_set_as_primary`).

KPI wall alignment:

```text
wall_trigger = FAILOVER_TRIGGER_EPOCH − SYSBENCH_READY_EPOCH
```

So “after trigger” means after this fire timestamp, not the planned integer sleep second alone.

### Advanced trigger methods

| Method | Action |
|--------|--------|
| `pod_delete` | Force/grace delete current primary pod (unplanned) |
| `mysqld_kill` | `kill` mysqld in primary container (unplanned) |
| `mysqld_freeze` | Node cgroup freeze of mysql container — GR UNREACHABLE/expel path (unplanned) |
| `set_as_primary` | Planned: `group_replication_set_as_primary` on a SECONDARY |

Matrix runs (`FAILOVER_TRIGGER_MATRIX`) export the method per subdirectory; `trigger_failover.sh` preserves that override across `benchmark.conf` load.

### Pre-trigger gates (Advanced)

1. **Replica workers gate** — `replica_parallel_workers` on all pods  
2. **GR readiness gate** — expected ONLINE members (default 3) + mysql pods Ready; abort on timeout by default  

---

## 5. Core KPI definitions

Stored in `failover_kpi.csv` / HTML report. Times in **seconds from trigger** unless noted.

### 5.1 Unplanned (`pod_delete` / `mysqld_kill` / `mysqld_freeze`)

| KPI | Column | Definition |
|-----|--------|------------|
| **TTD** (time to detect) | `failure_detection_sec` | First `primary_monitor` sample with `connect_ok=0` **at/after** `wall_trigger` (within `FAILOVER_DETECT_WINDOW_SEC`, default 60). Default `FAILOVER_DETECT_GUARD_SEC=0` (no pre-trigger clamp). |
| **TTP** (time to promote) | `primary_election_sec` | From that first `connect_ok=0` to first VIP sample that is: `connect_ok=1`, `write_ok=1`, GR PRIMARY, and **hostname ≠ primary_before**. |
| **Total failover** | `total_failover_sec` | Trigger → that same promote end (`≈ TTD + TTP`). |

```text
|-- TTD --|------------ TTP (promote) ------------|
trigger   first connect_ok=0              new PRIMARY + write_ok on VIP
```

### 5.2 Planned (`set_as_primary`)

| KPI | Definition |
|-----|------------|
| **TTD** | **N/A** (no “failure detection” in the unplanned sense) |
| **TTP / total** | Write-path gap: first `write_ok=0` or `connect_ok=0` after trigger → new PRIMARY hostname + `write_ok=1`. **0** if primary moved with no unhealthy samples in the short planned window (`FAILOVER_PLANNED_DETECT_WINDOW_SEC`, default 10). |

### 5.3 Application RTO

| KPI | Definition |
|-----|------------|
| `app_recovery_sec` | From trigger until sysbench TPS ≥ `FAILOVER_RECOVERY_THRESHOLD` × baseline for `FAILOVER_RECOVERY_STABLE_SEC` consecutive seconds (defaults 0.90 / 30s). |

Other columns (errors, latency peak, TPS dip duration, write probe fails) are derived from timeseries / monitor over the outage→recovery window; see `benchmark.conf.example`.

---

## 6. Time-to-promote breakdown

File: `failover_promotion_breakdown.txt` (+ `.csv`).

**Promote total** (same as unplanned TTP):

```text
promote_total = write_ok_rel − TTD
```

where `write_ok_rel` is the promote-end sample on the VIP monitor.

That window is split into three phases (sum ≈ promote total):

### 6.1 GR election after TTD

**What:** Internal Group Replication elected a new PRIMARY.

**Source (preferred):** mysqld logs → `gr_election_internal.env` (`GR_ELECTION_FROM_TRIGGER_SEC`, pod).  
**Fallback:** first PRIMARY+ONLINE on `gr_pod_monitor.tsv` (direct pod exec).

**Duration shown:**

```text
promote_gr_wait = max(0, gr_elect − TTD)
```

(0 if GR already elected before the client saw `connect_ok=0`.)

### 6.2 HAProxy routable

**What:** The **new** primary’s server in HAProxy backend `mysql-primary` is **UP** (stats socket).

**Source:** `haproxy_stats_monitor.tsv` → `haproxy_primary_up.env`  
(Prefer DOWN→UP on the elected pod’s server after GR election.)

**Duration shown:**

```text
ha_start = max(gr_elect, TTD)
promote_ha_route = ha_end − ha_start    # ha_end = stats UP time
```

**Not** “old primary DOWN” and **not** exclusive routing. With `check inter 2000 rise 1 fall 2`, the new backend can be UP while the old is still UP; traffic may still hit the old primary until it fails `fall` checks / loses non-backup status.

### 6.3 Client path restore

**What:** After HA marks the new backend UP, the **client VIP** path accepts writes on the new primary.

**Source:** `primary_monitor.tsv` promote-end sample.

**Duration shown:**

```text
client_start = max(ha_end, ha_start)   # usually HA UP time
promote_client_restore = write_ok_rel − client_start
```

So this is **HA UP → VIP write_ok**, not “leftover from TTD to write_ok” (that leftover is the whole promote total).

### 6.4 Example (unplanned iter)

```text
trigger 0.00
TTD     1.04     first VIP connect_ok=0
GR      1.99     mysqld elects new PRIMARY     → GR after TTD = 0.95
HA UP   3.19     new server UP in mysql-primary → HA after TTD = 1.20
write   3.54     VIP hostname new + write_ok=1  → client restore = 0.34

TTP = 2.50 = 0.95 + 1.20 + 0.34
total = 3.54 = TTD + TTP
```

---

## 7. How analysis is produced

At end of each scenario (and via `./reanalyze_failover.sh <results_dir>`):

1. Parse sysbench log → timeseries  
2. `write_failover_kpi` — TTD / TTP / total / RTO / …  
3. `write_failover_promotion_breakdown` — three-phase split + detail rows  
4. `scripts/generate_failover_graphs.py` — HTML report (and optional PNGs)

Reanalyze **does not** re-fire failover; it recomputes KPIs from existing monitor/log files. Changing TTD logic (e.g. detect guard) shifts the TTD/TTP split; **total** often stays the same if promote-end is unchanged.

---

## 8. Key result files

| File | Role |
|------|------|
| `full_run.log` | Harness stdout |
| `sysbench_run.log` / `failover_timeseries.csv` | Load metrics |
| `primary_monitor.tsv` | VIP path for TTD / TTP end |
| `gr_pod_monitor.tsv` | Per-pod GR |
| `k8s_pods_monitor.tsv` | Pod readiness |
| `haproxy_stats_monitor.tsv` | Backend UP/DOWN |
| `failover_event.txt` | Trigger method, epoch, target pod |
| `primary_change.env` | PRIMARY_BEFORE / AFTER |
| `failover_kpi.csv` | Rollup KPIs |
| `failover_promotion_breakdown.txt` | Promote split |
| `graphs/failover_report.html` | Human-readable report |

Control UI serves reports from the droplet under `/reports/...`.

---

## 9. Related config knobs

| Knob | Default / notes |
|------|-----------------|
| `FAILOVER_PRIMARY_MONITOR_INTERVAL` | 0.25s VIP poll grid |
| `FAILOVER_MONITOR_CONNECT_TIMEOUT` / `OP_TIMEOUT` | 1s |
| `FAILOVER_DETECT_WINDOW_SEC` | 60 (unplanned TTD search) |
| `FAILOVER_DETECT_GUARD_SEC` | **0** (TTD strictly at/after trigger epoch) |
| `FAILOVER_PLANNED_DETECT_WINDOW_SEC` | 10 |
| `FAILOVER_GR_EXPECTED_MEMBERS` | 3 |
| `FAILOVER_GR_REQUIRE_K8S_PODS_READY` | 1 |
| `HAPROXY_HEALTH_CHECK_INTERVAL_SEC` / `RISE` / `FALL` | Applied to CR; affects HA UP / old DOWN timing |

See `benchmark.conf.example` for the full list.
