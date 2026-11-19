# Fortuna kimlik zinciri (lab mock) ve SmsOtpCGW mock'u. ROLE: cgw | api | acl | sms
#   cgw : FortunaUsersCGW  -> captcha (demo değer) kontrolü, api'ye iletir
#   api : FortunaUserAPI   -> acl'ye iletir
#   acl : FortunaUserACL   -> LegacyDB (PostgreSQL, mgmt) üzerinde parola doğrulama
#   sms : SmsOtpCGW        -> OTP üretir/doğrular; lab'da SMS gönderilmez, kod yanıtta (demo) döner
# Lab mock: gerçek Fortuna değildir. Parola özeti (salt + sha256) yalnız lab içindir.
import hashlib
import hmac
import json
import os
import secrets
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse
from urllib.error import HTTPError
from urllib.request import Request, urlopen

ROLE = os.environ.get("ROLE", "")
PORT = int(os.environ.get("PORT", "8080"))
NEXT_URL = os.environ.get("NEXT_URL", "")
# Sonraki servise mTLS istemci bağlamı (NEXT_URL https ise): CLIENT_TLS_CERT/KEY/CA
CLIENT_TLS_CERT = os.environ.get("CLIENT_TLS_CERT", "")
CLIENT_TLS_KEY = os.environ.get("CLIENT_TLS_KEY", "")
CLIENT_TLS_CA = os.environ.get("CLIENT_TLS_CA", "")
_CLIENT_CTX = None


def _client_ctx():
    global _CLIENT_CTX
    if _CLIENT_CTX is None:
        import ssl
        ctx = ssl.create_default_context(cafile=CLIENT_TLS_CA)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2
        ctx.load_cert_chain(CLIENT_TLS_CERT, CLIENT_TLS_KEY)
        _CLIENT_CTX = ctx
    return _CLIENT_CTX
CAPTCHA_DEMO = os.environ.get("CAPTCHA_DEMO", "lab-captcha")
DB_DSN = os.environ.get("DB_DSN", "")
SEED_USER = os.environ.get("SEED_USER", "alice")
SEED_PASSWORD = os.environ.get("SEED_PASSWORD", "")
OTP_TTL = 300
OTP_TRIES = 5

_OTP = {}
_LOCK = threading.Lock()


def digest(salt, password):
    return hashlib.sha256((salt + password).encode()).hexdigest()


def forward(path, body):
    req = Request(NEXT_URL + path, data=json.dumps(body).encode(), method="POST",
                  headers={"Content-Type": "application/json"})
    try:
        with urlopen(req, timeout=10, context=_client_ctx() if NEXT_URL.startswith("https://") else None) as r:
            return r.status, json.loads(r.read() or b"{}")
    except HTTPError as e:  # üst katman 4xx/5xx döndü: durum kodu ve gövde korunur
        try:
            return e.code, json.loads(e.read() or b"{}")
        except ValueError:
            return e.code, {"error": "üst katman hatası"}
    except Exception as e:  # ağ hatası
        return 502, {"error": f"üst katman erişilemedi: {type(e).__name__}"}


def db_connect():
    import psycopg  # yalnız acl rolü
    return psycopg.connect(DB_DSN, autocommit=True)


def acl_init():
    with db_connect() as conn:
        conn.execute("""CREATE TABLE IF NOT EXISTS fortuna_users (
            username TEXT PRIMARY KEY, customer_id TEXT NOT NULL, salt TEXT NOT NULL,
            pw_hash TEXT NOT NULL, status TEXT NOT NULL)""")
        if SEED_PASSWORD:
            salt = secrets.token_hex(8)
            conn.execute("""INSERT INTO fortuna_users (username, customer_id, salt, pw_hash, status)
                VALUES (%s, %s, %s, %s, 'ACTIVE') ON CONFLICT (username) DO NOTHING""",
                         (SEED_USER, "C000000001", salt, digest(salt, SEED_PASSWORD)))


def acl_verify(customer_id, password):
    # Parola: fortuna_users; müşteri bilgisi (ad, durum): customers (aynı LegacyDB)
    with db_connect() as conn:
        row = conn.execute("SELECT customer_id, salt, pw_hash, status FROM fortuna_users WHERE customer_id = %s",
                           (customer_id,)).fetchone()
        if not row or row[3] != "ACTIVE":
            return False, None
        if not hmac.compare_digest(row[2], digest(row[1], password)):
            return False, None
        cust = conn.execute("SELECT full_name, status FROM customers WHERE customer_id = %s", (row[0],)).fetchone()
    if not cust or cust[1] != "ACTIVE":
        return False, {"reason": "müşteri pasif veya kayıtsız"}
    return True, {"customerId": row[0], "fullName": cust[0]}


def otp_request(flow):
    code = f"{secrets.randbelow(1000000):06d}"
    with _LOCK:
        _OTP[flow] = {"hash": digest("otp", code), "exp": time.time() + OTP_TTL, "tries": 0}
    return code


def otp_verify(flow, code):
    with _LOCK:
        rec = _OTP.get(flow)
        if not rec:
            return "NOT_FOUND"
        if time.time() > rec["exp"]:
            _OTP.pop(flow, None)
            return "EXPIRED"
        if rec["tries"] >= OTP_TRIES:
            return "LOCKED"
        if hmac.compare_digest(rec["hash"], digest("otp", code)):
            _OTP.pop(flow, None)
            return "OK"
        rec["tries"] += 1
        return "WRONG"


