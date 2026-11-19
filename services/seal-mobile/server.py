#!/usr/bin/env python3
"""Seal Mobile (VENDOR MOCK, DMZ, ns seal-mobile). SDK'nın konuştuğu mobil backend.

Kimlik ayrımı (tasarım):
  - Kullanıcı adı ve parola YALNIZCA auth-server'de doğrulanır. Seal hiçbir zaman parola görmez/saklamaz.
  - Seal Mobile, mobil uygulamanın auth-server'den aldığı access token'ı (channel=mobile, aud=channel-mobile) doğrular ve
    kullanıcıyı `sub` alanından alır.
  - Seal'a özgü işler: cihaz kaydı (cihaz sertifikası + PIN), PIN doğrulama, aktivasyon.
  - PIN doğrulayıcıları Fortuna legacy monolit içinde (/seal-pm/*): yalnızca kullanıcı + cihaz başına PIN doğrulayıcısı tutulur.

Cihaz: SDK cihaza özel istemci sertifikasıyla bağlanır (mTLS, CERT_REQUIRED, cihaz CA). TLS DMZ gateway'de
sonlanmaz (HAProxy -> gw-seal passthrough); cihaz kimliği bu pod'da doğrulanır.

Uç noktalar (Authorization: Bearer <auth-server access token>):
  POST /seal/mobile/v1/device/enroll       {pin}              -> PIN'i cihaz+kullanıcı için kaydeder (PM)
  POST /seal/mobile/v1/login/begin         {}                 -> {flowId}  (sub + cihaz CN'ine bağlı)
  POST /seal/mobile/v1/login/pin           {flowId, pin}      -> PIN_OK (+challenge) / NEW_DEVICE / PIN_EXPIRED / PIN_LOCKED / PIN_INVALID
  POST /seal/mobile/v1/login/authorize     {flowId, authorizationId, signature} -> PIN_AUTHORIZED (cihaz imzası, tek kullanım)

İç çağrılar: gw-internal (DMZ istemci sertifikasıyla mTLS). auth-server (auth-server, bank-prod) HTTPS NodePort (iç CA).

Ortam: SM_PORT, SM_TLS_CERT/KEY, SM_DEVICE_CA, SM_CA, SM_CLIENT_CERT/KEY, SM_INTERNAL, SM_MOCK_KEY, SM_PM_KEY,
       SM_AUTH_URL (IP:port), SM_AUTH_HOST, SM_ISSUER, SM_AUDIENCE (channel-mobile), SM_CHANNEL (mobile).
LAB SINIRI: flow ve aktivasyon bellekte; PIN taşıma hash'i (sha256) vendor'ın gerçek protokolü değildir.
"""
import base64
import hashlib
import http.client
import json
import os
import socket
import ssl
import threading
import time
import urllib.parse
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import jwt
from cryptography import x509
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import padding

import tracing  # ConfigMap ile /app/tracing.py (shared/tracing.py)

_CUR = threading.local()  # istek işlenirken aktif server span'i

INTERNAL = os.environ.get("SM_INTERNAL", "internal-gw.seal-mobile.svc:443")
# Doğrudan bağlantı (bank-prod/mgmt): auth-server ve Password Manager ayrı host:port ve SNI ile
AUTH_HOSTPORT = os.environ.get("SM_AUTH", INTERNAL)
AUTH_SNI = os.environ.get("SM_AUTH_SNI", "gw-internal")
PM_HOSTPORT = os.environ.get("SM_PM", INTERNAL)
PM_SNI = os.environ.get("SM_PM_SNI", "gw-internal")
PM_KEY = os.environ.get("SM_PM_KEY", "")
MOCK_KEY = os.environ.get("SM_MOCK_KEY", "")
# Seal Intranet (vendor mock): akış durumu yazılır (Fortuna getLoginStatus bu durumu okur)
SI_HOSTPORT = os.environ.get("SM_SI", "seal-intranet.seal-intranet.svc:8443")
SI_SNI = os.environ.get("SM_SI_SNI", "seal-intranet.seal-intranet.svc")
ISSUER = os.environ.get("SM_ISSUER", "https://id.bank.lab.local/realms/bank")
AUDIENCE = os.environ.get("SM_AUDIENCE", "channel-mobile")
CHANNEL = os.environ.get("SM_CHANNEL", "mobile")
CLIENT_ID = "seal-mobile"  # auth-server istemcisi (SM_MOBILE_SECRET): yalnız introspection
FLOWS = {}   # flowId -> {device, userId, created}
JWKS = {"set": None, "exp": 0}
LOCK = threading.Lock()
FLOW_TTL = 300


