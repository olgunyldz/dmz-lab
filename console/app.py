#!/usr/bin/env python3
"""DMZ lab konsolu: web ve mobil kanal (YALNIZ LAB).

Çalıştırma (repo kökünden):  PYTHONIOENCODING=utf-8 python console/app.py  ->  http://127.0.0.1:9000

Akışlar:
  web    : splash -> OTP (lab: demo kod yanıtta) -> login-user (müşteri no + parola + captcha + OTP) -> client token
  mobil  : splash -> auth-server (mobile-app, PKCE) -> Seal (PIN, cihaz imzası) -> janus secure-login -> mobile-login -> client token
  işlem  : client token ile /janus/transaction (Janus, içeri giderken server token üretir)

Bağımlılıklar: edge (HAProxy, SNI/Host yönlendirme), bank-prod auth-server (port-forward), codevo seal-mobile (edge passthrough).
Sırlar: alice parolası bank-prod auth-secrets'tan yalnız bellekte okunur; tarayıcıya gitmez.
Cihaz sertifikası her mobil girişte geçici dizinde device CA ile üretilir, sonra silinir.
"""
import base64
import hashlib
import http.client
import http.server
import json
import os
import re
import secrets
import shutil
import socket
import ssl
import subprocess
import tempfile
import threading
import time
import atexit
import sys
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# İzleme: span'ler platform (docker compose) Jaeger OTLP girişine gider (127.0.0.1:14318)
os.environ.setdefault("OTLP_ENDPOINT", "http://127.0.0.1:14318")
os.environ.setdefault("SERVICE_NAME", "console")
sys.path.insert(0, str(ROOT / "shared"))
import tracing  # noqa: E402  (shared/tracing.py)
LOKI_PUSH = "http://127.0.0.1:13100/loki/api/v1/push"
GRAFANA = "http://127.0.0.1:3000"
_CUR = threading.local()
_PF = []
SENSITIVE_KEYS = {"password", "pin", "otp", "smsCode", "token", "refreshToken", "activationToken",
                  "splashToken", "access_token", "demoOtp", "pass"}


def _redact(obj):
    if isinstance(obj, dict):
        return {k: ("***" if k in SENSITIVE_KEYS else _redact(v)) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_redact(v) for v in obj][:50]
    if isinstance(obj, str) and len(obj) > 300:
        return obj[:300] + "…"
    return obj


def log_event(tid, kind, data):
    """İstek/yanıt satırı -> Loki (app=console). Gönderim arka planda; hata akışı durdurmaz."""
    line = json.dumps({"trace_id": tid, "kind": kind, **data}, ensure_ascii=False)
    body = json.dumps({"streams": [{"stream": {"app": "console", "kind": kind},
                                    "values": [[str(time.time_ns()), line]]}]}).encode()
    def send():
        try:
            req = urllib.request.Request(LOKI_PUSH, data=body, method="POST",
                                         headers={"Content-Type": "application/json"})
            urllib.request.urlopen(req, timeout=5).read()
        except Exception:
            pass
    threading.Thread(target=send, daemon=True).start()


def _trace_header():
    sp = getattr(_CUR, "span", None)
    return {"traceparent": sp.header()} if sp else {}


CERTS = ROOT / "edge" / "certs"
PUBLIC_CA = str(CERTS / "public-ca.crt")
INTERNAL_CA = str(CERTS / "internal-ca.crt")
DEVICE_CA_CRT = str(CERTS / "device" / "device-ca.crt")
DEVICE_CA_KEY = str(CERTS / "device" / "device-ca.key")
EDGE = ("127.0.0.1", 8443)      # edge HAProxy host portu (container 443)

PORT = 9000
AUTH_LOCAL_PORT = 18443          # bank-prod auth-server port-forward
AUTH_HOST = "id.bank.lab.local"
AUTH_REALM = "/realms/bank/protocol/openid-connect"
SEAL_HOST = "seal.lab.local"
DEMO_CUSTOMER = "C000000001"
DEMO_CAPTCHA = "lab-captcha"    # FortunaUsersCGW lab değeri
MOBILE_PIN = "4321"