# Prometheus metrikleri (lab): istek sayacı, yol ve HTTP koduna göre. Süreç belleğinde; yeniden başlatmada sıfırlanır.
import threading as _mt
_METRICS = {}
_METRICS_LOCK = _mt.Lock()


def _count(method, path, code):
    key = (method, path.split("?")[0], int(code))
    with _METRICS_LOCK:
        _METRICS[key] = _METRICS.get(key, 0) + 1


def _send_metrics(handler, service):
    lines = ["# HELP http_requests_total HTTP istek sayısı", "# TYPE http_requests_total counter"]
    with _METRICS_LOCK:
        items = sorted(_METRICS.items())
    for (m, p, c), n in items:
        lines.append(f'http_requests_total{{service="{service}",method="{m}",path="{p}",code="{c}"}} {n}')
    body = ("\n".join(lines) + "\n").encode()
    handler.send_response(200)
    handler.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


# mTLS (lab): TLS_CERT/TLS_KEY/TLS_CA verilirse HTTPS. POST uçları istemci sertifikası CN'i ALLOWED_CLIENTS içinde olmalı.
TLS_CERT = os.environ.get("TLS_CERT", "")
TLS_KEY = os.environ.get("TLS_KEY", "")
TLS_CA = os.environ.get("TLS_CA", "")
TLS_ON = bool(TLS_CERT and TLS_KEY and TLS_CA)
ALLOWED_CLIENTS = set(filter(None, os.environ.get("ALLOWED_CLIENTS", "janus-web,janus-mobile").split(",")))


def peer_cn(sock):
    try:
        cert = sock.getpeercert()
    except (AttributeError, ValueError):
        return None
    for rdn in (cert or {}).get("subject", ()):
        for k, v in rdn:
            if k == "commonName":
                return v
    return None


def tls_wrap(httpd):
    import ssl
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(TLS_CERT, TLS_KEY)
    ctx.load_verify_locations(TLS_CA)
    ctx.verify_mode = ssl.CERT_OPTIONAL  # sağlık uçları sertifikasız; POST'ta uygulama katmanı zorunlu kılar
    httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)


class Handler(BaseHTTPRequestHandler):
    server_version = "fortuna-mock"

    def _json(self, code, obj):
        _count(self.command, self.path, code)
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _body(self):
        n = int(self.headers.get("Content-Length", "0") or 0)
        try:
            return json.loads(self.rfile.read(n) or b"{}")
        except ValueError:
            return None

    def do_GET(self):
        if self.path.split('?')[0] == '/metrics':
            return _send_metrics(self, f"fortuna-{os.environ.get('ROLE', '')}")
        if urlparse(self.path).path == "/health":
            return self._json(200, {"status": "ok", "role": ROLE})
        return self._json(404, {"error": "bilinmeyen uç nokta"})

    def do_POST(self):
        if TLS_ON and peer_cn(self.connection) not in ALLOWED_CLIENTS:
            return self._json(401, {"error": "istemci sertifikası yok veya yetkisiz"})
        path = urlparse(self.path).path
        req = self._body()
        if req is None:
            return self._json(400, {"error": "geçersiz JSON"})
        if ROLE == "cgw" and path == "/cgw/verifyUserPin":
            if req.get("captcha") != CAPTCHA_DEMO:
                return self._json(400, {"error": "captcha hatalı"})
            st, out = forward("/api/verifyUserPin", req)
            return self._json(st, out)
        if ROLE == "api" and path == "/api/verifyUserPin":
            st, out = forward("/acl/verify", {"customerId": req.get("customerId", ""), "password": req.get("password", "")})
            return self._json(st, out)
        if ROLE == "acl" and path == "/acl/verify":
            ok, info = acl_verify(str(req.get("customerId", "")), str(req.get("password", "")))
            if not ok:
                return self._json(401, {"error": (info or {}).get("reason", "kimlik doğrulanamadı")})
            return self._json(200, {"ok": True, **info})
        if ROLE == "sms" and path == "/sms/otp/request":
            flow = str(req.get("flowId", ""))
            if not flow:
                return self._json(400, {"error": "flowId gerekli"})
            return self._json(200, {"status": "SENT", "demoOtp": otp_request(flow),
                                    "note": "DEMO: SMS gönderilmez; kod yalnızca yanıtta"})
        if ROLE == "sms" and path == "/sms/otp/verify":
            res = otp_verify(str(req.get("flowId", "")), str(req.get("code", "")))
            return self._json(200 if res == "OK" else 401, {"status": res})
        return self._json(404, {"error": "bilinmeyen uç nokta"})

    def log_message(self, fmt, *args):
        print(fmt % args, flush=True)


if __name__ == "__main__":
    if ROLE == "acl":
        acl_init()
    print(f"fortuna-{ROLE} dinliyor (port {PORT})", flush=True)
    httpd = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    if TLS_ON:
        tls_wrap(httpd)
    print(f"mTLS={'evet' if TLS_ON else 'hayır'}", flush=True)
    httpd.serve_forever()
