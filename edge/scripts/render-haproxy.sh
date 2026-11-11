#!/usr/bin/env bash
# HAProxy yapılandırmasını üretir: haproxy.cfg.tpl içindeki DMZ node IP'lerini (lab-ips.sh) yazar,
# edge/haproxy/haproxy.cfg dosyasını oluşturur ve HAProxy'yi yeniden başlatır.
# Ön koşul: DMZ cluster kurulu (dmz-worker, dmz-worker2 node container'ları).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/lab-ips.sh"

TPL="$ROOT/edge/haproxy/haproxy.cfg.tpl"
OUT="$ROOT/edge/haproxy/haproxy.cfg"

render "$TPL" > "$OUT.tmp"
mv "$OUT.tmp" "$OUT"
echo "haproxy.cfg üretildi: dmz-worker=$(_ip_of dmz-worker) dmz-worker2=$(_ip_of dmz-worker2)"

# Yapılandırma yalnız container başlarken okunur
(cd "$ROOT/edge" && docker compose restart haproxy >/dev/null)
echo "HAProxy yeniden başlatıldı."
