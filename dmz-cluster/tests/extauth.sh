#!/usr/bin/env bash
# ext-authz uçtan uca testi (gerçek Keycloak token'ları).
#   - Dış token DMZ'de RS256 (JWKS), iss, aud, channel, exp ile doğrulanır.
#   - Geçerliyse ext-authz token exchange yapar, iç JWT yalnızca iç route'lara (/bff, /partner) iletilir.
#   - İç token hiçbir zaman istemciye dönmez (sızıntı testi).
#   - Upstream claim'leri iç servislerin x-channel / x-auth-method yanıtından doğrulanır.
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
absent() { # <name> <needle> <haystack>
    if [[ "$3" == *"$2"* ]]; then
        echo "FAIL  $1  (istenmeyen içerik bulundu)"; fail=$((fail + 1))
    else
        echo "PASS  $1"; pass=$((pass + 1))
    fi
}

secret() { $KI -n auth get secret keycloak-client-secrets -o jsonpath="{.data.$1}" | base64 -d; }
b64u() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# DPoP (RFC 9449) proof: test için RSA anahtarı (geçici), RS256 imzalı
DPOP_DIR=$(mktemp -d)
DPOP_KEY="$DPOP_DIR/dpop.pem"
openssl genrsa -out "$DPOP_KEY" 2048 2>/dev/null
DPOP_N=$(openssl rsa -in "$DPOP_KEY" -noout -modulus | cut -d= -f2 | xxd -r -p | b64u)
dpop_proof() { # <htm> <htu>
    local h p s
    h=$(printf '%s' "{\"typ\":\"dpop+jwt\",\"alg\":\"RS256\",\"jwk\":{\"kty\":\"RSA\",\"n\":\"$DPOP_N\",\"e\":\"AQAB\"}}" | b64u)
    p=$(printf '%s' "{\"htm\":\"$1\",\"htu\":\"$2\",\"iat\":$(date +%s),\"jti\":\"$(openssl rand -hex 8)\"}" | b64u)
    s=$(printf '%s.%s' "$h" "$p" | openssl dgst -sha256 -sign "$DPOP_KEY" | b64u)
    printf '%s.%s.%s' "$h" "$p" "$s"
}

PF_PIDS=()
$KI -n auth port-forward svc/keycloak 18080:8080 >/dev/null 2>&1 & PF_PIDS+=($!)
$KD -n gw-web     port-forward svc/gw-web     19443:443 >/dev/null 2>&1 & PF_PIDS+=($!)
$KD -n gw-mobile  port-forward svc/gw-mobile  19444:443 >/dev/null 2>&1 & PF_PIDS+=($!)
$KD -n gw-partner port-forward svc/gw-partner 19445:443 >/dev/null 2>&1 & PF_PIDS+=($!)
trap 'kill "${PF_PIDS[@]}" 2>/dev/null' EXIT
sleep 6

CURL=(curl)
if curl -V 2>/dev/null | grep -qi schannel; then CURL=(curl --ssl-no-revoke); fi

token_from() { # <client-id> <secret-or-empty> <user-or-empty>
    local body
    if [[ "$1" == "mobile-app" ]]; then
        local proof
        proof=$(dpop_proof POST "$ISSUER_BASE")
        body=$(curl -s -X POST "$ISSUER_BASE" -H "DPoP: $proof" -d grant_type=password -d client_id="$1" \
            -d username="$3" --data-urlencode "password=$(secret alice-password)")
    elif [[ -n "$3" ]]; then
        body=$(curl -s -X POST "$ISSUER_BASE" -d grant_type=password -d client_id="$1" \
            ${2:+-d client_secret="$2"} -d username="$3" --data-urlencode "password=$(secret alice-password)")
    else
        body=$(curl -s -X POST "$ISSUER_BASE" -d grant_type=client_credentials -d client_id="$1" -d "client_secret=$2")
    fi
    echo "$body" | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p'
}

web_get() { # <token-or-empty> <path>
    local auth=()
    [[ -n "$1" ]] && auth=(-H "Authorization: Bearer $1")
    "${CURL[@]}" -s --max-time 20 --cacert "$CERTS/internal-ca.crt" "${auth[@]}" \
        --resolve "gw-web:19443:127.0.0.1" -w '\nHTTP_CODE=%{http_code}' "https://gw-web:19443$2"
}
mobile_get() { # <token> <path> [dpop-proof]
    local proof_hdr=()
    [[ -n "${3:-}" ]] && proof_hdr=(-H "DPoP: $3")
    "${CURL[@]}" -s --max-time 20 --cacert "$CERTS/internal-ca.crt" -H "Authorization: Bearer $1" "${proof_hdr[@]}" \
        --resolve "gw-mobile:19444:127.0.0.1" -w '\nHTTP_CODE=%{http_code}' "https://gw-mobile:19444$2"
}

