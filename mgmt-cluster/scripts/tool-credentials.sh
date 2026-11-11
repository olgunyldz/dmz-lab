#!/usr/bin/env bash
# Lab araçlarının adreslerini ve parolalarını ekrana yazar (yalnız lab; repo'da parola yok, cluster secret'larından okunur).
# Kullanım (repo kökünden):  bash mgmt-cluster/scripts/tool-credentials.sh
# Uyarı: çıktıda parola vardır; ekran kaydı/paylaşım yapmayın.
set -uo pipefail

get() { # get <context> <ns> <secret> <key>
    kubectl --context "$1" -n "$2" get secret "$3" -o jsonpath="{.data.$4}" 2>/dev/null | base64 -d 2>/dev/null
}

echo "==================== LAB ARAÇLARI ===================="
echo
echo "Grafana     http://127.0.0.1:3000"
echo "  kullanıcı : admin"
echo "  parola    : $(get kind-mgmt observability grafana-admin password)"
echo
echo "Keycloak    http://127.0.0.1:18080/admin/"
echo "  kullanıcı : admin"
echo "  parola    : $(get kind-identity auth keycloak-admin password)"
echo
echo "Prometheus  http://127.0.0.1:9090   (kimlik gerekmez)"
echo
echo "Vault       http://127.0.0.1:8200"
echo "  yöntem    : Token"
echo "  root token: $(get kind-mgmt secrets vault-bootstrap root_token)"
echo "  (lab için; prod'da root token kapatılır)"
echo
echo "Şube UI     http://127.0.0.1:9100   (kimlik: teller; parola identity'de)"
echo "  teller    : $(get kind-identity auth keycloak-client-secrets teller-password)"
echo
echo "Konsol      http://127.0.0.1:9000   (bash console/start.sh ile açılır)"
echo "====================================================="
