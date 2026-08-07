#!/usr/bin/env bash
# =============================================================================
# setup_longevity.sh — one-shot longevity environment orchestrator
# =============================================================================
# Given a droplet + a Percona (Advanced MySQL) cluster, this wires up the whole
# longevity pipeline end to end:
#
#   1. kubeconfig   fetch via perconactl (or use --kubeconfig)
#   2. provision    rsync repo -> droplet, build sysbench, install kubectl+vmagent,
#                   render benchmark.conf with the DB credentials
#   3. pmm          enable PMM client on the cluster (CR patch + token secret)
#   4. monitor      start k8s pod-metrics exporter + vmagent (remote-write to PMM)
#   5. dashboard    create/refresh the native PMM (Grafana) dashboard
#   6. run          (optional) launch the longevity benchmark detached
#
# Every phase is idempotent and individually skippable. Re-running is safe.
#
# ---- Quick start -------------------------------------------------------------
#   export PMM_TOKEN=glsa_xxx
#   scripts/setup_longevity.sh \
#       --droplet 134.209.41.192 \
#       --cluster-uuid b266f052-af54-45c8-a914-6fc74084177b \
#       --user-id 27438062 \
#       --db-host longevity-am-n3-zlzxx.db1.ondigitalocean.com \
#       --db-user doadmin --db-pass 'ka8H3vtN9rMG7Pp0oU2Zu15I' \
#       --dataset flow
#
# Add --start-benchmark to also kick off the run. Use --duration-sec 21600 for 6h.
# =============================================================================
set -euo pipefail

# ---------- defaults ----------
DROPLET=""                    # ip or user@ip
SSH_USER="root"
SSH_KEY=""
CLUSTER_UUID=""
USER_ID=""                    # perconactl --user-id
PC_ENV="production"           # perconactl --env
PERCONACTL_DIR="${PERCONACTL_DIR:-}"  # dir to run perconactl from (cthulhu percona dir)
KUBECONFIG_SRC=""             # explicit kubeconfig (skip perconactl)
CLUSTER_NAME=""               # k8s CR name; auto-detected if empty

DB_HOST=""; DB_PORT="3306"; DB_USER="doadmin"; DB_PASS=""; DB_NAME="defaultdb"

PMM_HOST="${PMM_HOST:-138.197.18.113}"
PMM_TOKEN="${PMM_TOKEN:-}"
PMM_CLIENT_IMAGE="percona/pmm-client:3.8.1"

K8S_NAMESPACE="percona"
REMOTE_DIR="/root/mysql-benchmark"
REMOTE_KUBECONFIG="/root/.kube/config"

DATASET="flow"                # flow | full | custom
TPCC_TABLES=""; TPCC_SCALE=""
DURATION_SEC=""; DAYS=""
THREADS=""

DO_PROVISION=1; DO_PMM=1; DO_MONITOR=1; DO_DASHBOARD=1; START_BENCHMARK=0

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

usage() { sed -n '2,40p' "$0"; exit "${1:-0}"; }

# ---------- arg parsing ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --droplet) DROPLET="$2"; shift 2;;
    --ssh-user) SSH_USER="$2"; shift 2;;
    --ssh-key) SSH_KEY="$2"; shift 2;;
    --cluster-uuid) CLUSTER_UUID="$2"; shift 2;;
    --cluster-name) CLUSTER_NAME="$2"; shift 2;;
    --user-id) USER_ID="$2"; shift 2;;
    --env) PC_ENV="$2"; shift 2;;
    --perconactl-dir) PERCONACTL_DIR="$2"; shift 2;;
    --kubeconfig) KUBECONFIG_SRC="$2"; shift 2;;
    --db-host) DB_HOST="$2"; shift 2;;
    --db-port) DB_PORT="$2"; shift 2;;
    --db-user) DB_USER="$2"; shift 2;;
    --db-pass) DB_PASS="$2"; shift 2;;
    --db-name) DB_NAME="$2"; shift 2;;
    --pmm-host) PMM_HOST="$2"; shift 2;;
    --namespace) K8S_NAMESPACE="$2"; shift 2;;
    --dataset) DATASET="$2"; shift 2;;
    --tpcc-tables) TPCC_TABLES="$2"; shift 2;;
    --tpcc-scale) TPCC_SCALE="$2"; shift 2;;
    --duration-sec) DURATION_SEC="$2"; shift 2;;
    --days) DAYS="$2"; shift 2;;
    --threads) THREADS="$2"; shift 2;;
    --skip-provision) DO_PROVISION=0; shift;;
    --skip-pmm) DO_PMM=0; shift;;
    --skip-monitor) DO_MONITOR=0; shift;;
    --skip-dashboard) DO_DASHBOARD=0; shift;;
    --start-benchmark) START_BENCHMARK=1; shift;;
    -h|--help) usage 0;;
    *) echo "Unknown arg: $1" >&2; usage 1;;
  esac
