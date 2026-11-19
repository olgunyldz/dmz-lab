# auth-server ön kancası (deploy-app.sh source eder). Girdi: ROOT, CLUSTER, NAMESPACE.
# Vault'ta yoksa auth-server sırlarını üretir, auth-secrets / auth-tls / auth-signing secret'larını yazar.
# Çıktı: SUBST_EXPRS (__CODEVO_NODE_IP__, __OTLP_TRACES_URL__). Postgres ve auth-server manifestte; rollout catalog'da.
CA_DIR="$ROOT/edge/certs"
TLS_DIR="$CA_DIR/auth"
VAULT_PATH="secret/auth/auth-server"
KEYS=(AUTH_DB_PASSWORD ALICE_PASSWORD TELLER_PASSWORD WEB_APP_SECRET PARTNER_ACME_SECRET BFF_SECRET CORE_SVC_SECRET       AUTH_TLS_KEYSTORE_PASSWORD AUTH_TLS_TRUSTSTORE_PASSWORD AUTH_SIGNING_KEYSTORE_PASSWORD AUTH_INTERNAL_API_KEY       SEAL_B2B_SECRET SEAL_MOBILE_SECRET MOBILE_APP_SECRET)
source "$ROOT/scripts/lib/cluster.sh"

if ! vault_bootstrapped; then
    VAULT_CTX=kind-$CLUSTER bash "$ROOT/infra/vault/load-vault.sh"
fi


# 2) Sırlar (Vault secret/auth/auth-server; ilk kez üretilir)
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
apply_secret "$CLUSTER" "$NAMESPACE" auth-secrets "${lit[@]}"

# 3) TLS (yalnız yoksa): id.bank.lab.local ve auth-server.auth.svc için sunucu sertifikası
if ! secret_exists "$CLUSTER" "$NAMESPACE" auth-tls; then
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
        -out "$TLS_DIR/server.p12" -passout "pass:${VAL[AUTH_TLS_KEYSTORE_PASSWORD]}"
    cp "$CA_DIR/internal-ca.crt" "$TLS_DIR/internal-ca.crt"
    MSYS_NO_PATHCONV=1 docker run --rm -v "$(cd "$TLS_DIR" && pwd -W 2>/dev/null || pwd):/tls" \
        maven:3.9-eclipse-temurin-21 \
        keytool -importcert -noprompt -alias lab-internal-ca -file /tls/internal-ca.crt \
        -keystore /tls/trust.p12 -storetype PKCS12 -storepass "${VAL[AUTH_TLS_TRUSTSTORE_PASSWORD]}"
    apply_secret "$CLUSTER" "$NAMESPACE" auth-tls --from-file=server.p12="$TLS_DIR/server.p12" --from-file=trust.p12="$TLS_DIR/trust.p12"
    echo "auth-tls oluşturuldu ($TLS_DIR)"
fi

# 4) Token imzalama anahtarı (kalıcı; yalnız yoksa)
if ! secret_exists "$CLUSTER" "$NAMESPACE" auth-signing; then
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
    openssl pkcs12 -export -inkey "$TLS_DIR/signing/sign.key" -in "$TLS_DIR/signing/sign.crt" -name auth-sign \
        -out "$TLS_DIR/signing/signing.p12" -passout "pass:${VAL[AUTH_SIGNING_KEYSTORE_PASSWORD]}"
    apply_secret "$CLUSTER" "$NAMESPACE" auth-signing --from-file=signing.p12="$TLS_DIR/signing/signing.p12"
    echo "auth-signing oluşturuldu"
fi


SUBST_EXPRS=(
    "$(subst_ip __CODEVO_NODE_IP__ codevo-dmz-control-plane)"
    "$(subst_expr __OTLP_TRACES_URL__ "$(otlp_url)/v1/traces")"
)
