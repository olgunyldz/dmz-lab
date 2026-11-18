#!/usr/bin/env bash
# IP'ye bağlı tüm yapılandırmayı güncel node IP'leriyle yeniden uygular (idempotent).
# Neden: kind node'ları Docker yeniden başlayınca yeni IP alır; statik Endpoint'ler, HAProxy backend'leri ve
# firewall kuralları eski IP'de kalır. Bu betik her kurulum sonunda ve yeniden başlatmadan sonra çalıştırılır.
#   1) Vault'u aç (yeniden başlatmada mühürlenir)
#   2) IP'li manifest'leri (lab-ips.sh render) doğru cluster'a uygula
#   3) HAProxy yapılandırmasını yeniden üret; DMZ firewall kurallarını yenile
# Kullanım (repo kökünden): bash scripts/reconcile-ips.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/lab-ips.sh"

apply() { # <cluster> <manifest (repo göreli)>
    local ctx=$1 file=$2
    render "$ROOT/$file" | kubectl --context "kind-$ctx" apply -f - >/dev/null
    echo "  [$ctx] $file"
}

echo "1) Vault açılıyor (mühürlüyse)"
bash "$ROOT/identity-cluster/scripts/load-vault.sh" >/dev/null

echo "2) IP'li manifest'ler güncel IP'lerle uygulanıyor"
apply mgmt mgmt-cluster/manifests/prometheus.yaml
apply identity identity-cluster/manifests/spring-idp.yaml
apply internal internal-cluster/manifests/services.yaml
apply internal internal-cluster/manifests/gateway.yaml
apply internal internal-cluster/manifests/gateway-tracing.yaml
apply internal internal-cluster/manifests/device-gateway.yaml
apply internal internal-cluster/manifests/idp-internal.yaml
apply internal internal-cluster/manifests/seal-pm-route.yaml
apply dmz dmz-cluster/manifests/internal-backend.yaml
apply dmz dmz-cluster/manifests/device-gateway.yaml
apply dmz dmz-cluster/manifests/gateway-tracing.yaml
apply dmz dmz-cluster/manifests/branch.yaml
apply dmz dmz-cluster/manifests/extauth.yaml
apply dmz dmz-cluster/manifests/seal-mobile.yaml

echo "3) HAProxy ve DMZ firewall"
bash "$ROOT/edge/scripts/render-haproxy.sh" >/dev/null
bash "$ROOT/dmz-cluster/scripts/host-firewall.sh" >/dev/null

echo "Tamam: IP'ye bağlı yapılandırma güncel."
