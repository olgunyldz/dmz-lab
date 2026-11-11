#!/usr/bin/env bash
# İç cluster'ı baştan kurar (kind-internal). Tekrar çalıştırılabilir (idempotent).
#   1) kind cluster (kind-config.yaml)
#   2) Gateway API v1.7.0 CRD'leri ve kgateway v2.5.0 (CRD + chart)
#   3) gw-internal namespace'i; gw-internal-tls (sunucu) ve dmz-client-ca (DMZ istemci CA'sı, internal-ca) secret/ConfigMap
#   4) BFF ve core servisleri (load-services.sh; app-bff, app-core namespace'leri burada oluşur)
#   5) gw-internal Gateway, istemci doğrulaması, NodePort 30444, iç yetkilendirme (RBAC), metrikler
# Ön koşul: edge/certs (bash edge/scripts/gen-certs.sh && bash edge/scripts/gen-internal-certs.sh)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/../scripts/lab-ips.sh"
CERTS="$ROOT/../edge/certs"
CTX="kind-internal"
K="kubectl --context $CTX"

GATEWAY_API="v1.7.0"
KGATEWAY="v2.5.0"

for f in gw-internal.crt gw-internal.key internal-ca.crt; do
    if [[ ! -f "$CERTS/$f" ]]; then
        echo "HATA: $CERTS/$f yok. Önce: bash edge/scripts/gen-certs.sh && bash edge/scripts/gen-internal-certs.sh" >&2
        exit 1
    fi
done

if ! kind get clusters 2>/dev/null | grep -qx internal; then
    kind create cluster --config "$ROOT/kind-config.yaml" --wait 180s
fi

$K apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API}/standard-install.yaml"

helm upgrade -i --create-namespace -n kgateway-system --version "$KGATEWAY" --kube-context "$CTX" \
    kgateway-crds oci://cr.kgateway.dev/kgateway-dev/charts/kgateway-crds
helm upgrade -i -n kgateway-system --version "$KGATEWAY" --kube-context "$CTX" \
    kgateway oci://cr.kgateway.dev/kgateway-dev/charts/kgateway
$K -n kgateway-system wait --for=condition=available deploy --all --timeout=300s

# Gateway namespace ve sertifika secret'ları
$K create namespace gw-internal --dry-run=client -o yaml | $K apply -f - >/dev/null
$K -n gw-internal create secret tls gw-internal-tls \
    --cert="$CERTS/gw-internal.crt" --key="$CERTS/gw-internal.key" \
    --dry-run=client -o yaml | $K apply -f -
# DMZ istemci sertifikalarını doğrulayan CA (lab: internal-ca, dmz-client bu CA ile imzalı)
$K -n gw-internal create configmap dmz-client-ca --from-file=ca.crt="$CERTS/internal-ca.crt" \
    --dry-run=client -o yaml | $K apply -f -

# Servisler (app-bff, app-core oluşturulur)
bash "$ROOT/scripts/load-services.sh"

render "$ROOT/manifests/gateway.yaml" | $K apply -f -
$K apply -f "$ROOT/manifests/listener-client-cert.yaml"
$K apply -f "$ROOT/manifests/gw-internal-nodeport.yaml"
$K apply -f "$ROOT/manifests/internal-authz.yaml"
$K apply -f "$ROOT/manifests/metrics.yaml"

$K -n gw-internal wait --for=condition=Programmed gateway/gw-internal --timeout=300s

echo "Internal cluster hazır. Gateway: gw-internal (NodePort 30444). Testler: bash internal-cluster/tests/api.sh"
