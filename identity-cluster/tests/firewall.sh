#!/usr/bin/env bash
# Identity cluster erişim kısıtı testi (F8, lab karşılığı: host iptables, scripts/host-firewall.sh):
#   - İç cluster node'larından Keycloak'a erişim açık (200)
#   - Kind ağındaki yabancı kaynaklardan Keycloak'a erişim kapalı (000)
#   - Keycloak pod'undan PostgreSQL'e erişim açık
set -uo pipefail

KI="kubectl --context kind-identity"
KN="kubectl --context kind-internal"
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

KC_PATH="/realms/bank/.well-known/openid-configuration"
IDENTITY_NODE_IP=$(docker inspect identity-control-plane -f '{{ .NetworkSettings.Networks.kind.IPAddress }}')

# 1) İç cluster'dan (pod, kaynak node IP'si) Keycloak NodePort'u: 200
# Not: 'kubectl run -i' attach çıktısını kaybedebiliyor; sonuç log'dan okunur.
$KN delete pod fw-int --ignore-not-found --wait=false >/dev/null 2>&1
$KN run fw-int --image=curlimages/curl:8.11.1 --restart=Never -- \
    sh -c "curl -s -o /dev/null -w '%{http_code}' --max-time 10 'http://$IDENTITY_NODE_IP:30080$KC_PATH'" >/dev/null 2>&1
for _ in $(seq 1 30); do
    phase=$($KN get pod fw-int -o jsonpath='{.status.phase}' 2>/dev/null)
    [[ "$phase" == "Succeeded" || "$phase" == "Failed" ]] && break
    sleep 2
done
OUT_INT=$($KN logs fw-int 2>/dev/null)
$KN delete pod fw-int --ignore-not-found --wait=false >/dev/null 2>&1
check "internal cluster -> Keycloak NodePort açık" "200" "$OUT_INT"

# 2) Kind ağındaki yabancı container (iç node IP'si değil): reddedilmeli
OUT_EXT=$(MSYS_NO_PATHCONV=1 docker run --rm --network kind --entrypoint curl curlimages/curl:8.11.1 \
    -s -o /dev/null -w '%{http_code}' --max-time 5 "http://$IDENTITY_NODE_IP:30080$KC_PATH" 2>/dev/null; true)
check "yabancı kaynak (kind ağı) -> Keycloak reddedilir" "000" "$OUT_EXT"

# 3) Keycloak pod'undan PostgreSQL: açık
KC_POD=$($KI -n auth get pod -l app=keycloak -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
OUT_PG=$($KI -n auth exec "$KC_POD" -- sh -c 'cat < /dev/null > /dev/tcp/postgres.auth.svc.cluster.local/5432 && echo open || echo closed' 2>/dev/null)
check "Keycloak pod -> PostgreSQL açık" "open" "$OUT_PG"

echo
echo "Sonuç: $pass geçti, $fail kaldı (toplam $((pass + fail)))"
[[ $fail -eq 0 ]]
