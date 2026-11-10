#!/usr/bin/env bash
# Yük dengeleme: be_gw_web iki DMZ node'una (dmz-worker, dmz-worker2) dağıtılmalı, iki backend de UP olmalı.
# HAProxy istatistikleri (/stats;csv) üzerinden ölçülür; yanıt gövdesinde backend kimliği yoktur.
#
# Kapsam dışı: bir backend'in düşmesi (failover). Bunun için bir DMZ node'unu durdurmak gerekir;
# lab'da bu, kubernetes cluster'ını da etkiler. Failover prod'da ayrı bir kaos testi olarak yapılmalı.
source "$(dirname "$0")/lib.sh"

# be_gw_web satırlarının stot (toplam oturum) ve status değerlerini döner: "<svname> <stot> <status>"
backend_stats() {
    "${CURL[@]}" -s --max-time 5 "http://127.0.0.1:8404/stats;csv" | awk -F, '
        NR==1 { next }
        $1=="be_gw_web" && $2!="BACKEND" { print $2, $8, $18 }'
}

before=$(backend_stats)

for i in $(seq 1 20); do
    "${CURL[@]}" -s -o /dev/null --max-time 10 --cacert "$CERTS/public-ca.crt" \
        --connect-to "web.lab.local:443:$EDGE:$PORT" "https://web.lab.local/public/branches"
done

after=$(backend_stats)

delta() { # <svname>: stot farkı
    local b a
    b=$(echo "$before" | awk -v s="$1" '$1==s {print $2}')
    a=$(echo "$after"  | awk -v s="$1" '$1==s {print $2}')
    echo $(( ${a:-0} - ${b:-0} ))
}

d1=$(delta dmz-worker)
d2=$(delta dmz-worker2)
check "dmz-worker'a trafik gidiyor (20 istekten >0)" "ok" "$([ "$d1" -gt 0 ] && echo ok)"
check "dmz-worker2'ye trafik gidiyor (20 istekten >0)" "ok" "$([ "$d2" -gt 0 ] && echo ok)"
echo "      (dağılım: dmz-worker=$d1 dmz-worker2=$d2)"

up=$(echo "$after" | awk '$3 ~ /^UP/ {n++} END {print n+0}')
check "be_gw_web: iki backend de UP (check-ssl)" "2" "$up"

summary
