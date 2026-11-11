#!/usr/bin/env bash
# İç zone sertifikaları (internal-ca ile). Idempotent: var olan dosyalar yeniden üretilmez.
# Önce: bash edge/scripts/gen-certs.sh (internal-ca.crt/key bu betikte üretilir).
#   gw-internal          : iç kgateway sunucu sertifikası (SAN gw-internal, gw-internal.lab.local)
#   dmz-client           : DMZ'nin iç gateway'e mTLS istemci sertifikası (CN=dmz-edge-client)
#   dmz-exchange-{web,mobile,partner}: Keycloak client-x509 token exchange istemcileri (CN=dmz-exchange-<kanal>)
# dmz-exchange-branch gen-branch-certs.sh ile üretilir.
set -euo pipefail

export MSYS_NO_PATHCONV=1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$SCRIPT_DIR/../certs"
mkdir -p "$OUT"
cd "$OUT"

if [[ ! -f internal-ca.crt || ! -f internal-ca.key ]]; then
    echo "HATA: internal-ca yok. Önce: bash edge/scripts/gen-certs.sh" >&2
    exit 1
fi

# issue <ad> <CN> <EKU: server|client> <SAN1> [SAN2 ...]
issue() {
    local name=$1 cn=$2 eku=$3
    shift 3
    if [[ -f "$name.crt" && -f "$name.key" ]]; then
        echo "atlandı (mevcut): $name"
        return 0
    fi
    local sans ekuval
    sans=$(IFS=,; echo "$*")
    case $eku in
        server) ekuval="serverAuth,clientAuth" ;;
        client) ekuval="clientAuth" ;;
    esac
    openssl req -newkey rsa:2048 -nodes -keyout "$name.key" -out "$name.csr" -subj "/CN=$cn" 2>/dev/null
    printf "basicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=%s\nsubjectAltName=%s\n" \
        "$ekuval" "$sans" > "$name.ext"
    openssl x509 -req -in "$name.csr" -CA internal-ca.crt -CAkey internal-ca.key -CAcreateserial \
        -out "$name.crt" -days 397 -extfile "$name.ext" 2>/dev/null
    rm -f "$name.csr" "$name.ext"
    echo "üretildi: $name"
}

issue gw-internal "gw-internal" server DNS:gw-internal DNS:gw-internal.lab.local
issue dmz-client "dmz-edge-client" client DNS:dmz-edge-client
for ch in web mobile partner; do
    issue "dmz-exchange-$ch" "dmz-exchange-$ch" client "DNS:dmz-exchange-$ch"
done

rm -f ./*.srl
echo "İç zone sertifikaları hazır: $OUT"
