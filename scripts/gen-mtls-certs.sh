#!/usr/bin/env bash
# Servisler arası mTLS sertifikaları (lab). Lab iç CA'sı (edge/certs/internal-ca) ile imzalanır.
#   channel-gateway        : sunucu sertifikası (SAN: channel-gateway.channel.svc)
#   janus-web, janus-mobile: istemci sertifikaları (channel-gateway'e çağrı yapan kanallar)
#   fortuna-users-cgw, sms-otp-cgw, fortuna-mock: sunucu sertifikaları (Janus ve channel-gateway çağrıları)
#   channel-gateway-client : channel-gateway'in fortuna-mock'a istemci sertifikası
#   fortuna-user-api, fortuna-user-acl: iç zincir sunucu sertifikaları; fortuna-cgw-client, fortuna-api-client: iç zincir istemcileri
# Çıktı: edge/certs/mtls/ (edge/certs gitignored). Var olanlar yeniden üretilmez.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CA_CRT="$ROOT/edge/certs/internal-ca.crt"
CA_KEY="$ROOT/edge/certs/internal-ca.key"
OUT="$ROOT/edge/certs/mtls"
[[ -f "$CA_CRT" && -f "$CA_KEY" ]] || { echo "HATA: iç CA yok ($CA_CRT). Önce edge/scripts/gen-internal-certs.sh çalıştırın." >&2; exit 1; }
mkdir -p "$OUT"
cd "$OUT"

# issue <name> <CN> <EKU> <SAN ya da boş>
issue() {
    local name=$1 cn=$2 eku=$3 san=$4
    [[ -f "$name.crt" && -f "$name.key" ]] && { echo "var: $name"; return; }
    printf '[req]\ndistinguished_name=dn\nprompt=no\n[dn]\nCN=%s\n' "$cn" > "$name.cnf"
    {
        echo "basicConstraints=CA:FALSE"
        echo "extendedKeyUsage=$eku"
        [[ -n "$san" ]] && echo "subjectAltName=$san"
    } > "$name.ext"
    openssl req -newkey rsa:2048 -nodes -keyout "$name.key" -out "$name.csr" -config "$name.cnf" >/dev/null 2>&1
    openssl x509 -req -in "$name.csr" -CA "$CA_CRT" -CAkey "$CA_KEY" -set_serial "0x$(openssl rand -hex 8)" \
        -out "$name.crt" -days 365 -extfile "$name.ext" >/dev/null 2>&1
    rm -f "$name.csr" "$name.cnf" "$name.ext"
    echo "üretildi: $name"
}

cp -f "$CA_CRT" ca.crt
issue channel-gateway "channel-gateway" "serverAuth" "DNS:channel-gateway.channel.svc,DNS:channel-gateway"
issue janus-web "janus-web" "clientAuth" ""
issue janus-mobile "janus-mobile" "clientAuth" ""
issue fortuna-users-cgw "fortuna-users-cgw" "serverAuth" "DNS:fortuna-users-cgw.channel.svc,DNS:fortuna-users-cgw"
issue sms-otp-cgw "sms-otp-cgw" "serverAuth" "DNS:sms-otp-cgw.channel.svc,DNS:sms-otp-cgw"
issue fortuna-mock "fortuna-mock" "serverAuth" "DNS:fortuna-mock.fortuna.svc,DNS:fortuna-mock"
issue channel-gateway-client "channel-gateway" "clientAuth" ""
issue fortuna-user-api "fortuna-user-api" "serverAuth" "DNS:fortuna-user-api.channel.svc,DNS:fortuna-user-api"
issue fortuna-user-acl "fortuna-user-acl" "serverAuth" "DNS:fortuna-user-acl.channel.svc,DNS:fortuna-user-acl"
# İç zincir istemcileri: CN, karşı servisin izin listesindeki kimlikle aynı (fortuna-users-cgw, fortuna-user-api)
issue fortuna-cgw-client "fortuna-users-cgw" "clientAuth" ""
issue fortuna-api-client "fortuna-user-api" "clientAuth" ""
echo "mTLS sertifikaları hazır: $OUT"
