# Port-forward yardımcıları (test süitleri için; source ile yüklenir).
#   pf_start <ad> <yerel-port> -- <komut...>   arka planda başlatır, log'u PF_LOG_DIR'e yazar
#   pf_wait  <yerel-port> [saniye]            port gerçekten bağlantı kabul edene kadar bekler
#   pf_stop                                   başlatılan tüm süreçleri (Windows'ta süreç ağacıyla) kapatır
# Sabit "sleep" yerine hazır olma kontrolü yapar; hata olursa log'u gösterir.

PF_PIDS=()
PF_LOG_DIR=${PF_LOG_DIR:-${TMPDIR:-/tmp}/dmz-lab-pf}
mkdir -p "$PF_LOG_DIR"

pf_start() {
    local name=$1 port=$2
    shift 2
    [[ "$1" == "--" ]] && shift
    local log="$PF_LOG_DIR/pf-$name.log"
    "$@" >"$log" 2>&1 &
    PF_PIDS+=("$!")
    PF_LOG_FILE_LAST="$log"
    PF_PORT_LAST="$port"
}

pf_wait() {
    local port=$1 timeout=${2:-30} i pid
    pid=${PF_PIDS[-1]}
    for ((i = 0; i < timeout * 2; i++)); do
        if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
            exec 3>&- 3<&-
            return 0
        fi
        if ! kill -0 "$pid" 2>/dev/null; then
            echo "HATA: port-forward (port $port) süreci çöktü. Log: $PF_LOG_FILE_LAST" >&2
            cat "$PF_LOG_FILE_LAST" >&2
            return 1
        fi
        sleep 0.5
    done
    echo "HATA: port $port ${timeout}s içinde hazır olmadı. Log: $PF_LOG_FILE_LAST" >&2
    cat "$PF_LOG_FILE_LAST" >&2
    return 1
}

pf_stop() {
    local pid winpid
    for pid in "${PF_PIDS[@]:-}"; do
        [[ -z "$pid" ]] && continue
        # Git Bash: MSYS PID'in Windows PID'ini al; kubectl.exe ayrı süreç olduğu için ağacı öldür
        winpid=$(cat "/proc/$pid/winpid" 2>/dev/null || true)
        if [[ -n "$winpid" ]] && command -v taskkill >/dev/null 2>&1; then
            taskkill //PID "$winpid" //T //F >/dev/null 2>&1 || true
        fi
        kill "$pid" 2>/dev/null || true
    done
    PF_PIDS=()
}
