# Ortak yardımcı: Authorization Code + PKCE ile token alır (şifre grant'i yok).
# Kullanıcı girişi Spring IdP'nin login formu üzerinden yapılır (CSRF belirteci ile).
#
# Kullanım (çağıran betik kendi port-forward'ını açmış olmalı):
#   source "$ROOT/../identity-cluster/tests/lib/pkce.sh"
#   PKCE_BASE=https://id.bank.lab.local                       # yayın adresi (issuer host'u)
#   PKCE_CURL_ARGS="--cacert <internal-ca> --connect-to id.bank.lab.local:443:127.0.0.1:<port>"
#   WEB_TOKEN=$(pkce_token web-app https://web.lab.local:8443/callback alice "$ALICE_PW" "$WEB_SECRET")
#   MOBILE_TOKEN=$(pkce_token mobile-app com.bank.app:/callback alice "$ALICE_PW" "")
#
# Sınır: alice şifresi yalnız lab'da var (test kullanıcısı). Prod'da bu yardımcı kullanılmaz.

PKCE_BASE=${PKCE_BASE:-https://id.bank.lab.local}

# Ek curl argümanları (--cacert, --connect-to). Port-forward'a yönlendirme için kullanılır.
PKCE_CURL_ARGS=${PKCE_CURL_ARGS:-}
_pkce_curl() { curl -s ${PKCE_CURL_ARGS} "$@"; }

_pkce_b64u() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# Location başlığını döndürür (yönlendirme yapılmaz)
_pkce_location() { tr -d '\r' | grep -i '^location:' | head -1 | sed 's/^[Ll]ocation: //'; }

# pkce_token <client_id> <redirect_uri> <user> <password> <client_secret|"">
# Çıktı: access_token (boş ise hata; ham yanıt stderr'e yazılır)
pkce_token() {
    local client=$1 redirect=$2 user=$3 pw=$4 secret=$5
    local verifier challenge jar page csrf loc code body token

    verifier=$(openssl rand -hex 32)
    challenge=$(printf '%s' "$verifier" | openssl dgst -sha256 -binary | _pkce_b64u)
    jar=$(mktemp)

    # 1) Yetkilendirme isteği: IdP oturumu başlatır ve /login'e yönlendirir (istek oturumda saklanır)
    _pkce_curl -c "$jar" -b "$jar" -o /dev/null -D - -G "$PKCE_BASE/realms/bank/protocol/openid-connect/auth" \
        --data-urlencode "client_id=$client" --data-urlencode "redirect_uri=$redirect" \
        -d response_type=code -d scope=openid -d state=lab \
        -d code_challenge="$challenge" -d code_challenge_method=S256 >/dev/null

    # 2) Login formu ve CSRF belirteci
    page=$(_pkce_curl -c "$jar" -b "$jar" "$PKCE_BASE/login")
    csrf=$(echo "$page" | sed -n 's/.*name="_csrf"[^>]*value="\([^"]*\)".*/\1/p' | head -1)

    # 3) Kimlik bilgileri: 302 -> kayıtlı yetkilendirme isteği
    loc=$(_pkce_curl -c "$jar" -b "$jar" -o /dev/null -D - -X POST "$PKCE_BASE/login" \
        --data-urlencode "username=$user" --data-urlencode "password=$pw" --data-urlencode "_csrf=$csrf" \
        | _pkce_location)

    # 4) Yetkilendirmeye devam: 302 -> redirect_uri?code=...
    if [[ -n "$loc" && "$loc" != http* ]]; then loc="$PKCE_BASE$loc"; fi
    loc=$(_pkce_curl -c "$jar" -b "$jar" -o /dev/null -D - "$loc" | _pkce_location)
    code=$(echo "$loc" | sed -n 's/.*[?&]code=\([^&]*\).*/\1/p')
    rm -f "$jar"
    if [[ -z "$code" ]]; then
        echo "pkce: login başarısız ($client), yönlendirme: ${loc:-yok}" >&2
        return 1
    fi

    # 5) Token: code + code_verifier (+ confidential ise secret)
    local -a args=(-d grant_type=authorization_code -d "client_id=$client" -d "code=$code"
                   -d "redirect_uri=$redirect" -d "code_verifier=$verifier")
    # Gizli anahtarlı istemci: client_secret_basic (IdP kaydı bu yöntemi bekler)
    local -a hdr=()
    [[ -n "$secret" ]] && hdr+=(-u "$client:$secret")
    body=$(_pkce_curl -X POST "$PKCE_BASE/realms/bank/protocol/openid-connect/token" "${hdr[@]}" "${args[@]}")
    token=$(echo "$body" | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')
    if [[ -z "$token" ]]; then
        echo "pkce: token alınamadı ($client): $(echo "$body" | cut -c1-200)" >&2
        return 1
    fi
    echo "$token"
}
