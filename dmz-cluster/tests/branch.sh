#!/usr/bin/env bash
# Şube (branch) zone uçtan uca testi: teller.lab.local -> gw-branch (cihaz mTLS) -> ext-authz (branch) -> exchange -> BFF.
#   - cihaz sertifikasız bağlantı TLS'de reddedilir
#   - cihaz sertifikasıyla login route'u (/realms) erişilebilir
#   - token yok -> 401 (ext-authz); branch token -> 200, iç servis channel=branch, auth_method=branch_cert
#   - web token (aud channel-web) teller'da -> 403 (audience); /partner ve /public teller'da yok -> 404
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CERTS="$ROOT/../edge/certs"
KI="kubectl --context kind-identity"
EDGE=127.0.0.1
PORT=8443
REALM=/realms/bank/protocol/openid-connect

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

# teller_raw <path> [bearer-token] [cert:yes|no]  -> ham HTTP yanıtı (başlık + gövde)
teller_raw() {
    local path=$1 tok=${2:-} cert=${3:-yes} extra=""
    [[ -n "$tok" ]] && extra="Authorization: Bearer $tok"$'\r\n'
    local args=(-connect "$EDGE:$PORT" -servername teller.lab.local -CAfile "$CERTS/internal-ca.crt" -quiet)
    [[ "$cert" == yes ]] && args+=(-cert "$CERTS/branch-device.crt" -key "$CERTS/branch-device.key")
    printf "GET %s HTTP/1.1\r\nHost: teller.lab.local\r\n%sConnection: close\r\n\r\n" "$path" "$extra" \
        | timeout 20 openssl s_client "${args[@]}" 2>&1
}

# Token alma (PKCE, port-forward üzerinden identity; yalnız login adımı)
PF=()
$KI -n auth port-forward svc/keycloak 18080:8080 >/dev/null 2>&1 & PF+=($!)
trap 'kill "${PF[@]}" 2>/dev/null' EXIT
sleep 5
source "$ROOT/../identity-cluster/tests/lib/pkce.sh"
PKCE_BASE=http://127.0.0.1:18080
BRANCH_TOKEN=$(pkce_token branch-app https://teller.lab.local/callback teller "$(secret teller-password)" "$(secret branch-app)" "")
WEB_TOKEN=$(pkce_token web-app https://web.lab.local:8443/callback alice "$(secret alice-password)" "$(secret web-app)" "")

# 1) Cihaz sertifikasız: TLS el sıkışmasında reddedilir
out=$(teller_raw "$REALM/.well-known/openid-configuration" "" no)
check "cihaz sertifikasız bağlantı reddedilir (TLS)" "certificate required" "$out"

# 2) Cihaz sertifikasıyla login route'u (ext-authz yok)
out=$(teller_raw /realms/bank/.well-known/openid-configuration "" yes)
check "cihaz sertifikasıyla /realms erişilebilir" "HTTP/1.1 200" "$out"

# 3) Token yok -> 401
out=$(teller_raw /bff/accounts "" yes)
check "/bff token yok -> 401" "missing bearer token" "$out"

# 4) Branch token -> 200, iç servis kanal ve yöntemi görür
out=$(teller_raw /bff/accounts "$BRANCH_TOKEN" yes)
check "/bff branch token -> 200" "HTTP/1.1 200" "$out"
check "iç servis: channel=branch" "channel=branch" "$out"
check "iç servis: auth_method=branch_cert" "auth_method=branch_cert" "$out"

# 5) Web token (aud channel-web) şube kanalında reddedilir
out=$(teller_raw /bff/accounts "$WEB_TOKEN" yes)
check "web token teller'da -> 403 (audience)" "audience mismatch" "$out"

# 6) Şubede yalnız /bff ve /realms var; /partner ve /public yok
out=$(teller_raw /partner/payments "$BRANCH_TOKEN" yes)
check "/partner teller'da yok -> 404" "HTTP/1.1 404" "$out"
out=$(teller_raw /public/branches "" yes)
check "/public teller'da yok -> 404" "HTTP/1.1 404" "$out"

echo
echo "Sonuç: $pass geçti, $fail kaldı (toplam $((pass + fail)))"
[[ $fail -eq 0 ]]