class Unauthorized(Exception):
    pass


def tls_socket(host, port, server_name, ca):
    ctx = ssl.create_default_context(cafile=ca)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    return ctx, socket.create_connection((host, int(port)), timeout=10), server_name


def https_post_json(host, port, server_name, path, body, headers, ca, client=None):
    ctx = ssl.create_default_context(cafile=ca)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    if client:
        ctx.load_cert_chain(client[0], client[1])
    conn = http.client.HTTPSConnection(host, int(port), timeout=10)
    conn.sock = ctx.wrap_socket(socket.create_connection((host, int(port)), timeout=10), server_hostname=server_name)
    conn.request("POST", path, body=json.dumps(body).encode(),
                 headers={"Host": server_name, "Content-Type": "application/json", **headers})
    resp = conn.getresponse()
    data = json.loads(resp.read() or b"{}")
    conn.close()
    return resp.status, data


def child_span(name, peer):
    # Aktif server span'inden istemci span'i; istek dışında (ör. açılış) None
    parent = getattr(_CUR, "span", None)
    return tracing.start_client_span(name, parent, {"peer.service": peer}) if parent else None


def gw_request(method, path, headers, body):
    """DMZ -> gw-internal (mTLS, DMZ istemci sertifikası). auth-server'ye doğrudan bağlantı YOK: yol gateway üzerinden."""
    host, port = AUTH_HOSTPORT.rsplit(":", 1)
    child = child_span(f"seal-mobile -> auth {path}", AUTH_SNI)
    if child:
        headers = {**headers, "traceparent": child.header()}
    ctx = ssl.create_default_context(cafile=os.environ["SM_CA"])
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(os.environ["SM_CLIENT_CERT"], os.environ["SM_CLIENT_KEY"])
    conn = http.client.HTTPSConnection(host, int(port), timeout=10)
    conn.sock = ctx.wrap_socket(socket.create_connection((host, int(port)), timeout=10), server_hostname=AUTH_SNI)
    conn.request(method, path, body=body, headers={"Host": AUTH_SNI, **headers})
    resp = conn.getresponse()
    data = resp.read()
    conn.close()
    if child:
        child.end(http_status=resp.status)
    return resp.status, data


def auth_keys():
    """auth-server JWKS (önbellekli, 300 sn): gw-internal -> auth-server (HTTPS)."""
    with LOCK:
        if JWKS["set"] and time.time() < JWKS["exp"]:
            return JWKS["set"]
    st, data = gw_request("GET", "/realms/bank/protocol/openid-connect/certs", {}, None)
    if st != 200:
        raise Unauthorized("auth-server anahtarları alınamadı")
    keyset = jwt.PyJWKSet.from_dict(json.loads(data))
    with LOCK:
        JWKS.update(set=keyset, exp=time.time() + 300)
    return keyset


def auth_active(token):
    """auth-server introspection (RFC 7662) gw-internal üzerinden: oturum hâlâ aktif mi (tek aktif giriş)."""
    basic = base64.b64encode(f"{CLIENT_ID}:{os.environ['SM_MOBILE_SECRET']}".encode()).decode()
    body = urllib.parse.urlencode({"token": token, "token_type_hint": "access_token"}).encode()
    st, data = gw_request("POST", "/realms/bank/protocol/openid-connect/token/introspect",
                          {"Authorization": "Basic " + basic, "Content-Type": "application/x-www-form-urlencoded"}, body)
    if st != 200:
        raise Unauthorized("introspection başarısız")
    return bool(json.loads(data or b"{}").get("active"))


def require_user(headers):
    """auth-server access token'ını doğrular: imza/iss/aud/kanal, oturum aktif. Dönüş: sub."""
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
    if claims.get("channel") != CHANNEL:
        raise Unauthorized("token mobil kanala ait değil")
    if not auth_active(token):
        raise Unauthorized("oturum sonlanmış (başka bir kanalda giriş yapıldı)")
    return claims["sub"]


