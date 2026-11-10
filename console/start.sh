#!/usr/bin/env bash
# DMZ lab konsolunu başlatır (yalnız lab). Ön koşulları kontrol eder, sonra console/server.py'yi çalıştırır.
# Kullanım (repo kökünden):  bash console/start.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT=9000

fail() { echo "HATA: $1" >&2; exit 1; }

# 1) Edge (HAProxy + WAF) ayakta mı?
running=$(docker ps --format '{{.Names}}' | grep -c "dmz-edge-lab-haproxy-1\|dmz-edge-lab-coraza-spoa-1" || true)
[[ "$running" -ge 2 ]] || fail "edge ayakta değil. Çalıştırın: cd edge && docker compose up -d"

# 2) Gerekli cluster context'leri
for c in identity dmz; do
    kubectl config get-contexts -o name | grep -qx "kind-$c" || fail "kubectl context kind-$c yok (cluster kurulu mu?)"
done

# 3) Port boş mu, yoksa konsol zaten çalışıyor mu?
if curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$PORT/"; then
    echo "Konsol zaten çalışıyor: http://127.0.0.1:$PORT"
    exit 0
fi

echo "Organizer başlatılıyor (identity port-forward dahil)..."
cd "$ROOT"
PYTHONIOENCODING=utf-8 exec python console/app.py
