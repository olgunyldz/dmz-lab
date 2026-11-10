#!/usr/bin/env bash
# Identity cluster kurulumu (lab). Tekrar çalıştırılabilir (idempotent).
#   1) kind cluster (kindnet). F8 erişim kısıtı host iptables ile (scripts/host-firewall.sh)
#   2) Vault (kaynak secret deposu) ve Keycloak parolaları
#   3) PostgreSQL + Keycloak (SPI imajı) + NodePort + NetworkPolicy
# Realm, client ve kullanıcılar için: scripts/setup-realm.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CTX="kind-identity"
K="kubectl --context $CTX"
KEYCLOAK_IMAGE="dmz-lab/keycloak-dpop:26.6"   # keycloak-spi/ ile derlenir (docker build)

if ! kind get clusters 2>/dev/null | grep -qx identity; then
    kind create cluster --config "$ROOT/kind-config.yaml" --wait 60s
fi

# Keycloak SPI imajı kind node'larına yüklenir
kind load docker-image "$KEYCLOAK_IMAGE" --name identity >/dev/null

bash "$ROOT/scripts/load-vault.sh"

$K apply -f "$ROOT/manifests/keycloak.yaml"
$K apply -f "$ROOT/manifests/keycloak-nodeport.yaml"
bash "$ROOT/scripts/host-firewall.sh"

# Vault parolaları yenilendiyse PostgreSQL'i (emptyDir) yeni parolayla yeniden başlat
$K -n auth rollout restart deploy/postgres >/dev/null
$K -n auth rollout status deploy/postgres --timeout=240s
$K -n auth rollout restart deploy/keycloak >/dev/null
$K -n auth rollout status deploy/keycloak --timeout=600s

echo "Identity cluster hazır. Sonraki adım: bash identity-cluster/scripts/setup-realm.sh"