def internal_call(method, path, body, extra_headers):
    # PIN yolları (/seal-pm/) Fortuna monolitine, diğerleri auth-server'ye (internal uçlar)
    hostport, sni = (PM_HOSTPORT, PM_SNI) if path.startswith("/seal-pm/") else (AUTH_HOSTPORT, AUTH_SNI)
    host, port = hostport.rsplit(":", 1)
    child = child_span(f"seal-mobile -> {sni} {path}", sni)
    headers = dict(extra_headers)
    if child:
        headers["traceparent"] = child.header()
    st, data = https_post_json(host, port, sni, path, body, headers, os.environ["SM_CA"],
                               client=(os.environ["SM_CLIENT_CERT"], os.environ["SM_CLIENT_KEY"]))
    if child:
        child.end(http_status=st)
    return st, data


def si_flow(flow_id, user, status, new_device):
    host, port = SI_HOSTPORT.rsplit(":", 1)
    try:
        st, _ = https_post_json(host, port, SI_SNI, "/seal-v3/mock/flow",
                                {"flowId": flow_id, "ownerId": user, "status": status, "newDevice": new_device},
                                {"X-Seal-Key": MOCK_KEY}, os.environ["SM_CA"])
    except (OSError, ValueError):
        return False
    return st == 200


def device_public_key(sock):
    """Bağlantıdaki cihaz sertifikasının açık anahtarı (TLS el sıkışmasında doğrulanmış)."""
    der = sock.getpeercert(binary_form=True)
    return x509.load_der_x509_certificate(der).public_key()


def device_cn(sock):
    cert = sock.getpeercert()
    for rdn in (cert or {}).get("subject", ()):
        for k, v in rdn:
            if k == "commonName":
                return v
    return None


