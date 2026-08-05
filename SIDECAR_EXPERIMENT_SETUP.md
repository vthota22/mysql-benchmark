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
| `KUBECONFIG` | `/root/.kube/config_4_16` | Path to admin kubeconfig |
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

## Scripts Reference

| Script | Description |
|---|---|
| `scripts/sample_sidecar_memory.sh` | Cgroup memory sampler (start/stop/status/set-phase) |
| `scripts/run_sidecar_experiment.sh` | Full experiment orchestrator |
| `scripts/build_sidecar_report.py` | Parse memory CSV → text + HTML report |
| `scripts/k8s_pod_exporter.py` | Pod + sidecar metrics exporter for PMM |
| `scripts/pmm_create_dashboard.py` | Creates/updates PMM Grafana dashboard |
