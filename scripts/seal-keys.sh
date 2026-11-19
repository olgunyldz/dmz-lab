#!/usr/bin/env bash
# Seal v3 paylaşılan anahtarları: SEAL_PM_KEY (seal-mobile -> Fortuna monolit PIN uçları) ve SEAL_MOCK_KEY
# (seal-mobile -> seal-intranet mock yazma uçları). Kaynak: Vault secret/seal/v3 (bank-prod). Yoksa üretilip yazılır.
# Kullanım (source): source scripts/seal-keys.sh  ->  SEAL_PM_KEY, SEAL_MOCK_KEY ortam değişkenlerini ayarlar.
# Vault erişimi scripts/lib/cluster.sh (vault_get, vault_kv_set) üzerinden.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/cluster.sh"
_SEAL_PATH="secret/seal/v3"

SEAL_PM_KEY=$(vault_get "$_SEAL_PATH" SEAL_PM_KEY 2>/dev/null || true)
SEAL_MOCK_KEY=$(vault_get "$_SEAL_PATH" SEAL_MOCK_KEY 2>/dev/null || true)

_missing=()
[[ -z "$SEAL_PM_KEY" ]] && { SEAL_PM_KEY=$(openssl rand -hex 24); _missing+=("SEAL_PM_KEY=$SEAL_PM_KEY"); }
[[ -z "$SEAL_MOCK_KEY" ]] && { SEAL_MOCK_KEY=$(openssl rand -hex 24); _missing+=("SEAL_MOCK_KEY=$SEAL_MOCK_KEY"); }
if (( ${#_missing[@]} )); then
    vault_kv_set "$_SEAL_PATH" "${_missing[@]}"
fi
export SEAL_PM_KEY SEAL_MOCK_KEY
