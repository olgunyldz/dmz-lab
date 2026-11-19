#!/usr/bin/env bash
# Platform (host, docker compose): LegacyDB, merkezi Prometheus, Loki, Jaeger, Grafana, Fortuna monolit ve köprüler.
# .env: parolalar mevcut dosyadan korunur (yoksa üretilir); düğüm IP'leri ve
# sırlar her çalıştırmada cluster'lardan yeniden okunur. Repoda sır yok (.env gitignore'da).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source "$ROOT/../scripts/lib/cluster.sh"
get_env() { env_get "$1" "$ROOT/.env"; }
# İlk kurulum: parolalar yoksa üretilir. Mevcut .env'deki değerler korunur.
LEGACYDB_PASSWORD=$(get_env LEGACYDB_PASSWORD)
GRAFANA_ADMIN_PASSWORD=$(get_env GRAFANA_ADMIN_PASSWORD)
[[ -n "$LEGACYDB_PASSWORD" ]] || LEGACYDB_PASSWORD=$(openssl rand -hex 16)
[[ -n "$GRAFANA_ADMIN_PASSWORD" ]] || GRAFANA_ADMIN_PASSWORD=$(openssl rand -hex 16)
BANKPROD_NODE_IP=$(docker_ip bank-prod-control-plane)
CODEVO_NODE_IP=$(docker_ip codevo-dmz-control-plane)
# PIN anahtarı kaynağı: Vault secret/seal/v3 (seal-keys.sh ile aynı kaynak)
load_seal_keys   # Vault secret/seal/v3 yoksa üretir (ilk kurulumda seal henüz kurulmamış olabilir)
PM_KEY="$SEAL_PM_KEY"
# SEAL_B2B_SECRET Vault'ta (secret/auth/auth-server) tutulur; auth-server bu sırrı oradan alır.
# Platform auth-server'dan önce kalktığı için burada yoksa üretilip Vault'a yazılır (döngüyü kırar).
SEAL_B2B_SECRET=$(vault_get secret/auth/auth-server SEAL_B2B_SECRET 2>/dev/null || true)
if [[ -z "$SEAL_B2B_SECRET" ]]; then
    SEAL_B2B_SECRET=$(openssl rand -hex 16)
    vault_kv_set secret/auth/auth-server "SEAL_B2B_SECRET=$SEAL_B2B_SECRET"
fi
umask 077
printf 'LEGACYDB_PASSWORD=%s\nGRAFANA_ADMIN_PASSWORD=%s\nPM_KEY=%s\nSEAL_B2B_SECRET=%s\nBANKPROD_NODE_IP=%s\nCODEVO_NODE_IP=%s\n' \
    "$LEGACYDB_PASSWORD" "$GRAFANA_ADMIN_PASSWORD" "$PM_KEY" "$SEAL_B2B_SECRET" "$BANKPROD_NODE_IP" "$CODEVO_NODE_IP" > .env
bash "$ROOT/../images/build-base.sh" >/dev/null
docker compose up -d
echo "platform hazır. Köprü adresleri (kind ağı):"
for c in bridge-auth bridge-si bridge-fortuna; do echo "  $c: $(docker_ip $c)"; done
