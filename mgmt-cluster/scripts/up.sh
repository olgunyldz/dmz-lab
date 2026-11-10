#!/usr/bin/env bash
# Management / secrets cluster kurulumu (lab). Tekrar çalıştırılabilir.
#   1) kind cluster (kindnet)
#   2) Vault (secrets ns): manifest + NodePort 30200
#   3) F9 erişim kısıtı (host iptables)
# Vault başlatma, mühür açma ve secret seed'i: identity-cluster/scripts/load-vault.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
K="kubectl --context kind-mgmt"

if ! kind get clusters 2>/dev/null | grep -qx mgmt; then
    kind create cluster --config "$ROOT/kind-config.yaml" --wait 120s
fi

$K apply -f "$ROOT/manifests/vault.yaml"
$K apply -f "$ROOT/manifests/vault-nodeport.yaml"

kind load docker-image hashicorp/vault:1.18 --name mgmt >/dev/null 2>&1 || true
bash "$ROOT/scripts/host-firewall.sh"

echo "Mgmt cluster hazır. Vault: NodePort 30200. Sonraki: bash identity-cluster/scripts/load-vault.sh"
