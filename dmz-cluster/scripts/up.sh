#!/usr/bin/env bash
# DMZ cluster'ını baştan kurar. Tekrar çalıştırılabilir (idempotent).
#   1) kind cluster (dmz)
#   2) Gateway API v1.7.0 CRD'leri
#   3) kgateway v2.5.0 (CRD + chart)
#   4) Kanal gateway'leri ve stub backend'ler
#   5) TLS secret ve partner CA'sı (edge/certs'ten)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CTX="kind-dmz"
K="kubectl --context $CTX"

GATEWAY_API="v1.7.0"
KGATEWAY="v2.5.0"

if ! kind get clusters 2>/dev/null | grep -qx dmz; then
    kind create cluster --config "$ROOT/kind-config.yaml" --wait 180s
fi

$K apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API}/standard-install.yaml"

helm upgrade -i --create-namespace -n kgateway-system --version "$KGATEWAY" --kube-context "$CTX" \
    kgateway-crds oci://cr.kgateway.dev/kgateway-dev/charts/kgateway-crds
helm upgrade -i -n kgateway-system --version "$KGATEWAY" --kube-context "$CTX" \
    kgateway oci://cr.kgateway.dev/kgateway-dev/charts/kgateway
$K -n kgateway-system wait --for=condition=available deploy --all --timeout=300s

$K apply -f "$ROOT/manifests/channels.yaml"
# Kanal gateway NodePort servisleri (HAProxy -> 30446/30447/30448; F1 bu portları korur)
$K apply -f "$ROOT/manifests/gateway-nodeports.yaml"
bash "$ROOT/scripts/load-secrets.sh"

for ns in gw-web gw-mobile gw-partner; do
    $K -n "$ns" wait --for=condition=available deploy --all --timeout=300s
done

# F1: NodePort'lara yalnız edge HAProxy'den erişim (edge çalışmıyorsa uyarı, kurulum devam eder)
if ! bash "$ROOT/scripts/host-firewall.sh"; then
    echo "UYARI: F1 kuralı uygulanamadı (edge çalışıyor mu?). Sonra: bash dmz-cluster/scripts/host-firewall.sh" >&2
fi

echo "DMZ cluster hazır. Testler: bash dmz-cluster/tests/smoke.sh"
