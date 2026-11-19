#!/usr/bin/env bash
# Gözlemlenebilirlik yığını (mgmt cluster, ns observability): Tempo (iz), Prometheus (metrik), Loki (log), Grafana.
# Prometheus, /metrics sunan servisleri (Janus, channel-gateway, Fortuna, legacy) kazır.
#   - grafana-admin secret'ı yoksa rastgele parola ile oluşturulur (repo'da yok)
#   - manifestler uygulanır; prometheus.yaml node IP'leri docker inspect ile yerleştirilir
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
K="kubectl --context kind-mgmt"

$K create namespace observability --dry-run=client -o yaml | $K apply -f - >/dev/null

if ! $K -n observability get secret grafana-admin >/dev/null 2>&1; then
    $K -n observability create secret generic grafana-admin --from-literal=password="$(openssl rand -hex 16)" >/dev/null
    echo "grafana-admin secret'ı oluşturuldu (parola cluster'da, repo'da yok)."
fi

$K apply -f "$ROOT/mgmt-cluster/manifests/tempo.yaml"
$K apply -f "$ROOT/mgmt-cluster/manifests/loki.yaml"
BANKDMZ_IP=$(docker inspect -f '{{ .NetworkSettings.Networks.kind.IPAddress }}' bank-dmz-prod-control-plane)
BANKPROD_IP=$(docker inspect -f '{{ .NetworkSettings.Networks.kind.IPAddress }}' bank-prod-control-plane)
LEGACY_IP=$(docker inspect -f '{{ .NetworkSettings.Networks.kind.IPAddress }}' legacy-demo-control-plane)
CODEVO_IP=$(docker inspect -f '{{ .NetworkSettings.Networks.kind.IPAddress }}' codevo-dmz-control-plane)
sed -e "s/__BANKDMZ_IP__/$BANKDMZ_IP/g" -e "s/__BANKPROD_IP__/$BANKPROD_IP/g" -e "s/__LEGACY_IP__/$LEGACY_IP/g" -e "s/__CODEVO_IP__/$CODEVO_IP/g" \
    "$ROOT/mgmt-cluster/manifests/prometheus.yaml" | $K apply -f -
# ConfigMap değişince Prometheus yeniden başlamalı (yapılandırma yalnız açılışta okunur)
$K -n observability rollout restart deploy/prometheus >/dev/null
$K apply -f "$ROOT/mgmt-cluster/manifests/grafana.yaml"

$K -n observability rollout status deploy/tempo --timeout=240s
$K -n observability rollout status deploy/loki --timeout=240s
$K -n observability rollout status deploy/prometheus --timeout=240s
$K -n observability rollout status deploy/grafana --timeout=240s
echo "Observability hazır. Grafana: NodePort 30300, Prometheus: 30090, Tempo OTLP: 30318, Loki: 30100."
