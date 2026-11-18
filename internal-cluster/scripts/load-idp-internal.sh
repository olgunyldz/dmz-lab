#!/usr/bin/env bash
# gw-internal -> IdP iç API ve Password Manager yolları: Service/Endpoints/BackendTLSPolicy/HTTPRoute + gateway istemci sertifikası.
# Tekrar çalıştırılabilir. Ön koşul: identity IdP ayakta (idp/spring-idp), gw-internal kurulu.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$ROOT/.." && pwd)"
K="kubectl --context kind-internal"
CERTS="$REPO/edge/certs"

source "$REPO/scripts/lab-ips.sh"

# BackendTLSPolicy için iç CA (gw-internal ns)
$K -n gw-internal create configmap internal-ca-backend --from-file=ca.crt="$CERTS/internal-ca.crt" \
    --dry-run=client -o yaml | $K apply -f - >/dev/null

render "$ROOT/manifests/idp-internal.yaml" | $K apply -f -

# Gateway, IdP'ye TLS ile giderken kendi sertifikasını sunar (CN=gw-internal; IdP allowlist'i bunu bekler)
$K -n gw-internal patch gateway gw-internal --type merge -p \
    '{"spec":{"tls":{"backend":{"clientCertificateRef":{"group":"","kind":"Secret","name":"gw-internal-tls"}}}}}' >/dev/null
# Password Manager gateway yolu (/seal-pm/ -> identity:30455; Seal Mobile PIN doğrulaması için)
render "$ROOT/manifests/seal-pm-route.yaml" | $K apply -f -

echo "IdP iç API yolu hazır: gw-internal /internal/auth/ -> identity:30443 (gateway istemci sertifikası: gw-internal)."
