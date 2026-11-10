#!/usr/bin/env bash
# F9 (lab): mgmt node'larında Vault'a (pod 8200) yalnız identity ve internal cluster node IP'lerinden
# ve mgmt pod ağından erişim. Diğer kaynaklar (DMZ, yabancı kaynaklar) reddedilir.
# Yöntem identity-cluster/scripts/host-firewall.sh ile aynıdır (kindnet NetworkPolicy uygulamaz).
# Prod karşılığı: yönetim ağı firewall'u + NetworkPolicy + Vault'un kendi politikaları (design.md 6.2 F9).
set -euo pipefail

CHAIN="F9-VAULT"
POD_CIDR="10.244.0.0/16"
SOURCE_NODES="$(kind get nodes --name identity) $(kind get nodes --name internal) $(kind get nodes --name mgmt)"
SOURCE_IPS=$(for n in $SOURCE_NODES; do docker inspect "$n" -f '{{ .NetworkSettings.Networks.kind.IPAddress }}'; done)

for node in $(kind get nodes --name mgmt); do
    docker exec "$node" sh -c "
        iptables -N $CHAIN 2>/dev/null || true
        iptables -F $CHAIN
        iptables -A $CHAIN -s $POD_CIDR -j ACCEPT
        $(for ip in $SOURCE_IPS; do echo "iptables -A $CHAIN -s $ip/32 -j ACCEPT;"; done)
        iptables -A $CHAIN -j DROP
        iptables -C FORWARD -p tcp --dport 8200 -d $POD_CIDR -j $CHAIN 2>/dev/null || \
            iptables -I FORWARD 1 -p tcp --dport 8200 -d $POD_CIDR -j $CHAIN
    "
    echo "F9 kuralı uygulandı: $node"
done
