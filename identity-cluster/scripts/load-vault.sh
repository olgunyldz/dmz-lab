#!/usr/bin/env bash
# Vault (mgmt cluster, secrets zone) başlatır, mühürünü açar, KV v2 ve Keycloak politikasını kurar,
# Keycloak parolalarını Vault'ta tutar ve identity cluster'daki Kubernetes secret'larını Vault'tan türetir.
#
# Vault = kaynak (source of truth), mgmt cluster'da. Identity secret'ları türetilmiştir.
# LAB SAPMASI: Kubernetes secret'ı türetme bu betikte (host üzerinden). Prod: identity cluster'da
#              External Secrets Operator, Vault'a Kubernetes auth ile bağlanır (design.md 4.6).
# LAB SAPMASI: unseal anahtarı ve root token mgmt cluster'da "vault-bootstrap" secret'ında. Prod: auto-unseal, kısa ömürlü token.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
MGMT="kubectl --context kind-mgmt"
IDENT="kubectl --context kind-identity"

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
    init_json=$(vexec vault operator init -key-shares=1 -key-threshold=1 -format=json | tr -d '\n')
    unseal=$(echo "$init_json" | sed -n 's/.*"unseal_keys_b64": *\[ *"\([^"]*\)".*/\1/p')
    root=$(echo "$init_json" | sed -n 's/.*"root_token": *"\([^"]*\)".*/\1/p')
    [[ -n "$unseal" && -n "$root" ]] || { echo "init çıktısı okunamadı"; exit 1; }
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

# 3) KV v2 (secret/) ve Keycloak politikası
vx sh -c 'vault secrets list -format=json | grep -q "\"secret/\"" || vault secrets enable -path=secret kv-v2' >/dev/null
vx sh -c 'cat > /tmp/keycloak.hcl <<EOF
path "secret/data/identity/keycloak" {
  capabilities = ["read"]
}
EOF
vault policy write keycloak /tmp/keycloak.hcl' >/dev/null

# 4) Keycloak parolaları: Vault'ta yoksa üret, sonra Vault'tan oku
if ! vx vault kv get -field=db_password secret/identity/keycloak >/dev/null 2>&1; then
    db_pw=$(openssl rand -hex 24)
    admin_pw=$(openssl rand -hex 24)
    vx vault kv put secret/identity/keycloak db_password="$db_pw" admin_password="$admin_pw" >/dev/null
    echo "Keycloak parolaları Vault'ta üretildi."
fi
DB_PW=$(vx vault kv get -field=db_password secret/identity/keycloak | tr -d '\r')
ADMIN_PW=$(vx vault kv get -field=admin_password secret/identity/keycloak | tr -d '\r')

# 5) Identity cluster secret'ları Vault'tan türetilir (namespace yoksa önce oluştur)
$IDENT create namespace auth --dry-run=client -o yaml | $IDENT apply -f - >/dev/null
$IDENT -n auth create secret generic keycloak-db --from-literal=password="$DB_PW" --dry-run=client -o yaml | $IDENT apply -f - >/dev/null
$IDENT -n auth create secret generic keycloak-admin --from-literal=password="$ADMIN_PW" --dry-run=client -o yaml | $IDENT apply -f - >/dev/null

echo "Vault hazır (mgmt): KV v2, keycloak politikası. Identity secret'ları Vault'tan türetildi."
