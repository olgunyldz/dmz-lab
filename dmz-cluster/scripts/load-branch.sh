#!/usr/bin/env bash
# Şube (branch) zone DMZ kurulumu: gw-branch gateway'i, secret/ConfigMap'ler ve iç gateway istemci sertifikası.
#   1) manifests/branch.yaml (namespace önce gelir)
#   2) gw-branch-tls (sunucu, internal-ca), branch-ca (cihaz CA'sı), internal-ca-backend, dmz-gateway-client-tls
#   3) Gateway spec.tls.backend.clientCertificateRef -> dmz-gateway-client-tls
# Önce: bash edge/scripts/gen-branch-certs.sh. Ext-authz (branch kanalı) için scripts/load-extauth.sh çalıştırın.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
K="kubectl --context kind-dmz"
CERTS="$ROOT/../edge/certs"

$K apply -f "$ROOT/manifests/branch.yaml"

$K -n gw-branch create secret tls gw-branch-tls --cert="$CERTS/gw-branch.crt" --key="$CERTS/gw-branch.key" \
    --dry-run=client -o yaml | $K apply -f -
$K -n gw-branch create configmap branch-ca --from-file=ca.crt="$CERTS/branch-ca.crt" \
    --dry-run=client -o yaml | $K apply -f -
$K -n gw-branch create configmap internal-ca-backend --from-file=ca.crt="$CERTS/internal-ca.crt" \
    --dry-run=client -o yaml | $K apply -f -
$K -n gw-branch create secret tls dmz-gateway-client-tls --cert="$CERTS/dmz-client.crt" --key="$CERTS/dmz-client.key" \
    --dry-run=client -o yaml | $K apply -f -

$K -n gw-branch patch gateway gw-branch --type merge -p \
    '{"spec":{"tls":{"backend":{"clientCertificateRef":{"group":"","kind":"Secret","name":"dmz-gateway-client-tls"}}}}}' >/dev/null

$K -n gw-branch wait --for=condition=available deploy --all --timeout=300s 2>/dev/null || true
echo "gw-branch hazır (NodePort 30449). Test: bash dmz-cluster/tests/branch.sh"
