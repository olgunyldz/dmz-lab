#!/usr/bin/env bash
# auth-server'ı bank-prod cluster'ına kurar (namespace: auth). Tekrar çalıştırılabilir.
#   1) İmaj: bank-prod-cluster/spring-idp kaynağından dmz-lab/auth-server:0.1.0 derlenir ve kind düğümüne yüklenir
#   2) Sırlar: bank-prod Vault (secret/auth/auth-server); yoksa üretilip yazılır. Repoya sır yazılmaz.
#   3) TLS: lab iç CA ile imzalanmış sunucu sertifikası + PKCS12 keystore/truststore (edge/certs/auth, gitignored)
#   4) İmzalama anahtarı (auth-signing; bir kez üretilir)
#   5) manifests/auth-server.yaml uygulanır
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$ROOT/.." && pwd)"
CTX="kind-bank-prod"
K="kubectl --context $CTX"
IMAGE="dmz-lab/auth-server:0.1.0"
CA_DIR="$REPO/edge/certs"
TLS_DIR="$CA_DIR/auth"
VAULT_PATH="secret/auth/auth-server"
KEYS=(IDP_DB_PASSWORD ALICE_PASSWORD TELLER_PASSWORD WEB_APP_SECRET PARTNER_ACME_SECRET BFF_SECRET CORE_SVC_SECRET \
      IDP_TLS_KEYSTORE_PASSWORD IDP_TLS_TRUSTSTORE_PASSWORD IDP_SIGNING_KEYSTORE_PASSWORD IDP_INTERNAL_API_KEY \
      SEAL_B2B_SECRET SEAL_MOBILE_SECRET)

# Vault bank-prod'da (secrets namespace). Hazır değilse load-vault.sh ile başlatılır.
VAULT="kubectl --context $CTX -n secrets"
if ! $VAULT get secret vault-bootstrap >/dev/null 2>&1; then
    VAULT_CTX=$CTX bash "$REPO/bank-prod-cluster/scripts/load-vault.sh"
fi
VAULT_ROOT=$($VAULT get secret vault-bootstrap -o jsonpath='{.data.root_token}' | base64 -d)
vault_exec() { $VAULT exec deploy/vault -- env VAULT_TOKEN="$VAULT_ROOT" "$@"; }

# 1) İmaj
$K create namespace auth --dry-run=client -o yaml | $K apply -f - >/dev/null
docker build -q -t "$IMAGE" "$REPO/bank-prod-cluster/spring-idp" >/dev/null
kind load docker-image "$IMAGE" --name bank-prod >/dev/null

