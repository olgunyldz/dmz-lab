#!/usr/bin/env bash
# Spring auth-server duman testi: TLS, discovery, JWKS, client_credentials, token exchange (mTLS),
# olumsuz senaryolar.
#
# Gerekli ortam:
#   AUTH_URL          örn. https://127.0.0.1:18443
#   AUTH_CA           test sunucu sertifikası (self-signed veya CA)
#   EXCHANGE_CERT    dmz-exchange-web yaprak sertifikası (PEM)
#   EXCHANGE_KEY     dmz-exchange-web özel anahtarı (PEM)
#   EXCHANGE_CA      lab CA sertifikası (zincirin üst kısmı; Spring zinciri tek sertifikalıysa self-signed sayar)
#   BFF_SECRET, PARTNER_ACME_SECRET
# Authorization Code + PKCE (tarayıcı girişi) bu testte yok.
set -uo pipefail

AUTH="${AUTH_URL:?AUTH_URL gerekli}"           # yayın adresi (issuer): örn. https://id.bank.lab.local
REALM="$AUTH/realms/bank"
TOKEN="$REALM/protocol/openid-connect/token"
HERE="$(cd "$(dirname "$0")" && pwd)"
# Bağlantı: AUTH_CONNECT (örn. 127.0.0.1:18444, port-forward). Yoksa doğrudan AUTH_URL'nin host:port'u.
HOST_PORT="${AUTH#https://}"; HOST_PORT="${HOST_PORT%%/*}"
HOST="${HOST_PORT%%:*}"; PORT="${HOST_PORT##*:}"; [[ "$PORT" == "$HOST" ]] && PORT=443
CONNECT="${AUTH_CONNECT:-$HOST:$PORT}"
# Windows curl (schannel) lab CA'sının iptal durumunu bulamaz; lab için revocation kontrolü kapatılır (edge/tests/lib.sh ile aynı)
REVOKE_OPT=()
if curl -V 2>/dev/null | grep -qi schannel; then REVOKE_OPT=(--ssl-no-revoke); fi
CURL=(curl -s --cacert "$AUTH_CA" "${REVOKE_OPT[@]}" --connect-to "$HOST:$PORT:$CONNECT")
pass=0; fail=0

check() { # <ad> <beklenen> <gelen>
    if [[ "$3" == *"$2"* ]]; then echo "PASS  $1"; pass=$((pass + 1))
    else echo "FAIL  $1  (beklenen: '$2', gelen: '$3')"; fail=$((fail + 1)); fi
}

