# Seal Intranet ön kancası. Girdi: CLUSTER, NAMESPACE, ROOT. Çıktı: BUILD_CONTEXT, SUBST_EXPRS.
ensure_seal_certs
load_seal_keys
SEAL_CERTS="$ROOT/edge/certs/seal"

apply_secret "$CLUSTER" "$NAMESPACE" seal-intranet-tls --from-file=server.crt="$SEAL_CERTS/seal-intranet.crt" --from-file=server.key="$SEAL_CERTS/seal-intranet.key"
apply_secret "$CLUSTER" "$NAMESPACE" si-mock --from-literal=SEAL_MOCK_KEY="$SEAL_MOCK_KEY"

SUBST_EXPRS=(
    "$(subst_ip __AUTH_NODE_IP__ bank-prod-control-plane)"
)
