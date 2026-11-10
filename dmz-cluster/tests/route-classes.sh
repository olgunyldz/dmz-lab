#!/usr/bin/env bash
# Route sınıfları testi:
#   public : token olmadan GET -> 200; POST -> 200 olmamalı
#   login  : token olmadan /realms/* -> 200 (ext-authz atlanır)
#   api    : token olmadan -> 401 (ext-authz)
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

CURL=(curl)
if curl -V 2>/dev/null | grep -qi schannel; then CURL=(curl --ssl-no-revoke); fi

# web_req <method> <port> <host> <path> -> "CODE<TAB>BODY"
req() {
    local method=$1 port=$2 host=$3 path=$4
    "${CURL[@]}" -s -X "$method" --max-time 10 --cacert "$CERTS/internal-ca.crt" \
        --resolve "$host:$port:127.0.0.1" -w '\nHTTP_CODE=%{http_code}' "https://$host:$port$path"
}

# --- web ---
body=$(req GET 19443 gw-web /public/branches)
check "web public GET /public/branches -> 200" "HTTP_CODE=200" "$body"
check "web public: ext-authz atlandı (token yok)" "service=core" "$body"

body=$(req POST 19443 gw-web /public/branches)
if [[ "$body" == *"HTTP_CODE=200"* ]]; then
    echo "FAIL  web public POST reddedilmeli"; fail=$((fail + 1))
else
    echo "PASS  web public POST reddedildi"; pass=$((pass + 1))
fi

body=$(req GET 19443 gw-web /realms/bank/.well-known/openid-configuration)
check "web login /realms/* token yok -> 200 (ext-authz atlandı)" "HTTP_CODE=200" "$body"

body=$(req GET 19443 gw-web /bff/accounts)
check "web api token yok -> 401 (ext-authz)" "HTTP_CODE=401" "$body"

# --- mobile ---
body=$(req GET 19444 gw-mobile /public/rates)
check "mobile public GET -> 200" "HTTP_CODE=200" "$body"

body=$(req GET 19444 gw-mobile /realms/bank/.well-known/openid-configuration)
check "mobile login /realms/* -> 200" "HTTP_CODE=200" "$body"

body=$(req GET 19444 gw-mobile /bff/accounts)
check "mobile api token yok -> 401" "HTTP_CODE=401" "$body"

# --- partner (mTLS gateway'de; openssl ile) ---
partner_raw() {
    printf "$1" | timeout 10 openssl s_client -connect 127.0.0.1:19445 -servername partner-api.lab.local \
        -CAfile "$CERTS/internal-ca.crt" -cert "$CERTS/partner-client.crt" -key "$CERTS/partner-client.key" \
        -quiet 2>/dev/null
}

out=$(partner_raw 'GET /realms/bank/.well-known/openid-configuration HTTP/1.1\r\nHost: partner-api.lab.local\r\nConnection: close\r\n\r\n')
check "partner login /realms/* -> 200" "200 OK" "$out"

out=$(partner_raw 'GET /partner/payments HTTP/1.1\r\nHost: partner-api.lab.local\r\nConnection: close\r\n\r\n')
check "partner api token yok -> 401" "401" "$out"

echo
echo "Sonuç: $pass geçti, $fail kaldı"
[[ $fail -eq 0 ]]