done

# ---------- helpers ----------
c_blue()  { printf '\033[1;34m%s\033[0m\n' "$*"; }
c_green() { printf '\033[1;32m%s\033[0m\n' "$*"; }
c_red()   { printf '\033[1;31m%s\033[0m\n' "$*" >&2; }
step()    { echo; c_blue "==> $*"; }
die()     { c_red "ERROR: $*"; exit 1; }

SSH_OPTS="-o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new"
[[ -n "$SSH_KEY" ]] && SSH_OPTS="$SSH_OPTS -i $SSH_KEY"
SSH_TARGET=""   # set after validation

rmt()  { ssh $SSH_OPTS "$SSH_TARGET" "$@"; }
put()  { scp $SSH_OPTS -q "$1" "$SSH_TARGET:$2"; }

# ---------- validation ----------
[[ -n "$DROPLET" ]] || die "--droplet is required"
case "$DROPLET" in *@*) SSH_TARGET="$DROPLET";; *) SSH_TARGET="${SSH_USER}@${DROPLET}";; esac

if [[ "$DO_PMM" == 1 || "$DO_MONITOR" == 1 || "$DO_DASHBOARD" == 1 ]]; then
  [[ -n "$PMM_TOKEN" ]] || die "PMM_TOKEN env is required (or use --skip-pmm --skip-monitor --skip-dashboard)"
fi
if [[ "$DO_PROVISION" == 1 && "$START_BENCHMARK" == 1 ]]; then
  [[ -n "$DB_HOST" && -n "$DB_PASS" ]] || die "--db-host and --db-pass are required to run the benchmark"
fi

# dataset presets
case "$DATASET" in
  flow)   TPCC_TABLES="${TPCC_TABLES:-1}";  TPCC_SCALE="${TPCC_SCALE:-10}";  THREADS="${THREADS:-8}";  DURATION_SEC="${DURATION_SEC:-300}";;
  mid)    TPCC_TABLES="${TPCC_TABLES:-10}"; TPCC_SCALE="${TPCC_SCALE:-30}";  THREADS="${THREADS:-32}";;
  full)   TPCC_TABLES="${TPCC_TABLES:-10}"; TPCC_SCALE="${TPCC_SCALE:-100}"; THREADS="${THREADS:-32}";;
  custom) [[ -n "$TPCC_TABLES" && -n "$TPCC_SCALE" ]] || die "--dataset custom needs --tpcc-tables and --tpcc-scale";;
  *) die "--dataset must be flow|mid|full|custom";;
esac
THREADS="${THREADS:-32}"

echo "======================================================================"
c_green " Longevity setup"
echo " droplet     : $SSH_TARGET"
echo " cluster     : ${CLUSTER_NAME:-<autodetect>} (uuid=${CLUSTER_UUID:-n/a})"
echo " dataset     : $DATASET (tables=$TPCC_TABLES scale=$TPCC_SCALE ~$(awk "BEGIN{printf \"%.1f\", $TPCC_TABLES*$TPCC_SCALE*0.1}") GiB)"
echo " load        : threads=$THREADS duration=${DURATION_SEC:-days:${DAYS:-7}}"
echo " pmm         : $PMM_HOST"
echo " phases      : provision=$DO_PROVISION pmm=$DO_PMM monitor=$DO_MONITOR dashboard=$DO_DASHBOARD run=$START_BENCHMARK"
echo "======================================================================"