# JWT payload'unu (ikinci parça) JSON olarak yazdırır
payload() {
    local p; p=$(echo "$1" | cut -d. -f2 | tr '_-' '/+')
    while (( ${#p} % 4 )); do p+="="; done
    echo "$p" | base64 -d 2>/dev/null
}
# JSON yanıttan tek bir alanı alır
field() { python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get(sys.argv[1],""))' "$1" 2>/dev/null; }
# key=value çiftlerini URL-encoded form gövdesine çevirir
form() { python3 -c 'import sys,urllib.parse as u; print(u.urlencode([tuple(a.split("=",1)) for a in sys.argv[1:]]))' "$@"; }

# mTLS token isteği. Windows curl (schannel) istemci sertifika zincirini göndermediği için openssl s_client kullanılır.
# Zincir (yaprak + lab CA) açıkça gönderilir: Spring zinciri tek sertifikalıysa sertifikayı self-signed sayıyor.
mtls_post() { # <form gövdesi>
    local body="$1"
    { printf 'POST /realms/bank/protocol/openid-connect/token HTTP/1.1\r\nHost: %s\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s' \
        "$HOST_PORT" "${#body}" "$body"; } \
      | timeout 15 openssl s_client -connect "$CONNECT" -tls1_2 -quiet -CAfile "$AUTH_CA" \
          -cert "$EXCHANGE_CERT" -cert_chain "$EXCHANGE_CA" -key "$EXCHANGE_KEY" 2>/dev/null | tail -1
}

# 1) Discovery ve JWKS
disc=$("${CURL[@]}" "$AUTH/.well-known/openid-configuration")
check "discovery: issuer doğru" "\"issuer\":\"$REALM\"" "$disc"
check "discovery: token endpoint auth-server yolunda" "$TOKEN" "$disc"
jwks=$("${CURL[@]}" "$REALM/protocol/openid-connect/certs")
check "JWKS: RSA anahtar var" "\"kty\":\"RSA\"" "$jwks"

# 2) client_credentials (bff, client_secret_basic)
bff_resp=$("${CURL[@]}" -u "bff:$BFF_SECRET" -d grant_type=client_credentials "$TOKEN")
bff_token=$(echo "$bff_resp" | field access_token)
check "client_credentials: access_token üretildi" "eyJ" "$bff_token"

# 3) Token exchange: dmz-exchange-web, mTLS (tls_client_auth), bff token'ını core-svc audience'ı için değiştirir
ex=$(mtls_post "$(form client_id=dmz-exchange-web grant_type=urn:ietf:params:oauth:grant-type:token-exchange \
    "subject_token=$bff_token" subject_token_type=urn:ietf:params:oauth:token-type:access_token audience=core-svc)")
ex_token=$(echo "$ex" | field access_token)
ex_claims=$(payload "$ex_token")
check "exchange (mTLS): aud = core-svc" "\"aud\":\"core-svc\"" "$ex_claims"
check "exchange (mTLS): azp = dmz-exchange-web" "\"azp\":\"dmz-exchange-web\"" "$ex_claims"
check "exchange: sub korunur (bff)" "\"sub\":\"bff\"" "$ex_claims"
check "exchange: channel = web" "\"channel\":\"web\"" "$ex_claims"
check "exchange: auth_method = pwd_otp" "\"auth_method\":\"pwd_otp\"" "$ex_claims"

# 3b) İç yol: düz HTTP (AUTH_INTERNAL, örn. http://127.0.0.1:18081) + XFCC ile istemci sertifikası (gateway modeli)
if [[ -n "${AUTH_INTERNAL:-}" ]]; then
    xfcc_cert=$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(open(sys.argv[1]).read(), safe=""))' "$EXCHANGE_CERT")
    xfcc_ex=$(curl -s -H "X-Forwarded-Client-Cert: By=spiffe://lab/gw-internal;Cert=\"$xfcc_cert\"" \
        --data-urlencode client_id=dmz-exchange-web \
        --data-urlencode grant_type=urn:ietf:params:oauth:grant-type:token-exchange \
        --data-urlencode "subject_token=$bff_token" \
        --data-urlencode subject_token_type=urn:ietf:params:oauth:token-type:access_token \
        --data-urlencode audience=core-svc "$AUTH_INTERNAL/realms/bank/protocol/openid-connect/token")
    xfcc_claims=$(payload "$(echo "$xfcc_ex" | field access_token)")
    check "iç yol (XFCC): exchange aud = core-svc" "\"aud\":\"core-svc\"" "$xfcc_claims"
    check "iç yol (XFCC): JWKS erişilebilir" "\"kty\":\"RSA\"" \
        "$(curl -s "$AUTH_INTERNAL/realms/bank/protocol/openid-connect/certs")"
fi

# 4) partner-acme: partner_id ve kanal audience'ı
ptok=$("${CURL[@]}" -u "partner-acme:$PARTNER_ACME_SECRET" -d grant_type=client_credentials "$TOKEN" | field access_token)
p_claims=$(payload "$ptok")
check "partner-acme: partner_id = acme-001" "\"partner_id\":\"acme-001\"" "$p_claims"
check "partner-acme: aud = channel-partner" "channel-partner" "$p_claims"

# 6) Olumsuz: mTLS sertifikası olmadan exchange reddedilir
neg0=$("${CURL[@]}" -o /dev/null -w '%{http_code}' --data-urlencode client_id=dmz-exchange-web \
    --data-urlencode grant_type=urn:ietf:params:oauth:grant-type:token-exchange \
    --data-urlencode subject_token="$bff_token" --data-urlencode audience=core-svc "$TOKEN")
check "olumsuz: sertifikasız exchange reddedilir (HTTP 401)" "401" "$neg0"

# 7) Olumsuz: exchange yetkisi olmayan istemci (bff) reddedilir
neg1=$("${CURL[@]}" -u "bff:$BFF_SECRET" \
    --data-urlencode grant_type=urn:ietf:params:oauth:grant-type:token-exchange \
    --data-urlencode subject_token="$bff_token" "$TOKEN")
check "olumsuz: yetkisiz istemci reddedilir (unauthorized_client)" "unauthorized_client" "$neg1"

# 8) Olumsuz: sahte subject token reddedilir
neg2=$(mtls_post "$(form client_id=dmz-exchange-web grant_type=urn:ietf:params:oauth:grant-type:token-exchange \
    "subject_token=eyJhbGciOiJub25lIn0.eyJzdWIiOiJhdHRhY2tlciJ9.")")
check "olumsuz: sahte subject token reddedilir (invalid_grant)" "invalid_grant" "$neg2"

echo
echo "Sonuç: $pass geçti, $fail kaldı"
[[ $fail -eq 0 ]]
