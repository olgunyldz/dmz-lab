#!/usr/bin/env bash
# WAF testleri. Demo edge'de WAF MOCK'tur (Coraza kaldırıldı): normal istek 200 beklenir,
# saldırı testleri gerçek bir engelleme olmadığı için PASS sayılmaz, SKIP edilir.
source "$(dirname "$0")/lib.sh"

BASE="https://web.lab.local"
RESOLVE=(--connect-to "web.lab.local:443:$EDGE:$PORT" --cacert "$CERTS/public-ca.crt")

MOCK=0
if grep -q 'MOCK WAF' "$EDGE_DIR/haproxy/haproxy.cfg" 2>/dev/null; then MOCK=1; fi
if [[ $MOCK -eq 1 ]]; then
    echo "UYARI: MOCK WAF modu. WAF etkin değil; saldırı testleri SKIP edildi (bu bir güvenlik kanıtı değildir)."
fi

# 1) Normal istek geçmeli (mock modda da)
code=$("${CURL[@]}" -s -o /dev/null -w '%{http_code}' --max-time 10 "${RESOLVE[@]}" \
    -G --data-urlencode "q=merhaba dunya" "$BASE/public/branches")
check "normal istek -> 200" "200" "$code"

if [[ $MOCK -eq 1 ]]; then
    echo "SKIP  SQL injection -> 403            (mock WAF)"
    echo "SKIP  SQL injection -> waf-block      (mock WAF)"
    echo "SKIP  XSS -> 403                      (mock WAF)"
    echo "SKIP  path traversal -> 403           (mock WAF)"
else
    # 2) SQL injection -> 403
    headers=$("${CURL[@]}" -s -D - -o /dev/null --max-time 10 "${RESOLVE[@]}" \
        -G --data-urlencode "id=1' OR '1'='1" "$BASE/public/branches")
    check "SQL injection -> 403" "403" "$(echo "$headers" | head -1)"
    check "SQL injection -> waf-block başlığı" "waf-block" "$headers"

    # 3) XSS -> 403
    code=$("${CURL[@]}" -s -o /dev/null -w '%{http_code}' --max-time 10 "${RESOLVE[@]}" \
        -G --data-urlencode "q=<script>alert(1)</script>" "$BASE/public/branches")
    check "XSS -> 403" "403" "$code"

    # 4) Path traversal -> 403 (--path-as-is: curl ../ segmentlerini kırpmasın)
    code=$("${CURL[@]}" -s -o /dev/null -w '%{http_code}' --max-time 10 --path-as-is "${RESOLVE[@]}" \
        "$BASE/../../etc/passwd")
    check "path traversal -> 403" "403" "$code"
fi

summary
