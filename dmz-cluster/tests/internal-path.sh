#!/usr/bin/env bash
# DMZ → iç uçtan uca yol testi (design 5.1 / 5.2):
#   DMZ gateway (dış token, ext-authz, iç JWT) -> BackendTLSPolicy + DMZ istemci sertifikası -> iç gateway -> BFF/core
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CERTS="$ROOT/../edge/certs"
KD="kubectl --context kind-dmz"
KI="kubectl --context kind-identity"
ISSUER_BASE=http://127.0.0.1:18080/realms/bank/protocol/openid-connect/token

pass=0
fail=0
check() {
    local name=$1 expected=$2 actual=$3
    if [[ "$actual" == *"$expected"* ]]; then
        echo "PASS  $name"; pass=$((pass + 1))
    else
        echo "FAIL  $name  (beklenen: '$expected', gelen: '${actual:0:200}')"; fail=$((fail + 1))
    fi
}

secret() { $KI -n auth get secret keycloak-client-secrets -o jsonpath="{.data.$1}" | base64 -d; }
json_token() { sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p'; }

PF_PIDS=()
$KI -n auth port-forward svc/keycloak 18080:8080 >/dev/null 2>&1 & PF_PIDS+=($!)
$KD -n gw-web     port-forward svc/gw-web     19443:443 >/dev/null 2>&1 & PF_PIDS+=($!)
$KD -n gw-mobile  port-forward svc/gw-mobile  19444:443 >/dev/null 2>&1 & PF_PIDS+=($!)
$KD -n gw-partner port-forward svc/gw-partner 19445:443 >/dev/null 2>&1 & PF_PIDS+=($!)
trap 'kill "${PF_PIDS[@]}" 2>/dev/null' EXIT
sleep 6

CURL=(curl)
if curl -V 2>/dev/null | grep -qi schannel; then CURL=(curl --ssl-no-revoke); fi

source "$ROOT/../identity-cluster/tests/lib/pkce.sh"
PKCE_BASE=http://127.0.0.1:18080
WEB_TOKEN=$(pkce_token web-app https://web.lab.local:8443/callback alice "$(secret alice-password)" "$(secret web-app)" "")
PARTNER_TOKEN=$(curl -s -X POST "$ISSUER_BASE" -d grant_type=client_credentials -d client_id=partner-acme \
    -d "client_secret=$(secret partner-acme)" | json_token)

web_get() { # <token-or-empty> <path>
    local auth=()
    [[ -n "$1" ]] && auth=(-H "Authorization: Bearer $1")
    # DMZ gw-web gateway sertifikası iç CA'dan (SAN gw-web); port-forward üzerinden
    "${CURL[@]}" -s --max-time 20 --cacert "$CERTS/internal-ca.crt" "${auth[@]}" \
        --resolve "gw-web:19443:127.0.0.1" -w '\nHTTP_CODE=%{http_code}' "https://gw-web:19443$2"
}
partner_get() { # <token> <path>
    printf "GET $2 HTTP/1.1\r\nHost: partner-api.lab.local\r\nAuthorization: Bearer $1\r\nConnection: close\r\n\r\n" | \
        timeout 20 openssl s_client -connect 127.0.0.1:19445 -servername partner-api.lab.local \
        -CAfile "$CERTS/internal-ca.crt" -cert "$CERTS/partner-client.crt" -key "$CERTS/partner-client.key" \
        -quiet 2>/dev/null
}

# --- web: /bff/* iç BFF'e iletilir ---
body=$(web_get "$WEB_TOKEN" /bff/accounts)
check "web /bff: DMZ -> iç BFF (200)" "HTTP_CODE=200" "$body"
check "web /bff: iç BFF'ten yanıt (service=bff)" "service=bff" "$body"
check "web /bff: kanal bilgisi iç tarafa ulaştı (channel=web)" "channel=web" "$body"

body=$(web_get "" /bff/accounts)
check "web /bff: token yok -> 401 (DMZ ext-authz)" "HTTP_CODE=401" "$body"

# --- web: /bff dışındaki yollar DMZ'de kalır (iç gateway'e gitmez) ---
body=$(web_get "$WEB_TOKEN" /api/accounts)
check "web /api: DMZ default deny -> 404" "HTTP_CODE=404" "$body"

# --- partner: /partner/* iç core'a iletilir ---
body=$(partner_get "$PARTNER_TOKEN" /partner/payments)
check "partner /partner: DMZ -> iç core (service=core)" "service=core" "$body"
check "partner /partner: kanal bilgisi iç tarafa ulaştı (channel=partner)" "channel=partner" "$body"

# --- partner: web token /partner'da iç RBAC tarafından reddedilir ---
body=$(partner_get "$WEB_TOKEN" /partner/payments)
check "partner /partner: web token -> 403 (iç RBAC)" "403" "$body"

echo
echo "Sonuç: $pass geçti, $fail kaldı (toplam $((pass + fail)))"
[[ $fail -eq 0 ]]
