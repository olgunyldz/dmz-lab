#!/usr/bin/env bash
# ext-authz uçtan uca testi (gerçek IdP token'ları).
#   - Dış token DMZ'de RS256 (JWKS), iss, aud, channel, exp ile doğrulanır.
#   - Geçerliyse ext-authz token exchange yapar, iç JWT yalnızca iç route'lara (/bff, /partner) iletilir.
#   - İç token hiçbir zaman istemciye dönmez (sızıntı testi).
#   - Upstream claim'leri iç servislerin x-channel / x-auth-method yanıtından doğrulanır.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CERTS="$ROOT/../edge/certs"
KD="kubectl --context kind-dmz"
KI="kubectl --context kind-identity"
ISSUER_BASE=https://id.bank.lab.local/realms/bank/protocol/openid-connect/token
IDP_PORT=${IDP_PORT:-18447}

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
absent() { # <name> <needle> <haystack>
    if [[ "$3" == *"$2"* ]]; then
        echo "FAIL  $1  (istenmeyen içerik bulundu)"; fail=$((fail + 1))
    else
        echo "PASS  $1"; pass=$((pass + 1))
    fi
}

# Sırlar Spring IdP'nin secret'ından (idp/idp-secrets); test adları -> anahtar eşlemesi
secret() {
    local k
    case "$1" in
        alice-password) k=ALICE_PASSWORD ;; web-app) k=WEB_APP_SECRET ;; partner-acme) k=PARTNER_ACME_SECRET ;;
        bff) k=BFF_SECRET ;; core-svc) k=CORE_SVC_SECRET ;; *) k=$1 ;;
    esac
    $KI -n idp get secret idp-secrets -o jsonpath="{.data.$k}" | base64 -d
}
b64u() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

PF_PIDS=()
$KI -n idp port-forward svc/spring-idp "$IDP_PORT:8443" >/dev/null 2>&1 & PF_PIDS+=($!)
$KD -n gw-web     port-forward svc/gw-web     19443:443 >/dev/null 2>&1 & PF_PIDS+=($!)
$KD -n gw-mobile  port-forward svc/gw-mobile  19444:443 >/dev/null 2>&1 & PF_PIDS+=($!)
$KD -n gw-partner port-forward svc/gw-partner 19445:443 >/dev/null 2>&1 & PF_PIDS+=($!)
trap 'kill "${PF_PIDS[@]}" 2>/dev/null' EXIT
sleep 6

CURL=(curl)
if curl -V 2>/dev/null | grep -qi schannel; then CURL=(curl --ssl-no-revoke); fi

# Servis (client credentials) token'ı. Kullanıcı token'ları PKCE ile alınır (aşağıda); şifre grant'i yok.
token_from() { # <client-id> <secret>
    local body
    body=$("${CURL[@]}" --cacert "$CERTS/internal-ca.crt" --connect-to "id.bank.lab.local:443:127.0.0.1:$IDP_PORT" \
        -u "$1:$2" -X POST "$ISSUER_BASE" -d grant_type=client_credentials)
    echo "$body" | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p'
}

web_get() { # <token-or-empty> <path>
    local auth=()
    [[ -n "$1" ]] && auth=(-H "Authorization: Bearer $1")
    "${CURL[@]}" -s --max-time 20 --cacert "$CERTS/internal-ca.crt" "${auth[@]}" \
        --resolve "gw-web:19443:127.0.0.1" -w '\nHTTP_CODE=%{http_code}' "https://gw-web:19443$2"
}
mobile_get() { # <token> <path>
    "${CURL[@]}" -s --max-time 20 --cacert "$CERTS/internal-ca.crt" -H "Authorization: Bearer $1" \
        --resolve "gw-mobile:19444:127.0.0.1" -w '\nHTTP_CODE=%{http_code}' "https://gw-mobile:19444$2"
}

partner_get() { # <token-or-empty> <path>
    local auth=""
    [[ -n "$1" ]] && auth="Authorization: Bearer $1\r\n"
    printf "GET $2 HTTP/1.1\r\nHost: partner-api.lab.local\r\n${auth}Connection: close\r\n\r\n" | \
        timeout 20 openssl s_client -connect 127.0.0.1:19445 -servername partner-api.lab.local \
        -CAfile "$CERTS/internal-ca.crt" -cert "$CERTS/partner-client.crt" -key "$CERTS/partner-client.key" \
        -quiet 2>/dev/null
}

