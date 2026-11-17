#!/usr/bin/env bash
# Spring kimlik sağlayıcıyı identity cluster'a kurar (namespace: idp). Tekrar çalıştırılabilir (idempotent).
#   1) İmaj: dmz-lab/spring-idp:0.1.0 derlenir ve kind düğümlerine yüklenir (yoksa)
#   2) Sırlar: kaynak Vault (mgmt, secret/identity/idp). Vault'ta yoksa mevcut idp-secrets değerleri (veya rastgele)
#      Vault'a yazılır; sonra idp-secrets Vault'tan türetilir. Repoya sır yazılmaz.
#   3) TLS: sunucu sertifikası lab CA ile imzalanır; PKCS12 keystore/truststore (edge/certs/idp, gitignored)
#   4) İmzalama anahtarı: PKCS12 (idp-signing secret'ı; bir kez üretilir, kalıcı)
#   5) manifests/spring-idp.yaml (render: OTLP için mgmt node IP) uygulanır
# LAB SAPMASI: Vault değerini bu betik (host üzerinden) okur ve Kubernetes secret'ı üretir. Prod: ESO.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$ROOT/.." && pwd)"
CTX="kind-identity"
K="kubectl --context $CTX"
MGMT="kubectl --context kind-mgmt"
IMAGE="dmz-lab/spring-idp:0.1.0"
CA_DIR="$REPO/edge/certs"
TLS_DIR="$CA_DIR/idp"
VAULT_PATH="secret/identity/idp"
KEYS=(IDP_DB_PASSWORD ALICE_PASSWORD TELLER_PASSWORD WEB_APP_SECRET PARTNER_ACME_SECRET BFF_SECRET CORE_SVC_SECRET \
      IDP_TLS_KEYSTORE_PASSWORD IDP_TLS_TRUSTSTORE_PASSWORD IDP_SIGNING_KEYSTORE_PASSWORD)

# Vault'a erişim (mgmt cluster, root token vault-bootstrap'ten; KV v2 secret/ load-vault.sh ile hazır)
# Vault hiç başlatılmadıysa (vault-bootstrap yok) önce load-vault.sh çalıştırılır: init, unseal, KV v2.
if ! $MGMT -n secrets get secret vault-bootstrap >/dev/null 2>&1; then
    echo "vault-bootstrap yok: Vault başlatılıyor (load-vault.sh)"
    bash "$REPO/identity-cluster/scripts/load-vault.sh"
fi
VAULT_ROOT=$($MGMT -n secrets get secret vault-bootstrap -o jsonpath='{.data.root_token}' | base64 -d)
vault_exec() { $MGMT -n secrets exec deploy/vault -- env VAULT_TOKEN="$VAULT_ROOT" "$@"; }

# 1) İmaj: her çalıştırmada derlenir (Docker katman önbelleği hızlandırır); kaynak değişikliği hep devreye girer
docker build -q -t "$IMAGE" "$ROOT/spring-idp" >/dev/null
kind load docker-image "$IMAGE" --name identity >/dev/null
$K create namespace idp --dry-run=client -o yaml | $K apply -f - >/dev/null

# 2) Sırlar: Vault kaynak
declare -A VAL
if vault_exec vault kv get -format=json "$VAULT_PATH" >/dev/null 2>&1; then
    json=$(vault_exec vault kv get -format=json "$VAULT_PATH")
    for k in "${KEYS[@]}"; do
        VAL[$k]=$(echo "$json" | python3 -c 'import sys,json; print(json.load(sys.stdin)["data"]["data"].get(sys.argv[1],""))' "$k")
    done
    echo "sırlar Vault'tan okundu ($VAULT_PATH)"
else
    # İlk geçiş: mevcut Kubernetes değerleri (varsa) Vault'a kopyalanır; yoksa rastgele üretilir
    for k in "${KEYS[@]}"; do
        existing=$($K -n idp get secret idp-secrets -o jsonpath="{.data.$k}" 2>/dev/null | base64 -d 2>/dev/null || true)
        VAL[$k]=${existing:-$(openssl rand -hex 16)}
    done
    args=(); for k in "${KEYS[@]}"; do args+=("$k=${VAL[$k]}"); done
    vault_exec vault kv put "$VAULT_PATH" "${args[@]}" >/dev/null
    echo "sırlar Vault'a yazıldı ($VAULT_PATH)"
fi
lit=(); for k in "${KEYS[@]}"; do lit+=(--from-literal="$k=${VAL[$k]}"); done
$K -n idp create secret generic idp-secrets "${lit[@]}" --dry-run=client -o yaml | $K apply -f - >/dev/null

