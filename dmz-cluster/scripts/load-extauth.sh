#!/usr/bin/env bash
# DMZ ext-authz bileşenlerini kurar:
#   - auth namespace'i, ext-authz Deployment/Service, iç kgateway'e Service+Endpoints, ReferenceGrant, GatewayExtension, TrafficPolicy
#   - kod ConfigMap'i (extauth/ext_authz.py) ve iç CA ConfigMap'i
#   - exchange-client-secrets: dmz-exchange-<kanal> client secret'ları identity cluster'dan kopyalanır
#   - ext-authz'in eski STS stub'ı (sts-internal) varsa kaldırılır
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
K="kubectl --context kind-dmz"
KI="kubectl --context kind-identity"
CERTS="$ROOT/../edge/certs"

$K apply -f "$ROOT/manifests/extauth.yaml"

# Eski stub kaldır (artık kullanılmıyor)
$K delete namespace sts-internal --ignore-not-found >/dev/null 2>&1 || true

# Token exchange istemci sertifikaları (kanal başına, Keycloak client-x509). Secret paylaşılmaz.
$K -n auth create secret generic dmz-exchange-client-tls \
    --from-file=web.crt="$CERTS/dmz-exchange-web.crt" --from-file=web.key="$CERTS/dmz-exchange-web.key" \
    --from-file=mobile.crt="$CERTS/dmz-exchange-mobile.crt" --from-file=mobile.key="$CERTS/dmz-exchange-mobile.key" \
    --from-file=partner.crt="$CERTS/dmz-exchange-partner.crt" --from-file=partner.key="$CERTS/dmz-exchange-partner.key" \
    --from-file=branch.crt="$CERTS/dmz-exchange-branch.crt" --from-file=branch.key="$CERTS/dmz-exchange-branch.key" \
    --dry-run=client -o yaml | $K apply -f -

$K -n auth create configmap ext-authz-code --from-file=ext_authz.py="$ROOT/extauth/ext_authz.py" \
    --dry-run=client -o yaml | $K apply -f -
$K -n auth create configmap internal-ca --from-file=internal-ca.crt="$CERTS/internal-ca.crt" \
    --dry-run=client -o yaml | $K apply -f -

# DMZ kimliği: iç gateway'e mTLS ile bağlanmak için istemci sertifikası
$K -n auth create secret tls dmz-gateway-client-tls --cert="$CERTS/dmz-client.crt" --key="$CERTS/dmz-client.key" \
    --dry-run=client -o yaml | $K apply -f -

$K -n auth rollout restart deploy/ext-authz >/dev/null
$K -n auth rollout status deploy/ext-authz --timeout=180s
echo "ext-authz kuruldu (token exchange: iç kgateway -> identity Keycloak)."
