#!/usr/bin/env python3
"""Seal Mobile (VENDOR MOCK, DMZ, ns seal-mobile). SDK'nın konuştuğu mobil backend.

Kimlik ayrımı (tasarım):
  - Kullanıcı adı ve parola YALNIZCA IdP'de doğrulanır. Seal hiçbir zaman parola görmez/saklamaz.
  - Seal Mobile, mobil uygulamanın IdP'den aldığı access token'ı (channel=mobile, aud=channel-mobile) doğrular ve
    kullanıcıyı `sub` alanından alır.
  - Seal'a özgü işler: cihaz kaydı (cihaz sertifikası + PIN), PIN doğrulama, aktivasyon.
  - Password Manager (seal-pm) yalnızca kullanıcı + cihaz başına PIN doğrulayıcısı tutar.

Cihaz: SDK cihaza özel istemci sertifikasıyla bağlanır (mTLS, CERT_REQUIRED, cihaz CA). TLS DMZ gateway'de
sonlanmaz (HAProxy -> gw-seal passthrough); cihaz kimliği bu pod'da doğrulanır.

Uç noktalar (Authorization: Bearer <IdP access token>):
  POST /seal/mobile/v1/device/enroll       {pin}              -> PIN'i cihaz+kullanıcı için kaydeder (PM)
  POST /seal/mobile/v1/login/begin         {}                 -> {flowId}  (sub + cihaz CN'ine bağlı)
  POST /seal/mobile/v1/login/pin           {flowId, pin}      -> PIN_OK (+challenge) / NEW_DEVICE / PIN_EXPIRED / PIN_LOCKED / PIN_INVALID
  POST /seal/mobile/v1/login/authorize     {flowId, authorizationId, signature} -> PIN_AUTHORIZED (cihaz imzası, tek kullanım)
  POST /seal/mobile/v1/device/otp          {flowId, otp}      -> OTP_OK (yeni cihaz; IdP doğrular)
  POST /seal/mobile/v1/activation/start    {}                 -> {activationToken} (IdP üretir)
  POST /seal/mobile/v1/activation/complete {activationToken}  -> ACTIVATED (IdP'ye bildirim; kısıt kalkar)

İç çağrılar: gw-internal (DMZ istemci sertifikasıyla mTLS). IdP JWKS: identity HTTPS NodePort (iç CA).

Ortam: SM_PORT, SM_TLS_CERT/KEY, SM_DEVICE_CA, SM_CA, SM_CLIENT_CERT/KEY, SM_INTERNAL, SM_MOCK_KEY, SM_PM_KEY,
       SM_IDP_URL (IP:port), SM_IDP_HOST, SM_ISSUER, SM_AUDIENCE (channel-mobile), SM_CHANNEL (mobile).
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
PM_KEY = os.environ.get("SM_PM_KEY", "")
MOCK_KEY = os.environ.get("SM_MOCK_KEY", "")
ISSUER = os.environ.get("SM_ISSUER", "https://id.bank.lab.local/realms/bank")
AUDIENCE = os.environ.get("SM_AUDIENCE", "channel-mobile")
CHANNEL = os.environ.get("SM_CHANNEL", "mobile")
CLIENT_ID = "seal-mobile"  # IdP istemcisi (SM_MOBILE_SECRET): yalnız introspection
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
    """DMZ -> gw-internal (mTLS, DMZ istemci sertifikası). IdP'ye doğrudan bağlantı YOK: yol gateway üzerinden."""
    host, port = INTERNAL.rsplit(":", 1)
    child = child_span(f"seal-mobile -> gw-internal {path}", "gw-internal")
    if child:
        headers = {**headers, "traceparent": child.header()}
    ctx = ssl.create_default_context(cafile=os.environ["SM_CA"])
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(os.environ["SM_CLIENT_CERT"], os.environ["SM_CLIENT_KEY"])
    conn = http.client.HTTPSConnection(host, int(port), timeout=10)
    conn.sock = ctx.wrap_socket(socket.create_connection((host, int(port)), timeout=10), server_hostname="gw-internal")
    conn.request(method, path, body=body, headers={"Host": "gw-internal", **headers})
    resp = conn.getresponse()
    data = resp.read()
    conn.close()
    if child:
        child.end(http_status=resp.status)
    return resp.status, data


def idp_keys():
    """IdP JWKS (önbellekli, 300 sn): gw-internal -> IdP (HTTPS)."""
    with LOCK:
        if JWKS["set"] and time.time() < JWKS["exp"]:
            return JWKS["set"]
    st, data = gw_request("GET", "/realms/bank/protocol/openid-connect/certs", {}, None)
    if st != 200:
        raise Unauthorized("IdP anahtarları alınamadı")
    keyset = jwt.PyJWKSet.from_dict(json.loads(data))
    with LOCK:
        JWKS.update(set=keyset, exp=time.time() + 300)
    return keyset


def idp_active(token):
    """IdP introspection (RFC 7662) gw-internal üzerinden: oturum hâlâ aktif mi (tek aktif giriş)."""
    basic = base64.b64encode(f"{CLIENT_ID}:{os.environ['SM_MOBILE_SECRET']}".encode()).decode()
    body = urllib.parse.urlencode({"token": token, "token_type_hint": "access_token"}).encode()
    st, data = gw_request("POST", "/realms/bank/protocol/openid-connect/token/introspect",
                          {"Authorization": "Basic " + basic, "Content-Type": "application/x-www-form-urlencoded"}, body)
    if st != 200:
        raise Unauthorized("introspection başarısız")
    return bool(json.loads(data or b"{}").get("active"))


