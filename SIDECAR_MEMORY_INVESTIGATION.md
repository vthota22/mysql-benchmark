# Sidecar Memory Investigation — Advanced MySQL (4 vCPU / 16 GB)

**Date:** Aug 5, 2026
**Cluster:** `compare-am-gp-n3-4-16-i-adv` (Percona GR, 3-node HA, SGP1)
**Node size:** gd-4vcpu-16gb (15.6 Gi total, 13.3 Gi allocatable)
**Buffer pool:** 7 Gi (43.75% of node RAM)
**Load generator:** TPC-C via sysbench from droplet `188.166.208.101`

---

## Objective

Determine how much memory each MySQL sidecar container consumes, whether
unbounded sidecars affect cluster stability under load, and what limits
should be set.

## Setup

- Wrote a cgroup memory sampler (`sample_sidecar_memory.sh`) that reads
  `/sys/fs/cgroup/memory.current` via `kubectl exec` every 30 seconds for
  each container across all 3 MySQL pods.
- Added `longevity_k8s_container_memory_bytes` metrics to the pod exporter
  so sidecar memory is visible on the PMM Grafana dashboard over time.
- Ran a TPC-C prepare (scale 100, tables 1, 4 threads) to generate bulk
  write load.

## Container Memory Layout (per MySQL pod)

| Container | Idle Memory | Request | Limit | Notes |
|---|---|---|---|---|
| mysql | 12,572 Mi | 5 Gi | 13,926 Mi | InnoDB buffer pool = 7 Gi; rest is MySQL overhead |
| pmm-client | 257 Mi | **0** | **NONE** | Collects metrics + query analytics |
| do-agent | ~100 Mi (est.) | 64 Mi | 192 Mi | Scratch image, can't measure directly |
| mysqld-exporter | 15 Mi | 128 Mi | 256 Mi | Prometheus metrics exporter |
| slow-log-tailer | 4 Mi | 10 Mi | 32 Mi | Tails slow query log |
| xtrabackup | 13 Mi | **0** | **NONE** | Backup agent, mostly idle |

Additionally, node `37hbqz` co-locates the mysql-1 pod with:

| Pod | Container | Memory | Request | Limit |
|---|---|---|---|---|
| haproxy-0 | haproxy | 17 Mi | 128 Mi | 256 Mi |
| haproxy-0 | pmm-client | 113 Mi | **0** | **NONE** |
| haproxy-0 | mysql-monit | 15 Mi | — | — |
| binlog-server-0 | binlog-server | 111 Mi | 256 Mi | 512 Mi |

## What Happened

During TPC-C prepare (bulk INSERTs at scale 100), **Kubernetes evicted
`mysql-1`** after ~3 minutes of load.

### Eviction Event (verbatim)

```
The node was low on resource: memory.
Threshold quantity: 100Mi, available: 101880Ki.
Container xtrabackup was using 13348Ki, request is 0.
Container pmm-client was using 263036Ki, request is 0.
Container mysql was using 12789180Ki, request is 5Gi.
```

### Timeline

| Time (UTC) | Event |
|---|---|
| 14:03:07 | TPC-C prepare started (scale=100, 4 threads) |
| 14:06:11 | Last memory sample before eviction — mysql-1 at 12,625 Mi |
| 14:06:22 | **kubelet evicted mysql-1** — node free memory dropped below 100 Mi |
| 14:06:22 | GR members: 3 → 2 (mysql-1 removed from group) |
| 14:06:22 | Cluster state: Ready → Initializing |
| 14:06:22 | sysbench lost connection (Error 2013) |
| ~14:06:30 | StatefulSet recreated mysql-1 pod |
| ~14:08:00 | mysql-1 rejoined GR, members: 2 → 3 |
| ~14:08:22 | Cluster state: Initializing → Ready |

### Memory Math on the Evicted Node

```
Node total:                     15,999 Mi  (15.6 Gi)
Allocatable:                    13,654 Mi  (13.3 Gi)
Reserved (kubelet/OS):           2,345 Mi

Actual usage at eviction:
  mysql-1/mysql               12,489 Mi
  mysql-1/pmm-client             257 Mi  ← NO request, NO limit
  mysql-1/xtrabackup              13 Mi  ← NO request, NO limit
  mysql-1/mysqld-exporter         16 Mi
  mysql-1/slow-log-tailer          6 Mi
  mysql-1/do-agent              ~100 Mi
  haproxy-0 (all containers)     145 Mi
  binlog-server-0                111 Mi
                              --------
  Total on node:             ~13,137 Mi
  Available:                    ~517 Mi  ← BEFORE load started
```