def pin_hash(pin):
    return hashlib.sha256(str(pin).encode()).hexdigest()


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
    server_version = "seal-mobile"

    def _json(self, code, obj):
        _count(self.command, self.path, code)
        self._status = code
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

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        span = tracing.start_server_span(f"seal-mobile POST {path}", self.headers.get("traceparent"),
                                         {"http.method": "POST", "http.target": path})
        self._span = span
        self._status = None
        _CUR.span = span
        try:
            self._post()
        finally:
            _CUR.span = None
            span.end(http_status=self._status)

    def _post(self):
        dev = device_cn(self.connection)
        if not dev:
            return self._json(401, {"error": "cihaz kimliği yok"})
        try:
            user = require_user(self.headers)
        except Unauthorized as e:
            return self._json(401, {"error": str(e)})
        self._span.set("user.hash", tracing.user_hash(user))
        self._span.set("device.cn", dev)
        req = self._body()
        if req is None:
            return self._json(400, {"error": "geçersiz JSON"})

        if self.path == "/seal/mobile/v1/device/enroll":
            if not req.get("pin"):
                return self._json(400, {"error": "pin gerekli"})
            st, _ = internal_call("POST", "/seal-pm/v1/pin/set",
                                  {"userId": user, "deviceId": dev, "pin": pin_hash(req["pin"])},
                                  {"X-Seal-Key": PM_KEY})
            if st != 200:
                return self._json(502, {"status": "FAILED"})
            # Cihaz kaydı auth-server'ye bildirilir: bu kullanıcının web girişleri artık bu cihaza onay ister
            return self._json(200, {"status": "ENROLLED"})

        if self.path == "/seal/mobile/v1/login/begin":
            flow = str(uuid.uuid4())
            with LOCK:
                FLOWS[flow] = {"device": dev, "userId": user, "created": time.time()}
            return self._json(200, {"flowId": flow, "status": "PIN_REQUIRED"})

        if self.path == "/seal/mobile/v1/login/pin":
            with LOCK:
                flow = FLOWS.get(req.get("flowId", ""))
            if not flow or time.time() - flow["created"] > FLOW_TTL:
                return self._json(404, {"error": "flow yok veya süresi doldu"})
            if flow["device"] != dev or flow["userId"] != user:
                return self._json(403, {"error": "flow bu cihaza/kullanıcıya ait değil"})
            st, pm = internal_call("POST", "/seal-pm/v1/pin/verify",
                                   {"userId": user, "deviceId": dev, "pin": pin_hash(req.get("pin", ""))},
                                   {"X-Seal-Key": PM_KEY})
            if st != 200:
                return self._json(502, {"error": "PM erişilemedi"})
            if not pm.get("enrolled"):
                status = "NEW_DEVICE"        # bu cihaz kayıtlı değil: PIN doğrulanmaz, OTP/aktivasyon gerekir
            elif pm.get("locked"):
                status = "PIN_LOCKED"
            elif pm.get("expired"):
                status = "PIN_EXPIRED"       # PIN geçerlilik süresi doldu (PIN değişimi gerekir)
            elif pm.get("ok"):
                status = "PIN_OK"            # yetkilendirme adımı bekleniyor (cihaz imzası)
            else:
                status = "PIN_INVALID"
            # Yeni cihaz da PIN doğrulanmış sayılır ve cihaz imzası ister (PIN_AUTHORIZED); OTP Janus/SmsOtpCGW'de
            pin_ok = status in ("PIN_OK", "NEW_DEVICE")
            with LOCK:
                flow["status"] = "PIN_OK" if pin_ok else status
                flow["newDevice"] = status == "NEW_DEVICE"
                if pin_ok:
                    flow["authId"] = str(uuid.uuid4())
                    flow["nonce"] = base64.urlsafe_b64encode(os.urandom(24)).decode()
                    flow["authExp"] = time.time() + 60
                    flow["authUsed"] = False
            si_flow(req["flowId"], user, status, status == "NEW_DEVICE")
            if pin_ok:
                return self._json(200, {"flowId": req["flowId"], "status": status,
                                        "authorizationId": flow["authId"], "nonce": flow["nonce"]})
            return self._json(200, {"flowId": req["flowId"], "status": status})

        if self.path == "/seal/mobile/v1/login/authorize":
            # Vendor'daki authorizeTransaction karşılığı: cihaz, challenge'ı kendi anahtarıyla imzalar.
            with LOCK:
                flow = FLOWS.get(req.get("flowId", ""))
            if not flow or time.time() - flow["created"] > FLOW_TTL:
                return self._json(404, {"error": "flow yok veya süresi doldu"})
            if flow["device"] != dev or flow["userId"] != user:
                return self._json(403, {"error": "flow bu cihaza/kullanıcıya ait değil"})
            with LOCK:
                if flow.get("status") != "PIN_OK":
                    return self._json(409, {"error": "PIN doğrulaması tamamlanmadı"})
                if (req.get("authorizationId") != flow.get("authId") or flow.get("authUsed")
                        or time.time() > flow.get("authExp", 0)):
                    return self._json(403, {"error": "yetkilendirme geçersiz, kullanılmış veya süresi dolmuş"})
                flow["authUsed"] = True  # tek kullanımlık
            try:
                sig = base64.b64decode(req.get("signature", ""))
                device_public_key(self.connection).verify(sig, flow["nonce"].encode(), padding.PKCS1v15(),
                                                          hashes.SHA256())
            except (InvalidSignature, ValueError, TypeError):
                return self._json(401, {"error": "cihaz imzası geçersiz"})
            with LOCK:
                flow["status"] = "PIN_AUTHORIZED"
            # Yeni cihaz: PIN_AUTHORIZED (aktivasyon sürer); kayıtlı/aktif cihaz: SEAL_AUTHORIZED
            si_flow(req["flowId"], user, "PIN_AUTHORIZED" if flow.get("newDevice") else "SEAL_AUTHORIZED",
                    bool(flow.get("newDevice")))
            return self._json(200, {"flowId": req["flowId"], "status": "PIN_AUTHORIZED"})

        self._json(404, {"error": "bulunamadı"})

    def log_message(self, fmt, *args):
        pass


def main():
    port = int(os.environ.get("SM_PORT", "8443"))
    httpd = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    _start_metrics(int(os.environ.get("SM_METRICS_PORT", "9100")), "seal-mobile")
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(os.environ["SM_TLS_CERT"], os.environ["SM_TLS_KEY"])
    ctx.load_verify_locations(os.environ["SM_DEVICE_CA"])
    ctx.verify_mode = ssl.CERT_REQUIRED
    httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
    print(f"seal-mobile dinliyor (port {port})", flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