# 3) TLS (yalnız yoksa üretilir)
if ! $K -n idp get secret idp-tls >/dev/null 2>&1; then
    mkdir -p "$TLS_DIR"
    # Önceki denemeden kalan keystore'lar (farklı parola) yeniden üretilir
    rm -f "$TLS_DIR/server.p12" "$TLS_DIR/trust.p12"
    cat > "$TLS_DIR/server.ext" <<'EXT'
subjectAltName=DNS:id.bank.lab.local,DNS:spring-idp.idp.svc,DNS:localhost,IP:127.0.0.1
extendedKeyUsage=serverAuth
EXT
    cat > "$TLS_DIR/server.cnf" <<'CNF'
[req]
distinguished_name=dn
prompt=no
[dn]
CN=id.bank.lab.local
CNF
    openssl req -newkey rsa:2048 -nodes -keyout "$TLS_DIR/server.key" -out "$TLS_DIR/server.csr" \
        -config "$TLS_DIR/server.cnf"
    openssl x509 -req -in "$TLS_DIR/server.csr" -CA "$CA_DIR/internal-ca.crt" -CAkey "$CA_DIR/internal-ca.key" \
        -CAcreateserial -out "$TLS_DIR/server.crt" -days 365 -extfile "$TLS_DIR/server.ext" 2>/dev/null
    openssl pkcs12 -export -inkey "$TLS_DIR/server.key" -in "$TLS_DIR/server.crt" \
        -out "$TLS_DIR/server.p12" -passout "pass:${VAL[IDP_TLS_KEYSTORE_PASSWORD]}"
    cp "$CA_DIR/internal-ca.crt" "$TLS_DIR/internal-ca.crt"
    # Güven deposu: lab CA (Java keystore; keytool JDK imajından çalıştırılır). MSYS yolu yalnız bu komutta kapalı.
    MSYS_NO_PATHCONV=1 docker run --rm -v "$(cd "$TLS_DIR" && pwd -W 2>/dev/null || pwd):/tls" \
        maven:3.9-eclipse-temurin-21 \
        keytool -importcert -noprompt -alias lab-internal-ca -file /tls/internal-ca.crt \
        -keystore /tls/trust.p12 -storetype PKCS12 -storepass "${VAL[IDP_TLS_TRUSTSTORE_PASSWORD]}"
    $K -n idp create secret generic idp-tls \
        --from-file=server.p12="$TLS_DIR/server.p12" --from-file=trust.p12="$TLS_DIR/trust.p12" >/dev/null
    echo "idp-tls oluşturuldu ($TLS_DIR)"
fi

# 4) İmzalama anahtarı (kalıcı; yalnız yoksa üretilir). Alias: idp-sign (application.yml idp.signing.alias)
if ! $K -n idp get secret idp-signing >/dev/null 2>&1; then
    mkdir -p "$TLS_DIR/signing"
    rm -f "$TLS_DIR/signing/signing.p12"
    cat > "$TLS_DIR/signing/sign.cnf" <<'CNF'
[req]
distinguished_name=dn
prompt=no
[dn]
CN=lab-idp-signing
CNF
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TLS_DIR/signing/sign.key" -out "$TLS_DIR/signing/sign.crt" \
        -days 3650 -config "$TLS_DIR/signing/sign.cnf"
    openssl pkcs12 -export -inkey "$TLS_DIR/signing/sign.key" -in "$TLS_DIR/signing/sign.crt" -name idp-sign \
        -out "$TLS_DIR/signing/signing.p12" -passout "pass:${VAL[IDP_SIGNING_KEYSTORE_PASSWORD]}"
    $K -n idp create secret generic idp-signing --from-file=signing.p12="$TLS_DIR/signing/signing.p12" >/dev/null
    echo "idp-signing oluşturuldu"
fi

# 5) Manifest (render: __MGMT_NODE_IP__ gibi yer tutucular lab-ips.sh ile çözülür)
source "$REPO/scripts/lab-ips.sh"
render "$ROOT/manifests/spring-idp.yaml" | $K apply -f -
$K -n idp rollout status deploy/postgres-idp --timeout=240s
$K -n idp rollout restart deploy/spring-idp >/dev/null
$K -n idp rollout status deploy/spring-idp --timeout=300s
echo "Spring IdP hazır (idp/spring-idp, NodePort 30443 HTTPS, 30081 iç HTTP). Test: bkz. spring-idp/README.md"
