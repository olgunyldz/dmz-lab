#!/usr/bin/env python3
"""Seal Intranet (ayrı servis, VENDOR MOCK). Backend-to-backend API; yalnızca iç ağdan erişilir.

Kimlik: çağıran backend, auth-server'den client_credentials ile aldığı erişim token'ını taşır (RS256, JWKS ile doğrulanır;
iss, exp, sub, aud zorunlu; aud = seal-intranet; istemci SI_ALLOWED_CLIENTS içinde olmalı).

TLS: SI_TLS_CERT / SI_TLS_KEY verilirse HTTPS (TLS 1.2+). Düz HTTP yalnızca ortam değişkenleri verilmezse (yerel test).

Uç noktalar (sunucu, JWT gerekir):
  GET  /seal/v1/health                                              kimlik gerekmez
  GET  /seal/v1/whoami                                              çağıranın kimliği
  POST /seal/v1/signing/requests                                    imza isteği kabulü (STUB)
  POST /seal-v3/server/integration/login-api/get-login-status       {flowId}
  POST /seal-v3/server/integration/timestamp-api/create-timestamp   {flowId}
  POST /seal-v3/server/integration/activation-api/create-activation-token  {ownerId, userIdentifiers, pinRequestType}
  POST /seal-v3/server/integration/activation-api/get-activation-status    {activationToken}
  POST /seal-v3/server/integration/device-api/update-device                {ownerId, deviceId, status?}  (cihaz kaydı + durum)
  POST /seal-v3/server/integration/device-api/get-device                   {deviceId}  (cihaz durumu okuma)

Mock yazma uçları (vendor'ın Seal Mobile tarafı durumu bildirir; X-Seal-Key ile korunur, SI_MOCK_KEY):
  POST /seal-v3/mock/flow        {flowId, ownerId, status}
  POST /seal-v3/mock/activation  {activationToken, status}

LAB SINIRLARI: durum bellekte (yeniden başlatmada kaybolur); gerçek vendor davranışı değildir.
"""
import hmac
import json
import os
import ssl
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import http.client
import socket
import jwt

os.environ.setdefault("SERVICE_NAME", "seal-intranet")
import tracing  # /app/tracing.py (shared/tracing.py; build bağlamında kopyalanır)

ISSUER = os.environ.get("SI_ISSUER", "")
AUDIENCE = os.environ.get("SI_AUDIENCE", "seal-intranet")
ALLOWED = set(filter(None, os.environ.get("SI_ALLOWED_CLIENTS", "seal-b2b").split(",")))
MOCK_KEY = os.environ.get("SI_MOCK_KEY", "")
AUTH_IP, AUTH_PORT = os.environ.get("SI_AUTH_URL", "127.0.0.1:8443").rsplit(":", 1)
AUTH_HOST = os.environ.get("SI_AUTH_HOST", "id.bank.lab.local")
JWKS = {"set": None, "exp": 0}
JWKS_LOCK = threading.Lock()


def auth_keys():
    """auth-server JWKS: yalnız iç CA ile doğrulanmış HTTPS (SNI id.bank.lab.local). 300 sn önbellek."""
    with JWKS_LOCK:
        if JWKS["set"] and time.time() < JWKS["exp"]:
            return JWKS["set"]
    ctx = ssl.create_default_context(cafile=os.environ["SI_CA"])
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    conn = http.client.HTTPSConnection(AUTH_IP, int(AUTH_PORT), timeout=10)
    conn.sock = ctx.wrap_socket(socket.create_connection((AUTH_IP, int(AUTH_PORT)), timeout=10),
                                server_hostname=AUTH_HOST)
    conn.request("GET", "/realms/bank/protocol/openid-connect/certs", headers={"Host": AUTH_HOST})
    resp = conn.getresponse()
    data = json.loads(resp.read() or b"{}")
    conn.close()
    if resp.status != 200:
        raise Unauthorized("auth-server anahtarları alınamadı")
    keyset = jwt.PyJWKSet.from_dict(data)
    with JWKS_LOCK:
        JWKS.update(set=keyset, exp=time.time() + 300)
    return keyset

REQUESTS = {}     # imza istekleri (stub)
FLOWS = {}        # flowId -> {ownerId, status, updated}
ACTIVATIONS = {}  # activationToken -> {ownerId, status, updated}
# Cihaz kaydı (Seal'in kendi kaydı, cihaz durumunun tek kaynağı): deviceId -> {ownerId, status, updated}
# LAB SINIRI: bellekte; yeniden başlatmada kayıtlar silinir.
DEVICES = {}
LOCK = threading.Lock()


