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

# Failover: dmz-worker'daki gw-web NodePort'u (30446) geçici olarak düşürülür. Node ve cluster ayakta kalır;
# yalnız bu port DROP edilir. Kural, betik nasıl biterse bitsin (trap) kaldırılır.
FAIL_NODE=dmz-worker
FAIL_RULE="-p tcp -m conntrack --ctdir ORIGINAL --ctorigdstport 30446 -j DROP"
restore_rule() {
    docker exec "$FAIL_NODE" sh -c "iptables -D FORWARD $FAIL_RULE 2>/dev/null; iptables -D INPUT $FAIL_RULE 2>/dev/null; true"
}
trap restore_rule EXIT

docker exec "$FAIL_NODE" sh -c "iptables -I FORWARD 1 $FAIL_RULE && iptables -I INPUT 1 $FAIL_RULE"
sleep 15   # check-ssl: inter 2s, fall 2 -> DOWN

down=$(backend_stats | awk '$1=="dmz-worker" {print $3}')
check "failover: dmz-worker DOWN olur" "DOWN" "$down"

ok_count=$(for i in $(seq 1 10); do
    "${CURL[@]}" -s -o /dev/null -w '%{http_code}\n' --max-time 10 --cacert "$CERTS/public-ca.crt" \
        --connect-to "web.lab.local:443:$EDGE:$PORT" "https://web.lab.local/public/branches"
done | grep -c '^200$')
check "failover: 10 istekten 10'u 200 (dmz-worker2 üzerinden)" "10" "$ok_count"

restore_rule
sleep 15   # rise 2 -> UP

up_again=$(backend_stats | awk '$1=="dmz-worker" {print $3}')
check "failover: kural kalkınca dmz-worker tekrar UP" "UP" "$up_again"

summary
