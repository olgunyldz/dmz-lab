# channel-gateway ön kancası. Girdi: CLUSTER, NAMESPACE, ROOT. Çıktı: SUBST_EXPRS.
# Janus anahtarları bank-dmz-prod janus-keys'ten kopyalanır (repoda sır yok); mTLS sertifikaları ortak helper ile.
WEB=$(secret_value bank-dmz-prod janus janus-keys JANUS_KEY_WEB)
MOB=$(secret_value bank-dmz-prod janus janus-keys JANUS_KEY_MOBILE)
apply_secret "$CLUSTER" "$NAMESPACE" janus-verify --from-literal=JANUS_KEY_WEB="$WEB" --from-literal=JANUS_KEY_MOBILE="$MOB"

ensure_mtls_certs
mtls_secret "$CLUSTER" "$NAMESPACE" channel-gateway-tls channel-gateway server
mtls_secret "$CLUSTER" "$NAMESPACE" channel-gateway-client channel-gateway-client client

SUBST_EXPRS=(
    "$(subst_ip __LEGACY_NODE_IP__ bridge-fortuna)"
)
