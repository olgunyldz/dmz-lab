#!/usr/bin/env bash
# Seal v3 paylaşılan anahtarları: SEAL_PM_KEY (seal-mobile -> Fortuna monolit PIN uçları) ve SEAL_MOCK_KEY
# (seal-mobile -> seal-intranet mock yazma uçları). Kaynak: Vault secret/seal/v3 (mgmt). Yoksa üretilip yazılır.
# Kullanım (source): source scripts/seal-keys.sh  ->  SEAL_PM_KEY, SEAL_MOCK_KEY ortam değişkenlerini ayarlar.
set -euo pipefail

_SEAL_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_SEAL_MGMT="kubectl --context ${VAULT_CTX:-kind-bank-prod}"
_SEAL_PATH="secret/seal/v3"

_seal_vault() { $_SEAL_MGMT -n secrets exec deploy/vault -- env VAULT_TOKEN="$_SEAL_ROOT" "$@"; }

_SEAL_ROOT=$($_SEAL_MGMT -n secrets get secret vault-bootstrap -o jsonpath='{.data.root_token}' | base64 -d)

if _seal_vault vault kv get -format=json "$_SEAL_PATH" >/dev/null 2>&1; then
    _json=$(_seal_vault vault kv get -format=json "$_SEAL_PATH")
    SEAL_PM_KEY=$(echo "$_json" | python3 -c 'import sys,json; print(json.load(sys.stdin)["data"]["data"].get("SEAL_PM_KEY",""))')
    SEAL_MOCK_KEY=$(echo "$_json" | python3 -c 'import sys,json; print(json.load(sys.stdin)["data"]["data"].get("SEAL_MOCK_KEY",""))')
else
    SEAL_PM_KEY=""
    SEAL_MOCK_KEY=""
fi
_missing=()
[[ -z "$SEAL_PM_KEY" ]] && { SEAL_PM_KEY=$(openssl rand -hex 24); _missing+=("SEAL_PM_KEY=$SEAL_PM_KEY"); }
[[ -z "$SEAL_MOCK_KEY" ]] && { SEAL_MOCK_KEY=$(openssl rand -hex 24); _missing+=("SEAL_MOCK_KEY=$SEAL_MOCK_KEY"); }
if (( ${#_missing[@]} )); then
    if _seal_vault vault kv get "$_SEAL_PATH" >/dev/null 2>&1; then
        _seal_vault vault kv patch "$_SEAL_PATH" "${_missing[@]}" >/dev/null
    else
        _seal_vault vault kv put "$_SEAL_PATH" "${_missing[@]}" >/dev/null
    fi
fi
export SEAL_PM_KEY SEAL_MOCK_KEY
