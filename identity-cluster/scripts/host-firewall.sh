#!/usr/bin/env bash
# F8 (lab): Identity node'larında Keycloak'a (pod 8080) yalnız iç cluster node IP'lerinden ve
# identity pod ağından (cluster içi) erişim. Diğer kaynaklar (DMZ, kind ağındaki yabancı container'lar) reddedilir.
#
# Neden host iptables: kindnet NetworkPolicy uygulamaz. Cilium bu WSL2 çekirdeğinde çalışmıyor (xt_socket eksik).
# Kurallar filter/FORWARD zincirinde, kube-proxy NodePort DNAT'ından sonra uygulanır (dport=8080, hedef pod CIDR).
# Prod karşılığı: Cilium/Calico NetworkPolicy + kurumsal firewall (design.md 6.2 F8, 15.2).
#
# Idempotent: her çalıştırmada zincir sıfırlanır ve yeniden kurulur.
set -euo pipefail

INTERNAL_NODE_IPS=($(for n in $(kind get nodes --name internal); do docker inspect "$n" -f '{{ .NetworkSettings.Networks.kind.IPAddress }}'; done))  # internal cluster node IP'leri (kind-internal)
POD_CIDR="10.244.0.0/16"
CHAIN="F8-KEYCLOAK"

# Identity node IP'leri: kube-proxy NodePort trafiğini (externalTrafficPolicy=Cluster) giriş node'unda SNAT'ler.
# Dış kaynak, giriş node'unda (SNAT'tan önce) kontrol edilir; bu yüzden node IP'leri ikinci sıçrama için kabul edilir.
IDENTITY_NODES=$(kind get nodes --name identity)
IDENTITY_NODE_IPS=$(for n in $IDENTITY_NODES; do docker inspect "$n" -f '{{ .NetworkSettings.Networks.kind.IPAddress }}'; done)

rules_for_node() {
    local node=$1
    docker exec "$node" sh -c "
        iptables -N $CHAIN 2>/dev/null || true
        iptables -F $CHAIN
        iptables -A $CHAIN -s $POD_CIDR -j ACCEPT
        $(for ip in "${INTERNAL_NODE_IPS[@]}" $IDENTITY_NODE_IPS; do echo "iptables -A $CHAIN -s $ip/32 -j ACCEPT;"; done)
        iptables -A $CHAIN -j DROP
        iptables -C FORWARD -p tcp --dport 8080 -d $POD_CIDR -j $CHAIN 2>/dev/null || \
            iptables -I FORWARD 1 -p tcp --dport 8080 -d $POD_CIDR -j $CHAIN
    "
}

for node in $(kind get nodes --name identity); do
    rules_for_node "$node"
    echo "F8 kuralı uygulandı: $node"
done
