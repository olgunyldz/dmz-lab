#!/usr/bin/env bash
# DMZ lab'ını kaldırır (up.sh'nin tersi). Ters sırada çalışır:
#   1) Konsol port-forward süreçleri
#   2) DMZ, internal, identity, mgmt kind cluster'ları (node container'ları ve host iptables kuralları ile birlikte gider)
#   3) Edge (docker compose)
#   4) --purge ile: edge/certs (CA'lar dahil) ve dmz-lab yerel imajları
#
# Kullanım (repo kökünden):
#   bash down.sh              cluster'ları ve edge'i kaldır; sertifika ve imajlar kalır
#   bash down.sh --purge      ek olarak sertifikaları ve dmz-lab imajlarını da sil
#   bash down.sh --yes        onay sormadan çalıştır
#
# UYARI: mgmt cluster silinince Vault verisi (unseal anahtarı, root token, KV) gider.
#        Bir sonraki up.sh Vault'u yeniden başlatır ve parolaları yeniden üretir.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
CERTS="$ROOT/edge/certs"
PURGE=0
ASSUME_YES=0
for arg in "$@"; do
    case "$arg" in
        --purge) PURGE=1 ;;
        --yes|-y) ASSUME_YES=1 ;;
        *) echo "Bilinmeyen seçenek: $arg (kullanım: bash down.sh [--purge] [--yes])" >&2; exit 2 ;;
    esac
done

step() { echo; echo "=================== $* ==================="; }

if ! command -v kind >/dev/null 2>&1 || ! command -v docker >/dev/null 2>&1; then
    echo "HATA: kind ve docker gerekli." >&2
    exit 1
fi

CLUSTERS=$(kind get clusters 2>/dev/null | grep -E '^(branch|dmz|internal|identity|mgmt)$' || true)
EDGE_RUNNING=$(docker ps -a --filter "label=com.docker.compose.project=dmz-edge-lab" --format '{{.Names}}' 2>/dev/null || true)

echo "Kaldırılacak:"
if [[ -n "$CLUSTERS" ]]; then
    echo "  kind cluster'ları: $(echo $CLUSTERS)"
else
    echo "  kind cluster yok"
fi
if [[ -n "$EDGE_RUNNING" ]]; then
    echo "  edge (docker compose: dmz-edge-lab)"
else
    echo "  edge container'ı yok"
fi
if [[ $PURGE -eq 1 ]]; then
    echo "  --purge: edge/certs (CA'lar dahil) ve dmz-lab/* yerel imajları"
fi

if [[ $ASSUME_YES -ne 1 ]]; then
    echo
    read -r -p "Devam edilsin mi? (evet/hayır): " answer
    if [[ "$answer" != "evet" ]]; then
        echo "İptal edildi."
        exit 0
    fi
fi

# 1) Konsol port-forward'ları (kubectl port-forward süreçleri)
step "1/4 Port-forward süreçleri"
if command -v pkill >/dev/null 2>&1; then
    pkill -f "kubectl.*port-forward" 2>/dev/null && echo "port-forward süreçleri durduruldu" || echo "çalışan port-forward yok"
else
    echo "pkill yok; konsol (console/start.sh) ve port-forward süreçlerini elle durdurun"
fi

# 2) kind cluster'ları
step "2/4 kind cluster'ları"
for c in branch dmz internal identity mgmt; do
    if echo "$CLUSTERS" | grep -qx "$c"; then
        kind delete cluster --name "$c" && echo "silindi: $c"
    else
        echo "atlandı (yok): $c"
    fi
done

# 3) Edge
step "3/4 Edge (docker compose)"
if [[ -n "$EDGE_RUNNING" ]]; then
    docker compose -f "$ROOT/edge/docker-compose.yml" down
else
    echo "atlandı (çalışmıyor)"
fi

# 4) Purge
step "4/4 Temizlik"
if [[ $PURGE -eq 1 ]]; then
    if [[ -d "$CERTS" ]]; then
        rm -rf "$CERTS" && echo "silindi: edge/certs"
    fi
    for img in $(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep '^dmz-lab/' || true); do
        docker rmi "$img" >/dev/null 2>&1 && echo "silindi imaj: $img"
    done
else
    echo "Sertifikalar (edge/certs) ve imajlar korundu. Tümünü silmek için: bash down.sh --purge"
fi

# Kalan kind ağı (kind cluster'ları yokken boşta kalır; kind ağını docker kendisi yönetir)
echo
echo "=================== TAMAM ==================="
echo "Kurulum kaldırıldı. Yeniden kurmak için: bash up.sh"
