#!/usr/bin/env bash
# F1 (lab): DMZ node'larında NodePort'lara (30446-30448) yalnız edge HAProxy'den erişim.
# F10 (lab): gw-branch NodePort'u (30449) yalnız şube cluster'ının node IP'lerinden (WAN, cihaz mTLS) erişilir.
# Diğer her kaynak DROP edilir.
#
# Neden conntrack --ctorigdstport: kube-proxy NodePort'u DNAT eder, filter zincirinde hedef port artık
# pod portudur. Orijinal hedef portu conntrack'ten okumak gerekir. --ctdir ORIGINAL ile yalnız istemciden
# gelen paketler denetlenir; yanıt paketleri etkilenmez.
#
# Prod karşılığı: edge ile DMZ arasında fiziksel/sanal firewall (F1), şube ile DMZ arasında WAN firewall (F10).
# Idempotent: her çalıştırmada zincirler sıfırlanır ve yeniden kurulur.
set -euo pipefail

EDGE_PORTS=(30446 30447 30448)                   # gw-web, gw-mobile, gw-partner
BRANCH_PORT=30449                                # gw-branch (F10)
CHAIN="F1-EDGE"
BRANCH_CHAIN="F10-BRANCH"
EDGE_CONTAINER="dmz-edge-lab-haproxy-1"          # edge/docker-compose.yml, kind ağına bağlı

# HAProxy'nin kind ağındaki IP'si (container yeniden başlarsa değişebilir, script her seferinde okur)
EDGE_IP=$(docker inspect "$EDGE_CONTAINER" -f '{{ .NetworkSettings.Networks.kind.IPAddress }}' 2>/dev/null || true)
if [[ -z "$EDGE_IP" ]]; then
    echo "HAProxy IP alınamadı: $EDGE_CONTAINER (edge çalışıyor mu?)" >&2
    exit 1
fi

DMZ_NODES=$(kind get nodes --name dmz)
DMZ_NODE_IPS=$(for n in $DMZ_NODES; do docker inspect "$n" -f '{{ .NetworkSettings.Networks.kind.IPAddress }}'; done)

# Şube cluster'ı node IP'leri (WAN'dan gelen şube trafiğinin kaynağı). Cluster yoksa boş kalır.
BRANCH_NODES=$(kind get nodes --name branch 2>/dev/null || true)
BRANCH_NODE_IPS=$(for n in $BRANCH_NODES; do docker inspect "$n" -f '{{ .NetworkSettings.Networks.kind.IPAddress }}'; done)

jump() { # jump <port> <hedef zincir>
    local port=$1 target=$2
    echo "iptables -C FORWARD -p tcp -m conntrack --ctdir ORIGINAL --ctorigdstport $port -j $target 2>/dev/null || iptables -I FORWARD 1 -p tcp -m conntrack --ctdir ORIGINAL --ctorigdstport $port -j $target; "
    echo "iptables -C INPUT -p tcp -m conntrack --ctdir ORIGINAL --ctorigdstport $port -j $target 2>/dev/null || iptables -I INPUT 1 -p tcp -m conntrack --ctdir ORIGINAL --ctorigdstport $port -j $target; "
}

rules_for_node() {
    local node=$1
    local jumps=""
    for p in "${EDGE_PORTS[@]}"; do
        jumps+="$(jump "$p" "$CHAIN")"
    done
    jumps+="$(jump "$BRANCH_PORT" "$BRANCH_CHAIN")"

    local edge_accepts=""
    for ip in "$EDGE_IP" $DMZ_NODE_IPS; do
        edge_accepts+="iptables -A $CHAIN -s $ip/32 -j ACCEPT; "
    done
    local branch_accepts=""
    for ip in $BRANCH_NODE_IPS; do
        branch_accepts+="iptables -A $BRANCH_CHAIN -s $ip/32 -j ACCEPT; "
    done

    docker exec "$node" sh -c "
        iptables -N $CHAIN 2>/dev/null || true
        iptables -F $CHAIN
        $edge_accepts
        iptables -A $CHAIN -j DROP
        iptables -N $BRANCH_CHAIN 2>/dev/null || true
        iptables -F $BRANCH_CHAIN
        $branch_accepts
        iptables -A $BRANCH_CHAIN -j DROP
        $jumps
    "
}

for node in $DMZ_NODES; do
    rules_for_node "$node"
    echo "F1 uygulandı: $node (edge IP: $EDGE_IP; NodePort ${EDGE_PORTS[*]})"
    if [[ -n "$BRANCH_NODE_IPS" ]]; then
        echo "F10 uygulandı: $node (şube NodePort $BRANCH_PORT, kaynak: $(echo $BRANCH_NODE_IPS))"
    else
        echo "UYARI: şube cluster'ı yok; F10 yalnız kapalı kuralla uygulandı ($node:$BRANCH_PORT erişilemez)" >&2
    fi
done
