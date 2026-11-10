#!/usr/bin/env bash
# Tüm edge testlerini sırayla çalıştırır. Rate limit pencereleri sıfırlansın diye aralarda bekler.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"

overall=0
for t in smoke.sh lb.sh waf.sh ddos.sh; do
    echo "===== $t ====="
    bash "$DIR/$t" || overall=1
    echo
    sleep 12
done

[[ $overall -eq 0 ]] && echo "TÜM TESTLER GEÇTİ" || echo "BAZI TESTLER BAŞARISIZ"
exit $overall
