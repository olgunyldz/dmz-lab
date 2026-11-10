#!/usr/bin/env bash
# Şube (branch) zone sertifikaları. Idempotent: var olan dosyalar yeniden üretilmez; mevcut CA'lar değişmez.
#   branch-ca          : YENİ. Şube iş istasyonu (cihaz) istemci sertifikalarını imzalar
#   gw-branch          : internal-ca ile. gw-branch sunucu sertifikası (SAN teller.lab.local, gw-branch)
#   dmz-exchange-branch: internal-ca ile. Keycloak client-x509 exchange istemcisi (CN=dmz-exchange-branch)
#   branch-device      : branch-ca ile. Şube iş istasyonu (CN=branch-ws-01), gw-branch'e mTLS ile bağlanır
set -euo pipefail
export MSYS_NO_PATHCONV=1

OUT="$(cd "$(dirname "$0")/.." && pwd)/certs"
mkdir -p "$OUT"
cd "$OUT"

make_ca() {
    local name=$1 cn=$2
    openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
        -keyout "$name.key" -out "$name.crt" -subj "/CN=$cn" \
        -addext "basicConstraints=critical,CA:TRUE" \
        -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
}

# issue <ad> <ca-adı> <CN> <SAN...>
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

[[ -f internal-ca.crt ]] || { echo "internal-ca yok; önce gen-certs.sh çalıştırın"; exit 1; }

if [[ ! -f branch-ca.crt ]]; then
    make_ca branch-ca "Lab Branch CA"
    echo "branch-ca üretildi"
fi
[[ -f gw-branch.crt ]] || issue gw-branch internal-ca "gw-branch" DNS:gw-branch DNS:teller.lab.local
[[ -f dmz-exchange-branch.crt ]] || issue dmz-exchange-branch internal-ca "dmz-exchange-branch" DNS:dmz-exchange-branch
[[ -f branch-device.crt ]] || issue branch-device branch-ca "branch-ws-01" DNS:branch-ws-01.lab.local

rm -f ./*.srl
echo "Şube sertifikaları hazır: $OUT"