class Unauthorized(Exception):
    pass


def authenticate(headers):
    auth = headers.get("Authorization", "")
    if not auth.startswith("Bearer "):
        raise Unauthorized("bearer token yok")
    token = auth[len("Bearer "):]
    try:
        kid = jwt.get_unverified_header(token).get("kid")
        key = next(k.key for k in auth_keys().keys if k.key_id == kid)
        claims = jwt.decode(token, key, algorithms=["RS256"], issuer=ISSUER, audience=AUDIENCE,
                            options={"require": ["exp", "iss", "sub", "aud"]})
    except (jwt.PyJWTError, StopIteration) as e:
        raise Unauthorized(f"token geçersiz: {type(e).__name__}")
    if client_id(claims) not in ALLOWED:
        raise Unauthorized("istemci yetkili değil")
    return claims


def client_id(claims):
    # client_credentials token'larında azp yok; istemci kimliği sub'dadır
    return claims.get("azp") or claims.get("sub")


def mock_ok(headers):
    sent = headers.get("X-Seal-Key", "")
    return bool(MOCK_KEY) and hmac.compare_digest(sent.encode(), MOCK_KEY.encode())


# Prometheus metrikleri: düz HTTP, ayrı port (ana port mTLS olsa da kazıma için). İstekler kodlara göre sayılır.
import threading as _mt
_METRICS = {}
_METRICS_LOCK = _mt.Lock()


def _count(method, path, code):
    key = (method, path.split("?")[0], int(code))
    with _METRICS_LOCK:
        _METRICS[key] = _METRICS.get(key, 0) + 1


def _metrics_body(service):
    lines = ["# HELP http_requests_total HTTP istek sayısı", "# TYPE http_requests_total counter"]
    with _METRICS_LOCK:
        items = sorted(_METRICS.items())
    for (m, p, c), n in items:
        lines.append(f'http_requests_total{{service="{service}",method="{m}",path="{p}",code="{c}"}} {n}')
    return ("\n".join(lines) + "\n").encode()


