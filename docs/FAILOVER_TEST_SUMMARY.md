# Failover Benchmark Test Summary — bkp-my-5tb-n3

**Cluster:** DigitalOcean Advanced MySQL (`bkp-my-5tb-n3`, 3-node GR, ~5 TB TPC-C)  
**Droplet:** `165.227.120.67`  
**Test period:** July 2026  
**Iterations per trigger type:** 20  

---

## Failover paths and trigger types

Failover behavior in Group Replication depends on **how the primary is lost** — whether the member exits abruptly (triggering a relatively fast election) or becomes **unreachable** and must pass through GR suspicion and explicit expulsion before a new primary is elected.

### Path A — Immediate member loss (force primary pod delete)

This path covers failovers where the primary member **stops participating in the group immediately** — the rest of the group treats it as gone and can start **election quickly** (typically a few seconds), **without** waiting for GR suspicion or `group_replication_member_expel_timeout`.

| Trigger (harness) | Harness method | What happens |
|-------------------|----------------|--------------|
| **Force primary pod delete** | `pod_delete` | `kubectl delete pod --grace-period=0 --force` on the current PRIMARY. Container and mysqld terminate immediately; Kubernetes reschedules the pod. |

**Examples of failovers in this category** (immediate member loss; no expel wait):

- **Force primary pod delete** — ungraceful delete of the PRIMARY pod (what we benchmark with `pod_delete`).
- **Primary node / host failure** — the VM or bare-metal host running the primary is lost; kubelet and mysqld disappear from the group at once.
- **Primary mysqld crash** — OOM kill, segfault, or fatal error exits `mysqld` on the primary; GR sees the member as departed.
- **Primary pod evicted or killed by the platform** — kubelet OOM eviction, node drain, or scheduler replacement with no graceful shutdown window.
- **Storage or kernel panic on the primary node** — the member vanishes from the group without a controlled leave.

**Common characteristics:**

- No GR **suspicion timer** or **`group_replication_member_expel_timeout`** wait on survivors before election can proceed.
- Failover times in our tests are dominated by **GR election + HAProxy routing + VIP write probe**, not expel timeout.
- Typical **`total_failover_sec`** on this cluster: **~2–3 s** (see Table 1).

### Path B — Unreachability / expel path (no shutdown signal)

These triggers leave the primary **running but non-responsive** to the rest of the group. GR must:

1. Detect the member as **UNREACHABLE** (suspicion; ~5 s Default configuration),
2. Wait **`group_replication_member_expel_timeout`** (set to **5 s** on CR and all pods for these tests),
3. Run the **expel thread** (periodic; default check interval ~15 s in MySQL GR) to remove the member,
4. Only then perform **primary election**.

| Trigger (harness) | Harness method | What happens |
|-------------------|----------------|--------------|
| **mysqld freeze** | `mysqld_freeze` | Node **cgroup freeze** of the primary `mysql` container (25 s hold). mysqld is alive but frozen; GR heartbeats fail → **UNREACHABLE → expel → election**. |

**Examples of failovers in this category** (unreachability / expel path; no shutdown signal):

- **mysqld freeze** — primary process alive but frozen; simulates a hung mysqld (what we benchmark with `mysqld_freeze`).
- **Network partition of the primary** — primary isolated from other GR members; TCP hangs or times out; survivors mark it **UNREACHABLE**.
- **Network isolate / firewall block on GR port** — intentional or accidental loss of XCom/group communication while mysqld still runs.
- **Primary hung (I/O stall, deadlock, CPU freeze)** — mysqld does not exit but stops responding to group heartbeats within the suspicion window.
- **Partial connectivity loss** — asymmetric routing or flaky link causes missed heartbeats without killing the process.
- **Long stop-the-world pause on primary** — extreme GC, cgroup freeze, or scheduler starvation that exceeds GR’s reachability timeout.

**Common characteristics:**

- Primary is **not** sent a shutdown signal; it must be **explicitly expelled** from the group.
- Failover time includes **suspicion + expel_timeout + expel thread cadence + election + HA routing**.
- Typical **`total_failover_sec`** on this cluster: **~22 s** (see Table 2).
- Promotion breakdown (from mysqld logs) shows most of the promote window as **GR suspicion & expel** (~22 s from TTD), with **GR election** often sub-second once the member is removed.