# Kullanıcı token'ları: Authorization Code + PKCE (web ve mobil: Bearer)
source "$ROOT/../identity-cluster/tests/lib/pkce.sh"
PKCE_BASE=https://id.bank.lab.local
# IdP TLS: sunucu sertifikası lab CA ile imzalı; yayın host'u port-forward'a yönlendirilir (schannel iptal kontrolü kapalı)
PKCE_CURL_ARGS="${CURL[*]:1} --cacert $CERTS/internal-ca.crt --connect-to id.bank.lab.local:443:127.0.0.1:$IDP_PORT"
WEB_TOKEN=$(pkce_token web-app https://web.lab.local:8443/callback alice "$(secret alice-password)" "$(secret web-app)" "")
PARTNER_TOKEN=$(token_from partner-acme "$(secret partner-acme)" "")
echo "token'lar alındı: web=${#WEB_TOKEN} partner=${#PARTNER_TOKEN}"
# Tek aktif giriş: alice'in mobil girişi web oturumunu düşürür. Bu yüzden mobil token web bölümünden SONRA alınır.

# 1) Token yok -> 401 (iç route'ta)
check "web /bff: token yok -> 401" "HTTP_CODE=401" "$(web_get "" /bff/accounts)"

# 2) Geçerli web token -> 200; iç servis kanal ve kimlik doğrulama yöntemini görür
body=$(web_get "$WEB_TOKEN" /bff/accounts)
check "web /bff: geçerli token -> 200" "HTTP_CODE=200" "$body"
check "web /bff: upstream channel=web" "channel=web" "$body"
check "web /bff: upstream auth_method=pwd_otp" "auth_method=pwd_otp" "$body"
absent "web /bff: yanıtta iç token yok (Bearer)" "Bearer" "$body"
absent "web /bff: yanıtta JWT yok" "eyJ" "$body"

# Mobil giriş (yeni oturum; web oturumu bu noktadan sonra geçersizdir)
MOBILE_TOKEN=$(pkce_token mobile-app com.bank.app:/callback alice "$(secret alice-password)" "")

# 3) Mobil token web gateway'de -> 403 (kanal/audience uyuşmazlığı)
check "web /bff: mobil token -> 403" "HTTP_CODE=403" "$(web_get "$MOBILE_TOKEN" /bff/accounts)"

# 4) Mobil: bearer token ile iş API'si (DPoP yok); exchange çalışır
body=$(mobile_get "$MOBILE_TOKEN" /bff/accounts)
check "mobile /bff: bearer token -> 200" "HTTP_CODE=200" "$body"
check "mobile /bff: upstream channel=mobile" "channel=mobile" "$body"
check "mobile /bff: upstream auth_method=device" "auth_method=device" "$body"
absent "mobile /bff: yanıtta iç token yok" "eyJ" "$body"

# Web girişi yeniden (mobil oturum düşer); aşağıdaki web testleri geçerli web token'ı kullanır
WEB_TOKEN=$(pkce_token web-app https://web.lab.local:8443/callback alice "$(secret alice-password)" "$(secret web-app)" "")

# 5) Bozulmuş payload -> 401
tampered="$(echo "$WEB_TOKEN" | cut -d. -f1).$(echo '{"iss":"https://id.bank.lab.local/realms/bank","aud":"channel-web","channel":"web","exp":9999999999}' | b64u).$(echo "$WEB_TOKEN" | cut -d. -f3)"
check "web /bff: bozulmuş payload -> 401" "HTTP_CODE=401" "$(web_get "$tampered" /bff/accounts)"

# 6) HS256 ile imzalanmış sahte token -> 401
hs_h=$(printf '%s' '{"alg":"HS256","typ":"JWT"}' | b64u)
hs_p=$(printf '%s' '{"iss":"https://id.bank.lab.local/realms/bank","aud":"channel-web","channel":"web","exp":9999999999}' | b64u)
hs_s=$(printf '%s.%s' "$hs_h" "$hs_p" | openssl dgst -sha256 -hmac "lab" -binary | b64u)
check "web /bff: HS256 sahte token -> 401" "HTTP_CODE=401" "$(web_get "$hs_h.$hs_p.$hs_s" /bff/accounts)"

# 7) Tanımsız DMZ yolu, token olsa bile -> 404 (default deny; iç token üretilmez)
check "web /api (tanımsız): token ile -> 404" "HTTP_CODE=404" "$(web_get "$WEB_TOKEN" /api/accounts)"

# 8) Partner: client credentials token -> 200; iç servis kanal ve yöntemi görür
body=$(partner_get "$PARTNER_TOKEN" /partner/payments)
check "partner /partner: geçerli token -> 200" "200 OK" "$body"
check "partner /partner: upstream channel=partner" "channel=partner" "$body"
check "partner /partner: upstream auth_method=mtls_partner" "auth_method=mtls_partner" "$body"
absent "partner /partner: yanıtta iç token yok" "eyJ" "$body"

# 9) Partner: token yok -> 401 (ext-authz); mTLS geçer
check "partner /partner: token yok -> 401" "401" "$(partner_get "" /partner/payments)"

# 10) Partner gateway'e web token -> 403
check "partner /partner: web token -> 403" "403" "$(partner_get "$WEB_TOKEN" /partner/payments)"

echo
echo "Sonuç: $pass geçti, $fail kaldı (toplam $((pass + fail)))"
[[ $fail -eq 0 ]]
