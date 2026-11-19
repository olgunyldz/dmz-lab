#!/usr/bin/env bash
# channel-gateway'i bank-prod/channel'a kurar. Janus anahtarları bank-dmz-prod janus-keys'ten kopyalanır (repoda sır yok).
# mTLS: sunucu sertifikası channel-gateway-tls secret'ında (scripts/gen-mtls-certs.sh üretir, edge/certs/mtls).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$ROOT/.." && pwd)"
K="kubectl --context kind-bank-prod"
LEGACY_IP=$(docker inspect -f '{{ index .NetworkSettings.Networks "kind" "IPAddress" }}' platform-fortuna-bridge)

bash "$REPO/scripts/gen-mtls-certs.sh" >/dev/null
MTLS="$REPO/edge/certs/mtls"

WEB=$(kubectl --context kind-bank-dmz-prod -n janus get secret janus-keys -o jsonpath='{.data.JANUS_KEY_WEB}' | base64 -d)
MOB=$(kubectl --context kind-bank-dmz-prod -n janus get secret janus-keys -o jsonpath='{.data.JANUS_KEY_MOBILE}' | base64 -d)
$K -n channel create secret generic janus-verify --from-literal=JANUS_KEY_WEB="$WEB" --from-literal=JANUS_KEY_MOBILE="$MOB" \
    --dry-run=client -o yaml | $K apply -f - >/dev/null
$K -n channel create secret generic channel-gateway-tls \
    --from-file=server.crt="$MTLS/channel-gateway.crt" --from-file=server.key="$MTLS/channel-gateway.key" \
    --from-file=ca.crt="$MTLS/ca.crt" --dry-run=client -o yaml | $K apply -f - >/dev/null
$K -n channel create secret generic channel-gateway-client \
    --from-file=client.crt="$MTLS/channel-gateway-client.crt" --from-file=client.key="$MTLS/channel-gateway-client.key" \
    --from-file=ca.crt="$MTLS/ca.crt" --dry-run=client -o yaml | $K apply -f - >/dev/null
$K -n channel create configmap channel-gateway-code --from-file=channel_gateway.py="$ROOT/app/channel_gateway.py" \
    --dry-run=client -o yaml | $K apply -f - >/dev/null
sed "s/__LEGACY_NODE_IP__/$LEGACY_IP/" "$ROOT/manifests/channel-gateway.yaml" | $K apply -f - >/dev/null
$K -n channel rollout restart deploy/channel-gateway >/dev/null
$K -n channel rollout status deploy/channel-gateway --timeout=420s
echo "channel-gateway hazır (bank-prod/channel, HTTPS NodePort 30990, mTLS)"
