# Node IP'lerini kind node container'larından okur. Sabit IP varsayımı YOK: Docker IP'leri kurulum sırasına göre atar.
# Kullanım (kurulum betiklerinde):  source "$ROOT/../scripts/lab-ips.sh"
#   render <manifest>  -> yer tutucuları doldurulmuş YAML'ı stdout'a yazar. Yalnız dosyada geçen IP'ler okunur,
#                         çünkü her cluster kurulum sırasında henüz yok olabilir.
#   Örnek: render "$ROOT/manifests/x.yaml" | kubectl --context kind-dmz apply -f -
# Yer tutucular: __DMZ_NODE_IP__ __INTERNAL_NODE_IP__ __IDENTITY_NODE_IP__ __MGMT_NODE_IP__
# Node adı ile erişim (Docker DNS) yalnız HAProxy'de kullanılır; pod'lar node adını çözemez, IP gerekir.

_ip_of() {
    docker inspect "$1" -f '{{ .NetworkSettings.Networks.kind.IPAddress }}' 2>/dev/null || true
}

# Bir cluster'ın tüm node IP'leri (F8/F9 gibi listeler için)
cluster_node_ips() {
    local n
    for n in $(kind get nodes --name "$1" 2>/dev/null); do _ip_of "$n"; done
}

render() {
    local out pair var node ip
    out=$(cat "$1") || return 1
    for pair in DMZ_NODE_IP:dmz-worker DMZ_WORKER2_IP:dmz-worker2 INTERNAL_NODE_IP:internal-control-plane \
                IDENTITY_NODE_IP:identity-control-plane MGMT_NODE_IP:mgmt-control-plane; do
        var=${pair%%:*}
        node=${pair#*:}
        if grep -q "__${var}__" <<<"$out"; then
            ip=$(_ip_of "$node")
            if [[ -z "$ip" ]]; then
                echo "HATA: $node IP'si okunamadı (${var} gerekli; ilgili cluster kurulu mu?)" >&2
                return 1
            fi
            out=${out//__${var}__/$ip}
        fi
    done
    printf '%s\n' "$out"
}
