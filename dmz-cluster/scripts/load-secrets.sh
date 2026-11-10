#!/usr/bin/env bash
# DMZ cluster için TLS secret'larını ve partner CA'sını edge/certs'ten yükler.
# Lab sertifikaları kullanılır. Üretimde bu sertifikalar cert-manager + Vault üzerinden gelir.
set -euo pipefail

CTX="kind-dmz"
CERTS="$(cd "$(dirname "$0")/../../edge/certs" && pwd)"
K="kubectl --context $CTX"

tls_secret() {
    local ns=$1 name=$2 crt=$3 key=$4
    $K -n "$ns" create secret tls "$name" --cert="$CERTS/$crt" --key="$CERTS/$key" \
        --dry-run=client -o yaml | $K apply -f -
}

tls_secret gw-web     gw-web-tls     gw-web.crt     gw-web.key
tls_secret gw-mobile  gw-mobile-tls  gw-mobile.crt  gw-mobile.key
tls_secret gw-partner gw-partner-tls gw-partner.crt gw-partner.key

# Partner istemci CA'sı (mTLS doğrulaması için ConfigMap)
$K -n gw-partner create configmap partner-ca --from-file=ca.crt="$CERTS/partner-ca.crt" \
    --dry-run=client -o yaml | $K apply -f -

echo "Secret ve ConfigMap'ler yüklendi."
