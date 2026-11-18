#!/usr/bin/env python3
"""Cihaz yolu uçtan uca testi: HAProxy (SNI device.lab.local) -> DMZ gw-device -> iç gw-device-int -> device-trust.

Ön koşul: edge HAProxy 127.0.0.1:8443'te, device-trust cihaz sertifikaları edge/certs/device altında.
Kullanım: PYTHONIOENCODING=utf-8 python dmz_path_test.py [port]
TLS yalnız cihaz uçta sonlanır: DMZ/iç gateway istemci sertifikasını görmez; reddetme device-trust'tadır.
"""
import http.client
import json
import os
import socket
import ssl
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CERTS = os.path.join(HERE, "..", "..", "..", "edge", "certs", "device")
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8443
HOST = "device.lab.local"
passed = failed = 0


def check(name, ok, detail=""):
    global passed, failed
    if ok:
        passed += 1
        print("PASS  " + name)
    else:
        failed += 1
        print("FAIL  " + name + "  " + str(detail))


def cert_path(name):
    return os.path.join(CERTS, name)


def request(cert=None, method="GET", path="/device/status", body=None):
    ctx = ssl.create_default_context(cafile=cert_path("device-ca.crt"))
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    if cert:
        ctx.load_cert_chain(cert_path(cert + ".crt"), cert_path(cert + ".key"))
    try:
        raw = socket.create_connection(("127.0.0.1", PORT), timeout=10)
        sock = ctx.wrap_socket(raw, server_hostname=HOST)  # SNI + sunucu sertifikası doğrulaması
        conn = http.client.HTTPConnection(HOST, timeout=10)
        conn.sock = sock
        data = json.dumps(body).encode() if body is not None else None
        conn.request(method, path, body=data, headers={"Content-Type": "application/json"})
        resp = conn.getresponse()
        return resp.status, resp.read().decode()
    except (ssl.SSLError, OSError) as e:
        # TLS 1.3'te istemci sertifikası reddi bazen el sıkışmadan sonra bağlantı kopması olarak görünür
        return "TLS", f"{type(e).__name__}: {e}"


def main():
    status, body = request("device-lab-01")
    check("geçerli cihaz GET /device/status -> 200", status == 200, (status, body))
    status, body = request("device-lab-01", "POST", "/device/signal", {"event": "ok"})
    check("geçerli cihaz POST ok -> 200 risk=low", status == 200 and '"risk": "low"' in body, (status, body))
    status, body = request("device-lab-01", "POST", "/device/signal", {"event": "jailbreak_detected"})
    check("jailbreak olayı -> 200 risk=high", status == 200 and '"risk": "high"' in body, (status, body))
    status, body = request(None)
    check("istemci sertifikası yok -> TLS reddi", status == "TLS", (status, body))
    status, body = request("rogue-device")
    check("başka CA'dan sertifika -> TLS reddi", status == "TLS", (status, body))
    print(f"\nSonuç: {passed} geçti, {failed} kaldı")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
