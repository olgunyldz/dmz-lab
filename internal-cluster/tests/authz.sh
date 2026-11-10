#!/usr/bin/env bash
# İç kgateway testi: iç JWT doğrulaması ve kanal bazlı RBAC.
# İç token'lar gerçek exchange ile alınır: dış token -> iç gateway üzerinden Keycloak token exchange.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CERTS="$ROOT/../edge/certs"
KI="kubectl --context kind-identity"
KN="kubectl --context kind-internal"
ISS_HOST=https://id.bank.lab.local/realms/bank
TOKEN_PATH=/realms/bank/protocol/openid-connect/token

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

jwt_payload() {
    echo "$1" | cut -d. -f2 | tr '_-' '/+' | awk '{ while (length($0) % 4) $0 = $0 "="; print }' | base64 -d 2>/dev/null | tr -d ' '
}
secret() { $KI -n auth get secret keycloak-client-secrets -o jsonpath="{.data.$1}" | base64 -d; }

b64u() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
DPOP_DIR=$(mktemp -d); DPOP_KEY="$DPOP_DIR/dpop.pem"
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
$KN -n gw-internal port-forward svc/gw-internal 19543:443 >/dev/null 2>&1 & PF_PIDS+=($!)
trap 'kill "${PF_PIDS[@]}" 2>/dev/null' EXIT
sleep 6

CURL=(curl)
if curl -V 2>/dev/null | grep -qi schannel; then CURL=(curl --ssl-no-revoke); fi
# DMZ kimliği: iç gateway mTLS ister. Windows schannel için PKCS#12.
CERT_OPTS=(--cert-type P12 --cert "$CERTS/dmz-client.p12:lab-dmz")
KC_LOCAL=http://127.0.0.1:18080$TOKEN_PATH

