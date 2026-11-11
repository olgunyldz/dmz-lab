#!/usr/bin/env bash
# DMZ lab'ının tamamını sıfırdan (veya yarım kalmış bir kurulumun üzerine) ayağa kaldırır.
# Tekrar çalıştırılabilir: var olan cluster, sertifika ve imajlar yeniden üretilmez/derlenmez.
#
# Önce ön kontroller (preflight) çalışır; bir HATA varsa hiçbir şey kurulmaz.
#
# Sıra (bağımlılıklara göre):
#   0) Ön kontroller ve sertifikalar (edge/certs)
#   1) mgmt cluster (Vault)                   ← kind ağını oluşturur, edge bunu kullanır
#   2) Edge (docker compose: HAProxy + WAF)
#   3) identity cluster (PostgreSQL, Keycloak) + Vault'tan parolalar + realm/client kurulumu
#   4) internal cluster (kgateway, BFF, core)
#   5) DMZ cluster (kgateway, kanal gateway'leri, F1) + iç backend + ext-authz + şube
#
# Kullanım (repo kökünden):
#   bash up.sh           kur
#   bash up.sh --check   yalnız ön kontrolleri çalıştır, kurma
# Sonra testler:         bash run-all.sh
# Kaldırma:              bash down.sh
# Konsol (isteğe bağlı): bash console/start.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
CERTS="$ROOT/edge/certs"
CHECK_ONLY=0
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=1

step() { echo; echo "=================== $* ==================="; }

# ---------------------------------------------------------------------------
# Ön kontroller. PASS / WARN / FAIL. Herhangi bir FAIL varsa kurulum başlamaz.
# ---------------------------------------------------------------------------
FAILS=0
pass() { echo "  [PASS] $*"; }
warn() { echo "  [WARN] $*"; }
fail() { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }

port_open() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