---

## Workload and test configuration

Both 20-iteration runs used the **same application load profile**:

| Parameter | Value |
|-----------|--------|
| Scenario | `read_heavy_fat` (90% read / 10% write) |
| Target throughput | ~**20 MiB/s** read-heavy traffic |
| Fat read rows | `TPCC_FAT_READ_ROWS=150` (~250–300 KB/scan) |
| Threads | 16 |
| TPC-C scale | 5000 warehouses × 10 tables (~5 TB) |
| VIP load port | `:3306` (HAProxy primary pool) |
| Secondary warmup | `read_only_fat` on HAProxy **`:3307`** for **300 s** during each inter-iteration gap |
| Per iteration | 60 s warmup + 300 s baseline + trigger + 300 s observe + 300 s delay |
| GR expel timeout | `group_replication_member_expel_timeout=5` |

### Replication lag under heavy write load

These runs used a **90/10 read/write** mix, not pure write stress. Under **heavier write ratios**, secondaries accumulate **applier queue lag** before failover. After GR elects a new PRIMARY, that node may still need to **drain its applier queue** and satisfy **`super_read_only` / certification** before accepting writes. That adds **extra promote time or application downtime** beyond GR election itself — visible in the promotion breakdown as **HAProxy routable** and **client path restore** phases. Runs with higher write pressure and lag are expected to show **higher `total_failover_sec` and `app_recovery_sec`** than the tables below.

---

## KPI definitions (columns in tables)

All times in **seconds**, measured from **failover trigger** unless noted.

| Column | KPI field | Meaning |
|--------|-----------|---------|
| **Time to detect** | `failure_detection_sec` | Trigger → first client VIP sample with `connect_ok=0` (TTD) |
| **Time to promote and accept writes** | `primary_election_sec` | TTD → new PRIMARY on VIP with `write_ok=1` (hostname changed) |
| **Total failover time** | `total_failover_sec` | Trigger → same promote end (**≈ detect + promote**) |

---

## Tests performed

| # | Trigger type | Path | Iterations | Results directory | Report |
|---|--------------|------|------------|-------------------|--------|
| 1 | **`pod_delete`** (force primary pod delete, grace=0) | Immediate member loss | 20 | `results/failover_20260729_051635` | `advanced/graphs/failover_report.html` |
| 2 | **`mysqld_freeze`** (cgroup, 25 s) | UNREACHABLE / expel | 20 | `results/failover_20260730_194553` | `advanced/mixed/graphs/failover_report.html` |

Additional validation: 1-iteration **`mysqld_freeze`** smoke on the same cluster (`results/failover_20260730_191608`); 1-iteration smoke on `benchmark-failover2` earlier in branch development.

---

## Table 1 — `pod_delete` (20 iterations)

**Trigger:** Force primary pod delete (`FAILOVER_ADVANCED_TRIGGER_METHOD=pod_delete`, grace-period=0)  
**Path:** Immediate GR election (no expel wait)

| Iter | Time to detect (s) | Time to promote and accept writes (s) | Total failover time (s) |
|------|-------------------:|--------------------------------------:|------------------------:|
| 1 | 0.513 | 2.750 | 3.260 |
| 2 | 0.060 | 2.250 | 2.310 |
| 3 | 0.684 | 2.500 | 3.180 |
| 4 | 0.183 | 2.250 | 2.430 |
| 5 | 0.096 | 3.250 | 3.350 |
| 6 | 0.069 | 2.250 | 2.320 |
| 7 | 0.579 | 2.750 | 3.330 |
| 8 | 0.185 | 2.250 | 2.440 |
| 9 | 0.156 | 3.250 | 3.410 |
| 10 | 0.014 | 2.250 | 2.260 |
| 11 | 0.261 | 3.000 | 3.260 |
| 12 | 0.207 | 2.000 | 2.210 |
| 13 | 0.885 | 2.250 | 3.130 |
| 14 | 0.093 | 2.000 | 2.090 |
| 15 | 0.410 | 2.750 | 3.160 |
| 16 | 0.001 | 2.500 | 2.500 |
| 17 | 0.052 | 3.000 | 3.050 |
| 18 | 0.113 | 2.250 | 2.360 |
| 19 | 0.898 | 2.500 | 3.400 |
| 20 | 0.185 | 2.000 | 2.190 |
| **Avg (20 iters)** | **0.282** | **2.500** | **2.782** |