# =============================================================================
# Phase 0 — preflight
# =============================================================================
step "Phase 0: preflight"
rmt 'echo "  ssh OK on $(hostname)"' || die "cannot ssh to $SSH_TARGET"

# =============================================================================
# Phase 1 — kubeconfig
# =============================================================================
LOCAL_KUBECONFIG=""
if [[ "$DO_PMM" == 1 || "$DO_MONITOR" == 1 ]]; then
  step "Phase 1: kubeconfig"
  if [[ -n "$KUBECONFIG_SRC" ]]; then
    [[ -f "$KUBECONFIG_SRC" ]] || die "--kubeconfig not found: $KUBECONFIG_SRC"
    LOCAL_KUBECONFIG="$KUBECONFIG_SRC"
    echo "  using provided kubeconfig: $LOCAL_KUBECONFIG"
  else
    [[ -n "$CLUSTER_UUID" && -n "$USER_ID" ]] || die "need --kubeconfig OR (--cluster-uuid and --user-id) to fetch via perconactl"
    command -v perconactl >/dev/null || die "perconactl not on PATH; pass --kubeconfig instead"
    # perconactl WRITES ~/Downloads/kubeconfig-<uuid> itself and prints a preamble
    # to stdout. Do NOT redirect stdout onto that path (it corrupts the file).
    LOCAL_KUBECONFIG="${HOME}/Downloads/kubeconfig-${CLUSTER_UUID}"
    echo "  fetching kubeconfig via perconactl (it writes $LOCAL_KUBECONFIG itself)"
    rm -f "$LOCAL_KUBECONFIG"
    (
      [[ -n "$PERCONACTL_DIR" ]] && cd "$PERCONACTL_DIR"
      perconactl cluster kubeconfig --user-id "$USER_ID" --env "$PC_ENV" --cluster-uuid "$CLUSTER_UUID"
    ) >/tmp/perconactl.out 2>&1 \
      || { cat /tmp/perconactl.out >&2; die "perconactl failed"; }
    [[ -s "$LOCAL_KUBECONFIG" ]] \
      || { cat /tmp/perconactl.out >&2; die "perconactl did not produce $LOCAL_KUBECONFIG"; }
  fi
  # copy to droplet
  rmt "mkdir -p /root/.kube && chmod 700 /root/.kube"
  put "$LOCAL_KUBECONFIG" "$REMOTE_KUBECONFIG"
  rmt "chmod 600 $REMOTE_KUBECONFIG"

  # ensure kubectl on droplet
  rmt 'command -v kubectl >/dev/null || {
        echo "  installing kubectl";
        curl -sSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl";
        chmod +x /usr/local/bin/kubectl; }'

  # auto-detect CR name if not given
  if [[ -z "$CLUSTER_NAME" ]]; then
    CLUSTER_NAME="$(rmt "kubectl --kubeconfig $REMOTE_KUBECONFIG -n $K8S_NAMESPACE get ps -o jsonpath='{.items[0].metadata.name}'")"
    [[ -n "$CLUSTER_NAME" ]] || die "could not auto-detect cluster CR name; pass --cluster-name"
  fi
  echo "  cluster CR name: $CLUSTER_NAME"
fi
# derived naming for PMM/dashboard (node & service names share the percona-<cr> prefix)
SERVICE_RE="percona-${CLUSTER_NAME:-longevity-am-n3}.*"

