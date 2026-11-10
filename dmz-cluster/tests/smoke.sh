#!/usr/bin/env bash
# DMZ cluster duman testleri: her kanal gateway'i TLS üzerinden yanıt vermeli,
# partner gateway'i istemci sertifikasız bağlantıyı reddetmeli.
# Gateway'lere port-forward ile erişilir (kind'da LoadBalancer IP yok).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CERTS="$ROOT/../edge/certs"
K="kubectl --context kind-dmz"

pass=0
fail=0
check() {
    local name=$1 expected=$2 actual=$3
    if [[ "$actual" == *"$expected"* ]]; then
        echo "PASS  $name"; pass=$((pass + 1))
    else
        echo "FAIL  $name  (beklenen: '$expected', gelen: '$actual')"; fail=$((fail + 1))
    fi
}

PF_PIDS=()
$K -n gw-web     port-forward svc/gw-web     19443:443 >/dev/null 2>&1 & PF_PIDS+=($!)
$K -n gw-mobile  port-forward svc/gw-mobile  19444:443 >/dev/null 2>&1 & PF_PIDS+=($!)
$K -n gw-partner port-forward svc/gw-partner 19445:443 >/dev/null 2>&1 & PF_PIDS+=($!)
trap 'kill "${PF_PIDS[@]}" 2>/dev/null' EXIT
sleep 4

# Windows curl (schannel) lab CA'sının CRL'ini bulamıyor
CURL=(curl)
if curl -V 2>/dev/null | grep -qi schannel; then CURL=(curl --ssl-no-revoke); fi

body=$("${CURL[@]}" -s --max-time 10 --cacert "$CERTS/internal-ca.crt" \
    --resolve "gw-web:19443:127.0.0.1" https://gw-web:19443/bff/accounts)
check "web gateway: token yok -> ext-authz 401" "missing bearer token" "$body"

body=$("${CURL[@]}" -s --max-time 10 --cacert "$CERTS/internal-ca.crt" \
    --resolve "gw-mobile:19444:127.0.0.1" https://gw-mobile:19444/bff/accounts)
check "mobile gateway: token yok -> ext-authz 401" "missing bearer token" "$body"

# Partner: istemci sertifikası yok -> TLS seviyesinde reddedilmeli
out=$(printf 'GET /partner/payments HTTP/1.1\r\nHost: partner-api.lab.local\r\nConnection: close\r\n\r\n' | timeout 10 \
    openssl s_client -connect 127.0.0.1:19445 -servername partner-api.lab.local \
    -CAfile "$CERTS/internal-ca.crt" -quiet 2>&1)
check "partner sertifikasız -> reddedilir" "certificate required" "$out"

# Partner: geçerli istemci sertifikası -> kabul
out=$(printf 'GET /partner/payments HTTP/1.1\r\nHost: partner-api.lab.local\r\nConnection: close\r\n\r\n' | timeout 10 \
    openssl s_client -connect 127.0.0.1:19445 -servername partner-api.lab.local \
    -CAfile "$CERTS/internal-ca.crt" -cert "$CERTS/partner-client.crt" -key "$CERTS/partner-client.key" \
    -quiet 2>/dev/null)
check "partner mTLS geçer, token yok -> ext-authz 401" "missing bearer token" "$out"

echo
echo "Sonuç: $pass geçti, $fail kaldı"
[[ $fail -eq 0 ]]