CHANNELS = {
    "web": {"host": "web.lab.local", "ca": PUBLIC_CA, "title": "Web kanalı"},
    "mobile": {"host": "mobile-api.lab.local", "ca": PUBLIC_CA, "title": "Mobil kanal"},
}

SECRETS = {}                    # yalnız bellek
SESSIONS = {}                   # sid -> {"web": {...}, "mobile": {...}}
LOCK = threading.Lock()


# ---------------------------------------------------------------------------
# Kurulum: auth-server port-forward ve sırlar
# ---------------------------------------------------------------------------
def load_secrets():
    out = subprocess.run(["kubectl", "--context", "kind-bank-prod", "-n", "auth", "get", "secret", "auth-secrets",
                          "-o", "jsonpath={.data.ALICE_PASSWORD}"], capture_output=True, text=True, check=True).stdout
    SECRETS["alice"] = base64.b64decode(out).decode()


def start_auth_forward():
    proc = subprocess.Popen(["kubectl", "--context", "kind-bank-prod", "-n", "auth", "port-forward",
                             "svc/auth-server", f"{AUTH_LOCAL_PORT}:8443"],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    atexit.register(proc.terminate)
    time.sleep(3)


# ---------------------------------------------------------------------------
# TLS istemcisi (SNI ile)
# ---------------------------------------------------------------------------
def tls_call(addr, host, ca, method, path, headers=None, body=None, cert=None):
    ctx = ssl.create_default_context(cafile=ca)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    if cert:
        ctx.load_cert_chain(cert[0], cert[1])
    sock = ctx.wrap_socket(socket.create_connection(addr, timeout=20), server_hostname=host)
    conn = http.client.HTTPConnection(host, timeout=20)
    conn.sock = sock
    conn.request(method, path, body=body, headers={"Connection": "close", **_trace_header(), **(headers or {})})
    resp = conn.getresponse()
    data = resp.read()
    conn.close()
    return resp.status, json.loads(data or b"{}")


def post(addr, host, ca, path, obj, headers=None, cert=None):
    h = {"Content-Type": "application/json", **(headers or {})}
    return tls_call(addr, host, ca, "POST", path, h, json.dumps(obj).encode(), cert)


def janus(channel, path, obj, splash, token=None):
    h = {"X-Splash-Token": splash}
    if token:
        h["Authorization"] = "Bearer " + token
    return post(EDGE, CHANNELS[channel]["host"], PUBLIC_CA, path, obj, h)


def auth_token(password):
    """mobile-app (public, PKCE) ile alice için access token. Tarayıcı yok: giriş formu sunucudan doldurulur."""
    verifier = base64.urlsafe_b64encode(secrets.token_bytes(32)).rstrip(b"=").decode()
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    q = urllib.parse.urlencode({"response_type": "code", "client_id": "mobile-app",
                                "redirect_uri": "com.bank.app:/callback", "scope": "openid profile", "state": "c",
                                "code_challenge": challenge, "code_challenge_method": "S256"})
    cur, method, body, headers, jar = AUTH_REALM + "/auth?" + q, "GET", None, {}, {}
    code = None
    for _ in range(15):
        if jar:
            headers["Cookie"] = "; ".join(f"{k}={v}" for k, v in jar.items())
        st, h, data = _raw(method, cur, headers, body)
        for sc in h.get_all("Set-Cookie") or []:
            k, v = sc.split(";")[0].split("=", 1)
            jar[k] = v
        if st in (301, 302, 303, 307):
            loc = h["Location"]
            if loc.startswith("com.bank.app:"):
                code = urllib.parse.parse_qs(urllib.parse.urlparse(loc).query)["code"][0]
                break
            p = urllib.parse.urlparse(loc)
            cur, method, body = p.path + ("?" + p.query if p.query else ""), "GET", None
            continue
        if st == 200 and b'name="_csrf"' in data:
            m = re.search(rb'name="_csrf"[^>]*value="([^"]+)"', data) or re.search(rb'value="([^"]+)"[^>]*name="_csrf"', data)
            body = urllib.parse.urlencode({"username": "alice", "password": password,
                                           "_csrf": m.group(1).decode()}).encode()
            method, cur = "POST", "/login"
            headers["Content-Type"] = "application/x-www-form-urlencoded"
            continue
        raise RuntimeError(f"auth-server beklenmeyen yanıt: {st}")
    if not code:
        raise RuntimeError("auth-server kodu alınamadı (parola veya oturum)")
    form = urllib.parse.urlencode({"grant_type": "authorization_code", "code": code,
                                   "redirect_uri": "com.bank.app:/callback", "client_id": "mobile-app",
                                   "code_verifier": verifier}).encode()
    st, out = tls_call(("127.0.0.1", AUTH_LOCAL_PORT), AUTH_HOST, INTERNAL_CA, "POST", AUTH_REALM + "/token",
                       {"Content-Type": "application/x-www-form-urlencoded"}, form)
    if st != 200:
        raise RuntimeError(f"auth-server token alınamadı: {st}")
    return out["access_token"]


def _raw(method, path, headers, body):
    ctx = ssl.create_default_context(cafile=INTERNAL_CA)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    sock = ctx.wrap_socket(socket.create_connection(("127.0.0.1", AUTH_LOCAL_PORT), timeout=20),
                           server_hostname=AUTH_HOST)
    conn = http.client.HTTPConnection(AUTH_HOST, timeout=20)
    conn.sock = sock
    conn.request(method, path, body=body, headers={"Connection": "close", **_trace_header(), **headers})
    resp = conn.getresponse()
    data = resp.read()
    conn.close()
    return resp.status, resp.headers, data


def make_device_cert(td, cn):
    key, csr, crt = (os.path.join(td, n) for n in ("d.key", "d.csr", "d.crt"))
    cnf, ext = os.path.join(td, "d.cnf"), os.path.join(td, "d.ext")
    with open(cnf, "w") as f:
        f.write(f"[req]\ndistinguished_name=dn\nprompt=no\n[dn]\nCN={cn}\n")
    with open(ext, "w") as f:
        f.write(f"subjectAltName=DNS:{cn}\nextendedKeyUsage=clientAuth\nbasicConstraints=CA:FALSE\n")
    subprocess.run(["openssl", "req", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", csr, "-config", cnf],
                   check=True, capture_output=True)
    subprocess.run(["openssl", "x509", "-req", "-in", csr, "-CA", DEVICE_CA_CRT, "-CAkey", DEVICE_CA_KEY,
                    "-set_serial", "0x" + secrets.token_hex(8), "-out", crt, "-days", "1", "-extfile", ext],
                   check=True, capture_output=True)
    return crt, key


def device_sign(key, td, nonce):
    inp, sig = os.path.join(td, "n"), os.path.join(td, "s")
    with open(inp, "wb") as f:
        f.write(nonce.encode())
    subprocess.run(["openssl", "dgst", "-sha256", "-sign", key, "-out", sig, inp], check=True, capture_output=True)
    return base64.b64encode(open(sig, "rb").read()).decode()


# ---------------------------------------------------------------------------
# Kanal akışları
# ---------------------------------------------------------------------------
def splash(channel, device):
    st, d = post(EDGE, CHANNELS[channel]["host"], PUBLIC_CA, "/janus/splash", {"deviceId": device})
    if st != 200:
        raise RuntimeError(f"splash: {st}")
    return d["splashToken"]


# Lab SMS kutusu: her kanalın son OTP'si. Kod tarayıcıya yanıtta değil, yalnız /sms sayfasında gösterilir.
LAST_SMS = {}


def remember_sms(channel, code):
    LAST_SMS[channel] = {"demoOtp": code, "at": time.strftime("%H:%M:%S")}


def web_otp(sess):
    w = sess["web"]
    w["splash"] = splash("web", w["device"])
    st, d = janus("web", "/janus/otp/request", {"flowId": w["flow"]}, w["splash"])
    if st != 200:
        raise RuntimeError(f"OTP isteği: {st} {d.get('error', '')}")
    remember_sms("web", d.get("demoOtp", ""))
    return {"sent": True, "channel": "web"}


def web_login(sess, customer, password, smsCode):
    w = sess["web"]
    if not w.get("splash"):
        raise RuntimeError("önce OTP isteyin")
    st, d = janus("web", "/janus/login-user",
                  {"flowId": w["flow"], "customerId": customer, "password": password,
                   "captcha": DEMO_CAPTCHA, "smsCode": smsCode}, w["splash"])
    if st != 200:
        raise RuntimeError(d.get("error") or f"giriş reddedildi ({st})")
    w.update(token=d["token"], customerId=d["customerId"], fullName=d.get("fullName"), refresh=d.get("refreshToken"))
    return {"customerId": d["customerId"], "fullName": d.get("fullName")}


PIN_MESSAGES = {
    "PIN_INVALID": "PIN hatalı. Doğru PIN'i girin.",
    "PIN_LOCKED": "PIN, çok sayıda hatalı denemeden dolayı kilitli. Bir süre sonra tekrar deneyin.",
    "PIN_EXPIRED": "PIN süresi dolmuş. 'İlk kez kurulum' ile PIN'i yeniden tanımlayın.",
}


def pin_message(status):
    return PIN_MESSAGES.get(status, f"PIN doğrulanamadı ({status})")


def seal_authorize(auth, cert, key, td, pin):
    """Seal: login/begin -> login/pin -> login/authorize (cihaz imzası). Dönüş: (flowId, pin durumu)."""
    st, d = post(EDGE, SEAL_HOST, INTERNAL_CA, "/seal/mobile/v1/login/begin", {}, auth, cert)
    if st != 200:
        raise RuntimeError(f"Seal login/begin: {st} {d.get('error', '')}")
    flow = d["flowId"]
    st, d = post(EDGE, SEAL_HOST, INTERNAL_CA, "/seal/mobile/v1/login/pin", {"flowId": flow, "pin": pin}, auth, cert)
    if st != 200 or d.get("status") not in ("PIN_OK", "NEW_DEVICE"):
        raise RuntimeError(pin_message(d.get("status")) if d.get("status") else f"PIN doğrulanamadı (HTTP {st})")
    pin_status = d["status"]
    st, d = post(EDGE, SEAL_HOST, INTERNAL_CA, "/seal/mobile/v1/login/authorize",
                 {"flowId": flow, "authorizationId": d["authorizationId"],
                  "signature": device_sign(key, td, d["nonce"])}, auth, cert)
    if st != 200:
        raise RuntimeError(f"cihaz yetkisi: {st} {d.get('error', '')}")
    return flow, pin_status


def _complete_login(m, dev, flow, customer, steps):
    """secure-login + mobile-login: oturum belirteci al ve mobil oturumu kaydet."""
    st, d = janus("mobile", "/janus/secure-login", {"flowId": flow}, m["splash"])
    if st != 200:
        raise RuntimeError(f"secure-login: {st} {d.get('error', '')}")
    steps.append("secure-login: " + str(d.get("status")))
    st, d = janus("mobile", "/janus/mobile-login", {"flowId": flow, "customerId": customer}, m["splash"])
    if st != 200:
        raise RuntimeError(f"mobile-login: {d.get('error') or st}")
    steps.append("mobile-login")
    m.update(token=d["token"], customerId=d["customerId"], fullName=d.get("fullName"), device=dev,
             refresh=d.get("refreshToken"))
    return {"steps": steps, "customerId": d["customerId"], "fullName": d.get("fullName")}


def _drop_pending(m):
    p = m.pop("pending", None)
    if p:
        shutil.rmtree(p["td"], ignore_errors=True)


def _new_device_otp_request(sess, pin, customer):
    """Yeni cihaz 1. aşama: splash, auth-server, cihaz sertifikası, PIN yetkisi, secure-login, OTP üretimi.
    OTP (lab) yanıtta döner ve ekranda gösterilir; cihaz durumu sonraki aşama için bekletilir."""
    m = sess["mobile"]
    _drop_pending(m)
    dev = "mob-" + secrets.token_hex(3)
    m["splash"] = splash("mobile", dev)
    steps = ["splash (cihaz " + dev + ")"]
    td = tempfile.mkdtemp(prefix="mobile-")
    try:
        auth = {"Authorization": "Bearer " + auth_token(SECRETS["alice"])}
        steps.append("auth-server token (mobile-app, PKCE)")
        crt, key = make_device_cert(td, dev)
        cert = (crt, key)
        flow, _ = seal_authorize(auth, cert, key, td, pin)
        steps.append("yeni cihaz: PIN + cihaz imzası (PIN_AUTHORIZED)")
        st, d = janus("mobile", "/janus/secure-login", {"flowId": flow}, m["splash"])
        if st != 200:
            raise RuntimeError(f"secure-login: {st} {d.get('error', '')}")
        st, d = janus("mobile", "/janus/otp/request", {"flowId": flow}, m["splash"])
        if st != 200:
            raise RuntimeError(f"OTP isteği: {st} {d.get('error', '')}")
        m["pending"] = {"dev": dev, "td": td, "flow": flow, "auth": auth, "cert": cert, "key": key,
                        "pin": pin, "customer": customer, "steps": steps}
        remember_sms("mobile", d.get("demoOtp", ""))
        return {"needOtp": True, "steps": steps}
    except Exception:
        shutil.rmtree(td, ignore_errors=True)
        raise


def _new_device_finish(sess, otp):
    """Yeni cihaz 2. aşama: SMS OTP doğrulanır (parolasız), aktivasyon tamamlanır, PIN cihaza kaydedilir."""
    m = sess["mobile"]
    p = m.pop("pending", None)
    if not p:
        raise RuntimeError("önce 'SMS kodu gönder' adımını tamamlayın")
    try:
        dev, auth, cert, key, td = p["dev"], p["auth"], p["cert"], p["key"], p["td"]
        steps = p["steps"]
        # Parolasız aktivasyon: kimlik kanıtı PIN + cihaz imzası + SMS OTP
        st, d = janus("mobile", "/janus/otp/verify", {"flowId": p["flow"], "smsCode": otp}, m["splash"])
        if st != 200:
            raise RuntimeError(d.get("error") or f"SMS kodu doğrulanamadı ({st})")
        steps.append("SMS OTP doğrulandı")
        st, d = janus("mobile", "/janus/activation/token", {"customerId": p["customer"]}, m["splash"])
        if st != 200:
            raise RuntimeError(f"aktivasyon tokenı: {st} {d.get('error', '')}")
        act = d["activationToken"]
        st, d = janus("mobile", "/janus/activation/complete",
                      {"activationToken": act, "customerId": p["customer"]}, m["splash"])
        if st != 200 or d.get("status") != "ACTIVATED":
            raise RuntimeError(f"aktivasyon tamamlanmadı: {d.get('status') or st}")
        steps.append("cihaz aktive edildi (ACTIVE)")
        st, d = post(EDGE, SEAL_HOST, INTERNAL_CA, "/seal/mobile/v1/device/enroll", {"pin": p["pin"]}, auth, cert)
        if st != 200:
            raise RuntimeError(f"PIN kaydı: {st}")
        steps.append("PIN cihaza kaydedildi")
        flow, _ = seal_authorize(auth, cert, key, td, p["pin"])
        steps.append("PIN doğrulandı, cihaz imzası (Seal)")
        return _complete_login(m, dev, flow, p["customer"], steps)
    finally:
        shutil.rmtree(td, ignore_errors=True)


def mobile_login(sess, pin, enroll, customer, new_device, otp=None):
    """Mobil giriş. Yeni cihaz: otp yoksa 1. aşama (OTP üretilir ve döner), otp varsa 2. aşama (tamamlanır).
    Mevcut cihaz: tek çağrı."""
    if new_device:
        if otp:
            return _new_device_finish(sess, otp)
        return _new_device_otp_request(sess, pin, customer)
    m = sess["mobile"]
    _drop_pending(m)
    dev = m.get("device")
    if not dev:
        raise RuntimeError("bu oturumda aktive edilmiş cihaz yok; 'Yeni cihaz' ile aktive edin")
    m["splash"] = splash("mobile", dev)
    steps = ["splash (cihaz " + dev + ")"]
    access = auth_token(SECRETS["alice"])
    steps.append("auth-server token (mobile-app, PKCE)")
    auth = {"Authorization": "Bearer " + access}
    with tempfile.TemporaryDirectory() as td:
        crt, key = make_device_cert(td, dev)
        cert = (crt, key)
        if enroll:
            st, d = post(EDGE, SEAL_HOST, INTERNAL_CA, "/seal/mobile/v1/device/enroll", {"pin": pin}, auth, cert)
            if st != 200:
                raise RuntimeError(f"PIN kurulumu: {st}")
            steps.append("PIN kuruldu")
        flow, pin_status = seal_authorize(auth, cert, key, td, pin)
        if pin_status != "PIN_OK":
            raise RuntimeError(pin_message(pin_status))
        steps.append("PIN doğrulandı, cihaz imzası (Seal)")
    return _complete_login(m, dev, flow, customer, steps)


def mobile_cancel(sess):
    _drop_pending(sess["mobile"])
    return {"cancelled": True}


def renew(sess, channel):
    """Yenileme token'ı ile yeni client token ve yeni splash al (ikisi de 401'e yol açabilir). Başarıysa True."""
    c = sess[channel]
    dev = sess["web"]["device"] if channel == "web" else c.get("device")
    if not c.get("refresh") or not dev:
        return False
    st, d = post(EDGE, CHANNELS[channel]["host"], PUBLIC_CA, "/janus/token/refresh", {"refreshToken": c["refresh"]})
    if st != 200:
        return False
    st2, sp = post(EDGE, CHANNELS[channel]["host"], PUBLIC_CA, "/janus/splash", {"deviceId": dev})
    if st2 != 200:
        return False
    c.update(token=d["token"], refresh=d["refreshToken"], splash=sp["splashToken"])
    return True


def transaction(sess, channel, code, params=None):
    c = sess[channel]
    if not c.get("token"):
        raise RuntimeError("oturum yok")
    body = {"code": code, "params": params or {}}
    st, d = janus(channel, "/janus/transaction", body, c["splash"], c["token"])
    if st == 401 and renew(sess, channel):
        st, d = janus(channel, "/janus/transaction", body, c["splash"], c["token"])
    if st == 401:
        # Client token süresi (15 dk) dolmuş olabilir: oturumu temizle, kullanıcıya açık mesaj ver
        c.pop("token", None)
        c.pop("refresh", None)
        return 401, {"error": "oturum süresi doldu; yeniden giriş yapın", "expired": True}
    return st, d


def new_session():
    return {"web": {"device": "web-" + secrets.token_hex(4), "flow": secrets.token_hex(12)},
            "mobile": {}}


def summary(sess):
    out = {}
    for ch in ("web", "mobile"):
        c = sess[ch]
        out[ch] = {"loggedIn": bool(c.get("token")), "customerId": c.get("customerId"),
                   "fullName": c.get("fullName")}
    return out


# ---------------------------------------------------------------------------
# HTTP sunucusu
# ---------------------------------------------------------------------------
class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "dmz-console"

    def _sid(self):
        for part in (self.headers.get("Cookie") or "").split(";"):
            if part.strip().startswith("csid="):
                return part.strip()[5:]
        return None

    def _session(self):
        sid = self._sid()
        with LOCK:
            if sid not in SESSIONS:
                sid = secrets.token_urlsafe(24)
                SESSIONS[sid] = new_session()
            return sid, SESSIONS[sid]

    def _send(self, status, body, ctype, sid):
        raw = body.encode() if isinstance(body, str) else body
        self._status = status
        if "json" in ctype:
            try:
                payload = _redact(json.loads(raw or b"{}"))
            except ValueError:
                payload = None
            log_event(self._tid, "response", {"method": self.command, "path": self.path, "status": status,
                                              "body": payload})
        else:
            log_event(self._tid, "response", {"method": self.command, "path": self.path, "status": status})
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Set-Cookie", f"csid={sid}; HttpOnly; SameSite=Strict; Path=/")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Trace-Id", self._tid)
        self.end_headers()
        self.wfile.write(raw)

    def _json(self, status, obj, sid):
        self._send(status, json.dumps(obj, ensure_ascii=False), "application/json; charset=utf-8", sid)

    def _traced(self, method, fn):
        incoming = self.headers.get("traceparent")
        path = urllib.parse.urlparse(self.path).path
        span = tracing.start_server_span(f"console {method} {path}", incoming,
                                         {"http.method": method, "http.target": self.path})
        _CUR.span = span
        self._tid = span.trace_id
        self._status = None
        log_event(self._tid, "request", {"method": method, "path": self.path})
        try:
            fn()
        finally:
            _CUR.span = None
            span.end(http_status=self._status)

    def do_GET(self):
        self._traced("GET", self._do_get)

    def do_POST(self):
        self._traced("POST", self._do_post)

    def _do_get(self):
        sid, sess = self._session()
        path = urllib.parse.urlparse(self.path).path
        if path == "/":
            return self._send(200, (ROOT / "console" / "channel.html").read_bytes(), "text/html; charset=utf-8", sid)
        if path == "/api/state":
            return self._json(200, summary(sess), sid)
        if path == "/sms":
            return self._send(200, (ROOT / "console" / "sms.html").read_bytes(), "text/html; charset=utf-8", sid)
        if path == "/api/sms":
            return self._json(200, {"web": LAST_SMS.get("web"), "mobile": LAST_SMS.get("mobile")}, sid)
        self._json(404, {"error": "bulunamadı"}, sid)

    def _do_post(self):
        sid, sess = self._session()
        n = int(self.headers.get("Content-Length", "0") or 0)
        try:
            req = json.loads(self.rfile.read(n) or b"{}")
        except ValueError:
            return self._json(400, {"error": "geçersiz JSON"}, sid)
        path = urllib.parse.urlparse(self.path).path
        log_event(self._tid, "request_body", {"method": "POST", "path": path, "body": _redact(req)})
        try:
            if path == "/api/web/otp":
                return self._json(200, web_otp(sess), sid)
            if path == "/api/web/login":
                out = web_login(sess, str(req.get("customerId", "")), str(req.get("password", "")),
                                str(req.get("smsCode", "")))
                return self._json(200, out, sid)
            if path == "/api/mobile/login":
                out = mobile_login(sess, str(req.get("pin", MOBILE_PIN)), bool(req.get("enroll")),
                                   str(req.get("customerId", DEMO_CUSTOMER)), bool(req.get("newDevice")),
                                   str(req.get("smsCode", "")).strip() or None)
                return self._json(200, out, sid)
            if path == "/api/mobile/cancel":
                return self._json(200, mobile_cancel(sess), sid)
            if path == "/api/transaction":
                ch = req.get("channel")
                if ch not in CHANNELS:
                    return self._json(400, {"error": "kanal geçersiz"}, sid)
                params = req.get("params") if isinstance(req.get("params"), dict) else {}
                st, d = transaction(sess, ch, str(req.get("code", "BALANCE")), params)
                return self._json(st, d, sid)
            if path == "/api/logout":
                ch = req.get("channel")
                if ch in ("web", "mobile"):
                    if ch == "web":
                        sess[ch] = {"device": sess["web"]["device"], "flow": sess["web"]["flow"]}
                    else:
                        sess[ch] = {"device": sess["mobile"].get("device")}  # cihaz kalır, yeniden aktivasyon gerekmez
                return self._json(200, summary(sess), sid)
            return self._json(404, {"error": "bulunamadı"}, sid)
        except (RuntimeError, OSError, subprocess.CalledProcessError, KeyError) as e:
            return self._json(502 if isinstance(e, OSError) else 400, {"error": str(e)}, sid)

    def log_message(self, fmt, *args):
        print("console", self.command, self.path, fmt % args, flush=True)


def main():
    load_secrets()
    start_auth_forward()
    print(f"konsol: http://127.0.0.1:{PORT}", flush=True)
    http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
