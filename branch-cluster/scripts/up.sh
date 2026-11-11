#!/usr/bin/env bash
# Şube (branch) cluster'ını kurar (kind-branch). Tekrar çalıştırılabilir (idempotent).
#   1) kind cluster (kind-config.yaml): şube UI için 127.0.0.1:9100
#   2) Şube UI imajı (python:3.12-alpine) kind node'larına yüklenir
#   3) Secret'lar: branch-device-tls (cihaz sertifikası + internal-ca), branch-app-secrets (identity'den)
#   4) ConfigMap branch-code (server.py, probe.py, index.html) ve şube UI pod'u
#   5) BRANCH_GW_HOST: DMZ node IP'si (gw-branch NodePort 30449, WAN üzerinden)
#   6) DMZ F10 kuralı: 30449'a yalnız bu cluster'ın node IP'lerinden erişim (dmz-cluster/scripts/host-firewall.sh)
# Ön koşul: DMZ ve identity kurulu; edge/certs (gen-branch-certs.sh); identity'de keycloak-client-secrets.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$ROOT/.."
CERTS="$REPO/edge/certs"
CTX="kind-branch"
K="kubectl --context $CTX"
IMAGE="python:3.12-alpine"

for f in branch-device.crt branch-device.key internal-ca.crt; do
    if [[ ! -f "$CERTS/$f" ]]; then
        echo "HATA: $CERTS/$f yok. Önce: bash edge/scripts/gen-branch-certs.sh" >&2
        exit 1
    fi
done

if ! kind get clusters 2>/dev/null | grep -qx branch; then
    kind create cluster --config "$ROOT/kind-config.yaml" --wait 120s
fi
# Mevcut cluster için kubectl context'i (yarım kalmış kurulumda eksik olabilir)
kind export kubeconfig --name branch >/dev/null

# Şube UI imajı: tek platform (amd64) olarak çekilip yüklenir (çok platformlu imaj kind load'da hata verir)
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    docker pull --platform linux/amd64 "$IMAGE" >/dev/null
fi
# Çok platformlu imajlar kind load docker-image ile yüklenemez: tek platformlu arşiv alınıp yüklenir
ARCHIVE="$(mktemp -t branch-ui-XXXX).tar"
docker save --platform linux/amd64 "$IMAGE" -o "$ARCHIVE"
kind load image-archive "$ARCHIVE" --name branch >/dev/null
rm -f "$ARCHIVE"

$K apply -f "$ROOT/manifests/branch-ui.yaml"

# Sertifikalar (cihaz sertifikası ve gateway'in sunucu doğrulaması için internal-ca)
$K -n branch create secret generic branch-device-tls \
    --from-file=branch-device.crt="$CERTS/branch-device.crt" \
    --from-file=branch-device.key="$CERTS/branch-device.key" \
    --from-file=internal-ca.crt="$CERTS/internal-ca.crt" \
    --dry-run=client -o yaml | $K apply -f -

# Identity'deki client secret'ları (branch-app, teller parolası) şube pod'una kopyalanır. Repo'da tutulmaz.
BRANCH_APP_SECRET=$(kubectl --context kind-identity -n auth get secret keycloak-client-secrets -o jsonpath='{.data.branch-app}' | base64 -d)
TELLER_PASSWORD=$(kubectl --context kind-identity -n auth get secret keycloak-client-secrets -o jsonpath='{.data.teller-password}' | base64 -d)
$K -n branch create secret generic branch-app-secrets \
    --from-literal=BRANCH_APP_SECRET="$BRANCH_APP_SECRET" \
    --from-literal=TELLER_PASSWORD="$TELLER_PASSWORD" \
    --dry-run=client -o yaml | $K apply -f -

# Kod: server.py, probe.py ve index.html (pod /app altında)
$K -n branch create configmap branch-code \
    --from-file=server.py="$REPO/branch/server.py" \
    --from-file=probe.py="$REPO/branch/probe.py" \
    --from-file=index.html="$REPO/branch/index.html" \
    --dry-run=client -o yaml | $K apply -f -

# gw-branch'in erişildiği DMZ node IP'si (WAN benzeri: kind ağı üzerinden, HAProxy yok)
DMZ_NODE_IP=$(docker inspect dmz-worker -f '{{ .NetworkSettings.Networks.kind.IPAddress }}')
$K -n branch set env deploy/branch-ui BRANCH_GW_HOST="$DMZ_NODE_IP" >/dev/null

$K -n branch rollout restart deploy/branch-ui >/dev/null
$K -n branch rollout status deploy/branch-ui --timeout=240s

# F10: DMZ güvenlik duvarı şube cluster'ının node IP'lerini artık tanır
bash "$REPO/dmz-cluster/scripts/host-firewall.sh"

echo "Şube cluster hazır. Şube UI: http://127.0.0.1:9100  (gw-branch: $DMZ_NODE_IP:30449)"
echo "Test: bash dmz-cluster/tests/branch.sh"
