#!/usr/bin/env bash
# Dummy iş API'si testi (BFF -> core): hesaplar, işlemler, transfer, idempotency, limit, bakiye, yetki.
# Gerçek yol: web token -> exchange (dmz-exchange-web) -> iç gateway -> BFF -> core.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CERTS="$ROOT/../edge/certs"
KI="kubectl --context kind-identity"
KN="kubectl --context kind-internal"
TOKEN_PATH=/realms/bank/protocol/openid-connect/token

pass=0
fail=0
check() {
    local name=$1 expected=$2 actual=$3
    if [[ "$actual" == *"$expected"* ]]; then
        echo "PASS  $name"; pass=$((pass + 1))
    else
        echo "FAIL  $name  (beklenen: '$expected', gelen: '${actual:0:220}')"; fail=$((fail + 1))
    fi
}

secret() { $KI -n auth get secret keycloak-client-secrets -o jsonpath="{.data.$1}" | base64 -d; }
json_token() { sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p'; }

PF=()
$KI -n auth port-forward svc/keycloak 18080:8080 >/dev/null 2>&1 & PF+=($!)
$KN -n gw-internal port-forward svc/gw-internal 19543:443 >/dev/null 2>&1 & PF+=($!)
trap 'kill "${PF[@]}" 2>/dev/null' EXIT
sleep 6

source "$ROOT/../identity-cluster/tests/lib/pkce.sh"
PKCE_BASE=http://127.0.0.1:18080
WEB_EXT=$(pkce_token web-app https://web.lab.local:8443/callback alice "$(secret alice-password)" "$(secret web-app)" "")
PARTNER_EXT=$(curl -s -X POST "http://127.0.0.1:18080$TOKEN_PATH" -d grant_type=client_credentials -d client_id=partner-acme \
    -d "client_secret=$(secret partner-acme)" | json_token)

# gw_raw <method> <path> <content-type|""> <body> [token] [extra-header] -> ham HTTP yanıtı (mTLS: GW_CERT)
gw_raw() {
    local method=$1 path=$2 ctype=$3 data=$4 token=${5:-} hdr=${6:-} extra=""
    [[ -n "$token" ]] && extra="Authorization: Bearer $token"$'\r\n'
    [[ -n "$hdr" ]] && extra="${extra}${hdr}"$'\r\n'
    [[ -n "$ctype" ]] && extra="${extra}Content-Type: $ctype"$'\r\n'"Content-Length: ${#data}"$'\r\n'
    local raw="" _
    for _ in 1 2 3 4; do
        raw=$(printf "%s %s HTTP/1.1\r\nHost: gw-internal\r\n%sConnection: close\r\n\r\n%s" \
            "$method" "$path" "$extra" "$data" | timeout 20 openssl s_client -connect 127.0.0.1:19543 \
            -servername gw-internal -CAfile "$CERTS/internal-ca.crt" \
            -cert "$CERTS/${GW_CERT:-dmz-client}.crt" -key "$CERTS/${GW_CERT:-dmz-client}.key" -quiet 2>/dev/null)
        [[ "$raw" == *"HTTP/1.1"* ]] && break
        sleep 1
    done
    printf '%s' "$raw"
}
exchange() { # <kanal> <dış token> -> iç JWT
    local form="grant_type=urn:ietf:params:oauth:grant-type:token-exchange&client_id=dmz-exchange-$1&subject_token=$2&subject_token_type=urn:ietf:params:oauth:token-type:access_token&requested_token_type=urn:ietf:params:oauth:token-type:access_token&audience=kgateway-internal"
    GW_CERT="dmz-exchange-$1" gw_raw POST "$TOKEN_PATH" "application/x-www-form-urlencoded" "$form" | json_token
}

WEB_INT=$(exchange web "$WEB_EXT")
PARTNER_INT=$(exchange partner "$PARTNER_EXT")
RUN=$(openssl rand -hex 3)

# 1) Hesap listesi: 2 dummy hesap, TRY, bakiye alanı
out=$(gw_raw GET /bff/web/accounts "" "" "$WEB_INT")
check "web hesap listesi 200" "HTTP/1.1 200" "$out"
check "web hesap listesi: accounts alanı" '"accounts"' "$out"
ACC=$(echo "$out" | grep -o 'TR[0-9A-F]\{12\}' | head -n1)
check "hesap kimliği üretildi" "TR" "$ACC"

# 2) Token yok -> 401 (JSON hata gövdesi)
out=$(gw_raw GET /bff/web/accounts "" "" "")
check "token yok -> 401" "Jwt is missing" "$out"

# 3) İşlem geçmişi
out=$(gw_raw GET "/bff/web/accounts/$ACC/transactions" "" "" "$WEB_INT")
check "işlem geçmişi 200" "HTTP/1.1 200" "$out"
check "işlem geçmişi: transactions alanı" '"transactions"' "$out"

# 4) Transfer (1.00 TRY) + idempotency
IDEM="K-$RUN-1"
BODY="{\"from\":\"$ACC\",\"to\":\"EXT-100001\",\"amount\":\"1.00\",\"currency\":\"TRY\",\"description\":\"test $RUN\"}"
out=$(gw_raw POST /bff/web/transfers "application/json" "$BODY" "$WEB_INT" "Idempotency-Key: $IDEM")
check "transfer 200" "HTTP/1.1 200" "$out"
check "transfer completed" '"status": "completed"' "$out"
TID1=$(echo "$out" | grep -o '"transfer_id": "[^"]*"' | head -n1)
out=$(gw_raw POST /bff/web/transfers "application/json" "$BODY" "$WEB_INT" "Idempotency-Key: $IDEM")
TID2=$(echo "$out" | grep -o '"transfer_id": "[^"]*"' | head -n1)
check "aynı Idempotency-Key -> aynı transfer (çift işlem yok)" "$TID1" "$TID2"

# 5) Idempotency-Key yok -> 400
out=$(gw_raw POST /bff/web/transfers "application/json" "$BODY" "$WEB_INT")
check "Idempotency-Key yok -> 400" "HTTP/1.1 400" "$out"
check "Idempotency-Key yok: açıklama" "Idempotency-Key" "$out"

# 6) Negatif / geçersiz tutar -> 400
out=$(gw_raw POST /bff/web/transfers "application/json" "{\"from\":\"$ACC\",\"to\":\"EXT-100001\",\"amount\":\"-5\"}" "$WEB_INT" "Idempotency-Key: K-$RUN-neg")
check "negatif tutar -> 400" "HTTP/1.1 400" "$out"

# 7) Bakiye yetersiz -> 422 (web limiti içinde, bakiyeden büyük)
out=$(gw_raw POST /bff/web/transfers "application/json" "{\"from\":\"$ACC\",\"to\":\"EXT-100001\",\"amount\":\"90000\",\"currency\":\"TRY\"}" "$WEB_INT" "Idempotency-Key: K-$RUN-bal")
check "yetersiz bakiye -> 422" "yetersiz bakiye" "$out"

# 8) Kanal limiti -> 422
out=$(gw_raw POST /bff/web/transfers "application/json" "{\"from\":\"$ACC\",\"to\":\"EXT-100001\",\"amount\":\"999999\",\"currency\":\"TRY\"}" "$WEB_INT" "Idempotency-Key: K-$RUN-lim")
check "kanal limiti -> 422" "limiti aşıldı" "$out"

# 9) Başkasının / olmayan hesabı -> 404 (varlığı sızdırılmaz)
out=$(gw_raw GET "/bff/web/accounts/TRDEADBEEF0000/transactions" "" "" "$WEB_INT")
check "olmayan hesap -> 404" "HTTP/1.1 404" "$out"

# 10) Partner token ile web rotası -> 403 (gateway RBAC / kanal kuralı)
PART_INT=$(exchange partner "$PARTNER_EXT")
out=$(gw_raw GET /bff/web/accounts "" "" "$PART_INT")
check "partner token web rotasında -> 403" "HTTP/1.1 403" "$out"

echo
echo "Sonuç: $pass geçti, $fail kaldı (toplam $((pass + fail)))"
[[ $fail -eq 0 ]]
