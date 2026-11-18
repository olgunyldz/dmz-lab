#!/usr/bin/env python3
"""Password Manager (VENDOR MOCK, identity cluster, ns seal-pm). YALNIZCA mobil PIN doğrulayıcıları.

Kapsam: kullanıcı parolası BURADA YOK. Kullanıcı adı/parola doğrulaması IdP'de yapılır.
Saklanan kayıt: (userId, deviceId) -> PIN doğrulayıcısı (salted scrypt). Girdi, Seal Mobile'ın gönderdiği
taşıma hash'i (sha256(pin)); düz PIN hiçbir zaman saklanmaz.
Kilit: aynı (userId, deviceId) için MAX_FAILS ardışık yanlış denemeden sonra PIN kilitlenir.
Erişim: yalnızca gw-internal üzerinden, X-Seal-Key ile korunur (PM_KEY).

Uç noktalar (HTTPS, iç CA):
  POST /seal-pm/v1/pin/set     {userId, deviceId, pin, validitySeconds?}  -> {status}
  POST /seal-pm/v1/pin/verify  {userId, deviceId, pin}  -> {ok, locked, enrolled, expired}
    enrolled=false: bu (kullanıcı, cihaz) için PIN yok (yeni cihaz); expired=true: PIN geçerlilik süresi dolmuş.

LAB SINIRI: bellekte tutulur; vendor davranışı değildir.
"""
import hashlib
import hmac
import json
import os
import secrets
import ssl
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MAX_FAILS = 5
DEFAULT_VALIDITY = int(os.environ.get("PM_VALIDITY_SECONDS", str(90 * 24 * 3600)))  # PIN geçerlilik süresi
KEY = os.environ.get("PM_KEY", "")
PINS = {}  # (userId, deviceId) -> {salt, hash, fails}
LOCK = threading.Lock()


def derive(pin, salt):
    return hashlib.scrypt(pin.encode(), salt=salt, n=2 ** 14, r=8, p=1, dklen=32)


class Handler(BaseHTTPRequestHandler):
    server_version = "password-manager"

    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        sent = self.headers.get("X-Seal-Key", "")
        if not KEY or not hmac.compare_digest(sent.encode(), KEY.encode()):
            return self._json(401, {"error": "anahtar geçersiz"})
        if self.path not in ("/seal-pm/v1/pin/set", "/seal-pm/v1/pin/verify"):
            return self._json(404, {"error": "bulunamadı"})  # kaldırılmış parola uçları dahil
        length = int(self.headers.get("Content-Length", "0") or 0)
        try:
            req = json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            return self._json(400, {"error": "geçersiz JSON"})
        user, dev, pin = req.get("userId", ""), req.get("deviceId", ""), req.get("pin", "")
        if not user or not dev or not pin:
            return self._json(400, {"error": "userId, deviceId ve pin gerekli"})
        key = (user, dev)
        if self.path == "/seal-pm/v1/pin/set":
            salt = secrets.token_bytes(16)
            validity = int(req.get("validitySeconds") or DEFAULT_VALIDITY)
            with LOCK:
                PINS[key] = {"salt": salt, "hash": derive(pin, salt), "fails": 0,
                             "expires": time.time() + validity}
            return self._json(200, {"status": "ok"})
        if self.path == "/seal-pm/v1/pin/verify":
            with LOCK:
                rec = PINS.get(key)
                if not rec:
                    return self._json(200, {"ok": False, "locked": False, "enrolled": False, "expired": False})
                if rec["fails"] >= MAX_FAILS:
                    return self._json(200, {"ok": False, "locked": True, "enrolled": True, "expired": False})
                if time.time() > rec["expires"]:
                    return self._json(200, {"ok": False, "locked": False, "enrolled": True, "expired": True})
                good = hmac.compare_digest(derive(pin, rec["salt"]), rec["hash"])
                rec["fails"] = 0 if good else rec["fails"] + 1
                return self._json(200, {"ok": good, "locked": rec["fails"] >= MAX_FAILS,
                                        "enrolled": True, "expired": False})
        self._json(404, {"error": "bulunamadı"})

    def log_message(self, fmt, *args):
        pass


def main():
    port = int(os.environ.get("PM_PORT", "8443"))
    httpd = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(os.environ["PM_TLS_CERT"], os.environ["PM_TLS_KEY"])
    httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
    print(f"password-manager dinliyor (port {port})", flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
