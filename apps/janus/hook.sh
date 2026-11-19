# Janus ön kancası (deploy-app.sh source eder). Girdi: CLUSTER, NAMESPACE, ROOT. Çıktı: SUBST_EXPRS.
# Sırlar: janus-keys (bir kez üretilir), janus-mtls-web/-mobile (istemci sertifikaları).
secret_once "$CLUSTER" "$NAMESPACE" janus-keys \
    --from-literal=JANUS_KEY_WEB="$(openssl rand -hex 32)" --from-literal=JANUS_KEY_MOBILE="$(openssl rand -hex 32)"

ensure_mtls_certs
mtls_secret "$CLUSTER" "$NAMESPACE" janus-mtls-web janus-web client
mtls_secret "$CLUSTER" "$NAMESPACE" janus-mtls-mobile janus-mobile client

SUBST_EXPRS=(
    "$(subst_ip __BANKPROD_NODE_IP__ bank-prod-control-plane)"
    "$(subst_ip __LEGACY_NODE_IP__ platform-fortuna-bridge)"
)
