#!/usr/bin/env bash
# DMZ gateway'lerinin iç gateway'e mTLS ile bağlanması için:
#   - internal-ca-backend ConfigMap (BackendTLSPolicy doğrulaması, key: ca.crt)
#   - dmz-gateway-client-tls Secret (DMZ istemci sertifikası)
#   - Gateway spec.tls.backend.clientCertificateRef
#   - internal-backend.yaml (Service, Endpoints, BackendTLSPolicy) ve channels.yaml route'ları
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
K="kubectl --context kind-dmz"
CERTS="$ROOT/../edge/certs"

for ns in gw-web gw-mobile gw-partner; do
    $K -n "$ns" create configmap internal-ca-backend --from-file=ca.crt="$CERTS/internal-ca.crt" \
        --dry-run=client -o yaml | $K apply -f -
    $K -n "$ns" create secret tls dmz-gateway-client-tls --cert="$CERTS/dmz-client.crt" --key="$CERTS/dmz-client.key" \
        --dry-run=client -o yaml | $K apply -f -
done

$K apply -f "$ROOT/manifests/internal-backend.yaml"
$K apply -f "$ROOT/manifests/channels.yaml"

for gw in gw-web:gw-web gw-mobile:gw-mobile gw-partner:gw-partner; do
    ns=${gw%%:*}
    $K -n "$ns" patch gateway "$ns" --type merge -p \
        '{"spec":{"tls":{"backend":{"clientCertificateRef":{"group":"","kind":"Secret","name":"dmz-gateway-client-tls"}}}}}'
done

echo "DMZ → iç gateway backend'i hazır."
