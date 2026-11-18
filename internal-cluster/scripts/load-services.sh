#!/usr/bin/env bash
# İç servislerin (BFF, core) kodunu ConfigMap olarak yükler ve manifest'leri uygular.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/../scripts/lab-ips.sh"
K="kubectl --context kind-internal"

for ns in app-bff app-core; do
    $K create namespace "$ns" --dry-run=client -o yaml | $K apply -f - >/dev/null
    $K -n "$ns" create configmap svc-code --from-file=svc.py="$ROOT/services/svc.py" \
        --from-file=tracing.py="$ROOT/../shared/tracing.py" \
        --from-file=metrics.py="$ROOT/../shared/metrics.py" \
        --dry-run=client -o yaml | $K apply -f -
done

# Servis TLS sertifikaları (iç CA ile imzalı): core ve bff. BackendTLSPolicy ve BFF->core bu sertifikaları doğrular.
CERTS="$ROOT/../edge/certs"
SVC_CERTS="$CERTS/services"
mkdir -p "$SVC_CERTS"
svc_cert() { # <ad> <ns> <SAN listesi>
    local name=$1 ns=$2 san=$3
    if [[ ! -f "$SVC_CERTS/$name.crt" ]]; then
        cat > "$SVC_CERTS/$name.cnf" <<CNF
[req]
distinguished_name=dn
prompt=no
[dn]
CN=$name.$ns.svc.cluster.local
CNF
        cat > "$SVC_CERTS/$name.ext" <<EXT
subjectAltName=$san
extendedKeyUsage=serverAuth
basicConstraints=CA:FALSE
EXT
        openssl req -newkey rsa:2048 -nodes -keyout "$SVC_CERTS/$name.key" -out "$SVC_CERTS/$name.csr" -config "$SVC_CERTS/$name.cnf" 2>/dev/null
        openssl x509 -req -in "$SVC_CERTS/$name.csr" -CA "$CERTS/internal-ca.crt" -CAkey "$CERTS/internal-ca.key" -CAcreateserial             -out "$SVC_CERTS/$name.crt" -days 365 -extfile "$SVC_CERTS/$name.ext" 2>/dev/null
        rm -f "$SVC_CERTS/$name.csr" "$SVC_CERTS/$name.cnf" "$SVC_CERTS/$name.ext" "$CERTS/internal-ca.srl"
    fi
    $K -n "$ns" create secret generic "svc-$name-tls"         --from-file=server.crt="$SVC_CERTS/$name.crt" --from-file=server.key="$SVC_CERTS/$name.key"         --dry-run=client -o yaml | $K apply -f -
}
svc_cert core app-core "DNS:core.app-core.svc.cluster.local,DNS:core.app-core.svc"
svc_cert bff app-bff "DNS:bff.app-bff.svc.cluster.local,DNS:bff.app-bff.svc"
for ns in app-bff app-core; do
    $K -n "$ns" create configmap internal-ca-backend --from-file=ca.crt="$CERTS/internal-ca.crt"         --dry-run=client -o yaml | $K apply -f -
done

render "$ROOT/manifests/services.yaml" | $K apply -f -
$K apply -f "$ROOT/manifests/internal-authz.yaml" >/dev/null
$K -n app-bff rollout restart deploy/bff >/dev/null
$K -n app-core rollout restart deploy/core >/dev/null
$K -n app-bff rollout status deploy/bff --timeout=180s
$K -n app-core rollout status deploy/core --timeout=180s
echo "İç servisler (BFF, core) iç JWT doğrulamasıyla çalışıyor."