def require_user(headers):
    """IdP access token'ını doğrular: imza/iss/aud/kanal, oturum aktif. Dönüş: sub."""
    auth = headers.get("Authorization", "")
    if not auth.startswith("Bearer "):
        raise Unauthorized("bearer token yok")
    token = auth[len("Bearer "):]
    try:
        kid = jwt.get_unverified_header(token).get("kid")
        key = next(k.key for k in idp_keys().keys if k.key_id == kid)
        claims = jwt.decode(token, key, algorithms=["RS256"], issuer=ISSUER, audience=AUDIENCE,
                            options={"require": ["exp", "iss", "sub", "aud"]})
    except (jwt.PyJWTError, StopIteration) as e:
        raise Unauthorized(f"token geçersiz: {type(e).__name__}")
    if claims.get("channel") != CHANNEL:
        raise Unauthorized("token mobil kanala ait değil")
    if not idp_active(token):
        raise Unauthorized("oturum sonlanmış (başka bir kanalda giriş yapıldı)")
    return claims["sub"]


def internal_call(method, path, body, extra_headers):
    host, port = INTERNAL.rsplit(":", 1)
    child = child_span(f"seal-mobile -> gw-internal {path}", "gw-internal")
    headers = dict(extra_headers)
    if child:
        headers["traceparent"] = child.header()
    st, data = https_post_json(host, port, "gw-internal", path, body, headers, os.environ["SM_CA"],
                               client=(os.environ["SM_CLIENT_CERT"], os.environ["SM_CLIENT_KEY"]))
    if child:
        child.end(http_status=st)
    return st, data


def idp_flow_update(user, flow_id, status, new_device):
    """Login akış durumunu IdP'ye bildirir (IdP login/status ve kısıt kararları buradan okunur)."""
    st, _ = internal_call("POST", "/internal/auth/flow/update",
                          {"username": user, "flowId": flow_id, "status": status, "newDevice": new_device}, {})
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


class Handler(BaseHTTPRequestHandler):
    server_version = "seal-mobile"

    def _json(self, code, obj):
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
            return self._json(200 if st == 200 else 502, {"status": "ENROLLED" if st == 200 else "FAILED"})

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
            with LOCK:
                flow["status"] = status
                flow["newDevice"] = status == "NEW_DEVICE"
                if status == "PIN_OK":
                    flow["authId"] = str(uuid.uuid4())
                    flow["nonce"] = base64.urlsafe_b64encode(os.urandom(24)).decode()
                    flow["authExp"] = time.time() + 60
                    flow["authUsed"] = False
            if not idp_flow_update(user, req["flowId"], status, status == "NEW_DEVICE"):
                return self._json(502, {"error": "IdP akış durumu yazılamadı"})
            if status == "PIN_OK":
                return self._json(200, {"flowId": req["flowId"], "status": status,
                                        "authorizationId": flow["authId"], "nonce": flow["nonce"]})
            body = {"flowId": req["flowId"], "status": status}
            if status == "NEW_DEVICE":
                # Yeni cihaz: IdP OTP üretir (SMS yok; demo modunda yanıtta döner, konsol ekranda gösterir)
                st2, d2 = internal_call("POST", "/internal/auth/device/new",
                                        {"username": user, "flowId": req["flowId"]}, {})
                if st2 != 200:
                    return self._json(502, {"error": "OTP üretilemedi"})
                if "demoOtp" in d2:
                    body["demoOtp"] = d2["demoOtp"]
            return self._json(200, body)

        if self.path == "/seal/mobile/v1/device/otp":
            # Yeni cihaz OTP doğrulaması (IdP): başarıda kullanıcı aktivasyon kapsamına girer
            st, d = internal_call("POST", "/internal/auth/otp/verify",
                                  {"username": user, "flowId": req.get("flowId", ""), "code": req.get("otp", "")}, {})
            if st == 200:
                return self._json(200, {"status": "OTP_OK", "activationRequired": True})
            return self._json(st if st in (401, 404, 423) else 502, {"status": "OTP_FAILED", "detail": d.get("error")})

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
            if not idp_flow_update(user, req["flowId"], "PIN_AUTHORIZED", bool(flow.get("newDevice"))):
                return self._json(502, {"error": "IdP akış durumu yazılamadı"})
            return self._json(200, {"flowId": req["flowId"], "status": "PIN_AUTHORIZED"})

        if self.path == "/seal/mobile/v1/activation/start":
            # Aktivasyon token'ı: IdP üretir (Seal Intranet create-activation-token); kullanıcı token'ın sahibi
            st, d = internal_call("POST", "/internal/auth/activation/token", {"username": user}, {})
            if st != 200:
                return self._json(502, {"error": "aktivasyon başlatılamadı", "detail": d.get("error")})
            return self._json(200, {"activationToken": d.get("activationToken")})

        if self.path == "/seal/mobile/v1/activation/complete":
            # SDK aktivasyonu tamamlandı: IdP kullanıcının kısıtını kaldırır
            st, _ = internal_call("POST", "/internal/auth/activation/complete",
                                  {"activationToken": req.get("activationToken", "")}, {})
            return self._json(200 if st == 200 else 404, {"status": "ACTIVATED" if st == 200 else "FAILED"})
        self._json(404, {"error": "bulunamadı"})

    def log_message(self, fmt, *args):
        pass


def main():
    port = int(os.environ.get("SM_PORT", "8443"))
    httpd = ThreadingHTTPServer(("0.0.0.0", port), Handler)
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
