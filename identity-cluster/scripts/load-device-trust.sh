#!/usr/bin/env bash
# Cihaz güven servisini identity cluster'a kurar (örnek). Tekrar çalıştırılabilir.
#   1) Cihaz sertifikaları yoksa üretilir (edge/scripts/gen-device-certs.sh)
#   2) İmaj derlenir, kind düğümlerine yüklenir
#   3) Secret'lar (devtrust-tls, devtrust-device-ca) ve manifest uygulanır
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$ROOT/.." && pwd)"
CERTS="$REPO/edge/certs/device"
K="kubectl --context kind-identity"
IMAGE="dmz-lab/device-trust:0.1.0"

[[ -f "$CERTS/device-trust.crt" ]] || bash "$REPO/edge/scripts/gen-device-certs.sh"

docker build -q -t "$IMAGE" "$ROOT/device-trust" >/dev/null
kind load docker-image "$IMAGE" --name identity >/dev/null

$K create namespace devtrust --dry-run=client -o yaml | $K apply -f - >/dev/null
$K -n devtrust create secret generic devtrust-tls \
    --from-file=device-trust.crt="$CERTS/device-trust.crt" --from-file=device-trust.key="$CERTS/device-trust.key" \
    --dry-run=client -o yaml | $K apply -f - >/dev/null
$K -n devtrust create secret generic devtrust-device-ca \
    --from-file=device-ca.crt="$CERTS/device-ca.crt" --dry-run=client -o yaml | $K apply -f - >/dev/null

$K apply -f "$ROOT/manifests/device-trust.yaml"
$K -n devtrust rollout restart deploy/device-trust >/dev/null
$K -n devtrust rollout status deploy/device-trust --timeout=240s
echo "device-trust hazır (devtrust/device-trust, NodePort 30445)."
