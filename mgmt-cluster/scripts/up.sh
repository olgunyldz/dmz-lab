#!/usr/bin/env bash
# Management cluster'ını (kind-mgmt) oluşturur. Tekrar çalıştırılabilir.
# Bileşenler kendi yükleyicileriyle kurulur (cluster oluştuktan sonra):
#   LegacyDB ve Redis          : legacy-demo / veri katmanı yükleyicileri
#   Gözlemlenebilirlik         : scripts/load-observability.sh
#   Log toplayıcı (Alloy)      : scripts/load-alloy.sh (beş cluster'a)
# Vault bank-prod cluster'ındadır: bank-prod-cluster/scripts/load-vault.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if ! kind get clusters 2>/dev/null | grep -qx mgmt; then
    kind create cluster --config "$ROOT/kind-config.yaml" --wait 120s
fi

echo "Mgmt cluster hazır (kind-mgmt). Sonraki: scripts/load-observability.sh"