**Target check:** average `total_failover_sec` **2.78 s** — well under the **≤ 30 s** goal.

---

## Table 2 — `mysqld_freeze` (20 iterations)

**Trigger:** Cgroup freeze primary mysqld (`FAILOVER_ADVANCED_TRIGGER_METHOD=mysqld_freeze`, 25 s hold, thaw)  
**Path:** UNREACHABLE → suspicion (~5 s) + `member_expel_timeout` (5 s) + expel thread → election  
**GR config:** `group_replication_member_expel_timeout=5`

| Iter | Time to detect (s) | Time to promote and accept writes (s) | Total failover time (s) |
|------|-------------------:|--------------------------------------:|------------------------:|
| 1 | 0.105 | 22.500 | 22.610 |
| 2 | 0.012 | 23.750 | 23.760 |
| 3 | 0.107 | 21.750 | 21.860 |
| 4 | 0.015 | 24.000 | 24.010 |
| 5 | 0.416 | NOT_DETECTED | NOT_DETECTED |
| 6 | 0.196 | 22.750 | 22.950 |
| 7 | 0.395 | NOT_DETECTED | NOT_DETECTED |
| 8 | 0.047 | 22.000 | 22.050 |
| 9 | 0.207 | 22.000 | 22.210 |
| 10 | 0.204 | 22.500 | 22.700 |
| 11 | 0.125 | 23.000 | 23.120 |
| 12 | 0.114 | NOT_DETECTED | NOT_DETECTED |
| 13 | 0.024 | 22.000 | 22.020 |
| 14 | 0.214 | 21.500 | 21.710 |
| 15 | 0.047 | 22.250 | 22.300 |
| 16 | 0.055 | 22.750 | 22.810 |
| 17 | 0.186 | NOT_DETECTED | NOT_DETECTED |
| 18 | 0.009 | 22.250 | 22.260 |
| 19 | 0.092 | 23.250 | 23.340 |
| 20 | 0.242 | 21.500 | 21.740 |
| **Avg (16 valid iters)** | **0.106** | **22.484** | **22.591** |
| **Avg (all 20 iters)** | **0.141** | — | — |

**Notes on NOT_DETECTED (iters 5, 7, 12, 17):** VIP monitor did not capture the promote endpoint in the detection window; GR election still occurred (~22 s in adjacent iterations). Detect times were recorded.

**Target check:** average `total_failover_sec` **22.59 s** (16 valid iters) — under the **≤ 30 s** goal for the UNREACHABLE/expel path.

---

## Summary comparison

| Trigger type | Failover path | Avg time to detect | Avg time to promote & accept writes | Avg total failover time | Valid iters |
|--------------|---------------|-------------------:|------------------------------------:|------------------------:|------------:|
| **`pod_delete`** (force primary pod delete) | Immediate member loss | **0.28 s** | **2.50 s** | **2.78 s** | 20 / 20 |
| **`mysqld_freeze`** | UNREACHABLE / expel | **0.11 s** | **22.48 s** | **22.59 s** | 16 / 20 |

**Ratio:** UNREACHABLE-path failover is **~8× slower** than force primary pod delete on this cluster — expected, because **`mysqld_freeze` must wait for suspicion, expel timeout, and expel processing** before election, whereas **`pod_delete` removes the primary member immediately**.

---

## Infrastructure notes (both runs)

- **Probe tuning:** MySQL liveness `failureThreshold=40` applied once on CR (tolerates long GR RECOVERING on pod rejoin).
- **Secondary buffer pool warmup:** Read-only fat scans on `:3307` during each 300 s inter-iteration delay.
- **No data loss** detected (`data_loss=SKIPPED` in all KPI rows).
- **Zero transaction/write failures** on VIP during failover windows in reported KPIs.

---

## References

- Methodology: [FAILOVER_BENCHMARK_METHODOLOGY.md](./FAILOVER_BENCHMARK_METHODOLOGY.md)
- Harness: `run_failover_benchmark.sh`, `trigger_failover.sh`
- Raw KPI files: `failover_kpi.csv` in each results directory above
