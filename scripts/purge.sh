#!/usr/bin/env bash
# Lab temizliği: kind cluster'ları, compose yığınları, lab container/volume/network'leri, süreçler ve isteğe bağlı
# dosya ve imajlar.
#
# Kullanım:
#   bash scripts/purge.sh              etkileşimli menü: seçenekleri siz seçersiniz
#   bash scripts/purge.sh --dry-run    silinecekleri gösterir, hiçbir şey silmez
#   bash scripts/purge.sh --yes        onaylı gerçek silme (varsayılan kapsam; seçenek bayraklarıyla birlikte)
#
# Seçenekler:
#   --dry-run       silinecekleri gösterir, hiçbir şey silmez
#   --yes           onay: bayraklarla gerçek silme için zorunlu
#   --files         üretilmiş dosyaları da siler: platform/.env, edge/certs, edge/haproxy/haproxy.cfg, .tools-forward, .build
#   --images        lab imajlarını siler (dmz-lab/*)
#   --base-images   lab'ın kullandığı üçüncü taraf imajları siler (kindest/node, grafana, prometheus, loki, jaeger,
#                   haproxy, python, alpine/socat, vb.)
#   --docker-all    Docker'ın kullanılmayan tüm container, volume, network ve build cache'ini siler (imajlara dokunmaz)
#   -h, --help      bu yardım
#
# Varsayılan (her zaman): console ve port-forward süreçleri, kind cluster'ları, platform ve edge compose yığınları
# (volume'larıyla), lab container'ları (platform-*, lab-platform-*, dmz-edge-lab-*), lab volume'ları ve network'leri.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

usage() { awk 'NR>1 && /^set -uo/ {exit} NR>1 {print}' "$0" | sed 's/^# \{0,1\}//'; }

DRY=0; YES=0; FILES=0; IMAGES=0; BASE_IMAGES=0; DOCKER_ALL=0

ask() { # <soru> ; y/evet ise 0 döner
    local ans
    read -r -p "$1 [e/H]: " ans
    [[ "$ans" =~ ^([eEyY]|evet|yes)$ ]]
}

if [[ $# -eq 0 ]]; then
    if [[ ! -t 0 && -z "${PURGE_INTERACTIVE:-}" ]]; then  # PURGE_INTERACTIVE=1: boru ile yanıt verip test etmek için
        # Etkileşim yok (ör. otomasyon): hiçbir şey silmeden yardımı göster
        usage
        echo "Etkileşim yok; hiçbir şey silinmedi. Bayraklarla çalıştırın (yardım: -h)."
        exit 0
    fi
    echo "DMZ lab temizliği - seçenekleri seçin (Enter = hayır)"
    echo "Varsayılan kapsam her zaman silinir: süreçler, kind cluster'ları, platform/edge compose,"
    echo "lab container'ları ve volume'ları, lab network'leri."
    echo
    if ask "Hepsi silinsin mi? (dosyalar, dmz-lab imajları, üçüncü taraf imajlar, Docker temizliği)"; then
        if ask "Önce dry-run (sadece göster) yapılsın mı?"; then DRY=1; fi
        FILES=1; IMAGES=1; BASE_IMAGES=1; DOCKER_ALL=1
    else
        if ask "Önce dry-run (sadece göster) yapılsın mı?"; then DRY=1; fi
        ask "Üretilmiş dosyalar silinsin mi (platform/.env, edge/certs, haproxy.cfg, .tools-forward, .build)?" && FILES=1
        ask "Lab imajları silinsin mi (dmz-lab/*)?" && IMAGES=1
        ask "Üçüncü taraf lab imajları silinsin mi (kindest/node, grafana, prometheus, loki, jaeger, haproxy, ...)?" && BASE_IMAGES=1
        ask "Docker kullanılmayan container/volume/network/build cache temizlensin mi (imajlar korunur)?" && DOCKER_ALL=1
    fi
    echo
    echo "Seçilen: dry-run=$DRY dosyalar=$FILES lab-imajlar=$IMAGES 3.parti-imajlar=$BASE_IMAGES docker-temizlik=$DOCKER_ALL"
    if [[ $DRY -eq 0 ]]; then
        read -r -p "Gerçek silme için 'evet' yazın (başka her şey iptal): " confirm
        if [[ "$confirm" != "evet" ]]; then echo "İptal edildi; hiçbir şey silinmedi."; exit 0; fi
        YES=1
    fi
else
    for a in "$@"; do
        case "$a" in
            --dry-run) DRY=1 ;;
            --yes) YES=1 ;;
            --files) FILES=1 ;;
            --images) IMAGES=1 ;;
            --base-images) BASE_IMAGES=1 ;;
            --docker-all) DOCKER_ALL=1 ;;
            -h|--help) usage; exit 0 ;;
            *) echo "bilinmeyen seçenek: $a (yardım için -h)" >&2; exit 2 ;;
        esac
    done
    if [[ $DRY -eq 0 && $YES -eq 0 ]]; then
        echo "Gerçek silme için --yes gerekli. Önce --dry-run ile kontrol edin, ya da argümansız çalıştırıp menüden seçin." >&2
        exit 2
    fi
