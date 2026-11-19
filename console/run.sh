#!/usr/bin/env bash
# DMZ lab konsolu (Next.js) yönetimi. Host üzerinde çalışır (küme dışı); edge (HAProxy, 8443) gerekir.
# Kullanım:
#   bash console/run.sh install   # npm bağımlılıkları (package-lock.json ile)
#   bash console/run.sh build     # üretim derlemesi (.next)
#   bash console/run.sh start     # arka planda başlat (varsayılan port 9000; CONSOLE_PORT ile değiştir)
#   bash console/run.sh stop      # başlatılan süreci durdur
#   bash console/run.sh status    # çalışıyor mu, hangi port
#   bash console/run.sh up        # install + build + start
# Günlük: console/.run/console.log. PID: console/.run/console.pid
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
RUN_DIR="$HERE/.run"
PID_FILE="$RUN_DIR/console.pid"
LOG_FILE="$RUN_DIR/console.log"
PORT="${CONSOLE_PORT:-9000}"
mkdir -p "$RUN_DIR"

is_windows() { [[ "$(uname -s)" == MINGW* || "$(uname -s)" == MSYS* || "$(uname -s)" == CYGWIN* ]]; }

# Çalışan konsolun PID'i. Windows'ta (Git Bash) $! farklı bir PID olduğundan dinleyen süreç porttan bulunur.
running_pid() {
    local pid=""
    if is_windows; then
        pid="$(netstat -ano 2>/dev/null | grep -E "[:.]$PORT[[:space:]]+[^[:space:]]+[[:space:]]+LISTENING" | awk '{print $NF}' | head -1)"
    elif [[ -f "$PID_FILE" ]]; then
        pid="$(cat "$PID_FILE")"
        kill -0 "$pid" 2>/dev/null || pid=""
    fi
    [[ -n "$pid" ]] || return 1
    echo "$pid"
}

cmd_install() { npm install --no-audit --no-fund; }
cmd_build()   { npx next build; }

cmd_start() {
    if running_pid >/dev/null; then
        echo "konsol zaten çalışıyor (pid $(running_pid), port $PORT)"
        return 0
    fi
    [[ -d .next ]] || { echo "HATA: önce derleme yapın (bash console/run.sh build)" >&2; exit 2; }
    nohup npx next start -p "$PORT" >"$LOG_FILE" 2>&1 &
    echo $! > "$PID_FILE"
    # hazır olana kadar bekle (en fazla 30 sn)
    for _ in $(seq 1 30); do
        if curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$PORT/"; then
            echo "konsol çalışıyor: http://127.0.0.1:$PORT (günlük: $LOG_FILE)"
            return 0
        fi
        sleep 1
    done
    echo "HATA: konsol $PORT portunda açılmadı; günlük: $LOG_FILE" >&2
    tail -20 "$LOG_FILE" >&2 || true
    exit 1
}

cmd_stop() {
    local pid
    if ! pid="$(running_pid)"; then
        echo "çalışan konsol yok"
        rm -f "$PID_FILE"
        return 0
    fi
    if is_windows; then
        taskkill //PID "$pid" //T //F >/dev/null 2>&1 || true
    else
        kill "$pid" 2>/dev/null || true
    fi
    rm -f "$PID_FILE"
    echo "konsol durduruldu (pid $pid)"
}

cmd_status() {
    if running_pid >/dev/null; then
        echo "çalışıyor: pid $(running_pid), http://127.0.0.1:$PORT"
    else
        echo "çalışmıyor"
    fi
}

case "${1:-}" in
    install) cmd_install ;;
    build)   cmd_build ;;
    start)   cmd_start ;;
    stop)    cmd_stop ;;
    status)  cmd_status ;;
    up)      cmd_install && cmd_build && cmd_start ;;
    *) echo "kullanım: bash console/run.sh {install|build|start|stop|status|up}" >&2; exit 2 ;;
esac