json_token() { sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p'; }

# Dış token'lar (Keycloak, identity cluster)
source "$ROOT/../identity-cluster/tests/lib/pkce.sh"
PKCE_BASE=http://127.0.0.1:18080
WEB_EXT=$(pkce_token web-app https://web.lab.local:8443/callback alice "$(secret alice-password)" "$(secret web-app)" "")
MOBILE_EXT=$(pkce_token mobile-app com.bank.app:/callback alice "$(secret alice-password)" "" \
    "$(dpop_proof POST "$KC_LOCAL")")
PARTNER_EXT=$(curl -s -X POST "$KC_LOCAL" -d grant_type=client_credentials -d client_id=partner-acme \
    -d "client_secret=$(secret partner-acme)" | json_token)

# İç token'lar: exchange, iç gateway üzerinden (gerçek yol)
# İç gateway istemcisi: DMZ kimliği (mTLS) ile openssl s_client (schannel PKCS#12 yükleyemiyor)
gw_raw() { # <method> <path> <content-type-or-empty> <body> [token] -> ham HTTP yanıtı
    local method=$1 path=$2 ctype=$3 data=$4 token=${5:-} extra=""
    # Başlık satırları gerçek CRLF ile (\r\n çift tırnakta yorumlanmaz, $'...' kullan)
    [[ -n "$token" ]] && extra="Authorization: Bearer $token"$'\r\n'
    [[ -n "$ctype" ]] && extra="${extra}Content-Type: $ctype"$'\r\n'"Content-Length: ${#data}"$'\r\n'
    # port-forward bazen boş yanıt döndürür (geçici bağlantı hatası): en fazla 4 deneme
    local raw=""
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

exchange() { # <channel> <external-token> -> iç JWT
    local form raw
    form="grant_type=urn:ietf:params:oauth:grant-type:token-exchange&client_id=dmz-exchange-$1&subject_token=$2&subject_token_type=urn:ietf:params:oauth:token-type:access_token&requested_token_type=urn:ietf:params:oauth:token-type:access_token&audience=kgateway-internal"
    # Exchange: kanal sertifikası (client-x509), secret yok
    raw=$(GW_CERT="dmz-exchange-$1" gw_raw POST "$TOKEN_PATH" "application/x-www-form-urlencoded" "$form")
    echo "$raw" | json_token
}
WEB_INT=$(exchange web "$WEB_EXT")
MOBILE_INT=$(exchange mobile "$MOBILE_EXT")
PARTNER_INT=$(exchange partner "$PARTNER_EXT")
echo "iç token'lar: web=${#WEB_INT} mobile=${#MOBILE_INT} partner=${#PARTNER_INT}"

req() { # <method> <path> [token] -> body + HTTP_CODE
    local raw code body
    raw=$(gw_raw "$1" "$2" "" "" "${3:-}")
    code=$(echo "$raw" | awk 'NR==1{print $2}' | tr -d '\r')
    body=$(echo "$raw" | awk 'f{print} /^\r?$/{f=1}' | tr -d '\r')
    printf '%s\nHTTP_CODE=%s' "$body" "${code:-000}"
}

# 1) /bff/*: iç token yoksa -> 401
check "bff: token yok -> 401" "HTTP_CODE=401" "$(req GET /bff/accounts)"

# 2) /bff/*: web iç token -> 200, upstream kanal ve kullanıcı başlıklarını görür
body=$(req GET /bff/accounts "$WEB_INT")
check "bff: web iç token -> 200" "HTTP_CODE=200" "$body"
check "bff: upstream channel=web" "channel=web" "$body"
check "bff: upstream user=alice-sub (x-user-id)" "user=" "$body"

# 3) /bff/*: mobil iç token -> 200
body=$(req GET /bff/accounts "$MOBILE_INT")
check "bff: mobil iç token -> 200" "HTTP_CODE=200" "$body"
check "bff: upstream channel=mobile" "channel=mobile" "$body"

# 4) /bff/*: partner iç token -> 403 (RBAC: yalnızca web/mobile)
check "bff: partner iç token -> 403" "HTTP_CODE=403" "$(req GET /bff/accounts "$PARTNER_INT")"

# 5) /partner/*: partner iç token -> 200
body=$(req GET /partner/payments "$PARTNER_INT")
check "partner: partner iç token -> 200" "HTTP_CODE=200" "$body"
check "partner: upstream service=core" "service=core" "$body"

# 6) /partner/*: web iç token -> 403
check "partner: web iç token -> 403" "HTTP_CODE=403" "$(req GET /partner/payments "$WEB_INT")"

# 7) Dış token iç gateway'de kabul edilmemeli (aud=channel-web, kgateway-internal değil)
check "bff: dış token iç gateway'de -> audience ile reddedilir" "Audiences in Jwt are not allowed" "$(req GET /bff/accounts "$WEB_EXT")"

# 8) Bozulmuş iç token -> 401
tampered="$(echo "$WEB_INT" | cut -d. -f1).$(echo '{"iss":"https://id.bank.lab.local/realms/bank","aud":"kgateway-internal","channel":"web"}' | openssl base64 -A | tr '+/' '-_' | tr -d '=').$(echo "$WEB_INT" | cut -d. -f3)"
check "bff: bozulmuş iç token -> 401" "HTTP_CODE=401" "$(req GET /bff/accounts "$tampered")"

# 9) /public/*: token yok, GET -> 200 (JWT yok)
check "public: GET token yok -> 200" "HTTP_CODE=200" "$(req GET /public/branches)"

# 10) /public/*: POST -> 404 (route yok, default deny)
check "public: POST -> 404" "HTTP_CODE=404" "$(req POST /public/branches)"

# 10b) İstemci sertifikasız (DMZ kimliği yok) bağlantı TLS seviyesinde reddedilmeli
code=$("${CURL[@]}" -s -o /dev/null -w '%{http_code}' --max-time 10 --cacert "$CERTS/internal-ca.crt" \
    --resolve "gw-internal:19543:127.0.0.1" "https://gw-internal:19543/public/branches")
if [[ "$code" == "000" ]]; then
    echo "PASS  istemci sertifikasız public çağrı reddedildi (mTLS)"; pass=$((pass + 1))
else
    echo "FAIL  sertifikasız çağrı kabul edildi: $code"; fail=$((fail + 1))
fi

# 11) Tanımsız path -> 404 (default deny)
check "tanımsız path -> 404" "HTTP_CODE=404" "$(req GET /admin/users "$WEB_INT")"

echo
echo "Sonuç: $pass geçti, $fail kaldı (toplam $((pass + fail)))"
[[ $fail -eq 0 ]]
