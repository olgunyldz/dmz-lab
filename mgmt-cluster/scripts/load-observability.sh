#!/usr/bin/env bash
# Gözlemlenebilirlik yığını (mgmt cluster, ns observability): Tempo, Prometheus, Grafana.
# Tüm cluster'lar kurulduktan sonra çalışır (Prometheus hedefleri DMZ ve iç node IP'lerini ister).
#   - grafana-admin secret'ı yoksa rastgele parola ile oluşturulur (repo'da yok)
#   - tempo.yaml ve grafana.yaml uygulanır; prometheus.yaml yer tutucuları (lab-ips.sh) ile render edilir
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/lab-ips.sh"
K="kubectl --context kind-mgmt"

$K create namespace observability --dry-run=client -o yaml | $K apply -f - >/dev/null

if ! $K -n observability get secret grafana-admin >/dev/null 2>&1; then
    $K -n observability create secret generic grafana-admin --from-literal=password="$(openssl rand -hex 16)" >/dev/null
    echo "grafana-admin secret'ı oluşturuldu (parola cluster'da, repo'da yok)."
fi

$K apply -f "$ROOT/mgmt-cluster/manifests/tempo.yaml"
render "$ROOT/mgmt-cluster/manifests/prometheus.yaml" | $K apply -f -
$K apply -f "$ROOT/mgmt-cluster/manifests/grafana.yaml"

$K -n observability rollout status deploy/tempo --timeout=240s
$K -n observability rollout status deploy/prometheus --timeout=240s
$K -n observability rollout status deploy/grafana --timeout=240s
echo "Observability hazır. Grafana: NodePort 30300, Prometheus: 30090, Tempo OTLP: 30318."
