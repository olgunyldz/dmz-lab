#!/usr/bin/env bash
# Şube (branch) uçtan uca testi: şube pod'u (kind-branch) -> WAN -> gw-branch (cihaz mTLS, F10)
#   -> ext-authz (branch) -> exchange -> BFF. HAProxy kullanılmaz.
#   - cihaz sertifikasız bağlantı TLS'de reddedilir
#   - cihaz sertifikasıyla login route'u (/realms) erişilebilir
#   - token yok -> 401 (ext-authz); branch token -> 200, iç servis channel=branch, auth_method=branch_cert
#   - web token (aud channel-web) şubede -> 403 (audience); /partner ve /public şubede yok -> 404
set -uo pipefail
# Git Bash, kubectl exec içindeki /app yolunu Windows yoluna çevirmesin
export MSYS_NO_PATHCONV=1

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
KI="kubectl --context kind-identity"
KB="kubectl --context kind-branch"
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

# probe <path> [bearer-token|-] [cert:yes|no] -> şube pod'undan gw-branch'e ham yanıt
probe() {
    $KB -n branch exec deploy/branch-ui -- python3 /app/probe.py "$1" "${2:--}" "${3:-yes}" 2>&1
}

# Token alma (PKCE, port-forward üzerinden identity; yalnız login adımı)
PF=()
$KI -n auth port-forward svc/keycloak 18080:8080 >/dev/null 2>&1 & PF+=($!)
trap 'kill "${PF[@]}" 2>/dev/null' EXIT
sleep 5
source "$ROOT/identity-cluster/tests/lib/pkce.sh"
PKCE_BASE=http://127.0.0.1:18080
BRANCH_TOKEN=$(pkce_token branch-app https://teller.lab.local/callback teller "$(secret teller-password)" "$(secret branch-app)" "")
WEB_TOKEN=$(pkce_token web-app https://web.lab.local:8443/callback alice "$(secret alice-password)" "$(secret web-app)" "")

# 1) Cihaz sertifikasız: TLS el sıkışmasında reddedilir
out=$(probe "$REALM/.well-known/openid-configuration" - no)
check "cihaz sertifikasız bağlantı reddedilir (TLS)" "certificate required" "$out"

# 2) Cihaz sertifikasıyla login route'u (ext-authz yok)
out=$(probe /realms/bank/.well-known/openid-configuration - yes)
check "cihaz sertifikasıyla /realms erişilebilir" "HTTP/1.1 200" "$out"

# 3) Token yok -> 401
out=$(probe /bff/accounts - yes)
check "/bff token yok -> 401" "missing bearer token" "$out"

# 4) Branch token -> 200, iç servis kanal ve yöntemi görür
out=$(probe /bff/accounts "$BRANCH_TOKEN" yes)
check "/bff branch token -> 200" "HTTP/1.1 200" "$out"
check "iç servis: channel=branch" "channel=branch" "$out"
check "iç servis: auth_method=branch_cert" "auth_method=branch_cert" "$out"

# 5) Web token (aud channel-web) şube kanalında reddedilir
out=$(probe /bff/accounts "$WEB_TOKEN" yes)
check "web token şubede -> 403 (audience)" "audience mismatch" "$out"

# 6) Şubede yalnız /bff ve /realms var; /partner ve /public yok
out=$(probe /partner/payments "$BRANCH_TOKEN" yes)
check "/partner şubede yok -> 404" "HTTP/1.1 404" "$out"
out=$(probe /public/branches - yes)
check "/public şubede yok -> 404" "HTTP/1.1 404" "$out"

echo
echo "Sonuç: $pass geçti, $fail kaldı (toplam $((pass + fail)))"
[[ $fail -eq 0 ]]
