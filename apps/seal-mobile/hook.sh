# Seal Mobile ön kancası. Girdi: CLUSTER, NAMESPACE, ROOT. Çıktı: SUBST_EXPRS.
ensure_seal_certs
load_seal_keys
SEAL_CERTS="$ROOT/edge/certs/seal"
CERTS="$ROOT/edge/certs"

SEAL_MOBILE_SECRET=$(vault_get secret/auth/auth-server SEAL_MOBILE_SECRET 2>/dev/null || true)
if [[ -z "$SEAL_MOBILE_SECRET" ]]; then
    SEAL_MOBILE_SECRET=$(secret_value bank-prod auth auth-secrets SEAL_MOBILE_SECRET)
fi

apply_secret "$CLUSTER" "$NAMESPACE" sm-tls --from-file=server.crt="$SEAL_CERTS/seal-mobile.crt" --from-file=server.key="$SEAL_CERTS/seal-mobile.key"
apply_secret "$CLUSTER" "$NAMESPACE" sm-device-ca --from-file=device-ca.crt="$CERTS/device/device-ca.crt"
apply_secret "$CLUSTER" "$NAMESPACE" sm-internal-ca --from-file=internal-ca.crt="$CERTS/internal-ca.crt"
apply_secret "$CLUSTER" "$NAMESPACE" sm-auth-client --from-file=client.crt="$CERTS/seal-mobile-internal.crt" --from-file=client.key="$CERTS/seal-mobile-internal.key"
apply_secret "$CLUSTER" "$NAMESPACE" sm-keys --from-literal=SEAL_PM_KEY="$SEAL_PM_KEY" --from-literal=SEAL_MOCK_KEY="$SEAL_MOCK_KEY" --from-literal=SEAL_MOBILE_SECRET="$SEAL_MOBILE_SECRET"

SUBST_EXPRS=(
    "$(subst_ip __AUTH_NODE_IP__ bank-prod-control-plane)"
    "$(subst_ip __LEGACY_NODE_IP__ platform-fortuna-bridge)"
)
