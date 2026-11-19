#!/usr/bin/env bash
# Kind cluster'larındaki araçlara host'tan kubectl port-forward ile erişim.
# Grafana, Prometheus, Loki ve Jaeger host'ta docker compose (platform) ile 127.0.0.1'e yayımlı; burada yok.
#   http://127.0.0.1:18200 Vault        (bank-prod; sealed olabilir; UI yine açılır; 8200 Windows'ta ayrılmış: 8185-8284)
#   https://127.0.0.1:18443        auth-server (bank-prod, ns auth; sertifika lab CA ile imzalı)
#   Grafana: http://127.0.0.1:3000 (platform compose)
#
# Kullanım (repo kökünden):
#   bash tools/tools-forward.sh start   arka planda başlat
#   bash tools/tools-forward.sh stop    durdur
#   bash tools/tools-forward.sh status  durum
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PIDDIR="$ROOT/.tools-forward"
TOOLS=(
    "vault|kind-bank-prod|secrets|svc/vault|18200:8200"
    "auth-server|kind-bank-prod|auth|svc/auth-server|18443:8443"
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