def _start_metrics(port, service):
    class _MetricsOnly(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path.split("?")[0] == "/metrics":
                body = _metrics_body(service)
                self.send_response(200)
                self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()

        def log_message(self, fmt, *args):
            pass

    srv = ThreadingHTTPServer(("0.0.0.0", port), _MetricsOnly)
    _mt.Thread(target=srv.serve_forever, daemon=True).start()


class Handler(BaseHTTPRequestHandler):
    server_version = "seal-intranet"

    def _json(self, code, obj):
        _count(self.command, self.path, code)
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _body(self):
        length = int(self.headers.get("Content-Length", "0") or 0)
        try:
            return json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            return None

    def _guard(self):
        try:
            return authenticate(self.headers)
        except Unauthorized as e:
            self._json(401, {"error": str(e)})
            return None

    def do_GET(self):
        # Akışta GET ucu yok; yalnızca akış uçları (POST) sunulur
        self._json(404, {"error": "bulunamadı"})

    def do_POST(self):
        if self.path.startswith("/seal-v3/mock/"):
            return self._mock_write()
        if self.path.startswith("/seal-v3/server/integration/"):
            return self._v3()
        self._json(404, {"error": "bulunamadı"})

    def _signing(self):
        claims = self._guard()
        if not claims:
            return
        req = self._body()
        if req is None:
            return self._json(400, {"error": "geçersiz JSON"})
        if not req.get("document_id"):
            return self._json(400, {"error": "document_id gerekli"})
        rid = str(uuid.uuid4())
        with LOCK:
            REQUESTS[rid] = {"document_id": req["document_id"], "client": client_id(claims), "at": int(time.time())}
        self._json(202, {"request_id": rid, "status": "accepted"})

    def _v3(self):
        claims = self._guard()
        if not claims:
            return
        req = self._body()
        if req is None:
            return self._json(400, {"error": "geçersiz JSON"})
        op = self.path.rsplit("/", 1)[-1]
        if op == "get-login-status":
            with LOCK:
                flow = FLOWS.get(req.get("flowId", ""))
            if not flow:
                return self._json(404, {"error": "flow bulunamadı"})
            return self._json(200, {"ownerId": flow["ownerId"], "status": flow["status"],
                                    "newDevice": flow.get("newDevice", False),
                                    "remainingTime": 300, "pinLockStatus": "NONE", "deviceLockStatus": "NONE"})
        if op == "create-timestamp":
            return self._json(200, {"timestamp": int(time.time())})
        if op == "create-activation-token":
            if not req.get("ownerId"):
                return self._json(400, {"error": "ownerId gerekli"})
            token = uuid.uuid4().hex
            with LOCK:
                ACTIVATIONS[token] = {"ownerId": req["ownerId"], "status": "PENDING", "updated": int(time.time())}
            return self._json(200, {"activationToken": token})
        if op == "update-device":
            # Cihaz kaydı: sahip, cihaz ve durum (PENDING | ACTIVE | LOCKED | REVOKED). Durum verilmezse korunur.
            owner, dev = str(req.get("ownerId", "")), str(req.get("deviceId", ""))
            status = req.get("status")
            if not owner or not dev:
                return self._json(400, {"error": "ownerId ve deviceId gerekli"})
            if status is not None and status not in ("PENDING", "ACTIVE", "LOCKED", "REVOKED"):
                return self._json(400, {"error": "geçersiz durum"})
            with LOCK:
                rec = DEVICES.get(dev, {"ownerId": owner, "status": None})
                if rec["ownerId"] != owner:
                    return self._json(409, {"error": "cihaz başka bir sahibe ait"})
                rec.update(ownerId=owner, updated=int(time.time()))
                if status is not None:
                    rec["status"] = status
                DEVICES[dev] = rec
            return self._json(200, {"deviceId": dev, "status": rec["status"]})
        if op == "get-device":
            # Cihaz durumu okuma (Janus mobil giriş ve yenileme kontrolü, Fortuna monolit üzerinden)
            dev = str(req.get("deviceId", ""))
            with LOCK:
                rec = DEVICES.get(dev)
            if not rec:
                return self._json(404, {"error": "cihaz kaydı yok"})
            return self._json(200, {"deviceId": dev, "ownerId": rec["ownerId"], "status": rec["status"]})
        if op == "get-activation-status":
            with LOCK:
                act = ACTIVATIONS.get(req.get("activationToken", ""))
                if act and act["status"] == "PENDING":
                    # Mock kuralı: owner'ın yeni cihazı PIN + cihaz imzasıyla yetkilendirmiş olması (PIN_AUTHORIZED) aktivasyonu tamamlar
                    flow = next((f for f in FLOWS.values() if f["ownerId"] == act["ownerId"] and f["newDevice"]
                                 and f["status"] == "PIN_AUTHORIZED"), None)
                    if flow:
                        act["status"] = "ACTIVATED"
                        act["updated"] = int(time.time())
            if not act:
                return self._json(404, {"error": "token bulunamadı"})
            return self._json(200, {"ownerId": act["ownerId"], "status": act["status"], "remainingTime": 600})
        self._json(404, {"error": "bulunamadı"})

    def _mock_write(self):
        if not mock_ok(self.headers):
            return self._json(401, {"error": "mock anahtarı geçersiz"})
        req = self._body()
        if req is None:
            return self._json(400, {"error": "geçersiz JSON"})
        if self.path == "/seal-v3/mock/flow":
            with LOCK:
                FLOWS[req.get("flowId", "")] = {"ownerId": req.get("ownerId", ""), "status": req.get("status", ""),
                                                "newDevice": bool(req.get("newDevice")),
                                                "updated": int(time.time())}
            return self._json(200, {"status": "ok"})
        if self.path == "/seal-v3/mock/activation":
            with LOCK:
                if req.get("activationToken") in ACTIVATIONS:
                    ACTIVATIONS[req["activationToken"]]["status"] = req.get("status", "")
                    ACTIVATIONS[req["activationToken"]]["updated"] = int(time.time())
                    return self._json(200, {"status": "ok"})
            return self._json(404, {"error": "token bulunamadı"})
        self._json(404, {"error": "bulunamadı"})

    def log_message(self, fmt, *args):
        pass


def main():
    port = int(os.environ.get("SI_PORT", "8080"))
    tracing.instrument(Handler)
    httpd = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    _start_metrics(int(os.environ.get("SI_METRICS_PORT", "9100")), "seal-intranet")
    cert, key = os.environ.get("SI_TLS_CERT"), os.environ.get("SI_TLS_KEY")
    if cert and key:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2
        ctx.load_cert_chain(cert, key)
        httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
    print(f"seal-intranet dinliyor (port {port}, tls={'evet' if cert and key else 'hayır'})", flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