# =============================================================================
# Phase 2 — provision droplet (repo + sysbench + vmagent + benchmark.conf)
# =============================================================================
if [[ "$DO_PROVISION" == 1 ]]; then
  step "Phase 2: provision droplet"
  echo "  rsync repo -> $REMOTE_DIR"
  rsync -az --delete \
    --exclude '.git' --exclude '.venv' --exclude 'results' --exclude '__pycache__' \
    --exclude 'sysbench-1.1' --exclude 'src' --exclude 'build-deps' \
    --exclude 'TPCC' --exclude 'benchmark.conf' --exclude '*.log' \
    -e "ssh $SSH_OPTS" "$REPO_DIR/" "$SSH_TARGET:$REMOTE_DIR/"

  echo "  building sysbench + deps (setup_benchmark.sh) — this can take a few minutes"
  rmt "cd $REMOTE_DIR && ./setup_benchmark.sh" || die "setup_benchmark.sh failed"

  echo "  ensuring vmagent"
  rmt 'test -x /root/vmagent-prod || {
        VER=$(curl -s https://api.github.com/repos/VictoriaMetrics/VictoriaMetrics/releases/latest | python3 -c "import sys,json;print(json.load(sys.stdin)[\"tag_name\"])");
        curl -sL "https://github.com/VictoriaMetrics/VictoriaMetrics/releases/download/${VER}/vmutils-linux-amd64-${VER}.tar.gz" -o /root/vmutils.tgz;
        tar xzf /root/vmutils.tgz -C /root; echo "  installed vmagent $VER"; }'

  if [[ -n "$DB_HOST" && -n "$DB_PASS" ]]; then
    echo "  rendering benchmark.conf"
    DURATION_LINE="LONGEVITY_DURATION_SEC=${DURATION_SEC}"
    [[ -z "$DURATION_SEC" ]] && DURATION_LINE="# LONGEVITY_DURATION_SEC="
    cat > /tmp/benchmark.conf.gen <<CONF
# Auto-generated by setup_longevity.sh — do not commit (contains credentials)
STANDARD_MYSQL_HOST=unused
STANDARD_MYSQL_PORT=25060
STANDARD_MYSQL_USER=doadmin
STANDARD_MYSQL_PASSWORD=unused
STANDARD_MYSQL_DB=defaultdb

ADVANCED_MYSQL_HOST=${DB_HOST}
ADVANCED_MYSQL_PORT=${DB_PORT}
ADVANCED_MYSQL_USER=${DB_USER}
ADVANCED_MYSQL_PASSWORD=${DB_PASS}
ADVANCED_MYSQL_DB=${DB_NAME}

TPCC_TABLES=${TPCC_TABLES}
TPCC_SCALE=${TPCC_SCALE}
TPCC_FORCE_PK=1
TPCC_TRX_LEVEL=RR
PREP_THREADS=8

LONGEVITY_EDITIONS="advanced"
LONGEVITY_DAYS=${DAYS:-7}
${DURATION_LINE}
LONGEVITY_THREADS=${THREADS}
LONGEVITY_WARMUP_SEC=$([[ "$DATASET" == flow ]] && echo 30 || echo 300)
LONGEVITY_REPORT_INTERVAL=$([[ "$DATASET" == flow ]] && echo 10 || echo 60)
LONGEVITY_MONITOR_PRIMARY=1
LONGEVITY_MONITOR_INTERVAL=$([[ "$DATASET" == flow ]] && echo 10 || echo 60)
LONGEVITY_AUTO_RESTART=1
LONGEVITY_RUN_TPCC_CHECK=1
LONGEVITY_GENERATE_GRAPHS=1

ADVANCED_CLUSTER_UUID=${CLUSTER_UUID}
ADVANCED_KUBECONFIG_PATH=${REMOTE_KUBECONFIG}
ADVANCED_K8S_NAMESPACE=${K8S_NAMESPACE}
CONF
    put /tmp/benchmark.conf.gen "$REMOTE_DIR/benchmark.conf"
    rmt "chmod 600 $REMOTE_DIR/benchmark.conf"
    rm -f /tmp/benchmark.conf.gen
  else
    echo "  (no DB creds given — skipping benchmark.conf render)"
  fi
fi

# =============================================================================
# Phase 3 — enable PMM on the cluster
# =============================================================================
if [[ "$DO_PMM" == 1 ]]; then
  step "Phase 3: enable PMM on cluster $CLUSTER_NAME"
  # values passed positionally (env does not survive ssh + bash -s)
  ssh $SSH_OPTS "$SSH_TARGET" bash -s -- \
      "$CLUSTER_NAME" "$K8S_NAMESPACE" "$REMOTE_KUBECONFIG" \
      "$PMM_TOKEN" "$PMM_HOST" "$PMM_CLIENT_IMAGE" <<'REMOTE'
