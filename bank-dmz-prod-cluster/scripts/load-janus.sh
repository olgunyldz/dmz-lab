#!/usr/bin/env bash
# Janus (web, mobile) bank-dmz-prod cluster'ına kurar (ns janus). Tekrar çalıştırılabilir.
# Anahtarlar (JANUS_KEY_WEB, JANUS_KEY_MOBILE) yoksa üretilir ve janus-keys secret'ına yazılır (repoda sır yok).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
K="kubectl --context kind-bank-dmz-prod"

$K create namespace janus --dry-run=client -o yaml | $K apply -f - >/dev/null
if ! $K -n janus get secret janus-keys >/dev/null 2>&1; then
    $K -n janus create secret generic janus-keys --from-literal=JANUS_KEY_WEB="$(openssl rand -hex 32)" \
        --from-literal=JANUS_KEY_MOBILE="$(openssl rand -hex 32)" >/dev/null
    echo "janus-keys üretildi"
fi
# mTLS istemci sertifikaları (channel-gateway'e çağrı): kanal başına ayrı secret (scripts/gen-mtls-certs.sh üretir)
bash "$ROOT/../scripts/gen-mtls-certs.sh" >/dev/null
MTLS="$ROOT/../edge/certs/mtls"
for ch in web mobile; do
    $K -n janus create secret generic "janus-mtls-$ch" \
        --from-file=client.crt="$MTLS/janus-$ch.crt" --from-file=client.key="$MTLS/janus-$ch.key" \
        --from-file=ca.crt="$MTLS/ca.crt" --dry-run=client -o yaml | $K apply -f - >/dev/null
done
$K -n janus create configmap janus-code --from-file=janus.py="$ROOT/app/janus.py" \
    --dry-run=client -o yaml | $K apply -f - >/dev/null
BANKPROD_IP=$(docker inspect -f '{{ index .NetworkSettings.Networks "kind" "IPAddress" }}' bank-prod-control-plane)
LEGACY_IP=$(docker inspect -f '{{ index .NetworkSettings.Networks "kind" "IPAddress" }}' platform-fortuna-bridge)
sed -e "s/__BANKPROD_NODE_IP__/$BANKPROD_IP/" -e "s/__LEGACY_NODE_IP__/$LEGACY_IP/" "$ROOT/manifests/janus.yaml" | $K apply -f - >/dev/null
$K -n janus rollout restart deploy/janus-mobile deploy/janus-web >/dev/null
$K -n janus rollout status deploy/janus-mobile --timeout=240s
$K -n janus rollout status deploy/janus-web --timeout=240s
echo "Janus hazır (bank-dmz-prod/janus: mobile NodePort 30801, web NodePort 30802)"
