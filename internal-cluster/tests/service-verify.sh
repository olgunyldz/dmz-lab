#!/usr/bin/env bash
# İç servis savunma derinliği testi: BFF ve core, gateway'i ATLAYARAK doğrudan çağrılsa bile
# iç JWT'yi kendileri doğrulamalı (design.md 4.3). İstekler küme içinden bir pod'dan yapılır.
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
        echo "FAIL  $name  (beklenen: '$expected', gelen: '${actual:0:200}')"; fail=$((fail + 1))
    fi
}

secret() { $KI -n auth get secret keycloak-client-secrets -o jsonpath="{.data.$1}" | base64 -d; }
b64u() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
json_token() { sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p'; }

PF_PIDS=()
$KI -n auth port-forward svc/keycloak 18080:8080 >/dev/null 2>&1 & PF_PIDS+=($!)
$KN -n gw-internal port-forward svc/gw-internal 19543:443 >/dev/null 2>&1 & PF_PIDS+=($!)
trap 'kill "${PF_PIDS[@]}" 2>/dev/null' EXIT
sleep 6

# Dış token'lar (Keycloak)
WEB_EXT=$(curl -s -X POST "http://127.0.0.1:18080$TOKEN_PATH" -d grant_type=password -d client_id=lab-cli \
    -d "client_secret=$(secret lab-cli)" -d username=alice --data-urlencode "password=$(secret alice-password)" | json_token)
PARTNER_EXT=$(curl -s -X POST "http://127.0.0.1:18080$TOKEN_PATH" -d grant_type=client_credentials \
    -d client_id=partner-acme -d "client_secret=$(secret partner-acme)" | json_token)

# İç token'lar: gerçek exchange (iç gateway, kanal sertifikası)
exchange() { # <channel> <external-token> -> iç JWT
    local form raw
    form="grant_type=urn:ietf:params:oauth:grant-type:token-exchange&client_id=dmz-exchange-$1&subject_token=$2&subject_token_type=urn:ietf:params:oauth:token-type:access_token&requested_token_type=urn:ietf:params:oauth:token-type:access_token&audience=kgateway-internal"
    raw=$(printf "POST $TOKEN_PATH HTTP/1.1\r\nHost: gw-internal\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: ${#form}\r\nConnection: close\r\n\r\n%s" "$form" | \
        timeout 20 openssl s_client -connect 127.0.0.1:19543 -servername gw-internal -CAfile "$CERTS/internal-ca.crt" \
        -cert "$CERTS/dmz-exchange-$1.crt" -key "$CERTS/dmz-exchange-$1.key" -quiet 2>/dev/null)
    echo "$raw" | json_token
}
WEB_INT=$(exchange web "$WEB_EXT")
PARTNER_INT=$(exchange partner "$PARTNER_EXT")
echo "iç token'lar: web=${#WEB_INT} partner=${#PARTNER_INT}"

# Sahte token: HS256 ile imzalanmış, iç issuer ve audience taklidi
FORGED_H=$(printf '%s' '{"alg":"HS256","typ":"JWT"}' | b64u)
FORGED_P=$(printf '%s' '{"iss":"https://id.bank.lab.local/realms/bank","aud":"kgateway-internal","channel":"web","sub":"x","exp":9999999999}' | b64u)
FORGED_S=$(printf '%s.%s' "$FORGED_H" "$FORGED_P" | openssl dgst -sha256 -hmac "lab" -binary | b64u)
FORGED="$FORGED_H.$FORGED_P.$FORGED_S"

# Küme içi istemci pod'u: BFF ve core'a gateway'siz istek. Sonuçlar satır satır yazılır.
# Not: 'kubectl run -i' attach çıktıyı kaydırabiliyor (satırlar karışır). Sonuçlar pod log'undan okunur.
run_in_cluster() {
    $KN delete pod svc-verify --ignore-not-found --wait=true >/dev/null 2>&1
    $KN run svc-verify --image=curlimages/curl:8.11.1 --restart=Never \
        --env=WEB_INT="$WEB_INT" --env=PARTNER_INT="$PARTNER_INT" --env=WEB_EXT="$WEB_EXT" --env=FORGED="$FORGED" \
        -- sh -c '
req() { # <name> <url> [token]
  if [ -n "$3" ]; then
    code=$(curl -s -o /tmp/b -w "%{http_code}" --max-time 10 -H "Authorization: Bearer $3" "$2")
  else
    code=$(curl -s -o /tmp/b -w "%{http_code}" --max-time 10 "$2")
  fi
  echo "$1 => $code $(cat /tmp/b | tr -d "\n")"
}
B=http://bff.app-bff.svc.cluster.local/bff/accounts
C=http://core.app-core.svc.cluster.local
req "bff-no-token" "$B"
req "bff-forged" "$B" "$FORGED"
req "bff-external-token-wrong-aud" "$B" "$WEB_EXT"
req "bff-web-internal" "$B" "$WEB_INT"
req "bff-partner-internal-channel" "$B" "$PARTNER_INT"
req "core-partner-internal" "$C/partner/payments" "$PARTNER_INT"
req "core-web-internal-channel" "$C/partner/payments" "$WEB_INT"
req "core-public-no-token" "$C/public/branches"
req "bff-public-no-token" "http://bff.app-bff.svc.cluster.local/public/branches"
' >/dev/null 2>&1
    for _ in $(seq 1 60); do
        phase=$($KN get pod svc-verify -o jsonpath='{.status.phase}' 2>/dev/null)
        [[ "$phase" == "Succeeded" || "$phase" == "Failed" ]] && break
        sleep 2
    done
    $KN logs svc-verify 2>/dev/null
    $KN delete pod svc-verify --ignore-not-found --wait=false >/dev/null 2>&1
}
OUT=$(run_in_cluster)
echo "$OUT" | sed 's/^/      /'

check "bff: token yok -> 401 (gateway atlandı)" "bff-no-token => 401" "$OUT"
check "bff: sahte HS256 token -> 401" "bff-forged => 401" "$OUT"
check "bff: dış token (yanlış aud, geçerli imza) -> 401" "bff-external-token-wrong-aud => 401" "$OUT"
check "bff: web iç token -> 200" "bff-web-internal => 200" "$OUT"
check "bff: partner iç token (kanal yasak) -> 403" "bff-partner-internal-channel => 403" "$OUT"
check "core: partner iç token -> 200" "core-partner-internal => 200" "$OUT"
check "core: web iç token (kanal yasak) -> 403" "core-web-internal-channel => 403" "$OUT"
check "core: public yol token olmadan -> 200" "core-public-no-token => 200" "$OUT"
check "bff: public yol token olmadan -> 401 (bff public açmaz)" "bff-public-no-token => 401" "$OUT"

echo
echo "Sonuç: $pass geçti, $fail kaldı (toplam $((pass + fail)))"
[[ $fail -eq 0 ]]
