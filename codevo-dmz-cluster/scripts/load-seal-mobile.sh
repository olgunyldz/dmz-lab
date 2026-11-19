#!/usr/bin/env bash
# Seal Mobile (vendor mock) codevo-dmz cluster'ına kurar (ns seal-mobile). Tekrar çalıştırılabilir.
# Ön koşul: bank-prod auth-server (30543), mgmt Password Manager (30455), bank-prod Vault (secret/auth, secret/seal).
#   Doğrudan bağlantı (seçim 1): IdP ve PM node IP + NodePort ile; cihaz girişi NodePort 30456 (HAProxy SNI seal.lab.local).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$ROOT/.." && pwd)"
K="kubectl --context kind-codevo-dmz"
IMAGE="dmz-lab/seal-mobile:0.1.0"
CERTS="$REPO/edge/certs"
SEAL_CERTS="$CERTS/seal"
AUTH_IP=$(docker inspect -f '{{ index .NetworkSettings.Networks "kind" "IPAddress" }}' bank-prod-control-plane)
LEGACY_IP=$(docker inspect -f '{{ index .NetworkSettings.Networks "kind" "IPAddress" }}' platform-fortuna-bridge)

[[ -f "$SEAL_CERTS/seal-mobile.crt" ]] || bash "$REPO/edge/scripts/gen-seal-certs.sh"
source "$REPO/scripts/seal-keys.sh"
SEAL_MOBILE_SECRET=$(kubectl --context kind-bank-prod -n auth get secret auth-secrets -o jsonpath='{.data.SEAL_MOBILE_SECRET}' | base64 -d)

docker build -q -t "$IMAGE" "$REPO/codevo-dmz-cluster/seal-mobile" >/dev/null
kind load docker-image "$IMAGE" --name codevo-dmz >/dev/null

$K create namespace seal-mobile --dry-run=client -o yaml | $K apply -f - >/dev/null
$K -n seal-mobile create secret generic sm-tls \
    --from-file=server.crt="$SEAL_CERTS/seal-mobile.crt" --from-file=server.key="$SEAL_CERTS/seal-mobile.key" \
    --dry-run=client -o yaml | $K apply -f - >/dev/null
$K -n seal-mobile create secret generic sm-device-ca --from-file=device-ca.crt="$CERTS/device/device-ca.crt" \
    --dry-run=client -o yaml | $K apply -f - >/dev/null
$K -n seal-mobile create secret generic sm-internal-ca --from-file=internal-ca.crt="$CERTS/internal-ca.crt" \
    --dry-run=client -o yaml | $K apply -f - >/dev/null
$K -n seal-mobile create secret generic sm-idp-client \
    --from-file=client.crt="$CERTS/seal-mobile-internal.crt" --from-file=client.key="$CERTS/seal-mobile-internal.key" \
    --dry-run=client -o yaml | $K apply -f - >/dev/null
$K -n seal-mobile create secret generic sm-keys \
    --from-literal=SEAL_PM_KEY="$SEAL_PM_KEY" --from-literal=SEAL_MOCK_KEY="$SEAL_MOCK_KEY" \
    --from-literal=SEAL_MOBILE_SECRET="$SEAL_MOBILE_SECRET" \
    --dry-run=client -o yaml | $K apply -f - >/dev/null

$K -n seal-mobile create configmap seal-mobile-code --from-file=tracing.py="$REPO/shared/tracing.py"  \
    --dry-run=client -o yaml | $K apply -f - >/dev/null

sed -e "s/__AUTH_NODE_IP__/$AUTH_IP/" -e "s/__LEGACY_NODE_IP__/$LEGACY_IP/" "$ROOT/manifests/seal-mobile.yaml" | $K apply -f - >/dev/null
$K -n seal-mobile rollout restart deploy/seal-mobile >/dev/null
$K -n seal-mobile rollout status deploy/seal-mobile --timeout=240s
echo "Seal Mobile hazır (codevo-dmz, ns seal-mobile; NodePort 30456; IdP $AUTH_IP:30543; PIN (legacy monolit) $LEGACY_IP:30890)."
