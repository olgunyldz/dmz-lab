#!/usr/bin/env bash
# Seal Intranet (vendor mock) codevo-dmz cluster'ına kurar (ns seal-intranet). Tekrar çalıştırılabilir.
# Ön koşul: bank-prod auth-server (NodePort 30543). Doğrudan bağlantı (seçim 1): JWKS node IP:30543 üzerinden.
#   1) Sırlar: scripts/seal-keys.sh (bank-prod Vault secret/seal/v3) -> si-mock
#   2) TLS: edge/certs/seal -> seal-intranet-tls; iç CA ConfigMap'i internal-ca-backend
#   3) İmaj derlenir, kind düğümüne yüklenir; manifest (auth node IP ile render) uygulanır
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$ROOT/.." && pwd)"
K="kubectl --context kind-codevo-dmz"
IMAGE="dmz-lab/seal-intranet:0.1.0"
CERTS="$REPO/edge/certs"
SEAL_CERTS="$CERTS/seal"
AUTH_IP=$(docker inspect -f '{{ index .NetworkSettings.Networks "kind" "IPAddress" }}' bank-prod-control-plane)

[[ -f "$SEAL_CERTS/seal-intranet.crt" ]] || bash "$REPO/edge/scripts/gen-seal-certs.sh"
source "$REPO/scripts/seal-keys.sh"

docker build -q -t "$IMAGE" "$REPO/codevo-dmz-cluster/seal-intranet" >/dev/null
kind load docker-image "$IMAGE" --name codevo-dmz >/dev/null

$K create namespace seal-intranet --dry-run=client -o yaml | $K apply -f - >/dev/null
$K -n seal-intranet create configmap internal-ca-backend --from-file=ca.crt="$CERTS/internal-ca.crt" \
    --dry-run=client -o yaml | $K apply -f - >/dev/null
$K -n seal-intranet create secret generic seal-intranet-tls \
    --from-file=server.crt="$SEAL_CERTS/seal-intranet.crt" --from-file=server.key="$SEAL_CERTS/seal-intranet.key" \
    --dry-run=client -o yaml | $K apply -f - >/dev/null
$K -n seal-intranet create secret generic si-mock --from-literal=SEAL_MOCK_KEY="$SEAL_MOCK_KEY" \
    --dry-run=client -o yaml | $K apply -f - >/dev/null

sed "s/__AUTH_NODE_IP__/$AUTH_IP/" "$ROOT/manifests/seal-intranet.yaml" | $K apply -f - >/dev/null
$K -n seal-intranet rollout restart deploy/seal-intranet >/dev/null
$K -n seal-intranet rollout status deploy/seal-intranet --timeout=240s
echo "Seal Intranet hazır (codevo-dmz, ns seal-intranet; JWKS: $AUTH_IP:30543)."