preflight() {
    echo "Ön kontroller:"

    # 1) Araçlar ve sürümleri
    for tool in docker kind kubectl helm openssl curl; do
        if command -v "$tool" >/dev/null 2>&1; then
            pass "$tool bulundu"
        else
            fail "$tool bulunamadı (kurup tekrar deneyin)"
        fi
    done

    # 2) Docker daemon ve compose
    if docker info >/dev/null 2>&1; then
        pass "Docker çalışıyor"
        mem=$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)
        if [[ "$mem" -ge $((8 * 1024 * 1024 * 1024)) ]]; then
            pass "Docker belleği yeterli ($((mem / 1024 / 1024 / 1024)) GB)"
        else
            warn "Docker belleği 8 GB'ın altında; 4 cluster ağır olabilir (Docker Desktop/WSL ayarını kontrol edin)"
        fi
    else
        fail "Docker daemon'a bağlanılamıyor (Docker Desktop açık mı?)"
    fi
    if docker compose version >/dev/null 2>&1; then
        pass "docker compose (v2) hazır"
    else
        fail "docker compose v2 yok"
    fi

    # 3) Repo dosyaları: betiklerin ve manifest'lerin varlığı
    local required=(
        edge/docker-compose.yml edge/haproxy/haproxy.cfg edge/scripts/build-waf.sh
        edge/scripts/gen-certs.sh edge/scripts/gen-branch-certs.sh edge/scripts/gen-internal-certs.sh
        mgmt-cluster/kind-config.yaml mgmt-cluster/scripts/up.sh
        identity-cluster/kind-config.yaml identity-cluster/scripts/up.sh
        identity-cluster/scripts/load-vault.sh identity-cluster/scripts/setup-realm.sh
        identity-cluster/keycloak-spi/Dockerfile
        internal-cluster/kind-config.yaml internal-cluster/scripts/up.sh
        internal-cluster/scripts/load-services.sh
        dmz-cluster/kind-config.yaml dmz-cluster/scripts/up.sh
        dmz-cluster/scripts/load-internal-backend.sh dmz-cluster/scripts/load-extauth.sh
        dmz-cluster/scripts/load-branch.sh
        branch-cluster/kind-config.yaml branch-cluster/manifests/branch-ui.yaml
        branch-cluster/scripts/up.sh branch/server.py branch/probe.py branch/index.html
        shared/tracing.py shared/metrics.py
    )
    local missing=0
    for f in "${required[@]}"; do
        [[ -e "$ROOT/$f" ]] || { fail "eksik dosya: $f"; missing=1; }
    done
    [[ $missing -eq 0 ]] && pass "Repo dosyaları eksiksiz (${#required[@]} kontrol)"

    # 4) kind ağı: lab IP planı 172.18.0.0/16 varsayar
    if docker network inspect kind >/dev/null 2>&1; then
        subnets=$(docker network inspect kind --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null)
        if echo "$subnets" | grep -qw "172.18.0.0/16"; then
            pass "kind ağı 172.18.0.0/16 içeriyor"
        else
            fail "kind ağı ($subnets) 172.18.0.0/16 içermiyor; lab IP planı bu subnet'e bağlı. Ağı yeniden oluşturmak için önce tüm kind cluster'larını silin (bash down.sh)."
        fi
    else
        pass "kind ağı henüz yok (ilk cluster oluşturulunca açılır)"
    fi

    # 5) Mevcut cluster'lar (yeniden kullanılır)
    existing=$(kind get clusters 2>/dev/null | tr '\n' ' ' || true)
    if [[ -n "${existing// /}" ]]; then
        pass "Mevcut kind cluster'ları yeniden kullanılacak: $existing"
    else
        pass "Kind cluster yok; sıfırdan oluşturulacak"
    fi

    # 6) Host portları: edge 8443/8404. Compose'un haproxy'si çalışmıyorsa bu portlar dolu olmamalı.
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q 'haproxy'; then
        pass "Edge (haproxy) zaten çalışıyor; port kontrolü atlandı"
    else
        for p in 8443 8404; do
            if port_open "$p"; then
                fail "host port $p dolu (başka bir süreç kullanıyor)"
            else
                pass "host port $p boş"
            fi
        done
    fi
    for p in 9000 9100 18081 14318 3000; do
        if port_open "$p"; then
            warn "host port $p dolu (konsol/port-forward kalıntısı olabilir; konsol için gerekli)"
        fi
    done

    # 7) İnternet: gateway API manifest'i, kgateway chart, WAF/Keycloak bağımlılıkları
    for url in https://github.com https://cr.kgateway.dev; do
        if curl -sI --max-time 10 "$url" >/dev/null 2>&1; then
            pass "erişilebilir: $url"
        else
            warn "erişilemiyor: $url (kurulum cache'e bağlıysa devam edilebilir)"
        fi
    done

    # 8) Sertifika durumu (bilgi)
    if [[ -f "$CERTS/internal-ca.crt" ]]; then
        pass "CA'lar mevcut (yeniden üretilmeyecek)"
    else
        warn "CA'lar yok; kurulumda üretilecek"
    fi
}

echo "=================== ÖN KONTROLLER ==================="
preflight
echo
if [[ $FAILS -gt 0 ]]; then
    echo "$FAILS kontrol başarısız. Kurulum durduruldu."
    exit 1
fi
echo "Ön kontroller geçti."
[[ $CHECK_ONLY -eq 1 ]] && exit 0

# ---------------------------------------------------------------------------
# Kurulum
# ---------------------------------------------------------------------------

# 0) Sertifikalar
step "0/5 Sertifikalar ve yerel imajlar"
# CA'lar bir kez üretilir. gen-certs.sh her çalıştığında CA'ları yeniden üretir, bu yüzden yalnızca yoksa çağrılır.
if [[ ! -f "$CERTS/internal-ca.crt" ]]; then
    bash "$ROOT/edge/scripts/gen-certs.sh"
