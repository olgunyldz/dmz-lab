#!/usr/bin/env python3
"""device-trust mTLS testleri (yerel). Önce: bash edge/scripts/gen-device-certs.sh

Senaryolar: geçerli cihaz (ok / jailbreak), sertifikasız istemci (reddedilmeli), başka CA'dan cihaz (reddedilmeli),
iptal edilmiş cihaz (403), bilinmeyen olay (400), GET /device/status.
"""
import http.client
import os
import socket
import ssl
import subprocess
import sys
import tempfile
import time
import json

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER = os.path.join(HERE, "..", "server.py")
CERTS = os.path.join(HERE, "..", "..", "..", "edge", "certs", "device")
PORT = int(os.environ.get("DT_TEST_PORT", "18600"))

passed = failed = 0


def check(name, ok, detail=""):
    global passed, failed
    if ok:
        passed += 1
        print(f"PASS  {name}")
    else:
        failed += 1
        print(f"FAIL  {name}  {detail}")


def cert(name):
    return os.path.join(CERTS, f"{name}.crt"), os.path.join(CERTS, f"{name}.key")


def serial_hex(crt):
    out = subprocess.run(["openssl", "x509", "-noout", "-serial", "-in", crt],
                         capture_output=True, text=True, check=True).stdout.strip()
    return format(int(out.split("=", 1)[1], 16), "X")


def client(name=None, ca_name="device-ca"):
    ctx = ssl.create_default_context(cafile=cert(ca_name)[0])
    if name:
        ctx.load_cert_chain(*cert(name))
    return http.client.HTTPSConnection("127.0.0.1", PORT, context=ctx, timeout=10)


def request(conn, method, path, body=None):
    headers = {"Content-Type": "application/json"}
    conn.request(method, path, body=json.dumps(body) if body is not None else None, headers=headers)
    resp = conn.getresponse()
    data = resp.read()
    conn.close()
    return resp.status, data


def wait_port(proc, timeout=20):
    end = time.time() + timeout
    while time.time() < end:
        if proc.poll() is not None:
            raise RuntimeError("sunucu açılmadı: " + proc.stdout.read().decode(errors="replace"))
        try:
            socket.create_connection(("127.0.0.1", PORT), timeout=1).close()
            return
        except OSError:
            time.sleep(0.3)
    raise RuntimeError("sunucu zaman aşımı")


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    if not os.path.exists(cert("device-trust")[0]):
        print("Sertifikalar yok: bash edge/scripts/gen-device-certs.sh")
        return 2
    revoked = tempfile.NamedTemporaryFile("w", delete=False, suffix=".txt")
    revoked.write(serial_hex(cert("device-lab-02")[0]) + "\n")
    revoked.close()

    env = dict(os.environ, DT_PORT=str(PORT), DT_CERT=cert("device-trust")[0],
               DT_KEY=cert("device-trust")[1], DT_DEVICE_CA=cert("device-ca")[0], DT_REVOKED=revoked.name)
    proc = subprocess.Popen([sys.executable, SERVER], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    try:
        wait_port(proc)

        status, body = request(client("device-lab-01"), "POST", "/device/signal", {"event": "ok"})
        check("geçerli cihaz, olay ok -> 200 / risk low", status == 200 and json.loads(body)["risk"] == "low", body)

        status, body = request(client("device-lab-01"), "POST", "/device/signal", {"event": "jailbreak_detected"})
        check("geçerli cihaz, jailbreak -> 200 / risk high", status == 200 and json.loads(body)["risk"] == "high", body)

        status, body = request(client("device-lab-01"), "GET", "/device/status")
        check("GET /device/status son kararı döner (high)", status == 200 and json.loads(body)["risk"] == "high", body)

        status, body = request(client("device-lab-01"), "POST", "/device/signal", {"event": "bilinmeyen"})
        check("bilinmeyen olay -> 400", status == 400, body)

        for label, conn_factory in [
            ("sertifikasız istemci reddedilir", lambda: client(None)),
            ("başka CA'dan cihaz reddedilir", lambda: client("rogue-device", ca_name="device-ca")),
        ]:
            try:
                status, body = request(conn_factory(), "POST", "/device/signal", {"event": "ok"})
                check(label, False, f"yanıt alındı: HTTP {status}")
            except (ssl.SSLError, OSError) as e:
                check(label, True, type(e).__name__)

        try:
            ctx = ssl.create_default_context(cafile=cert("device-ca")[0])
            ctx.load_cert_chain(*cert("rogue-device"))
            conn = http.client.HTTPSConnection("127.0.0.1", PORT, context=ctx, timeout=10)
            request(conn, "POST", "/device/signal", {"event": "ok"})
            check("sahte CA istemcisi (sunucu CA'sı doğru) reddedilir", False, "yanıt alındı")
        except (ssl.SSLError, OSError) as e:
            check("sahte CA istemcisi (sunucu CA'sı doğru) reddedilir", True, type(e).__name__)

        status, body = request(client("device-lab-02"), "POST", "/device/signal", {"event": "ok"})
        check("iptal edilmiş cihaz -> 403", status == 403, body)
    finally:
        proc.terminate()
        proc.wait(timeout=10)
        os.unlink(revoked.name)

    print(f"\nSonuç: {passed} geçti, {failed} kaldı")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
