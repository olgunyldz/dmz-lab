#!/usr/bin/env bash
# Test betikleri için ortak yardımcılar. Diğer betikler "source" eder.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EDGE_DIR="$(cd "$TESTS_DIR/.." && pwd)"
CERTS="$EDGE_DIR/certs"
PORT=8443
EDGE=127.0.0.1

# Windows curl (schannel) lab CA'sının CRL'ini bulamıyor. Lab için revocation kontrolünü kapat.
CURL=(curl)
if curl -V 2>/dev/null | grep -qi schannel; then CURL=(curl --ssl-no-revoke); fi

pass=0
fail=0

check() {
    local name=$1 expected=$2 actual=$3
    if [[ "$actual" == *"$expected"* ]]; then
        echo "PASS  $name"
        pass=$((pass + 1))
    else
        echo "FAIL  $name  (beklenen: '$expected', gelen: '$actual')"
        fail=$((fail + 1))
    fi
}

summary() {
    echo
    echo "Sonuç: $pass geçti, $fail kaldı"
    [[ $fail -eq 0 ]]
}
