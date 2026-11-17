#!/usr/bin/env bash
# Identity cluster kurulumu (lab). Tekrar çalıştırılabilir (idempotent).
#   1) kind cluster (kindnet)
#   2) Spring kimlik sağlayıcı: PostgreSQL + IdP (imaj, sırlar, TLS, manifest) -> load-spring-idp.sh
#   3) F8 erişim kısıtı host iptables ile (scripts/host-firewall.sh)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CTX="kind-identity"

if ! kind get clusters 2>/dev/null | grep -qx identity; then
    kind create cluster --config "$ROOT/kind-config.yaml" --wait 60s
fi

bash "$ROOT/scripts/load-spring-idp.sh"
bash "$ROOT/scripts/host-firewall.sh"

echo "Identity cluster hazır (Spring IdP). Testler: bash identity-cluster/spring-idp/tests/smoke.sh ve dmz/internal test süitleri."