# RFC 9449 DPoP proof (kaynak isteği): ath = base64url(SHA-256(token)), htu = istek URL'i
rsa_jwk_n() { openssl rsa -in "$1" -noout -modulus | cut -d= -f2 | xxd -r -p | b64u; }
make_proof() { # <key-file> <htm> <htu> <token-or-empty> [jti] [iat]
    local key=$1 htm=$2 htu=$3 tok=$4 n h p s ath="" jti iat
    jti=${5:-$(openssl rand -hex 8)}
    iat=${6:-$(date +%s)}
    n=$(rsa_jwk_n "$key")
    h=$(printf '%s' "{\"typ\":\"dpop+jwt\",\"alg\":\"RS256\",\"jwk\":{\"kty\":\"RSA\",\"n\":\"$n\",\"e\":\"AQAB\"}}" | b64u)
    if [[ -n "$tok" ]]; then ath=",\"ath\":\"$(printf '%s' "$tok" | openssl dgst -sha256 -binary | b64u)\""; fi
    p=$(printf '%s' "{\"htm\":\"$htm\",\"htu\":\"$htu\",\"iat\":$iat,\"jti\":\"$jti\"$ath}" | b64u)
    s=$(printf '%s.%s' "$h" "$p" | openssl dgst -sha256 -sign "$key" | b64u)
    printf '%s.%s.%s' "$h" "$p" "$s"
}
MOBILE_HTU="https://gw-mobile:19444/bff/accounts"
OTHER_KEY="$DPOP_DIR/other.pem"
openssl genrsa -out "$OTHER_KEY" 2048 2>/dev/null
partner_get() { # <token-or-empty> <path>
    local auth=""
    [[ -n "$1" ]] && auth="Authorization: Bearer $1\r\n"
    printf "GET $2 HTTP/1.1\r\nHost: partner-api.lab.local\r\n${auth}Connection: close\r\n\r\n" | \
        timeout 20 openssl s_client -connect 127.0.0.1:19445 -servername partner-api.lab.local \
        -CAfile "$CERTS/internal-ca.crt" -cert "$CERTS/partner-client.crt" -key "$CERTS/partner-client.key" \
        -quiet 2>/dev/null
}

WEB_TOKEN=$(token_from lab-cli "$(secret lab-cli)" alice)
MOBILE_TOKEN=$(token_from mobile-app "" alice)
PARTNER_TOKEN=$(token_from partner-acme "$(secret partner-acme)" "")
echo "token'lar alındı: web=${#WEB_TOKEN} mobile=${#MOBILE_TOKEN} partner=${#PARTNER_TOKEN}"

# 1) Token yok -> 401 (iç route'ta)
check "web /bff: token yok -> 401" "HTTP_CODE=401" "$(web_get "" /bff/accounts)"

# 2) Geçerli web token -> 200; iç servis kanal ve kimlik doğrulama yöntemini görür
body=$(web_get "$WEB_TOKEN" /bff/accounts)
check "web /bff: geçerli token -> 200" "HTTP_CODE=200" "$body"
check "web /bff: upstream channel=web" "channel=web" "$body"
check "web /bff: upstream auth_method=pwd_otp" "auth_method=pwd_otp" "$body"
absent "web /bff: yanıtta iç token yok (Bearer)" "Bearer" "$body"
absent "web /bff: yanıtta JWT yok" "eyJ" "$body"

# 3) Mobil token web gateway'de -> 403 (kanal/audience uyuşmazlığı)
check "web /bff: mobil token -> 403" "HTTP_CODE=403" "$(web_get "$MOBILE_TOKEN" /bff/accounts)"

# 4) Mobil: DPoP (RFC 9449) doğrulaması
# 4a) DPoP proof yok -> 401
body=$(mobile_get "$MOBILE_TOKEN" /bff/accounts)
check "mobile /bff: DPoP proof yok -> 401" "missing dpop proof" "$body"

# 4b) Yanlış htu (başka yol için üretilmiş proof) -> 401
bad_htu=$(make_proof "$DPOP_KEY" GET "https://gw-mobile:19444/bff/other" "$MOBILE_TOKEN")
body=$(mobile_get "$MOBILE_TOKEN" /bff/accounts "$bad_htu")
check "mobile /bff: htu uyuşmazlığı -> 401" "htu mismatch" "$body"

# 4c) Yanlış anahtar (token cnf.jkt'si ile eşleşmiyor) -> 401
wrong_key=$(make_proof "$OTHER_KEY" GET "$MOBILE_HTU" "$MOBILE_TOKEN")
body=$(mobile_get "$MOBILE_TOKEN" /bff/accounts "$wrong_key")
check "mobile /bff: anahtar cnf.jkt ile eşleşmiyor -> 401" "does not match" "$body"

# 4d) Geçerli proof -> DPoP kontrolü geçer (401 değil). Token exchange SPI'ye kadar Keycloak reddedebilir.
replay_jti="lab-$(openssl rand -hex 6)"
good=$(make_proof "$DPOP_KEY" GET "$MOBILE_HTU" "$MOBILE_TOKEN" "$replay_jti")
body=$(mobile_get "$MOBILE_TOKEN" /bff/accounts "$good")
check "mobile /bff: geçerli DPoP + SPI exchange -> 200" "HTTP_CODE=200" "$body"
check "mobile /bff: upstream channel=mobile" "channel=mobile" "$body"
check "mobile /bff: upstream auth_method=dpop_device" "auth_method=dpop_device" "$body"
absent "mobile /bff: yanıtta iç token yok" "eyJ" "$body"

# 4e) Aynı proof tekrar -> replay, 401
body=$(mobile_get "$MOBILE_TOKEN" /bff/accounts "$good")
check "mobile /bff: proof tekrarı (replay) -> 401" "replayed proof" "$body"

# 4f) Eski iat (5 dk'dan eski) -> 401
old=$(make_proof "$DPOP_KEY" GET "$MOBILE_HTU" "$MOBILE_TOKEN" "lab-old-$(openssl rand -hex 4)" "$(( $(date +%s) - 900 ))")
body=$(mobile_get "$MOBILE_TOKEN" /bff/accounts "$old")
check "mobile /bff: eski iat -> 401" "stale or future iat" "$body"

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
