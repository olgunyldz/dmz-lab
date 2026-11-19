#!/usr/bin/env bash
# HAProxy yapılandırmasını şablondan üretir ve HAProxy'yi yeniden başlatır.
# Edge kind ağına bağlı değildir; DMZ cluster'larına host.docker.internal üzerinden (yayınlanmış NodePort) gider.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TPL="$ROOT/edge/haproxy/haproxy.cfg.tpl"
OUT="$ROOT/edge/haproxy/haproxy.cfg"

cp "$TPL" "$OUT.tmp"
mv "$OUT.tmp" "$OUT"
echo "haproxy.cfg üretildi (şablon: $TPL)"
(cd "$ROOT/edge" && docker compose up -d >/dev/null && docker compose restart haproxy >/dev/null)
echo "HAProxy hazır."
