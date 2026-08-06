# Sidecar Memory Experiment — Setup Guide

This guide walks through setting up the sidecar memory profiling experiment
on an Advanced MySQL (Percona GR) cluster. The experiment measures cgroup
memory usage of every container in the MySQL pods under various TPC-C load
levels.

---

## Prerequisites

| Component | Description |
|---|---|
| **Percona cluster** | A running Advanced MySQL cluster (any node size) |
| **TPC-C droplet** | An Ubuntu droplet with sysbench installed (see `setup_benchmark.sh`) |
| **Kubeconfig** | Admin-level kubeconfig with `exec` permissions (from `perconactl`) |
| **PMM server** | Running PMM instance for dashboard (optional but recommended) |

## 1. Obtain the Kubeconfig

The cloud-panel kubeconfig does **not** have `exec` permissions. Use
`perconactl` from the cthulhu repo:

```bash
cd <cthulhu>/docode/src/do/teams/paas/dbaas/percona

perconactl cluster kubeconfig \
  --user-id <your-do-user-id> \
  --env production \
  --region <cluster-region> \
  --cluster-uuid <percona-cluster-uuid>
```

The file is written to `~/Downloads/kubeconfig-<uuid>`. Copy it to the
droplet:

```bash
scp ~/Downloads/kubeconfig-<uuid> root@<droplet>:/root/.kube/config_cluster
```

Verify `exec` works:

```bash
ssh root@<droplet> 'KUBECONFIG=/root/.kube/config_cluster \
  kubectl -n percona exec <cluster>-mysql-0 -c mysqld-exporter -- \
  sh -c "cat /sys/fs/cgroup/memory.current"'
```

## 2. Configure the Droplet

### benchmark.conf

Create `/root/mysql-benchmark/benchmark.conf` on the droplet:

```bash
ADVANCED_MYSQL_HOST=<cluster-host>.db1.ondigitalocean.com
ADVANCED_MYSQL_PORT=3306
ADVANCED_MYSQL_USER=doadmin
ADVANCED_MYSQL_PASSWORD=<password>
ADVANCED_MYSQL_DB=defaultdb

TPCC_TABLES=1
TPCC_SCALE=100     # warehouses — adjust based on node size
TPCC_FORCE_PK=1
TPCC_TRX_LEVEL=RR
```

### Verify connectivity

```bash
mysql -h <host> -P 3306 -u doadmin -p'<password>' \
  --ssl-mode=REQUIRED defaultdb \
  -e "SELECT VERSION(), @@hostname, @@innodb_buffer_pool_size/(1024*1024*1024) AS bp_gb;"
```

## 3. Set Up PMM Dashboard (Optional)

### Start the pod exporter

The pod exporter collects container memory and pod health metrics via
`kubectl` and exposes them at `/metrics` for vmagent to scrape.

```bash
KUBECONFIG=/root/.kube/config_cluster \
CLUSTER=<cluster-name> \
MEMORY_CONTAINERS=mysql,mysqld-exporter,slow-log-tailer,pmm-client,xtrabackup \
  nohup python3 /root/podmon/k8s_pod_exporter.py > /root/podmon/exporter.log 2>&1 &
```

### Push the dashboard

From your local machine:

```bash
PMM_TOKEN=<glsa_token> \
PMM_HOST=<pmm-ip> \
CLUSTER_DEFAULT=<cluster-name> \
  python3 scripts/pmm_create_dashboard.py
```

The dashboard includes a **"Sidecar Container Memory"** row with panels
for each sidecar.

## 4. Run the Experiment

### Environment variables

| Variable | Default | Description |
|---|---|---|
| `KUBECONFIG` | `/root/.kube/config` | Path to admin kubeconfig |
| `POD_PREFIX` | `mysql` | Pod name prefix (e.g. `<cluster-name>-mysql`) |
| `EDITION` | `advanced` | Which cluster edition to use |
| `K8S_NAMESPACE` | `percona` | Kubernetes namespace |

### Start

```bash
ssh root@<droplet>

KUBECONFIG=/root/.kube/config_cluster \
POD_PREFIX=<cluster-name>-mysql \
EDITION=advanced \
  nohup bash /root/mysql-benchmark/scripts/run_sidecar_experiment.sh \
  > /root/mysql-benchmark/logs/sidecar_experiment_full.log 2>&1 &
```

### Phases

The experiment runs these phases automatically:

| Phase | Duration | What happens |
|---|---|---|
| Baseline | 5 min | No load, collects idle memory |
| Prepare | 30–45 min | TPC-C prepare (bulk INSERTs) |
| 50 TPS | 20 min | Low OLTP load (8 threads) |
| 100 TPS | 20 min | Medium load (16 threads) |
| 200 TPS | 20 min | High load (32 threads) |
| 300 TPS | 20 min | Peak load (64 threads) |

Total runtime: ~2–2.5 hours.

### Monitor progress

