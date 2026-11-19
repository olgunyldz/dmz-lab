#!/usr/bin/env bash
# Alloy'u tüm lab cluster'larına kurar (ns observability). Her cluster'da pod logları Loki'ye gider.
#   mgmt   : Loki'ye servis adıyla (cluster içi)
#   diğerleri: mgmt node IP'si + Loki NodePort 30100 (kind ağı üzerinden)
# Önkoşul: mgmt-cluster/scripts/load-observability.sh çalıştırılmış olmalı (Loki).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATE="$ROOT/manifests/alloy.yaml"
MGMT_IP=$(docker inspect -f '{{ .NetworkSettings.Networks.kind.IPAddress }}' platform-loki)   # Loki köprüsü (platform)
[[ -n "$MGMT_IP" ]] || { echo "HATA: mgmt node IP okunamadı" >&2; exit 1; }

# context  cluster-etiketi  Loki adresi
TARGETS=(
  "kind-codevo-dmz|codevo-dmz|http://$MGMT_IP:30100/loki/api/v1/push"
  "kind-bank-dmz-prod|bank-dmz-prod|http://$MGMT_IP:30100/loki/api/v1/push"
  "kind-bank-prod|bank-prod|http://$MGMT_IP:30100/loki/api/v1/push"
)

for t in "${TARGETS[@]}"; do
    IFS='|' read -r ctx cluster loki <<<"$t"
    K="kubectl --context $ctx"
    echo "== $ctx ($cluster) -> $loki"
    $K create namespace observability --dry-run=client -o yaml | $K apply -f - >/dev/null
    sed -e "s|__CLUSTER__|$cluster|" -e "s|__LOKI_URL__|$loki|" "$TEMPLATE" | $K apply -f - >/dev/null
    $K -n observability rollout restart deploy/alloy >/dev/null
    $K -n observability rollout status deploy/alloy --timeout=240s
done
echo "Alloy hazır: cluster loglarını platform Loki'sine gönderiyor (Grafana > Explore > Loki)."
