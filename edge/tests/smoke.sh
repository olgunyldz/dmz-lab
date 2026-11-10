#!/usr/bin/env bash
# Duman testleri: TLS, yönlendirme, başlıklar, 404, L7 rate limit, partner mTLS, ağ izolasyonu.
# Önce: docker compose up -d
source "$(dirname "$0")/lib.sh"

# 1) web.lab.local -> gw-web
body=$("${CURL[@]}" -s --max-time 10 --cacert "$CERTS/public-ca.crt" \
    --connect-to "web.lab.local:443:$EDGE:$PORT" "https://web.lab.local/public/branches")
check "web route -> core (public, service=core)" "service=core" "$body"

# 2) mobile-api.lab.local -> gw-mobile
body=$("${CURL[@]}" -s --max-time 10 --cacert "$CERTS/public-ca.crt" \
    --connect-to "mobile-api.lab.local:443:$EDGE:$PORT" "https://mobile-api.lab.local/public/branches")
check "mobile route -> core (public, service=core)" "service=core" "$body"

# 3) Güvenlik başlıkları, sunucu sürümü gizli
headers=$("${CURL[@]}" -s -D - -o /dev/null --max-time 10 --cacert "$CERTS/public-ca.crt" \
    --connect-to "web.lab.local:443:$EDGE:$PORT" "https://web.lab.local/public/branches")
# HAProxy başlıkları küçük harfle gönderir; karşılaştırma büyük/küçük harf duyarsız yapılır
headers_lc=$(echo "$headers" | tr 'A-Z' 'a-z')
check "HSTS başlığı var" "strict-transport-security" "$headers_lc"
check "nosniff başlığı var" "x-content-type-options: nosniff" "$headers_lc"
if echo "$headers" | grep -qi "^server:"; then
    echo "FAIL  Server başlığı gizli değil"; fail=$((fail + 1))
else
    echo "PASS  Server başlığı gizli"; pass=$((pass + 1))
fi

# 4) Tanımsız host -> 404 (sertifika eşleşmediği için -k)
code=$("${CURL[@]}" -s -k -o /dev/null -w '%{http_code}' --max-time 10 \
    --connect-to "evil.lab.local:443:$EDGE:$PORT" "https://evil.lab.local/")
check "tanımsız host -> 404" "404" "$code"

# 5) Uçtan uca: edge -> DMZ -> iç gateway -> core. 10 istekten 10'u 200 olmalı.
#    (Backend node dağılımı lb.sh içinde HAProxy istatistiklerinden ölçülür.)
ok_n=$(for i in $(seq 1 10); do
    "${CURL[@]}" -s -o /dev/null -w '%{http_code}\n' --max-time 10 --cacert "$CERTS/public-ca.crt" \
        --connect-to "web.lab.local:443:$EDGE:$PORT" "https://web.lab.local/public/branches"
done | grep -c '^200$')
check "uçtan uca: 10 istekten 10'u 200 (core)" "10" "$ok_n"

# 6) HAProxy istatistik sayfası
stats=$("${CURL[@]}" -s --max-time 10 "http://127.0.0.1:8404/stats")
check "HAProxy stats sayfası" "HAProxy" "$stats"

# 7) L7 rate limit: 100 eşzamanlı istek, 429 dönmeli (eşik: 50 istek / 10 sn / IP)
codes=$(seq 1 100 | xargs -P 50 -I{} "${CURL[@]}" -s -o /dev/null -w '%{http_code}\n' --max-time 10 \
    --cacert "$CERTS/public-ca.crt" --connect-to "web.lab.local:443:$EDGE:$PORT" "https://web.lab.local/public/branches")
n429=$(echo "$codes" | grep -c '^429$')
check "L7 rate limit 429 üretiyor" "429" "$([ "$n429" -gt 0 ] && echo 429)"
echo "      (dağılım: $(echo "$codes" | sort | uniq -c | tr -s ' ' | tr '\n' ' '))"

# 8) Partner passthrough: istemci sertifikası YOK -> TLS el sıkışmasında reddedilir (curl 000).
#    Gateway frontend doğrulaması (partner-ca) sertifikasız bağlantıyı HTTP'ye ulaştırmaz.
code=$("${CURL[@]}" -s -o /dev/null -w '%{http_code}' --max-time 10 --cacert "$CERTS/internal-ca.crt" \
    --connect-to "partner-api.lab.local:443:$EDGE:$PORT" "https://partner-api.lab.local/partner/payments")
check "partner sertifikasız -> TLS'de reddedilir (000)" "000" "$code"

# 9) Partner passthrough: geçerli istemci sertifikası -> mTLS geçer, ext-authz token ister (401).
# Windows schannel PEM istemci sertifikasını içe aktaramadığı için OpenSSL ile test edilir.
body=$(printf 'GET /partner/payments HTTP/1.1\r\nHost: partner-api.lab.local\r\nConnection: close\r\n\r\n' | timeout 10 openssl s_client \
    -connect "$EDGE:$PORT" -servername partner-api.lab.local -CAfile "$CERTS/internal-ca.crt" \
    -cert "$CERTS/partner-client.crt" -key "$CERTS/partner-client.key" -quiet 2>/dev/null)
check "partner mTLS geçer -> /partner ext-authz token ister (401)" "missing bearer token" "$body"

# 10) Gateway'ler artık DMZ cluster'da; edge compose'da WAF servisi host'a port yayınlamaz
for svc in coraza-spoa; do
    port=$(docker compose -f "$EDGE_DIR/docker-compose.yml" port "$svc" 443 2>/dev/null)
    if [[ -z "$port" ]]; then
        echo "PASS  $svc host'a açık değil"; pass=$((pass + 1))
    else
        echo "FAIL  $svc host'a açık: $port"; fail=$((fail + 1))
    fi
done

summary
