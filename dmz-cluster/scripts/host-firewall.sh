#!/usr/bin/env bash
# F1 (lab): DMZ node'larında NodePort'lara (30446-30448) yalnız edge HAProxy'den erişim.
# Diğer her kaynak (kind ağındaki yabancı container'lar, diğer node'lar dışındaki her IP) DROP edilir.
#
# Neden conntrack --ctorigdstport: kube-proxy NodePort'u DNAT eder, filter zincirinde hedef port artık
# pod portudur. Orijinal hedef portu conntrack'ten okumak gerekir. --ctdir ORIGINAL ile yalnız istemciden
# gelen paketler denetlenir; yanıt paketleri etkilenmez.
#
# Prod karşılığı: edge ile DMZ arasında fiziksel/sanal firewall (F1), kaynak IP ve port allowlist.
# Idempotent: her çalıştırmada zincir sıfırlanır ve yeniden kurulur.
set -euo pipefail

NODEPORTS=(30446 30447 30448 30449)              # gw-web, gw-mobile, gw-partner, gw-branch
CHAIN="F1-EDGE"
EDGE_CONTAINER="dmz-edge-lab-haproxy-1"          # edge/docker-compose.yml, kind ağına bağlı

# HAProxy'nin kind ağındaki IP'si (container yeniden başlarsa değişebilir, script her seferinde okur)
EDGE_IP=$(docker inspect "$EDGE_CONTAINER" -f '{{ .NetworkSettings.Networks.kind.IPAddress }}')
if [[ -z "$EDGE_IP" ]]; then
    echo "HAProxy IP alınamadı: $EDGE_CONTAINER (edge çalışıyor mu?)" >&2
    exit 1
fi

DMZ_NODES=$(kind get nodes --name dmz)
DMZ_NODE_IPS=$(for n in $DMZ_NODES; do docker inspect "$n" -f '{{ .NetworkSettings.Networks.kind.IPAddress }}'; done)

rules_for_node() {
    local node=$1
    local jumps=""
    for p in "${NODEPORTS[@]}"; do
        jumps+="iptables -C FORWARD -p tcp -m conntrack --ctdir ORIGINAL --ctorigdstport $p -j $CHAIN 2>/dev/null || iptables -I FORWARD 1 -p tcp -m conntrack --ctdir ORIGINAL --ctorigdstport $p -j $CHAIN; "
        jumps+="iptables -C INPUT -p tcp -m conntrack --ctdir ORIGINAL --ctorigdstport $p -j $CHAIN 2>/dev/null || iptables -I INPUT 1 -p tcp -m conntrack --ctdir ORIGINAL --ctorigdstport $p -j $CHAIN; "
    done
    local accepts=""
    for ip in "$EDGE_IP" $DMZ_NODE_IPS; do
        accepts+="iptables -A $CHAIN -s $ip/32 -j ACCEPT; "
    done
    docker exec "$node" sh -c "
        iptables -N $CHAIN 2>/dev/null || true
        iptables -F $CHAIN
        $accepts
        iptables -A $CHAIN -j DROP
        $jumps
    "
}

for node in $DMZ_NODES; do
    rules_for_node "$node"
    echo "F1 kuralı uygulandı: $node (edge IP: $EDGE_IP)"
done
