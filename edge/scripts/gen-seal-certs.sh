#!/usr/bin/env bash
# Seal v3 servisleri için sunucu sertifikaları (iç CA ile imzalı). Lab sertifikaları; çıktı edge/certs/seal (gitignored).
#   seal-intranet    : seal-intranet.seal-intranet.svc (iç HTTPS)
#   bank-backend     : bank-backend.bank-auth.svc
#   seal-mobile      : seal-mobile.seal-mobile.svc + seal.lab.local (cihaz yüzü, passthrough; SNI seal.lab.local)
#   seal-mobile-internal : Seal Mobile istemci sertifikası (CN=seal-mobile: monolit ve auth-server izin listesi; clientAuth)
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

issue seal-intranet "seal-intranet" "DNS:seal-intranet.lab.local,DNS:seal-intranet.seal-intranet.svc,DNS:seal-intranet"
issue bank-backend "bank-backend" "DNS:bank-backend.bank-auth.svc"
issue seal-mobile "seal-mobile" "DNS:seal-mobile.seal-mobile.svc,DNS:seal.lab.local"

# İstemci sertifikası (auth-server'a mTLS). Varsa yeniden üretilmez; cihaz kayıtları etkilenmesin.
if [[ ! -f seal-mobile-internal.crt ]]; then
    printf '[req]
distinguished_name=dn
prompt=no
[dn]
CN=seal-mobile
' > seal-mobile-internal.cnf
    printf 'subjectAltName=DNS:seal-mobile
extendedKeyUsage=clientAuth
basicConstraints=CA:FALSE
' > seal-mobile-internal.ext
    openssl req -newkey rsa:2048 -nodes -keyout seal-mobile-internal.key -out seal-mobile-internal.csr -config seal-mobile-internal.cnf 2>/dev/null
    openssl x509 -req -in seal-mobile-internal.csr -CA "$CA_DIR/internal-ca.crt" -CAkey "$CA_DIR/internal-ca.key" -CAcreateserial         -out seal-mobile-internal.crt -days 365 -extfile seal-mobile-internal.ext 2>/dev/null
    rm -f seal-mobile-internal.csr seal-mobile-internal.cnf seal-mobile-internal.ext
fi
cp "$CA_DIR/internal-ca.crt" "$OUT/internal-ca.crt"
rm -f "$CA_DIR/internal-ca.srl"
echo "Seal sertifikaları hazır: $OUT"
