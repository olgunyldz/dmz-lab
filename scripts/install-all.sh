#!/usr/bin/env bash
# Sıfırdan kurulum (tekrar çalıştırılabilir). Sıra bağımlılıklara göre:
#   1) kind cluster'ları (infra/clusters/<ad>/kind-config.yaml)
#   2) edge iç CA sertifikaları
#   3) nginx ingress controller (her cluster'da; helm, scripts/lib/cluster.sh: install_ingress)
#   4) Vault (bank-prod, infra/vault/load-vault.sh)
#   5) auth-server          apps/auth-server   (manifest + ingress)
#   6) Platform (compose)   platform/scripts/up.sh (LegacyDB, monolit, Loki, Jaeger, Prometheus, Grafana, köprüler)
#   7) Fortuna zinciri      apps/fortuna
#   8) Janus web/mobil      apps/janus         (manifest + ingress)
#   9) channel-gateway      apps/channel-gateway
#  10) Seal Intranet        apps/seal-intranet (manifest + ingress)
#  11) Seal Mobile          apps/seal-mobile   (manifest + ingress)
#  12) Edge (HAProxy)       edge/scripts/render-haproxy.sh
#  13) Gözlemlenebilirlik   observability/install.sh (Alloy, Prometheus agent)
# Uygulamalar scripts/deploy-app.sh ile kurulur; Jenkins da aynı script'i çağırır.
# Console (python console/app.py) ayrı başlatılır.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source "$ROOT/scripts/lib/cluster.sh"

echo "== 1) kind cluster'ları"
for c in bank-prod bank-dmz-prod codevo-dmz; do ensure_cluster "$c"; done

echo "== 2) edge iç CA sertifikaları"
[[ -f edge/certs/internal-ca.crt ]] || { bash edge/scripts/gen-certs.sh; bash edge/scripts/gen-internal-certs.sh; }

echo "== 3) nginx ingress controller"
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
helm repo update ingress-nginx >/dev/null
install_ingress bank-dmz-prod 30802 30443 false
install_ingress codevo-dmz    30080 30456 true
install_ingress bank-prod     30081 30543 true

echo "== 4) Vault";              bash infra/vault/load-vault.sh
echo "== 5) auth-server";        bash scripts/deploy-app.sh auth-server
echo "== 6) Platform";           bash platform/scripts/up.sh
echo "== 7) Fortuna";            bash scripts/deploy-app.sh fortuna
echo "== 8) Janus";              bash scripts/deploy-app.sh janus
echo "== 9) channel-gateway";    bash scripts/deploy-app.sh channel-gateway
echo "== 10) Seal Intranet";     bash scripts/deploy-app.sh seal-intranet
echo "== 11) Seal Mobile";       bash scripts/deploy-app.sh seal-mobile
echo "== 12) Edge";              bash edge/scripts/render-haproxy.sh
echo "== 13) Gözlemlenebilirlik"; bash observability/install.sh
echo "Kurulum tamam. Console: nohup python console/app.py (http://127.0.0.1:9000)"
