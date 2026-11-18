#!/usr/bin/env bash
# Password Manager (vendor mock) identity cluster'a kurar (ns seal-pm). Tekrar çalıştırılabilir.
#   1) Sırlar: scripts/seal-keys.sh (Vault secret/seal/v3) -> pm-key secret'ı
#   2) TLS: edge/certs/seal (gen-seal-certs.sh) -> pm-tls secret'ı
#   3) İmaj derlenir, kind düğümlerine yüklenir; manifest uygulanır
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$ROOT/.." && pwd)"
K="kubectl --context kind-identity"
IMAGE="dmz-lab/password-manager:0.1.0"
CERTS="$REPO/edge/certs/seal"

[[ -f "$CERTS/password-manager.crt" ]] || bash "$REPO/edge/scripts/gen-seal-certs.sh"
source "$REPO/scripts/seal-keys.sh"

docker build -q -t "$IMAGE" "$ROOT/password-manager" >/dev/null
kind load docker-image "$IMAGE" --name identity >/dev/null

$K create namespace seal-pm --dry-run=client -o yaml | $K apply -f - >/dev/null
$K -n seal-pm create secret generic pm-key --from-literal=PM_KEY="$SEAL_PM_KEY" \
    --dry-run=client -o yaml | $K apply -f - >/dev/null
$K -n seal-pm create secret generic pm-tls \
    --from-file=server.crt="$CERTS/password-manager.crt" --from-file=server.key="$CERTS/password-manager.key" \
    --dry-run=client -o yaml | $K apply -f - >/dev/null

$K apply -f "$ROOT/manifests/password-manager.yaml"
$K -n seal-pm rollout restart deploy/password-manager >/dev/null
$K -n seal-pm rollout status deploy/password-manager --timeout=240s
echo "Password Manager hazır (identity, ns seal-pm, NodePort 30455, HTTPS)."
