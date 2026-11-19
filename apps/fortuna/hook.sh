# Fortuna zinciri ön kancası (CGW, API, ACL, SMS mock). Girdi: CLUSTER, NAMESPACE, ROOT. Çıktı: SUBST_EXPRS.
# DB parolası platform/.env (LEGACYDB_PASSWORD); ALICE_PASSWORD bank-prod auth-secrets'tan; sertifikalar ortak helper ile.
PGPW=$(env_get LEGACYDB_PASSWORD)
[[ -n "$PGPW" ]] || { echo "HATA: platform/.env içinde LEGACYDB_PASSWORD yok (önce platform/scripts/up.sh)" >&2; exit 2; }
apply_secret "$CLUSTER" "$NAMESPACE" fortuna-db --from-literal=POSTGRES_PASSWORD="$PGPW"

# Fortuna DB kullanıcısı ilk kurulumda legacydb 'fortuna' rolüyle zaten var; seed parolası auth-secrets'tan
SEEDPW=$(secret_value bank-prod auth auth-secrets ALICE_PASSWORD)
apply_secret "$CLUSTER" "$NAMESPACE" fortuna-seed --from-literal=SEED_PASSWORD="$SEEDPW"

ensure_mtls_certs
mtls_secret "$CLUSTER" "$NAMESPACE" fortuna-cgw-tls fortuna-users-cgw server
mtls_secret "$CLUSTER" "$NAMESPACE" sms-otp-tls sms-otp-cgw server
mtls_secret "$CLUSTER" "$NAMESPACE" fortuna-api-tls fortuna-user-api server
mtls_secret "$CLUSTER" "$NAMESPACE" fortuna-acl-tls fortuna-user-acl server
# İç zincir istemci sertifikaları (CGW ve API'nin sonraki servise çağrısı)
mtls_secret "$CLUSTER" "$NAMESPACE" fortuna-cgw-client fortuna-cgw-client client
mtls_secret "$CLUSTER" "$NAMESPACE" fortuna-api-client fortuna-api-client client

SUBST_EXPRS=(
    "$(subst_ip __MGMT_NODE_IP__ bridge-legacydb)"
)