fi
bash "$ROOT/edge/scripts/gen-branch-certs.sh"
bash "$ROOT/edge/scripts/gen-internal-certs.sh"

# Yerel imajlar (Docker Hub'da yok ya da kind'a yüklenmeli)
if ! docker image inspect dmz-lab/coraza-spoa:0.9.1 >/dev/null 2>&1; then
    bash "$ROOT/edge/scripts/build-waf.sh"
fi
if ! docker image inspect dmz-lab/keycloak-dpop:26.6 >/dev/null 2>&1; then
    docker build -t dmz-lab/keycloak-dpop:26.6 "$ROOT/identity-cluster/keycloak-spi"
fi

# 1) mgmt cluster (Vault). kind ağı bu adımda oluşur.
step "1/5 mgmt cluster (Vault, F9)"
bash "$ROOT/mgmt-cluster/scripts/up.sh"

# 2) Edge
step "2/5 Edge (HAProxy + Coraza WAF)"
# HAProxy yapılandırması: DMZ IP'leri henüz yoksa (ilk kurulum) yer tutucular 127.0.0.1 ile başlatılır;
# DMZ kurulduktan sonra render-haproxy.sh gerçek IP'lerle yeniden üretir ve HAProxy'yi yeniden başlatır.
if [[ ! -f "$ROOT/edge/haproxy/haproxy.cfg" ]]; then
    sed -e 's/__DMZ_NODE_IP__/127.0.0.1/g' -e 's/__DMZ_WORKER2_IP__/127.0.0.1/g' \n        "$ROOT/edge/haproxy/haproxy.cfg.tpl" > "$ROOT/edge/haproxy/haproxy.cfg"
fi
docker compose -f "$ROOT/edge/docker-compose.yml" up -d

# 3) identity: cluster, Vault'tan parolalar, Keycloak, realm
step "3/5 identity cluster (Keycloak, PostgreSQL, F8)"
bash "$ROOT/identity-cluster/scripts/up.sh"
bash "$ROOT/identity-cluster/scripts/setup-realm.sh"

# 4) internal
step "4/5 internal cluster (gw-internal, BFF, core)"
bash "$ROOT/internal-cluster/scripts/up.sh"

# 5) DMZ
step "5/5 DMZ cluster (gateway'ler, F1, iç backend, ext-authz, şube)"
bash "$ROOT/dmz-cluster/scripts/up.sh"
bash "$ROOT/dmz-cluster/scripts/load-internal-backend.sh"
# load-branch.sh önce: gw-branch namespace'ini oluşturur; load-extauth.sh onun içindeki kaynakları ister
bash "$ROOT/dmz-cluster/scripts/load-branch.sh"
bash "$ROOT/dmz-cluster/scripts/load-extauth.sh"

# Edge (HAProxy) DMZ node IP'lerini bilir: yapılandırma DMZ kurulduktan sonra üretilir
bash "$ROOT/edge/scripts/render-haproxy.sh"

# 6) Şube cluster'ı (HAProxy yok; gw-branch'e WAN üzerinden doğrudan, F10)
step "6/6 Şube cluster (şube UI pod'u, gw-branch'e doğrudan bağlantı)"
bash "$ROOT/branch-cluster/scripts/up.sh"

# Gözlemlenebilirlik (Tempo, Prometheus, Grafana): tüm cluster IP'leri hazır olduktan sonra
bash "$ROOT/mgmt-cluster/scripts/load-observability.sh"

# Yönetim araçları host'tan doğrudan (HAProxy yok): Grafana 3000, Prometheus 9090, Vault 8200
bash "$ROOT/mgmt-cluster/scripts/tools-forward.sh" start || true

echo
echo "=================== TAMAM ==================="
echo "Sistem ayakta. Test:      bash run-all.sh"
echo "Konsol (isteğe bağlı):    bash console/start.sh   (port-forward'ları kurar)"
echo "Grafana NodePort 30300 (mgmt), Prometheus 30090, Tempo OTLP 30318."