# 2) Sırlar
declare -A VAL
if vault_exec vault kv get -format=json "$VAULT_PATH" >/dev/null 2>&1; then
    json=$(vault_exec vault kv get -format=json "$VAULT_PATH")
    for k in "${KEYS[@]}"; do
        VAL[$k]=$(echo "$json" | python3 -c 'import sys,json; print(json.load(sys.stdin)["data"]["data"].get(sys.argv[1],""))' "$k")
    done
    missing=()
    for k in "${KEYS[@]}"; do
        if [[ -z "${VAL[$k]}" ]]; then VAL[$k]=$(openssl rand -hex 16); missing+=("$k=${VAL[$k]}"); fi
    done
    if (( ${#missing[@]} )); then vault_exec vault kv patch "$VAULT_PATH" "${missing[@]}" >/dev/null; fi
    echo "sırlar Vault'tan okundu ($VAULT_PATH)"
else
    for k in "${KEYS[@]}"; do VAL[$k]=$(openssl rand -hex 16); done
    args=(); for k in "${KEYS[@]}"; do args+=("$k=${VAL[$k]}"); done
    vault_exec vault kv put "$VAULT_PATH" "${args[@]}" >/dev/null
    echo "sırlar Vault'a yazıldı ($VAULT_PATH)"
fi
lit=(); for k in "${KEYS[@]}"; do lit+=(--from-literal="$k=${VAL[$k]}"); done
$K -n auth create secret generic auth-secrets "${lit[@]}" --dry-run=client -o yaml | $K apply -f - >/dev/null

# 3) TLS (yalnız yoksa): id.bank.lab.local ve auth-server.auth.svc için sunucu sertifikası
if ! $K -n auth get secret auth-tls >/dev/null 2>&1; then
    mkdir -p "$TLS_DIR"
    rm -f "$TLS_DIR/server.p12" "$TLS_DIR/trust.p12"
    cat > "$TLS_DIR/server.ext" <<'EXT'
subjectAltName=DNS:id.bank.lab.local,DNS:auth-server.auth.svc,DNS:localhost,IP:127.0.0.1
extendedKeyUsage=serverAuth
EXT
    cat > "$TLS_DIR/server.cnf" <<'CNF'
[req]
distinguished_name=dn
prompt=no
[dn]
CN=id.bank.lab.local
CNF
    openssl req -newkey rsa:2048 -nodes -keyout "$TLS_DIR/server.key" -out "$TLS_DIR/server.csr" -config "$TLS_DIR/server.cnf"
    openssl x509 -req -in "$TLS_DIR/server.csr" -CA "$CA_DIR/internal-ca.crt" -CAkey "$CA_DIR/internal-ca.key" \
        -CAcreateserial -out "$TLS_DIR/server.crt" -days 365 -extfile "$TLS_DIR/server.ext" 2>/dev/null
    openssl pkcs12 -export -inkey "$TLS_DIR/server.key" -in "$TLS_DIR/server.crt" \
        -out "$TLS_DIR/server.p12" -passout "pass:${VAL[IDP_TLS_KEYSTORE_PASSWORD]}"
    cp "$CA_DIR/internal-ca.crt" "$TLS_DIR/internal-ca.crt"
    MSYS_NO_PATHCONV=1 docker run --rm -v "$(cd "$TLS_DIR" && pwd -W 2>/dev/null || pwd):/tls" \
        maven:3.9-eclipse-temurin-21 \
        keytool -importcert -noprompt -alias lab-internal-ca -file /tls/internal-ca.crt \
        -keystore /tls/trust.p12 -storetype PKCS12 -storepass "${VAL[IDP_TLS_TRUSTSTORE_PASSWORD]}"
    $K -n auth create secret generic auth-tls \
        --from-file=server.p12="$TLS_DIR/server.p12" --from-file=trust.p12="$TLS_DIR/trust.p12" >/dev/null
    echo "auth-tls oluşturuldu ($TLS_DIR)"
fi

# 4) Token imzalama anahtarı (kalıcı; yalnız yoksa)
if ! $K -n auth get secret auth-signing >/dev/null 2>&1; then
    mkdir -p "$TLS_DIR/signing"
    rm -f "$TLS_DIR/signing/signing.p12"
    cat > "$TLS_DIR/signing/sign.cnf" <<'CNF'
[req]
distinguished_name=dn
prompt=no
[dn]
CN=lab-auth-signing
CNF
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TLS_DIR/signing/sign.key" -out "$TLS_DIR/signing/sign.crt" \
        -days 3650 -config "$TLS_DIR/signing/sign.cnf"
    openssl pkcs12 -export -inkey "$TLS_DIR/signing/sign.key" -in "$TLS_DIR/signing/sign.crt" -name idp-sign \
        -out "$TLS_DIR/signing/signing.p12" -passout "pass:${VAL[IDP_SIGNING_KEYSTORE_PASSWORD]}"
    $K -n auth create secret generic auth-signing --from-file=signing.p12="$TLS_DIR/signing/signing.p12" >/dev/null
    echo "auth-signing oluşturuldu"
fi

# 5) Manifest
CODEVO_IP=$(docker inspect -f '{{ index .NetworkSettings.Networks "kind" "IPAddress" }}' codevo-dmz-control-plane)
sed "s/__CODEVO_NODE_IP__/$CODEVO_IP/" "$ROOT/manifests/auth-server.yaml" | $K apply -f - >/dev/null
$K -n auth rollout status deploy/postgres-auth --timeout=240s
$K -n auth rollout restart deploy/auth-server >/dev/null
$K -n auth rollout status deploy/auth-server --timeout=300s
echo "auth-server hazır (bank-prod/auth, NodePort 30543 HTTPS, 30582 iç HTTP)"
