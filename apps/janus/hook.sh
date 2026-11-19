# Janus ön kancası (deploy-app.sh source eder). Girdi: CLUSTER, NAMESPACE, ROOT. Çıktı: SUBST_EXPRS.
# Sırlar: janus-keys (bir kez üretilir), janus-mtls-web/-mobile (istemci sertifikaları).
secret_once "$CLUSTER" "$NAMESPACE" janus-keys \
    --from-literal=JANUS_KEY_WEB="$(openssl rand -hex 32)" --from-literal=JANUS_KEY_MOBILE="$(openssl rand -hex 32)"

# IdP (mobile-app, gizli istemci) sırrı: bank-prod auth-secrets'tan; Janus yalnız token isteğinde kullanır
MOBILE_IDP_SECRET=$(secret_value bank-prod auth auth-secrets MOBILE_APP_SECRET)
WEB_IDP_SECRET=$(secret_value bank-prod auth auth-secrets WEB_APP_SECRET)
apply_secret "$CLUSTER" "$NAMESPACE" janus-idp --from-literal=MOBILE_APP_SECRET="$MOBILE_IDP_SECRET" --from-literal=WEB_APP_SECRET="$WEB_IDP_SECRET"

ensure_mtls_certs
mtls_secret "$CLUSTER" "$NAMESPACE" janus-mtls-web janus-web client
mtls_secret "$CLUSTER" "$NAMESPACE" janus-mtls-mobile janus-mobile client

SUBST_EXPRS=(
    "$(subst_ip __BANKPROD_NODE_IP__ bank-prod-control-plane)"
    "$(subst_ip __LEGACY_NODE_IP__ bridge-fortuna)"
)
