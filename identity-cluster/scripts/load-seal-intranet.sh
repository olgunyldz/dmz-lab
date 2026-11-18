#!/usr/bin/env bash
# Seal Intranet (vendor mock) identity cluster'a kurar (ns seal-intranet). Tekrar çalıştırılabilir.
# Ön koşul: IdP (idp/spring-idp, idp/idp-secrets: SEAL_B2B_SECRET). Yalnızca IdP çağırır; dış yol yok.
#   1) Sırlar: scripts/seal-keys.sh (Vault secret/seal/v3) -> si-mock
#   2) TLS: edge/certs/seal (gen-seal-certs.sh) -> seal-intranet-tls; iç CA ConfigMap'i internal-ca-backend
#   3) İmaj derlenir, kind düğümlerine yüklenir; manifest uygulanır
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$ROOT/.." && pwd)"
K="kubectl --context kind-identity"
IMAGE="dmz-lab/seal-intranet:0.1.0"
CERTS="$REPO/edge/certs"
SEAL_CERTS="$CERTS/seal"

[[ -f "$SEAL_CERTS/seal-intranet.crt" ]] || bash "$REPO/edge/scripts/gen-seal-certs.sh"
source "$REPO/scripts/seal-keys.sh"

docker build -q -t "$IMAGE" "$ROOT/seal-intranet" >/dev/null
kind load docker-image "$IMAGE" --name identity >/dev/null

$K create namespace seal-intranet --dry-run=client -o yaml | $K apply -f - >/dev/null
$K -n seal-intranet create configmap internal-ca-backend --from-file=ca.crt="$CERTS/internal-ca.crt" \
    --dry-run=client -o yaml | $K apply -f - >/dev/null
$K -n seal-intranet create secret generic seal-intranet-tls \
    --from-file=server.crt="$SEAL_CERTS/seal-intranet.crt" --from-file=server.key="$SEAL_CERTS/seal-intranet.key" \
    --dry-run=client -o yaml | $K apply -f - >/dev/null
$K -n seal-intranet create secret generic si-mock --from-literal=SEAL_MOCK_KEY="$SEAL_MOCK_KEY" \
    --dry-run=client -o yaml | $K apply -f - >/dev/null

$K apply -f "$ROOT/manifests/seal-intranet.yaml"
$K -n seal-intranet rollout restart deploy/seal-intranet >/dev/null
$K -n seal-intranet rollout status deploy/seal-intranet --timeout=240s
echo "Seal Intranet hazır (identity, ns seal-intranet; yalnız küme içi HTTPS)."
