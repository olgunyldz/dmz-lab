#!/usr/bin/env bash
# Tek realm (bank) ve client'ları kurar: müşteri kanalları, partner, iç servisler, token exchange.
# Idempotent: var olan kaynaklar 409 ile geçilir. Client secret'ları ve test kullanıcı şifresi
# identity cluster'da "keycloak-client-secrets" secret'ında saklanır (repo'da yok).
set -euo pipefail

CTX="kind-identity"
K="kubectl --context $CTX"
REALM="bank"
PORT=18080
BASE="http://127.0.0.1:$PORT"

$K -n auth port-forward svc/keycloak $PORT:8080 >/dev/null 2>&1 & PF=$!
trap 'kill $PF 2>/dev/null' EXIT
sleep 4

ADMIN_PW=$($K -n auth get secret keycloak-admin -o jsonpath='{.data.password}' | base64 -d)
TOKEN=$(curl -s -X POST "$BASE/realms/master/protocol/openid-connect/token" \
    -d grant_type=password -d client_id=admin-cli -d username=admin --data-urlencode "password=$ADMIN_PW" \
    | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')
[[ -n "$TOKEN" ]] || { echo "admin token alınamadı"; exit 1; }

api() { # <method> <path> [json] -> body (HTTP kodu stderr'e değil, kontrol için global)
    local method=$1 path=$2 data=${3:-}
    if [[ -n "$data" ]]; then
        curl -s -o /tmp/kc-body -w '%{http_code}' -X "$method" "$BASE$path" \
            -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d "$data"
    else
        curl -s -o /tmp/kc-body -w '%{http_code}' -X "$method" "$BASE$path" -H "Authorization: Bearer $TOKEN"
    fi
}

ok() { [[ "$1" == 2* || "$1" == 409 ]]; }

# 1) Realm
code=$(api POST /admin/realms "{\"realm\":\"$REALM\",\"enabled\":true}")
ok "$code" || { echo "realm oluşturulamadı ($code): $(cat /tmp/kc-body)"; exit 1; }
echo "realm: $REALM ($code)"

# client_id -> secret (secret yoksa üretilir)
declare -A SECRETS
for c in web-app mobile-app partner-acme bff core-svc dmz-exchange-web dmz-exchange-mobile dmz-exchange-partner kgateway-internal; do
    SECRETS[$c]=$($K -n auth get secret keycloak-client-secrets -o jsonpath="{.data.$c}" 2>/dev/null | base64 -d 2>/dev/null || true)
    [[ -n "${SECRETS[$c]}" ]] || SECRETS[$c]=$(openssl rand -hex 24)
done

# Protokol mapper'ı ekle (JSON); var ise geç
client_uuid() { # <clientId> -> UUID (yanıt [{"id":"...",...}] biçiminde; ilk id alınır)
    api GET "/admin/realms/$REALM/clients?clientId=$1" >/dev/null
    sed -n 's/^\[{"id":"\([^"]*\)".*/\1/p' /tmp/kc-body
}

add_mapper() { # <client_id> <json>
    local cid=$1 json=$2 uuid code
    uuid=$(client_uuid "$cid")
    [[ -n "$uuid" ]] || { echo "  client bulunamadı: $cid"; return; }
    code=$(api POST "/admin/realms/$REALM/clients/$uuid/protocol-mappers/models" "$json")
    ok "$code" || echo "  mapper hata ($code) [$cid]: $(cat /tmp/kc-body)"
}

# client oluştur: <clientId> <json-tail: alanlar, virgülle başlamadan>
create_client() {
    local cid=$1 extra=$2
    local code
    code=$(api POST "/admin/realms/$REALM/clients" "{\"clientId\":\"$cid\",\"enabled\":true,\"secret\":\"${SECRETS[$cid]}\",$extra}")
    ok "$code" || { echo "client $cid ($code): $(cat /tmp/kc-body)"; return; }
    echo "client: $cid ($code)"
}

aud_mapper() { # <client> <audience>
    add_mapper "$1" "{\"name\":\"aud-$2\",\"protocol\":\"openid-connect\",\"protocolMapper\":\"oidc-audience-mapper\",\"config\":{\"included.custom.audience\":\"$2\",\"access.token.claim\":\"true\",\"id.token.claim\":\"false\"}}"
}
claim_mapper() { # <client> <claim> <value>
    add_mapper "$1" "{\"name\":\"claim-$2\",\"protocol\":\"openid-connect\",\"protocolMapper\":\"oidc-hardcoded-claim-mapper\",\"config\":{\"claim.name\":\"$2\",\"claim.value\":\"$3\",\"jsonType.label\":\"String\",\"access.token.claim\":\"true\",\"id.token.claim\":\"false\"}}"
}

# Standard token exchange: subject token, exchange yapacak client'ın audience'ında olmalı
exch_mapper() { # <client> <exchange-client>
    add_mapper "$1" "{\"name\":\"exch-$2\",\"protocol\":\"openid-connect\",\"protocolMapper\":\"oidc-audience-mapper\",\"config\":{\"included.client.audience\":\"$2\",\"access.token.claim\":\"true\",\"id.token.claim\":\"false\"}}"
}

PKCE_MOBILE='"attributes":{"pkce.code.challenge.method":"S256","dpop.bound.access.tokens":"true"}'
PKCE_WEB='"attributes":{"pkce.code.challenge.method":"S256","dpop.bound.access.tokens":"false"}'
EXCHANGE='"attributes":{"standard.token.exchange.enabled":"true"}'

# client sil (mapper'ları ile birlikte). Yoksa sessiz geçer.
delete_client() { # <clientId>
    local uuid
    uuid=$(client_uuid "$1")
    [[ -n "$uuid" ]] || return 0
    code=$(api DELETE "/admin/realms/$REALM/clients/$uuid")
    ok "$code" && echo "client silindi: $1 ($code)"
}

# 2) Müşteri kanalları. Web ve mobil akışları AYRI:
#    - web-app: Authorization Code + PKCE, confidential, DPoP YOK (Bearer token; sender-constrained token exchange'de kabul edilmiyor)
#    - mobile-app: Authorization Code + PKCE, public, DPoP ZORUNLU (cihaz anahtarı; SPI dmz-dpop-mobile-exchange)
#    web-app ve mobile-app yeniden oluşturulur: var olan client'ın attribute'ları 409 ile değişmez.
delete_client web-app
create_client web-app "\"fullScopeAllowed\":false,\"publicClient\":false,\"standardFlowEnabled\":true,\"directAccessGrantsEnabled\":false,\"redirectUris\":[\"https://web.lab.local:8443/*\"],$PKCE_WEB"
aud_mapper web-app channel-web; claim_mapper web-app channel web; exch_mapper web-app dmz-exchange-web

delete_client mobile-app
create_client mobile-app "\"fullScopeAllowed\":false,\"publicClient\":true,\"standardFlowEnabled\":true,\"directAccessGrantsEnabled\":false,\"redirectUris\":[\"com.bank.app:/callback\"],$PKCE_MOBILE"
aud_mapper mobile-app channel-mobile; claim_mapper mobile-app channel mobile; exch_mapper mobile-app dmz-exchange-mobile

# 3) Partner (client credentials; mTLS cnf bağlaması sonraki adım)
create_client partner-acme "\"fullScopeAllowed\":false,\"publicClient\":false,\"serviceAccountsEnabled\":true,\"standardFlowEnabled\":false"
aud_mapper partner-acme channel-partner; claim_mapper partner-acme channel partner; claim_mapper partner-acme partner_id acme-001; exch_mapper partner-acme dmz-exchange-partner

# 4) İç servisler
create_client bff "\"publicClient\":false,\"serviceAccountsEnabled\":true,\"standardFlowEnabled\":false"
create_client core-svc "\"publicClient\":false,\"serviceAccountsEnabled\":true,\"standardFlowEnabled\":false"

# 5) Token exchange istemcileri (kanal başına) ve hedef audience
create_client kgateway-internal "\"publicClient\":false,\"standardFlowEnabled\":false,\"serviceAccountsEnabled\":false,$EXCHANGE"
for ch in web mobile partner; do
    # Exchange istemcisi mTLS (client-x509): kimlik, sertifika subject'i CN=dmz-exchange-<kanal> ile eşleşir
    create_client "dmz-exchange-$ch" "\"publicClient\":false,\"serviceAccountsEnabled\":true,\"standardFlowEnabled\":false,\"clientAuthenticatorType\":\"client-x509\",\"attributes\":{\"standard.token.exchange.enabled\":\"true\",\"x509.subjectdn\":\"CN=dmz-exchange-$ch\"}"
done

# 6) lab-cli (şifre grant'i ile token veren test istemcisi) kaldırıldı. Eski kurulumlardan kalanı sil.
delete_client lab-cli

# 7) Test kullanıcısı
USER_PW=$($K -n auth get secret keycloak-client-secrets -o jsonpath='{.data.alice-password}' 2>/dev/null | base64 -d 2>/dev/null || true)
[[ -n "$USER_PW" ]] || USER_PW=$(openssl rand -hex 16)
code=$(api POST "/admin/realms/$REALM/users" "{\"username\":\"alice\",\"firstName\":\"Alice\",\"lastName\":\"Lab\",\"email\":\"alice@lab.local\",\"enabled\":true,\"emailVerified\":true,\"requiredActions\":[],\"credentials\":[{\"type\":\"password\",\"value\":\"$USER_PW\",\"temporary\":false}]}")
ok "$code" && echo "kullanıcı: alice ($code)"
SECRETS[alice-password]=$USER_PW

# 7b) Token exchange yetkileri:
#     - kgateway-internal client'ında "access" rolü; default role'e eklenir (tüm kullanıcılar hedef audience'ı alabilir)
#     - her exchange client'ı bu rolü scope olarak alır (audience çözümlemesi için)
#     - iç token'a kanal ve auth_method claim'leri, exchange client'ının sabit değeriyle eklenir
KG=$(client_uuid kgateway-internal)
if [[ -n "$KG" ]]; then
    api POST "/admin/realms/$REALM/clients/$KG/roles" '{"name":"access"}' >/dev/null
    RID=$(api GET "/admin/realms/$REALM/clients/$KG/roles/access" >/dev/null; sed -n 's/.*"id":"\([^"]*\)".*/\1/p' /tmp/kc-body | head -1)
    DEF=$(api GET "/admin/realms/$REALM/roles/default-roles-$REALM" >/dev/null; sed -n 's/.*"id":"\([^"]*\)".*/\1/p' /tmp/kc-body | head -1)
    api POST "/admin/realms/$REALM/roles-by-id/$DEF/composites" "[{\"id\":\"$RID\",\"name\":\"access\",\"clientRole\":true,\"containerId\":\"$KG\"}]" >/dev/null
    for ch in web mobile partner; do
        DX=$(client_uuid "dmz-exchange-$ch")
        api POST "/admin/realms/$REALM/clients/$DX/scope-mappings/clients/$KG" "[{\"id\":\"$RID\",\"name\":\"access\"}]" >/dev/null
    done
fi
claim_mapper dmz-exchange-web channel web;         claim_mapper dmz-exchange-web auth_method pwd_otp
claim_mapper dmz-exchange-mobile channel mobile;   claim_mapper dmz-exchange-mobile auth_method dpop_device
claim_mapper dmz-exchange-partner channel partner; claim_mapper dmz-exchange-partner auth_method mtls_partner
# Lab sınırı: partner_id sabit (acme-001). Üretimde partner kimliği subject token'dan taşınmalı.
claim_mapper dmz-exchange-partner partner_id acme-001
echo "token exchange yetkileri ayarlandı."

# 8) Secret'ları cluster'a yaz
args=()
for k in "${!SECRETS[@]}"; do args+=("--from-literal=$k=${SECRETS[$k]}"); done
$K -n auth create secret generic keycloak-client-secrets "${args[@]}" --dry-run=client -o yaml | $K apply -f - >/dev/null
echo "secret'lar keycloak-client-secrets içine yazıldı."
