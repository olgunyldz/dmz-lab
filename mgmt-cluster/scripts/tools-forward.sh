#!/usr/bin/env bash
# Yönetim araçlarına host'tan DOĞRUDAN erişim (HAProxy yok): Grafana, Prometheus, Vault.
# Yöntem: kubectl port-forward (kind node port eşlemesi yok; mgmt cluster'ı yeniden kurmadan çalışır).
#   http://127.0.0.1:3000  Grafana      (kullanıcı admin; parola: grafana-admin secret'ı)
#   http://127.0.0.1:9090  Prometheus
#   http://127.0.0.1:8200  Vault        (sealed olabilir; UI yine açılır)
#   http://127.0.0.1:18080/admin/  Keycloak admin (kullanıcı admin; parola: identity cluster'ı auth/keycloak-admin secret'ı)
#
# Kullanım (repo kökünden):
#   bash mgmt-cluster/scripts/tools-forward.sh start   arka planda başlat
#   bash mgmt-cluster/scripts/tools-forward.sh stop    durdur
#   bash mgmt-cluster/scripts/tools-forward.sh status  durum
# Kalıcı çözüm (sonraki adım): mgmt kind-config.yaml'a extraPortMappings (BRANCH'teki gibi); bu cluster'ın
# yeniden oluşturulmasını gerektirir (Vault verisi gider).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PIDDIR="$ROOT/.tools-forward"
TOOLS=(
    "grafana|kind-mgmt|observability|svc/grafana|3000:3000"
    "prometheus|kind-mgmt|observability|svc/prometheus|9090:9090"
    "vault|kind-mgmt|secrets|svc/vault-nodeport|8200:8200"
    "keycloak|kind-identity|auth|svc/keycloak|18080:8080"
)

start() {
    mkdir -p "$PIDDIR"
    for t in "${TOOLS[@]}"; do
        IFS='|' read -r name ctx ns target ports <<<"$t"
        local local_port=${ports%%:*}
        if [[ -f "$PIDDIR/$name.pid" ]] && kill -0 "$(cat "$PIDDIR/$name.pid")" 2>/dev/null; then
            echo "$name zaten çalışıyor (port $local_port)"
            continue
        fi
        if (exec 3<>"/dev/tcp/127.0.0.1/$local_port") 2>/dev/null; then
            echo "UYARI: port $local_port dolu, $name başlatılamadı (başka bir süreç kullanıyor)" >&2
            continue
        fi
        nohup kubectl --context "$ctx" -n "$ns" port-forward "$target" "$ports" --address 127.0.0.1 >"$PIDDIR/$name.log" 2>&1 &
        echo $! > "$PIDDIR/$name.pid"
        echo "$name başlatıldı: http://127.0.0.1:$local_port"
    done
    sleep 3
    status
}

stop() {
    for t in "${TOOLS[@]}"; do
        IFS='|' read -r name _ _ _ _ <<<"$t"
        if [[ -f "$PIDDIR/$name.pid" ]]; then
            kill "$(cat "$PIDDIR/$name.pid")" 2>/dev/null && echo "$name durduruldu"
            rm -f "$PIDDIR/$name.pid"
        fi
    done
}

status() {
    for t in "${TOOLS[@]}"; do
        IFS='|' read -r name _ _ _ ports <<<"$t"
        local local_port=${ports%%:*}
        if (exec 3<>"/dev/tcp/127.0.0.1/$local_port") 2>/dev/null; then
            echo "$name: AÇIK  http://127.0.0.1:$local_port"
        else
            echo "$name: kapalı"
        fi
    done
}

case "${1:-status}" in
    start) start ;;
    stop) stop ;;
    status) status ;;
    *) echo "kullanım: $0 start|stop|status"; exit 2 ;;
esac
