#!/usr/bin/env bash
# Fortuna kimlik zinciri (CGW -> API -> ACL -> LegacyDB) ve SmsOtpCGW mock'unu bank-prod/channel'a kurar.
# Ön koşul: mgmt legacydb (PostgreSQL). Sırlar: legacydb-auth (mgmt), auth-secrets (bank-prod, ALICE_PASSWORD).
# Repoda sır yok; fortuna-db ve fortuna-seed secret'ları yüklemede üretilir/kopyalanır.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$ROOT/.." && pwd)"
K="kubectl --context kind-bank-prod"
MGMT_IP=$(docker inspect -f '{{ index .NetworkSettings.Networks "kind" "IPAddress" }}' platform-legacydb)  # LegacyDB köprüsü (platform)

$K create namespace channel --dry-run=client -o yaml | $K apply -f - >/dev/null

PGPW=$(grep '^LEGACYDB_PASSWORD=' "$REPO/platform/.env" | cut -d= -f2-)
$K -n channel create secret generic fortuna-db --from-literal=POSTGRES_PASSWORD="$PGPW" \
    --dry-run=client -o yaml | $K apply -f - >/dev/null
# Fortuna DB kullanıcısını oluştur (ilk kurulum): legacydb 'fortuna' rolü POSTGRES_USER ile zaten var
SEEDPW=$($K -n auth get secret auth-secrets -o jsonpath='{.data.ALICE_PASSWORD}' | base64 -d)
$K -n channel create secret generic fortuna-seed --from-literal=SEED_PASSWORD="$SEEDPW" \
    --dry-run=client -o yaml | $K apply -f - >/dev/null

# mTLS sunucu sertifikaları (CGW ve SMS): scripts/gen-mtls-certs.sh üretir
bash "$REPO/scripts/gen-mtls-certs.sh" >/dev/null
MTLS="$REPO/edge/certs/mtls"
for pair in "fortuna-cgw-tls:fortuna-users-cgw" "sms-otp-tls:sms-otp-cgw" "fortuna-api-tls:fortuna-user-api" "fortuna-acl-tls:fortuna-user-acl"; do
    sec=${pair%%:*}; svc=${pair#*:}
    $K -n channel create secret generic "$sec" \
        --from-file=server.crt="$MTLS/$svc.crt" --from-file=server.key="$MTLS/$svc.key" \
        --from-file=ca.crt="$MTLS/ca.crt" --dry-run=client -o yaml | $K apply -f - >/dev/null
done
# İç zincir istemci sertifikaları (CGW ve API'nin sonraki servise çağrısı)
for pair in "fortuna-cgw-client:fortuna-cgw-client" "fortuna-api-client:fortuna-api-client"; do
    sec=${pair%%:*}; f=${pair#*:}
    $K -n channel create secret generic "$sec" \
        --from-file=client.crt="$MTLS/$f.crt" --from-file=client.key="$MTLS/$f.key" \
        --from-file=ca.crt="$MTLS/ca.crt" --dry-run=client -o yaml | $K apply -f - >/dev/null
done
$K -n channel create configmap fortuna-code --from-file=fortuna_stack.py="$ROOT/app/fortuna_stack.py" \
    --dry-run=client -o yaml | $K apply -f - >/dev/null
sed "s/__MGMT_NODE_IP__/$MGMT_IP/" "$ROOT/manifests/fortuna.yaml" | $K apply -f - >/dev/null
# Janus'un (bank-dmz-prod) erişimi için NodePort: CGW 30880, SMS 30881
cat <<'EOF' | $K apply -f - >/dev/null
apiVersion: v1
kind: Service
metadata: {name: fortuna-users-cgw-nodeport, namespace: channel}
spec: {type: NodePort, selector: {app: fortuna-users-cgw}, ports: [{name: https, port: 8443, targetPort: 8443, nodePort: 30880}]}
---
apiVersion: v1
kind: Service
metadata: {name: sms-otp-cgw-nodeport, namespace: channel}
spec: {type: NodePort, selector: {app: sms-otp-cgw}, ports: [{name: https, port: 8443, targetPort: 8443, nodePort: 30881}]}
EOF
for d in fortuna-users-cgw fortuna-user-api fortuna-user-acl sms-otp-cgw; do
    $K -n channel rollout restart deploy/$d >/dev/null
    $K -n channel rollout status deploy/$d --timeout=420s
done
echo "Fortuna zinciri ve SMS mock hazır (bank-prod/channel; DB: $MGMT_IP:30432)"