During TPC-C prepare, MySQL grew by ~50–70 Mi (dirty pages, sort buffers).
That pushed the node past the kubelet eviction threshold (100 Mi remaining).

## Root Cause

**The primary culprit is `pmm-client`** — it consumes 257 Mi on the MySQL
pod and 113 Mi on the HAProxy pod with **zero requests and no memory
limit**. The Kubernetes scheduler has no visibility into this memory usage.

The scheduler sees ~5.5 Gi of memory requests for the MySQL pod (5 Gi
mysql + 128 Mi exporter + 10 Mi tailer + 64 Mi do-agent) and believes
there is plenty of room on a 13.3 Gi-allocatable node. In reality, the
pod uses **12.9 Gi** — more than double the declared requests.

### Contributing factors

1. **pmm-client (257 Mi, no request/limit):** Invisible to scheduler.
   Under load, it processes more queries and can grow further.
2. **xtrabackup (13 Mi, no request/limit):** Small but also invisible.
   During scheduled backups, this grows significantly.
3. **mysql container request too low:** Request is 5 Gi but actual usage is
   12.5 Gi. The 7 Gi buffer pool alone exceeds the request.
4. **Co-located pods:** haproxy-0 and binlog-server-0 share the same node,
   adding 256 Mi of load (including another pmm-client at 113 Mi).

## Sidecar Memory Under Load (from sampler data)

| Container | Baseline | During Prepare | Delta | % of Limit |
|---|---|---|---|---|
| mysqld-exporter | 15.3 Mi | 15.9 Mi | +0.6 Mi | 6.2% of 256 Mi |
| slow-log-tailer | 4.5 Mi | 5.6 Mi | +1.1 Mi | 17.5% of 32 Mi |
| mysql | 12,572 Mi | 12,625 Mi | +53 Mi | 90.7% of 13,926 Mi |

`mysqld-exporter` and `slow-log-tailer` are well within their limits and
are not a concern. The bounded sidecars (`do-agent`, `mysqld-exporter`,
`slow-log-tailer`) behave correctly.

## GR Impact

- GR applier queue lag was only ~15 transactions — **GR lag was NOT the
  cause** of the failure.
- The failure was purely a Kubernetes node-level memory eviction, not a
  MySQL/GR issue.
- However, the eviction caused a GR membership change (3 → 2 → 3) and a
  brief period of writer unavailability (~2 minutes).

## Recommendations

### Immediate: Set memory requests/limits on unbounded sidecars

| Container | Current Request | Current Limit | Proposed Request | Proposed Limit |
|---|---|---|---|---|
| pmm-client (mysql pod) | 0 | none | 300 Mi | 512 Mi |
| pmm-client (haproxy pod) | 0 | none | 150 Mi | 256 Mi |
| xtrabackup | 0 | none | 64 Mi | 256 Mi |

This makes the scheduler aware of actual memory needs and prevents
node-level evictions.

### Medium-term: Align mysql container request with actual usage

The mysql container's request (5 Gi) is far below its actual usage
(12.5 Gi). The request should be raised to at least the buffer pool size
(7 Gi) plus overhead (~1–2 Gi), e.g. 9–10 Gi. This ensures the scheduler
does not over-commit nodes.

### Sizing guidance for innodb_buffer_pool_size

On a 16 Gi node:
- Allocatable: 13.3 Gi
- Sidecars (with proposed limits): ~0.8–1.0 Gi
- System/other pods: ~0.4 Gi
- Available for MySQL: ~12 Gi
- Safe buffer pool: **~8–9 Gi (50–56% of node RAM)**

Current 7 Gi (43.75%) is conservative but appropriate given the
unbounded sidecar situation. Once limits are set, it can safely be
raised to 8–9 Gi.

## Dashboard

Sidecar memory is now tracked on the PMM longevity dashboard:
`https://138.197.18.113/graph/d/longevity-bench-main/`

Panels added under **"Sidecar Container Memory"** row:
- mysqld-exporter, slow-log-tailer, pmm-client, xtrabackup (per pod)
- MySQL container memory (per pod)
- All sidecars combined (per pod)

## Scripts Created

| Script | Purpose |
|---|---|
| `scripts/sample_sidecar_memory.sh` | Cgroup memory sampler via kubectl exec (start/stop/status) |
| `scripts/run_sidecar_experiment.sh` | Orchestrator: baseline → prepare → load ramp (50/100/200/300 TPS) |
| `scripts/build_sidecar_report.py` | Parse CSV, generate text + HTML summary |
