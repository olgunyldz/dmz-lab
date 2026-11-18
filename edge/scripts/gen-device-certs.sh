#!/usr/bin/env bash
# Cihaz güven (device trust) örneği için sertifikalar. Lab sertifikaları; üretimde cihaz kaydı (enrollment) ile üretilir.
#   device-ca      : cihaz CA'sı (ayrı; internal-ca ile karıştırılmaz)
#   device-trust   : sunucu sertifikası (device-trust servisi)
#   device-lab-01  : geçerli cihaz istemci sertifikası
#   device-lab-02  : geçerli ama iptal edilecek cihaz (test)
#   rogue-*        : başka CA'dan, negatif test için
# Çıktı: edge/certs/device/ (edge/certs gitignored).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/edge/certs/device"
mkdir -p "$OUT"
cd "$OUT"

ca_cnf() { # <CN>
    printf '[req]\ndistinguished_name=dn\nprompt=no\nx509_extensions=v3\n[dn]\nCN=%s\n[v3]\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n' "$1"
}
leaf_ext() { # <SAN> <EKU>
    printf 'subjectAltName=%s\nextendedKeyUsage=%s\nbasicConstraints=CA:FALSE\n' "$1" "$2"
}
leaf_cnf() { # <CN>
    printf '[req]\ndistinguished_name=dn\nprompt=no\n[dn]\nCN=%s\n' "$1"
}

issue() { # <name> <CN> <ca-prefix> <SAN> <EKU>
    local name=$1 cn=$2 ca=$3 san=$4 eku=$5
    leaf_cnf "$cn" > "$name.cnf"
    leaf_ext "$san" "$eku" > "$name.ext"
    openssl req -newkey rsa:2048 -nodes -keyout "$name.key" -out "$name.csr" -config "$name.cnf"
    openssl x509 -req -in "$name.csr" -CA "$ca.crt" -CAkey "$ca.key" -CAcreateserial \
        -out "$name.crt" -days 365 -extfile "$name.ext" 2>/dev/null
    rm -f "$name.csr"
}

# Cihaz CA'sı
ca_cnf "Lab Device CA" > device-ca.cnf
openssl req -x509 -newkey rsa:2048 -nodes -keyout device-ca.key -out device-ca.crt -days 3650 -config device-ca.cnf 2>/dev/null
rm -f device-ca.cnf

issue device-trust "device-trust" device-ca "DNS:device.lab.local,DNS:device-trust.devtrust.svc,DNS:localhost,IP:127.0.0.1" "serverAuth"
issue device-lab-01 "device-lab-01" device-ca "DNS:device-lab-01" "clientAuth"
issue device-lab-02 "device-lab-02" device-ca "DNS:device-lab-02" "clientAuth"
issue device-lab-03 "device-lab-03" device-ca "DNS:device-lab-03" "clientAuth"  # yeni cihaz senaryosu (enroll edilmemiş)

# Negatif test: başka CA
ca_cnf "Rogue CA" > rogue-ca.cnf
openssl req -x509 -newkey rsa:2048 -nodes -keyout rogue-ca.key -out rogue-ca.crt -days 3650 -config rogue-ca.cnf 2>/dev/null
rm -f rogue-ca.cnf
issue rogue-device "rogue-device" rogue-ca "DNS:rogue-device" "clientAuth"

rm -f device-ca.srl rogue-ca.srl
echo "Cihaz sertifikaları hazır: $OUT"
