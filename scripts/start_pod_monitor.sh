#!/usr/bin/env bash
# Launch the K8s pod-metrics exporter + vmagent (remote-write to PMM).
# Reusable across clusters: set CLUSTER + KUBECONFIG per cluster.
#
# Required env:
#   PMM_TOKEN     Grafana/PMM service-account token (glsa_...)
# Optional env:
#   PMM_HOST      default 138.197.18.113
#   KUBECONFIG    default /root/.kube/config
#   CLUSTER       default longevity-am-n3
#   K8S_NAMESPACE default percona
#   WORKDIR       default /root/podmon
#   VMAGENT_BIN   default /root/vmagent-prod
set -u

PMM_HOST="${PMM_HOST:-138.197.18.113}"
PMM_TOKEN="${PMM_TOKEN:?set PMM_TOKEN}"
export KUBECONFIG="${KUBECONFIG:-/root/.kube/config}"
export CLUSTER="${CLUSTER:-longevity-am-n3}"
export K8S_NAMESPACE="${K8S_NAMESPACE:-percona}"
export LISTEN="127.0.0.1:9111"
WORKDIR="${WORKDIR:-/root/podmon}"
VMAGENT_BIN="${VMAGENT_BIN:-/root/vmagent-prod}"

mkdir -p "$WORKDIR"
cat > "$WORKDIR/scrape.yml" <<YML
global:
  scrape_interval: 15s
  external_labels:
    monitor: longevity-podmon
scrape_configs:
  - job_name: k8s_pods
    static_configs:
      - targets: ["${LISTEN}"]
YML

pkill -f k8s_pod_exporter.py >/dev/null 2>&1 || true
pkill -f "$VMAGENT_BIN"       >/dev/null 2>&1 || true
sleep 1

setsid python3 "$WORKDIR/k8s_pod_exporter.py" \
  > "$WORKDIR/exporter.log" 2>&1 < /dev/null &
sleep 2

setsid "$VMAGENT_BIN" \
  -promscrape.config="$WORKDIR/scrape.yml" \
  -remoteWrite.url="https://${PMM_HOST}/prometheus/api/v1/write" \
  -remoteWrite.bearerToken="$PMM_TOKEN" \
  -remoteWrite.tlsInsecureSkipVerify=true \
  -httpListenAddr=127.0.0.1:8429 \
  > "$WORKDIR/vmagent.log" 2>&1 < /dev/null &
sleep 2

echo "started. cluster=$CLUSTER ns=$K8S_NAMESPACE"
echo "exporter: $WORKDIR/exporter.log | vmagent: $WORKDIR/vmagent.log"
pgrep -af "k8s_pod_exporter.py|$VMAGENT_BIN" | grep -v pgrep || echo "WARN: processes not found"
