#!/usr/bin/env bash
# F1 testi (DMZ node NodePort erişim kısıtı, scripts/host-firewall.sh):
#   - Edge HAProxy üzerinden gelen istek DMZ gateway'ine ulaşır (401 = gateway yanıt verdi, token yok)
#   - Kind ağındaki yabancı bir container, her üç NodePort'tan da reddedilir (000)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CERTS="$ROOT/../edge/certs"
DMZ_NODE_IP=$(docker inspect dmz-worker -f '{{ .NetworkSettings.Networks.kind.IPAddress }}')

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

CURL=(curl)
if curl -V 2>/dev/null | grep -qi schannel; then CURL=(curl --ssl-no-revoke); fi

# 1) Edge HAProxy (kaynak IP = edge container IP) -> DMZ gateway: açık
# Host başlığı port'suz gönderilir (gerçek istemci gibi); HAProxy host ACL'i tam host adını bekler.
OUT_EDGE=$("${CURL[@]}" -s -o /dev/null -w '%{http_code}' --max-time 10 \
    --cacert "$CERTS/public-ca.crt" --resolve "web.lab.local:8443:127.0.0.1" \
    -H "Host: web.lab.local" "https://web.lab.local:8443/bff/accounts" 2>/dev/null)
check "edge HAProxy -> DMZ gateway (NodePort 30446) açık" "401" "$OUT_EDGE"

# 2) Yabancı container (kind ağı, edge değil): her NodePort reddedilir
for port in 30446 30447 30448; do
    OUT=$(MSYS_NO_PATHCONV=1 docker run --rm --network kind --entrypoint curl curlimages/curl:8.11.1 \
        -s -o /dev/null -w '%{http_code}' --max-time 5 "http://$DMZ_NODE_IP:$port/" 2>/dev/null; true)
    check "yabancı kaynak -> DMZ NodePort $port reddedilir" "000" "$OUT"
done

echo
echo "Sonuç: $pass geçti, $fail kaldı (toplam $((pass + fail)))"
[[ $fail -eq 0 ]]
