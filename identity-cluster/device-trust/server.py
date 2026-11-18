#!/usr/bin/env python3
"""Cihaz güven servisi (örnek, Seçenek A). Identity cluster'da çalışır.

Akış: mobil cihaz -> DMZ (L4 passthrough, TLS açılmaz) -> bu servis.
Cihaz kimliği, cihaza özel istemci sertifikasıdır. Sunucu istemci sertifikasını KENDİSİ doğrular
(CERT_REQUIRED + cihaz CA'sı); DMZ bu doğrulamaya dahil değildir.

Ortam değişkenleri:
  DT_PORT         dinlenecek port (varsayılan 8443)
  DT_CERT, DT_KEY sunucu sertifikası ve anahtarı (PEM)
  DT_DEVICE_CA    cihaz CA sertifikası (PEM); yalnız bu CA'nın imzaladığı istemciler kabul edilir
  DT_REVOKED      (ops.) iptal edilmiş sertifika seri numaraları, satır başına bir tane (hex)

Uç noktalar:
  POST /device/signal   JSON {"event": "ok" | "jailbreak_detected" | "root_detected" | "attestation_failed"}
  GET  /device/status   bu cihazın son risk kararı

LAB SINIRI: attestation (Apple App Attest / Google Play Integrity) doğrulanmıyor; olay yalnız kayıt altına alınır.
"""
import json
import os
import ssl
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HIGH_RISK_EVENTS = {"jailbreak_detected", "root_detected", "attestation_failed"}
KNOWN_EVENTS = HIGH_RISK_EVENTS | {"ok"}

STATE = {}          # cihaz CN -> son karar
REVOKED = set()     # iptal edilmiş seri numaraları (büyük harf hex)
LOCK = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    server_version = "device-trust"

    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _identity(self):
        """İstemci sertifikasından (doğrulanmış) cihaz CN'i ve seri numarasını döndürür."""
        cert = self.connection.getpeercert()
        if not cert:
            return None, None
        cn = None
        for rdn in cert.get("subject", ()):
            for key, value in rdn:
                if key == "commonName":
                    cn = value
        return cn, (cert.get("serialNumber") or "").upper()

    def do_POST(self):
        if self.path != "/device/signal":
            return self._json(404, {"error": "bulunamadı"})
        cn, serial = self._identity()
        if cn is None:
            return self._json(401, {"error": "cihaz kimliği yok"})
        if serial in REVOKED:
            return self._json(403, {"error": "cihaz iptal edildi", "device": cn})
        length = int(self.headers.get("Content-Length", "0") or 0)
        try:
            req = json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            return self._json(400, {"error": "geçersiz JSON"})
        event = req.get("event", "")
        if event not in KNOWN_EVENTS:
            return self._json(400, {"error": "bilinmeyen olay", "device": cn})
        risk = "high" if event in HIGH_RISK_EVENTS else "low"
        decision = {"device": cn, "risk": risk, "reason": event, "at": int(time.time())}
        with LOCK:
            STATE[cn] = decision
        self._json(200, decision)

    def do_GET(self):
        if self.path != "/device/status":
            return self._json(404, {"error": "bulunamadı"})
        cn, serial = self._identity()
        if cn is None:
            return self._json(401, {"error": "cihaz kimliği yok"})
        if serial in REVOKED:
            return self._json(403, {"error": "cihaz iptal edildi", "device": cn})
        with LOCK:
            decision = STATE.get(cn, {"device": cn, "risk": "unknown", "reason": "henüz olay yok"})
        self._json(200, decision)

    def log_message(self, fmt, *args):
        # Kişisel veri (cihaz kimliği, IP) log'a yazılmaz; yalnız istek sayısı görünür
        pass


def load_revoked(path):
    if not path or not os.path.exists(path):
        return set()
    with open(path, encoding="utf-8") as f:
        return {line.strip().upper() for line in f if line.strip()}


def main():
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(os.environ["DT_CERT"], os.environ["DT_KEY"])
    ctx.load_verify_locations(os.environ["DT_DEVICE_CA"])
    ctx.verify_mode = ssl.CERT_REQUIRED
    REVOKED.update(load_revoked(os.environ.get("DT_REVOKED")))
    httpd = ThreadingHTTPServer(("0.0.0.0", int(os.environ.get("DT_PORT", "8443"))), Handler)
    httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
    print(f"device-trust dinliyor (port {httpd.server_address[1]}, iptal {len(REVOKED)} seri)", flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
