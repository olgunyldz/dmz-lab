#!/usr/bin/env bash
# Seal v3 servisleri için sunucu sertifikaları (iç CA ile imzalı). Lab sertifikaları; çıktı edge/certs/seal (gitignored).
#   seal-intranet    : seal-intranet.seal-intranet.svc (iç HTTPS)
#   password-manager : password-manager.seal-pm.svc (gw-internal BackendTLSPolicy doğrulaması)
#   bank-backend     : bank-backend.bank-auth.svc
#   seal-mobile      : seal-mobile.seal-mobile.svc + seal.lab.local (cihaz yüzü, passthrough; SNI seal.lab.local)
# Mevcut dmz-client (gw-internal istemci sertifikası) ve internal-ca kullanılır; yeniden üretilmez.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CA_DIR="$ROOT/edge/certs"
OUT="$CA_DIR/seal"
mkdir -p "$OUT"
cd "$OUT"

issue() { # <name> <CN> <SAN>
    local name=$1 cn=$2 san=$3
    printf '[req]\ndistinguished_name=dn\nprompt=no\n[dn]\nCN=%s\n' "$cn" > "$name.cnf"
    printf 'subjectAltName=%s\nextendedKeyUsage=serverAuth\nbasicConstraints=CA:FALSE\n' "$san" > "$name.ext"
    openssl req -newkey rsa:2048 -nodes -keyout "$name.key" -out "$name.csr" -config "$name.cnf" 2>/dev/null
    openssl x509 -req -in "$name.csr" -CA "$CA_DIR/internal-ca.crt" -CAkey "$CA_DIR/internal-ca.key" -CAcreateserial \
        -out "$name.crt" -days 365 -extfile "$name.ext" 2>/dev/null
    rm -f "$name.csr" "$name.cnf" "$name.ext"
}

issue seal-intranet "seal-intranet" "DNS:seal-intranet.seal-intranet.svc,DNS:seal-intranet"
issue password-manager "password-manager" "DNS:password-manager.seal-pm.svc"
issue bank-backend "bank-backend" "DNS:bank-backend.bank-auth.svc"
issue seal-mobile "seal-mobile" "DNS:seal-mobile.seal-mobile.svc,DNS:seal.lab.local"
cp "$CA_DIR/internal-ca.crt" "$OUT/internal-ca.crt"
rm -f "$CA_DIR/internal-ca.srl"
echo "Seal sertifikaları hazır: $OUT"
