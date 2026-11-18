#!/usr/bin/env bash
# Seal Mobile (vendor mock) DMZ cluster'a kurar (ns seal-mobile): passthrough gateway gw-seal (SNI seal.lab.local).
# Ön koşul: identity'de Password Manager, internal'da Seal Intranet + gw-internal route'ları.
# Tekrar çalıştırılabilir. Cihaz CA'sı: edge/certs/device (gen-device-certs.sh).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$ROOT/.." && pwd)"
K="kubectl --context kind-dmz"
IMAGE="dmz-lab/seal-mobile:0.1.0"
CERTS="$REPO/edge/certs"
SEAL_CERTS="$CERTS/seal"

[[ -f "$SEAL_CERTS/seal-mobile.crt" ]] || bash "$REPO/edge/scripts/gen-seal-certs.sh"
source "$REPO/scripts/seal-keys.sh"
source "$REPO/scripts/lab-ips.sh"

docker build -q -t "$IMAGE" "$ROOT/seal-mobile" >/dev/null
kind load docker-image "$IMAGE" --name dmz >/dev/null

$K create namespace seal-mobile --dry-run=client -o yaml | $K apply -f - >/dev/null
$K -n seal-mobile create secret generic sm-tls \
    --from-file=server.crt="$SEAL_CERTS/seal-mobile.crt" --from-file=server.key="$SEAL_CERTS/seal-mobile.key" \
    --dry-run=client -o yaml | $K apply -f - >/dev/null
$K -n seal-mobile create secret generic sm-device-ca --from-file=device-ca.crt="$CERTS/device/device-ca.crt" \
    --dry-run=client -o yaml | $K apply -f - >/dev/null
$K -n seal-mobile create secret generic sm-internal-ca --from-file=internal-ca.crt="$CERTS/internal-ca.crt" \
    --dry-run=client -o yaml | $K apply -f - >/dev/null
$K -n seal-mobile create secret generic sm-dmz-client \
    --from-file=client.crt="$CERTS/dmz-client.crt" --from-file=client.key="$CERTS/dmz-client.key" \
    --dry-run=client -o yaml | $K apply -f - >/dev/null
SEAL_MOBILE_SECRET=$(kubectl --context kind-identity -n idp get secret idp-secrets -o jsonpath='{.data.SEAL_MOBILE_SECRET}' | base64 -d)
$K -n seal-mobile create secret generic sm-keys \
    --from-literal=SEAL_PM_KEY="$SEAL_PM_KEY" --from-literal=SEAL_MOCK_KEY="$SEAL_MOCK_KEY" \
    --from-literal=SEAL_MOBILE_SECRET="$SEAL_MOBILE_SECRET" \
    --dry-run=client -o yaml | $K apply -f - >/dev/null

render "$ROOT/manifests/seal-mobile.yaml" | $K apply -f -
$K -n seal-mobile rollout restart deploy/seal-mobile >/dev/null
$K -n seal-mobile rollout status deploy/seal-mobile --timeout=240s
echo "Seal Mobile hazır (DMZ, ns seal-mobile; passthrough NodePort 30456, SNI seal.lab.local)."
