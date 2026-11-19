#!/usr/bin/env bash
# Platform (host, docker compose): LegacyDB, merkezi Prometheus, Loki, Tempo, Grafana, Fortuna monolit ve köprüler.
# .env: parolalar mevcut dosyadan korunur (ilk kurulumda mgmt secret'larından alınır); düğüm IP'leri ve
# sırlar her çalıştırmada cluster'lardan yeniden okunur. Repoda sır yok (.env gitignore'da).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
get_env() { [[ -f .env ]] && grep "^$1=" .env | cut -d= -f2- || true; }
LEGACYDB_PASSWORD=$(get_env LEGACYDB_PASSWORD)
GRAFANA_ADMIN_PASSWORD=$(get_env GRAFANA_ADMIN_PASSWORD)
if [[ -z "$LEGACYDB_PASSWORD" || -z "$GRAFANA_ADMIN_PASSWORD" ]]; then
    echo "HATA: .env yok ya da parolalar boş; ilk kurulumda mgmt secret'larından oluşturulmalı" >&2; exit 1
fi
node_ip() { docker inspect -f '{{ index .NetworkSettings.Networks "kind" "IPAddress" }}' "$1"; }
BANKPROD_NODE_IP=$(node_ip bank-prod-control-plane)
CODEVO_NODE_IP=$(node_ip codevo-dmz-control-plane)
# PIN anahtarı kaynağı: Vault secret/seal/v3 (seal-keys.sh ile aynı kaynak)
VAULT_ROOT=$(kubectl --context kind-bank-prod -n secrets get secret vault-bootstrap -o jsonpath='{.data.root_token}' | base64 -d)
PM_KEY=$(kubectl --context kind-bank-prod -n secrets exec deploy/vault -- env VAULT_TOKEN="$VAULT_ROOT" vault kv get -field=SEAL_PM_KEY secret/seal/v3)
SEAL_B2B_SECRET=$(kubectl --context kind-bank-prod -n auth get secret auth-secrets -o jsonpath='{.data.SEAL_B2B_SECRET}' | base64 -d)
umask 077
printf 'LEGACYDB_PASSWORD=%s\nGRAFANA_ADMIN_PASSWORD=%s\nPM_KEY=%s\nSEAL_B2B_SECRET=%s\nBANKPROD_NODE_IP=%s\nCODEVO_NODE_IP=%s\n' \
    "$LEGACYDB_PASSWORD" "$GRAFANA_ADMIN_PASSWORD" "$PM_KEY" "$SEAL_B2B_SECRET" "$BANKPROD_NODE_IP" "$CODEVO_NODE_IP" > .env
docker compose up -d
echo "platform hazır. Köprü adresleri (kind ağı):"
for c in platform-idp-bridge platform-si-bridge platform-fortuna-bridge; do echo "  $c: $(node_ip $c)"; done