fi

# Komut çalıştır; dry-run'da yalnız yazdırır
run() {
    if [[ $DRY -eq 1 ]]; then
        echo "  [dry] $*"
    else
        "$@" >/dev/null 2>&1 || true
    fi
}

KIND_CLUSTERS=(bank-prod bank-dmz-prod codevo-dmz mgmt legacy-demo identity)
COMPOSE_FILES=(platform/docker-compose.yml edge/docker-compose.yml)
LAB_NETWORKS=(kind lab-platform edge)
BASE_IMAGE_PATTERN='^(kindest/node|grafana/grafana|prom/prometheus|grafana/loki|grafana/tempo|jaegertracing/all-in-one|grafana/alloy|alpine/socat|haproxy|python|postgres|ingress-nginx/controller|registry.k8s.io/ingress-nginx/controller|bitnami/kubectl)'

echo "== 1) Süreçler (console, kubectl port-forward)"
if [[ $DRY -eq 1 ]]; then
    echo "  [dry] console (127.0.0.1:9000) ve kubectl süreçleri kapatılır"
else
    for pid in $(netstat -ano 2>/dev/null | grep -E "127\.0\.0\.1:9000[[:space:]].*LISTENING" | awk '{print $5}' | sort -u); do
        taskkill //PID "$pid" //F >/dev/null 2>&1 || true
    done
    taskkill //F //IM kubectl.exe >/dev/null 2>&1 || true
fi

echo "== 2) kind cluster'ları"
existing=$(kind get clusters 2>/dev/null || true)
for c in "${KIND_CLUSTERS[@]}"; do
    if grep -qx "$c" <<<"$existing"; then
        if [[ $DRY -eq 1 ]]; then echo "  [dry] kind delete cluster --name $c"
        else kind delete cluster --name "$c" >/dev/null 2>&1 || true; fi
    fi
done

echo "== 3) Compose yığınları (volume'larla)"
for f in "${COMPOSE_FILES[@]}"; do
    if [[ -f "$f" ]]; then
        if [[ $DRY -eq 1 ]]; then echo "  [dry] docker compose -f $f down -v --remove-orphans"
        else docker compose -f "$f" down -v --remove-orphans >/dev/null 2>&1 || true; fi
    fi
done

echo "== 4) Lab container'ları (compose dışında kalanlar)"
for n in $(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E '^(platform-|lab-platform-|dmz-edge-lab-)' | sort -u); do
    if [[ $DRY -eq 1 ]]; then echo "  [dry] docker rm -f $n"; else docker rm -f "$n" >/dev/null 2>&1 || true; fi
done

echo "== 5) Lab volume'ları ve network'leri"
for v in $(docker volume ls -q 2>/dev/null | grep -E '^(lab-platform_|dmz-edge-lab_)' | sort -u); do
    run docker volume rm -f "$v"
done
for n in "${LAB_NETWORKS[@]}"; do
    run docker network rm "$n"
done

if [[ $FILES -eq 1 ]]; then
    echo "== 6) Üretilmiş dosyalar (--files)"
    for p in platform/.env edge/certs edge/haproxy/haproxy.cfg .tools-forward .build; do
        if [[ -e "$p" ]]; then
            if [[ $DRY -eq 1 ]]; then echo "  [dry] rm -rf $p"; else rm -rf "$p"; fi
        fi
    done
fi

if [[ $IMAGES -eq 1 ]]; then
    echo "== 7) Lab imajları (dmz-lab/*)"
    for img in $(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep '^dmz-lab/' | sort -u); do
        run docker rmi -f "$img"
    done
fi

if [[ $BASE_IMAGES -eq 1 ]]; then
    echo "== 8) Üçüncü taraf lab imajları"
    for img in $(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -E "$BASE_IMAGE_PATTERN" | sort -u); do
        run docker rmi -f "$img"
    done
fi

if [[ $DOCKER_ALL -eq 1 ]]; then
    echo "== 9) Docker temizliği (imajlar korunur)"
    if [[ $DRY -eq 1 ]]; then
        echo "  [dry] docker container prune -f"
        echo "  [dry] docker volume prune -f"
        echo "  [dry] docker network prune -f"
        echo "  [dry] docker builder prune -af"
    else
        docker container prune -f >/dev/null 2>&1 || true
        docker volume prune -f >/dev/null 2>&1 || true
        docker network prune -f >/dev/null 2>&1 || true
        docker builder prune -af >/dev/null 2>&1 || true
    fi
fi

echo "== Bitti"
echo "Kalan kind cluster'ları:"; kind get clusters 2>/dev/null || true
echo "Kalan lab container'ları:"
docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E '^(platform-|lab-platform-|dmz-edge-lab-)' || echo "  yok"
[[ $DRY -eq 1 ]] && echo "(dry-run: hiçbir şey silinmedi)"
exit 0
