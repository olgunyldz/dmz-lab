# Ortak yardımcı: Authorization Code + PKCE ile token alır (şifre grant'i yok).
# Kullanıcı login'i Keycloak'ın gerçek login formu üzerinden yapılır.
#
# Kullanım (çağıran betik kendi port-forward'ını açmış olmalı):
#   source "$ROOT/../identity-cluster/tests/lib/pkce.sh"
#   PKCE_BASE=http://127.0.0.1:18080          # port-forward (token ve auth uç noktaları)
#   PKCE_PUBLIC_HOST=https://id.bank.lab.local # Keycloak KC_HOSTNAME (form action'daki host)
#   WEB_TOKEN=$(pkce_token web-app https://web.lab.local:8443/callback alice "$ALICE_PW" "$WEB_SECRET")
#   MOBILE_TOKEN=$(pkce_token mobile-app com.bank.app:/callback alice "$ALICE_PW" "" "$DPOP_PROOF_FOR_TOKEN_URL")
#
# Sınır: alice şifresi yalnız lab'da var (test kullanıcısı). Prod'da bu yardımcı kullanılmaz.

PKCE_BASE=${PKCE_BASE:-http://127.0.0.1:18080}
PKCE_PUBLIC_HOST=${PKCE_PUBLIC_HOST:-https://id.bank.lab.local}

_pkce_b64u() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# pkce_token <client_id> <redirect_uri> <user> <password> <client_secret|""> <dpop_proof|"">
# Çıktı: access_token (boş ise hata; ham yanıt stderr'e yazılır)
pkce_token() {
    local client=$1 redirect=$2 user=$3 pw=$4 secret=$5 proof=${6:-}
    local verifier challenge jar page action loc code body token

    verifier=$(openssl rand -hex 32)
    challenge=$(printf '%s' "$verifier" | openssl dgst -sha256 -binary | _pkce_b64u)
    jar=$(mktemp)

    # 1) Yetkilendirme isteği: login formunu al
    page=$(curl -s -c "$jar" -b "$jar" -G "$PKCE_BASE/realms/bank/protocol/openid-connect/auth" \
        --data-urlencode "client_id=$client" --data-urlencode "redirect_uri=$redirect" \
        -d response_type=code -d scope=openid -d state=lab \
        -d code_challenge="$challenge" -d code_challenge_method=S256)

    # 2) Form action: KC_HOSTNAME (https://id.bank.lab.local) yerine port-forward adresine çevrilir
    action=$(echo "$page" | grep -o 'action="[^"]*"' | head -1 | sed 's/action="//;s/"$//;s/&amp;/\&/g')
    action=${action/$PKCE_PUBLIC_HOST/$PKCE_BASE}

    # 3) Kimlik bilgilerini gönder: 302 Location içinde code
    loc=$(curl -s -o /dev/null -D - -c "$jar" -b "$jar" -X POST "$action" \
        --data-urlencode "username=$user" --data-urlencode "password=$pw" --data-urlencode "credentialId=" \
        | tr -d '\r' | grep -i '^location:' | sed 's/^[Ll]ocation: //')
    code=$(echo "$loc" | sed -n 's/.*[?&]code=\([^&]*\).*/\1/p')
    rm -f "$jar"
    if [[ -z "$code" ]]; then
        echo "pkce: login başarısız ($client), yönlendirme: ${loc:-yok}" >&2
        return 1
    fi

    # 4) Token: code + code_verifier (+ confidential ise secret, mobil ise DPoP proof)
    local -a args=(-d grant_type=authorization_code -d "client_id=$client" -d "code=$code"
                   -d "redirect_uri=$redirect" -d "code_verifier=$verifier")
    [[ -n "$secret" ]] && args+=(-d "client_secret=$secret")
    local -a hdr=()
    [[ -n "$proof" ]] && hdr=(-H "DPoP: $proof")
    body=$(curl -s -X POST "$PKCE_BASE/realms/bank/protocol/openid-connect/token" "${hdr[@]}" "${args[@]}")
    token=$(echo "$body" | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')
    if [[ -z "$token" ]]; then
        echo "pkce: token alınamadı ($client): $(echo "$body" | cut -c1-200)" >&2
        return 1
    fi
    echo "$token"
}
