#!/usr/bin/env bash
# Vault (bank-prod cluster, ns secrets) başlatır ve mühürünü açar; KV v2 (secret/) hazır olur.
# Vault = platform secret deposu, bank-prod cluster'da (manifests/vault.yaml). Kimlik sağlayıcı sırları
# (auth-secrets) load-auth-server.sh tarafından Vault'tan okunur.
#
# LAB SAPMASI: unseal anahtarı ve root token bank-prod cluster'da "vault-bootstrap" secret'ında. Prod: auto-unseal, kısa ömürlü token.
set -euo pipefail

MGMT="kubectl --context ${VAULT_CTX:-kind-bank-prod}"
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"

$MGMT apply -f "$ROOT_DIR/vault.yaml" >/dev/null
$MGMT -n secrets rollout status deploy/vault --timeout=240s >/dev/null

vexec() { $MGMT -n secrets exec deploy/vault -- "$@"; }

# Vault sunucusu dinlemeye başlayana kadar bekle (vault status: 0 açık, 2 mühürlü; 1 = erişilemiyor)
until $MGMT -n secrets exec deploy/vault -- sh -c 'vault status >/dev/null 2>&1; [ $? -ne 1 ]' >/dev/null 2>&1; do
    sleep 3
done

# Lab'da Vault emptyDir kullanır: pod yeniden başlarsa Vault başlatılmamış döner. Eski bootstrap secret'ı silinir.
vstatus=$(vexec vault status -format=json 2>/dev/null || true)
if echo "$vstatus" | grep -q '"initialized": *false'; then
    $MGMT -n secrets delete secret vault-bootstrap --ignore-not-found >/dev/null
fi

# 1) Init (yalnızca bir kez)
if ! $MGMT -n secrets get secret vault-bootstrap >/dev/null 2>&1; then
    # CR/LF temizliği: Windows (Git Bash + kubectl) çıktısında CR kalabilir; anahtara karışırsa unseal reddedilir
    init_json=$(vexec vault operator init -key-shares=1 -key-threshold=1 -format=json | tr -d '\r\n')
    unseal=$(echo "$init_json" | sed -n 's/.*"unseal_keys_b64": *\[ *"\([^"]*\)".*/\1/p' | tr -d '\r\n ')
    root=$(echo "$init_json" | sed -n 's/.*"root_token": *"\([^"]*\)".*/\1/p' | tr -d '\r\n ')
    [[ -n "$unseal" && -n "$root" ]] || { echo "init çıktısı okunamadı"; exit 1; }
    [[ "$unseal" =~ ^[A-Za-z0-9+/=]+$ ]] || { echo "unseal anahtarı base64 biçiminde değil"; exit 1; }
    $MGMT -n secrets create secret generic vault-bootstrap --from-literal=unseal_key="$unseal" --from-literal=root_token="$root" >/dev/null
    echo "Vault başlatıldı (vault-bootstrap secret'ı mgmt cluster'da)."
fi

UNSEAL=$($MGMT -n secrets get secret vault-bootstrap -o jsonpath='{.data.unseal_key}' | base64 -d)
ROOT=$($MGMT -n secrets get secret vault-bootstrap -o jsonpath='{.data.root_token}' | base64 -d)

# 2) Mühür aç
vstatus=$(vexec vault status -format=json 2>/dev/null || true)
if echo "$vstatus" | grep -q '"sealed": *true'; then
    vexec vault operator unseal "$UNSEAL" >/dev/null
fi

vx() { $MGMT -n secrets exec deploy/vault -- env VAULT_TOKEN="$ROOT" "$@"; }

# 3) KV v2 (secret/)
vx sh -c 'vault secrets list -format=json | grep -q "\"secret/\"" || vault secrets enable -path=secret kv-v2' >/dev/null

echo "Vault hazır (bank-prod): KV v2 (secret/)."
