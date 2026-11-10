#!/usr/bin/env bash
# Lab sertifikalarını üretir. Üç ayrı CA vardır:
#   public-ca   : Edge'in public sertifikasını imzalar (web/mobile)
#   internal-ca : Edge -> gw-* re-encrypt bağlantısındaki sunucu sertifikalarını imzalar
#   partner-ca  : Partner istemci sertifikalarını imzalar
# Çıktılar: edge/certs/ (git'e eklenmez)
set -euo pipefail

# Git Bash'te "/CN=..." yolunun Windows yoluna çevrilmesini engelle
export MSYS_NO_PATHCONV=1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$SCRIPT_DIR/../certs"
mkdir -p "$OUT"
cd "$OUT"

make_ca() {
    local name=$1 cn=$2
    openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
        -keyout "$name.key" -out "$name.crt" -subj "/CN=$cn" \
        -addext "basicConstraints=critical,CA:TRUE" \
        -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
}

# issue <ad> <ca-adı> <CN> <SAN1> [SAN2 ...]
issue() {
    local name=$1 ca=$2 cn=$3
    shift 3
    local sans
    sans=$(IFS=,; echo "$*")
    openssl req -newkey rsa:2048 -nodes -keyout "$name.key" -out "$name.csr" -subj "/CN=$cn" 2>/dev/null
    printf "basicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth,clientAuth\nsubjectAltName=%s\n" "$sans" > "$name.ext"
    openssl x509 -req -in "$name.csr" -CA "$ca.crt" -CAkey "$ca.key" -CAcreateserial \
        -out "$name.crt" -days 397 -extfile "$name.ext" 2>/dev/null
    rm -f "$name.csr" "$name.ext"
}

make_ca public-ca   "Lab Public CA"
make_ca internal-ca "Lab Internal CA"
make_ca partner-ca  "Lab Partner CA"

issue edge        public-ca   "web.lab.local" DNS:web.lab.local DNS:mobile-api.lab.local
issue gw-web      internal-ca "gw-web"         DNS:gw-web
issue gw-mobile   internal-ca "gw-mobile"      DNS:gw-mobile
issue gw-partner  internal-ca "gw-partner"     DNS:gw-partner DNS:partner-api.lab.local
issue partner-client partner-ca "acme-partner" DNS:acme-partner.lab.local

# HAProxy tek bir PEM (sertifika + anahtar) bekler
cat edge.crt edge.key > edge.pem

rm -f ./*.srl
echo "Sertifikalar üretildi: $OUT"
ls -1 "$OUT"