```bash
tail -f /root/mysql-benchmark/logs/sidecar_experiment.log
```

### Check the memory sampler

```bash
KUBECONFIG=/root/.kube/config_cluster \
POD_PREFIX=<cluster-name>-mysql \
  bash scripts/sample_sidecar_memory.sh status
```

## 5. Generate the Report

After the experiment completes:

```bash
python3 scripts/build_sidecar_report.py logs/sidecar_memory.csv
```

Output:
- **Text summary** printed to stdout (peak memory per sidecar per phase)
- **HTML report** at `logs/sidecar_report.html` with color-coded tables

## 6. Interpreting Results

### What to look for

- **% of limit:** If a sidecar reaches >80% of its Kubernetes memory
  limit, it risks OOM-kill.
- **Sidecars with no limit:** `pmm-client` and `xtrabackup` have no
  memory limits by default. Track their peak usage to determine safe
  limits.
- **Node evictions:** If the combined memory of all containers on a node
  exceeds the node's allocatable memory minus 100 Mi (kubelet eviction
  threshold), Kubernetes will evict pods — even if no single container
  exceeds its own limit.

### Key metrics on the PMM dashboard

| Panel | What it shows |
|---|---|
| Sidecar Memory — pmm-client | Memory over time, per pod (no limit set) |
| Sidecar Memory — mysqld-exporter | Should stay well under 256 Mi limit |
| Sidecar Memory — slow-log-tailer | Should stay well under 32 Mi limit |
| All Sidecar Memory Combined | Total non-mysql memory pressure per pod |

## 7. OOM Reproduction Tests

To reproduce slow-log-tailer OOM kills (for verification or operator
testing), use the targeted OOM scripts:

### Multi-line OOM test (recommended)

```bash
ssh root@<droplet>

POD=<cluster-name>-mysql-0 \
KUBECONFIG=/root/.kube/config_cluster \
  bash scripts/oom_multiline_test.sh [num_queries] [target_mb]
```

- `num_queries`: number of large INSERT queries to fire (default 1000)
- `target_mb`: size per INSERT in MiB (default 35 — exceeds 32 MiB limit)

The script creates a test table, generates multi-line INSERTs, monitors
the tailer's cgroup memory and restart count, and reports OOM if detected.

### Single INSERT OOM test

```bash
POD=<cluster-name>-mysql-0 \
KUBECONFIG=/root/.kube/config_cluster \
  bash scripts/oom_slowlog_test.sh
```

Fires a single ~25 MiB INSERT and monitors tailer memory.

## 8. mysqld-exporter Pressure Test

Tests whether the `mysqld-exporter` sidecar can be pushed to OOM under
extreme concurrent connection load:

```bash
POD=<cluster-name>-mysql-0 \
KUBECONFIG=/root/.kube/config_cluster \
EDITION=advanced \
  bash scripts/exporter_pressure_test.sh
```

Phases: baseline → 100/300/500 connections with 10KB queries → 200
connections with 50KB queries → TPC-C load with rapid scrapes.

Output: `logs/exporter_pressure/memory_samples.csv` and experiment log.

**Prerequisite:** `pip3 install mysql-connector-python` on the droplet.

## 9. Slow-Log-Tailer Pressure Test

Long-running test with bulk INSERTs and OLTP load, measuring
slow-log-tailer cgroup memory growth over time:

```bash
KUBECONFIG=/root/.kube/config_cluster \
POD_PREFIX=<cluster-name>-mysql \
EDITION=advanced \
  nohup bash scripts/run_slowlog_pressure.sh \
  > logs/slowlog_pressure/full.log 2>&1 &
```

Phases: baseline → TPC-C prepare (bulk writes with `long_query_time=0.1s`)
→ OLTP load (200 TPS).

Output: memory CSV, slowlog size CSV, proc snapshots, experiment log.

## Scripts Reference

| Script | Where to run | Description |
|---|---|---|
| `scripts/sample_sidecar_memory.sh` | Droplet | Cgroup memory sampler (start/stop/status/set-phase) |
| `scripts/run_sidecar_experiment.sh` | Droplet | Full experiment orchestrator |
| `scripts/run_slowlog_pressure.sh` | Droplet | Slow-log-tailer targeted pressure test |
| `scripts/oom_slowlog_test.sh` | Droplet | OOM reproduction: single massive INSERT |
| `scripts/oom_multiline_test.sh` | Droplet | OOM reproduction: multi-line queries |
| `scripts/exporter_pressure_test.sh` | Droplet | mysqld-exporter memory stress test |
| `scripts/build_sidecar_report.py` | Droplet or local | Parse memory CSV → text + HTML report |
| `scripts/k8s_pod_exporter.py` | Droplet | Pod + sidecar metrics exporter for PMM |
| `scripts/start_pod_monitor.sh` | Droplet | Launches pod exporter + vmagent → PMM |
| `scripts/pmm_create_dashboard.py` | Local or droplet | Creates/updates PMM Grafana dashboard |
