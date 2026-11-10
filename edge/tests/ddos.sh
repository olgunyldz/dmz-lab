#!/usr/bin/env bash
# DDoS testleri (lab kapsamı):
#   - L4: IP başına bağlantı hızı sınırı (tcp-request connection reject)
#   - Slowloris: yarım kalan istek, http-request zaman aşımı ile kesilmeli
# Not: Hacimsel (volumetric) saldırılar edge'de durdurulamaz. Bkz. design.md, DDoS bölümü.
source "$(dirname "$0")/lib.sh"

# 1) L4 bağlantı hızı: 400 eşzamanlı yeni bağlantı, eşik 200/10 sn
# Tek curl süreciyle paralel burst: Windows'ta süreç başlatma maliyeti bağlantı hızını düşürmesin diye.
# Her URL ayrı bir TCP bağlantısı açar (--parallel: aynı anda 200).
urls=()
for i in $(seq 1 400); do urls+=(--url "https://web.lab.local/public/branches"); done
codes=$("${CURL[@]}" -s --parallel --parallel-max 200 -o /dev/null -w '%{http_code}\n' --max-time 10 \
    --cacert "$CERTS/public-ca.crt" --connect-to "web.lab.local:443:$EDGE:$PORT" "${urls[@]}")
n_rejected=$(echo "$codes" | grep -c '^000$')
check "L4 bağlantı hızı sınırı bağlantıları kesiyor" "000" "$([ "$n_rejected" -gt 0 ] && echo 000)"
echo "      (dağılım: $(echo "$codes" | sort | uniq -c | tr -s ' ' | tr '\n' ' '))"

# 2) Slowloris: başlıkları tamamlamadan bekle. http-request timeout (10 sn) sonrası 408 dönmeli.
#    L4 limitine takılmamak için önce birkaç saniye bekle.
sleep 12
response=$( (printf 'GET / HTTP/1.1\r\nHost: web.lab.local\r\n'; sleep 15) | timeout 25 openssl s_client \
    -connect "$EDGE:$PORT" -servername web.lab.local -CAfile "$CERTS/public-ca.crt" -quiet 2>/dev/null)
check "slowloris -> 408 (istek zaman aşımı)" "408" "$response"

summary