set -euo pipefail
CN="$1"; NS="$2"; KC="$3"; TOKEN="$4"; PHOST="$5"; IMG="$6"
K="kubectl --kubeconfig $KC -n $NS"
SEC="${CN}-secrets"
B64=$(printf %s "$TOKEN" | base64 | tr -d '\n')
echo "  setting pmmservertoken in secret $SEC"
$K patch secret "$SEC" --type=merge -p "{\"data\":{\"pmmservertoken\":\"$B64\"}}"
echo "  patching CR pmm block"
$K patch ps "$CN" --type=merge -p "{\"spec\":{\"pmm\":{\"enabled\":true,\"image\":\"$IMG\",\"serverHost\":\"$PHOST\"}}}"
echo "  waiting for pmm-client sidecar on ${CN}-mysql-0 (up to 5 min)"
for i in $(seq 1 60); do
  if $K get pod "${CN}-mysql-0" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null | grep -q pmm-client; then
    ready=$($K get pod "${CN}-mysql-0" -o jsonpath='{range .status.containerStatuses[?(@.name=="pmm-client")]}{.ready}{end}' 2>/dev/null || true)
    [[ "$ready" == "true" ]] && { echo "  pmm-client ready"; break; }
  fi
  sleep 5
done
REMOTE
fi

# =============================================================================
# Phase 4 — start pod-metrics monitor (exporter + vmagent)
# =============================================================================
if [[ "$DO_MONITOR" == 1 ]]; then
  step "Phase 4: start pod-metrics monitor"
  rmt "mkdir -p /root/podmon && cp $REMOTE_DIR/scripts/k8s_pod_exporter.py /root/podmon/k8s_pod_exporter.py && cp $REMOTE_DIR/scripts/start_pod_monitor.sh /root/start_pod_monitor.sh"
  rmt "PMM_TOKEN='$PMM_TOKEN' PMM_HOST='$PMM_HOST' CLUSTER='$CLUSTER_NAME' K8S_NAMESPACE='$K8S_NAMESPACE' KUBECONFIG='$REMOTE_KUBECONFIG' bash /root/start_pod_monitor.sh"
fi

# =============================================================================
# Phase 5 — create/refresh PMM dashboard
# =============================================================================
if [[ "$DO_DASHBOARD" == 1 ]]; then
  step "Phase 5: create/refresh PMM dashboard"
  rmt "cp $REMOTE_DIR/scripts/pmm_create_dashboard.py /root/pmm_create_dashboard.py"
  rmt "PMM_TOKEN='$PMM_TOKEN' PMM_HOST='$PMM_HOST' DEFAULT_RE='$SERVICE_RE' CLUSTER_DEFAULT='$CLUSTER_NAME' python3 /root/pmm_create_dashboard.py"
fi

# =============================================================================
# Phase 6 — optionally start the benchmark
# =============================================================================
if [[ "$START_BENCHMARK" == 1 ]]; then
  step "Phase 6: launch longevity benchmark (detached)"
  rmt "cd $REMOTE_DIR && mkdir -p results && nohup ./run_longevity_benchmark.sh >> results/longevity_nohup.log 2>&1 & echo \$! > results/longevity.pid; echo '  started pid '\$(cat results/longevity.pid)"
  echo "  tail logs: ssh $SSH_TARGET 'tail -f $REMOTE_DIR/results/longevity_nohup.log'"
fi

echo
c_green "=== DONE ==="
echo "PMM dashboard : https://${PMM_HOST}/graph/d/longevity-bench-main"
echo "Cluster       : $CLUSTER_NAME  (services=~ $SERVICE_RE)"
[[ "$START_BENCHMARK" != 1 ]] && echo "To run now    : re-run with --start-benchmark (or ssh in and ./run_longevity_benchmark.sh)"
