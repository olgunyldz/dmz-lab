#!/usr/bin/env bash
# Tüm lab test süitlerini sırayla çalıştırır ve sonuçları tek tabloda özetler.
# Ön koşul: 4 cluster (dmz, internal, identity, mgmt) ve edge (docker compose) ayakta, sırlar yüklü.
# Süitler port-forward kullandığı için sırayla çalışır.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"

SUITES=(
    "identity-cluster/tests/firewall.sh"
    "dmz-cluster/tests/smoke.sh"
    "dmz-cluster/tests/route-classes.sh"
    "dmz-cluster/tests/extauth.sh"
    "dmz-cluster/tests/internal-path.sh"
    "dmz-cluster/tests/firewall.sh"
    "dmz-cluster/tests/branch.sh"
    "internal-cluster/tests/authz.sh"
    "internal-cluster/tests/service-verify.sh"
    "edge/tests/run-all.sh"
)

overall=0
declare -a rows
for s in "${SUITES[@]}"; do
    echo "===== $s"
    out=$(bash "$ROOT/$s" 2>&1)
    rc=$?
    echo "$out" | grep -E "FAIL|Sonuç|TÜM|BAZI" | sed 's/^/      /'
    # PASS/FAIL satırlarını say (iç içe çalışan süitlerde de doğru toplam verir)
    npass=$(echo "$out" | grep -c '^PASS')
    nfail=$(echo "$out" | grep -c '^FAIL')
    result="$npass geçti, $nfail kaldı"
    [[ $npass -eq 0 && $nfail -eq 0 ]] && result="çıktı yok (rc=$rc)"
    [[ $rc -ne 0 ]] && overall=1
    rows+=("$(printf '%-42s %s' "$s" "$result")")
    echo
done

echo "================ ÖZET ================"
printf '%s\n' "${rows[@]}"
echo
[[ $overall -eq 0 ]] && echo "TÜM SÜİTLER GEÇTİ" || echo "BAZI SÜİTLER BAŞARISIZ"
exit $overall
