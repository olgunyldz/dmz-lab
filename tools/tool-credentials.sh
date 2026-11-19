#!/usr/bin/env bash
# Lab araçlarının adreslerini ve parolalarını ekrana yazar (yalnız lab; repo'da parola yok, cluster secret'larından okunur).
# Kullanım (repo kökünden):  bash tools/tool-credentials.sh
# Uyarı: çıktıda parola vardır; ekran kaydı/paylaşım yapmayın.
set -uo pipefail

get() { # get <context> <ns> <secret> <key>
    kubectl --context "$1" -n "$2" get secret "$3" -o jsonpath="{.data.$4}" 2>/dev/null | base64 -d 2>/dev/null
}

echo "==================== LAB ARAÇLARI ===================="
echo
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GRAFANA_PW=$(grep -E '^GRAFANA_ADMIN_PASSWORD=' "$ROOT/platform/.env" 2>/dev/null | cut -d= -f2-)

echo "Grafana     http://127.0.0.1:3000   (platform compose)"
echo "  kullanıcı : admin"
echo "  parola    : ${GRAFANA_PW:-<platform/.env yok; bash platform/scripts/up.sh>}"
echo
echo "Kimlik (auth-server) https://id.bank.lab.local/realms/bank   (yerel: tools-forward 18443, https)"
echo "  kullanıcı : alice"
echo "  parola    : $(get kind-bank-prod auth auth-secrets ALICE_PASSWORD)"
echo
echo "Prometheus  http://127.0.0.1:9090   (platform compose; kimlik gerekmez)"
echo
echo "Vault       http://127.0.0.1:18200   (tools-forward start)"
echo "  yöntem    : Token"
echo "  root token: $(get kind-bank-prod secrets vault-bootstrap root_token)"
echo "  (lab için; prod'da root token kapatılır)"
echo
echo "Konsol      http://127.0.0.1:9000   (bash console/start.sh ile açılır)"
echo "====================================================="
