# Janus (lab): kanal ağ geçidi. CHANNEL=web|mobile. Splash token'ı Janus kendi anahtarıyla (HS256) imzalar.
# Bu aşama: sağlık ve splash uçları. Login/OTP/işlem uçları sonraki adımda (Fortuna mock'ları ile birlikte).
import hashlib
import hmac
import base64
import json
import os
import secrets
import ssl
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError
from urllib.parse import urlparse
from urllib.request import Request, urlopen

os.environ.setdefault("SERVICE_NAME", "janus-" + os.environ.get("CHANNEL", "mobile"))
import tracing  # ConfigMap ile /app/tracing.py (shared/tracing.py)

PORT = int(os.environ.get("PORT", "8080"))
CHANNEL = os.environ.get("CHANNEL", "mobile")
SECRET = os.environ.get("JANUS_KEY", "").encode()
SPLASH_TTL = 15 * 60
LOGIN_TTL = 15 * 60
REFRESH_TTL = 8 * 60 * 60   # yenileme token'ı: tek kullanımlık (döndürme), 8 saat
_REFRESH = {}
_REFRESH_LOCK = threading.Lock()
FORTUNA_CGW_URL = os.environ.get("FORTUNA_CGW_URL", "")
SMS_OTP_URL = os.environ.get("SMS_OTP_URL", "")
FORTUNA_URL = os.environ.get("FORTUNA_URL", "")  # Fortuna monolith (legacy-demo, NodePort 30890)
CHANNEL_GATEWAY_URL = os.environ.get("CHANNEL_GATEWAY_URL", "")  # channel-gateway (bank-prod)
SERVER_TTL = 60  # iç (server) token: kısa ömürlü, yalnız Janus -> channel-gateway
_PENDING = {}  # flowId -> {customerId, exp}; tek replika (lab)
_PLOCK = threading.Lock()


def b64u(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def sign(payload):
    head = b64u(json.dumps({"alg": "HS256", "typ": "JWT", "kid": f"janus-{CHANNEL}"}, separators=(",", ":")).encode())
    body = b64u(json.dumps(payload, separators=(",", ":")).encode())
    sig = hmac.new(SECRET, f"{head}.{body}".encode(), hashlib.sha256).digest()
    return f"{head}.{body}.{b64u(sig)}"


def verify_jwt(token, typ=None):
    try:
        head, body, sig = token.split(".")
        expect = hmac.new(SECRET, f"{head}.{body}".encode(), hashlib.sha256).digest()
        if not hmac.compare_digest(b64u(expect), sig):
            return None
        pad = "=" * (-len(body) % 4)
        claims = json.loads(base64.urlsafe_b64decode(body + pad))
    except (ValueError, TypeError):
        return None
    if claims.get("exp", 0) < time.time() or claims.get("ch") != CHANNEL:
        return None
    if typ and claims.get("typ") != typ:
        return None
    return claims


# mTLS istemci bağlamı (https üst katman çağrıları için): JANUS_TLS_CERT/KEY/CA verilirse
TLS_CERT = os.environ.get("JANUS_TLS_CERT", "")
TLS_KEY = os.environ.get("JANUS_TLS_KEY", "")
TLS_CA = os.environ.get("JANUS_TLS_CA", "")
_TLS_CTX = None


def _client_ctx():
    global _TLS_CTX
    if _TLS_CTX is None:
        ctx = ssl.create_default_context(cafile=TLS_CA)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2
        ctx.load_cert_chain(TLS_CERT, TLS_KEY)
        _TLS_CTX = ctx
    return _TLS_CTX


def call_upstream(url, body, headers=None):
    path = urlparse(url).path
    peer = ("channel-gateway" if path.startswith("/cg/") else "sms-otp" if path.startswith("/sms/")
            else "fortuna" if path.startswith("/fortuna/") else "upstream")
    with tracing.client_span(f"janus->{peer} POST {path}", peer=peer, attrs={"http.url": url}) as sp:
        # traceparent: aktif istemci span'inden; alt servis bu span'i üst kabul eder
        req = Request(url, data=json.dumps(body).encode(), method="POST",
                      headers=tracing.inject({"Content-Type": "application/json", **(headers or {})}))
        try:
            ctx = _client_ctx() if url.startswith("https://") else None
            with urlopen(req, timeout=10, context=ctx) as r:
                if sp is not None:
                    sp.set("http.status_code", r.status)
                return r.status, json.loads(r.read() or b"{}")
        except HTTPError as e:
            if sp is not None:
                sp.set("http.status_code", e.code)
            try:
                return e.code, json.loads(e.read() or b"{}")
            except ValueError:
                return e.code, {"error": "üst katman hatası"}
        except Exception as e:
            return 502, {"error": f"üst katman erişilemedi: {type(e).__name__}"}


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


def issue_refresh(cust, dev):
    rt = secrets.token_urlsafe(32)
    with _REFRESH_LOCK:
        _REFRESH[rt] = {"cust": cust, "dev": dev, "ch": CHANNEL, "exp": time.time() + REFRESH_TTL}
    return rt


def consume_refresh(rt):
    # tek kullanımlık: bulunan kayıt silinir; süresi dolmuşsa None
    with _REFRESH_LOCK:
        entry = _REFRESH.pop(rt, None)
    if not entry or entry["exp"] < time.time():
        return None
    return entry


class Handler(BaseHTTPRequestHandler):
    server_version = "janus"

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
            return _send_metrics(self, f"janus-{CHANNEL}")
        if urlparse(self.path).path == "/janus/health":
            return self._json(200, {"status": "ok", "channel": CHANNEL})
        return self._json(404, {"error": "bilinmeyen uç nokta"})

    def do_POST(self):
        path = urlparse(self.path).path
        req = self._body()
        if req is None:
            return self._json(400, {"error": "geçersiz JSON"})
        if path == "/janus/splash":
            # Uygulama açılışı: cihaz bilgisiyle splash token ve splashCode
            device = str(req.get("deviceId", "")).strip()
            if not device:
                return self._json(400, {"error": "deviceId gerekli"})
            now = int(time.time())
            sid = secrets.token_hex(16)
            token = sign({"sid": sid, "dev": device, "ch": CHANNEL, "iat": now, "exp": now + SPLASH_TTL,
                          "typ": "splash"})
            code = hmac.new(SECRET, sid.encode(), hashlib.sha256).hexdigest()[:8].upper()
            return self._json(200, {"splashToken": token, "splashCode": code, "expiresIn": SPLASH_TTL,
                                    "channel": CHANNEL})
        flow_paths = ("/janus/transaction", "/janus/secure-login", "/janus/otp/request", "/janus/otp/verify",
                      "/janus/login-user", "/janus/activation/token", "/janus/activation/complete", "/janus/mobile-login")
        if path in flow_paths:
            splash = verify_jwt(self.headers.get("X-Splash-Token", ""), typ="splash")
            if not splash:
                return self._json(401, {"error": "geçersiz veya süresi dolmuş splash token"})
        if path == "/janus/transaction":
            # Client token (dışarı) -> Janus doğrular -> server token (içeri) üretir -> channel-gateway'e iletir
            client = verify_jwt(self.headers.get("Authorization", "").removeprefix("Bearer "), typ="client")
            if not client:
                return self._json(401, {"error": "geçersiz veya süresi dolmuş client token"})
            now = int(time.time())
            server = sign({"sub": client["sub"], "customerId": client["customerId"], "ch": CHANNEL,
                           "typ": "server", "aud": "channel-gateway", "iss": f"janus-{CHANNEL}",
                           "iat": now, "exp": now + SERVER_TTL, "cid": secrets.token_hex(8)})
            st, out = call_upstream(CHANNEL_GATEWAY_URL + "/cg/transaction",
                                    {"code": str(req.get("code", "")), "params": req.get("params", {})},
                                    {"Authorization": "Bearer " + server})
            return self._json(st, out)
        if path == "/janus/secure-login":
            # Akış A/B: Seal'de PIN/cihaz yetkisi (Fortuna, Seal Intranet'i sorgular)
            st, out = call_upstream(FORTUNA_URL + "/fortuna/secure-login", {"flowId": str(req.get("flowId", ""))})
            return self._json(st, out)
        if path == "/janus/otp/request":
            # OtpRequest: SmsOtpCGW (lab: demo OTP yanıtta)
            st, out = call_upstream(SMS_OTP_URL + "/sms/otp/request", {"flowId": str(req.get("flowId", ""))})
            return self._json(st, out)
        if path == "/janus/otp/verify":
            # Parolasız aktivasyon: yalnız SMS OTP doğrulanır (SmsOtpCGW). Cihaz yetkisi secure-login'de (PIN) alındı.
            st, out = call_upstream(SMS_OTP_URL + "/sms/otp/verify",
                                    {"flowId": str(req.get("flowId", "")), "code": str(req.get("smsCode", ""))})
            return self._json(st, out)
        if path == "/janus/login-user":
            # LoginUser: kullanıcı (müşteri no + parola + captcha) Fortuna'da, OTP SmsOtpCGW'de doğrulanır
            flow = str(req.get("flowId", ""))
            st, out = call_upstream(FORTUNA_CGW_URL, {"customerId": str(req.get("customerId", "")),
                                                     "password": str(req.get("password", "")),
                                                     "captcha": str(req.get("captcha", ""))})
            if st != 200:
                return self._json(st, out)
            st2, out2 = call_upstream(SMS_OTP_URL + "/sms/otp/verify", {"flowId": flow, "code": str(req.get("smsCode", ""))})
            if st2 != 200:
                return self._json(st2, out2)
            # Web girişi: Seal yok; OTP tamam -> client token (kanal web). fullName Fortuna'dan gelirse eklenir.
            cust = str(out.get("customerId") or req.get("customerId", ""))
            now = int(time.time())
            token = sign({"sub": cust, "customerId": cust, "ch": CHANNEL, "sid": splash.get("sid"),
                          "iat": now, "exp": now + LOGIN_TTL, "typ": "client", "iss": f"janus-{CHANNEL}"})
            return self._json(200, {"status": "OTP_OK", "customerId": cust, "channel": CHANNEL,
                                    "fullName": out.get("fullName"), "token": token, "expiresIn": LOGIN_TTL,
                                    "refreshToken": issue_refresh(cust, splash.get("dev"))})
        if path == "/janus/activation/token":
            # CreateActivationToken: Fortuna -> Seal Intranet (createActivationToken)
            st, out = call_upstream(FORTUNA_URL + "/fortuna/activation/token",
                                    {"customerId": str(req.get("customerId", "")), "deviceId": splash.get("dev")})
            return self._json(st, out)
        if path == "/janus/activation/complete":
            # ActivationCompleted: Fortuna -> Seal Intranet (getActivationStatus)
            st, out = call_upstream(FORTUNA_URL + "/fortuna/activation/status",
                                    {"activationToken": str(req.get("activationToken", "")),
                                     "customerId": str(req.get("customerId", "")), "deviceId": splash.get("dev")})
            if st != 200:
                return self._json(st, out)
            return self._json(200, {"status": out.get("status")})
        if path == "/janus/mobile-login":
            # MobileUserLogin (aktif müşteri): Fortuna doğrular, Janus login token'ı üretir
            cust = str(req.get("customerId", ""))
            st, out = call_upstream(FORTUNA_URL + "/fortuna/mobile-login",
                                    {"customerId": cust, "flowId": str(req.get("flowId", "")),
                                     "deviceId": splash.get("dev")})
            if st != 200:
                return self._json(st, out)
            now = int(time.time())
            token = sign({"sub": cust, "customerId": cust, "ch": CHANNEL, "sid": splash.get("sid"),
                          "iat": now, "exp": now + LOGIN_TTL, "typ": "client", "iss": f"janus-{CHANNEL}"})
            return self._json(200, {"status": "LOGGED_IN", "token": token, "expiresIn": LOGIN_TTL,
                                    "customerId": cust, "channel": CHANNEL, "fullName": out.get("fullName"),
                                    "refreshToken": issue_refresh(cust, splash.get("dev"))})
        if path == "/janus/token/refresh":
            # Oturum yenileme: splash gerekmez (splash ayrı alınır). Refresh token döndürülür (tek kullanımlık).
            # Mobilde cihaz durumu kontrol edilir; müşteri durumu yenilemede kontrol edilmez (lab sınırı).
            entry = consume_refresh(str(req.get("refreshToken", "")))
            if not entry:
                return self._json(401, {"error": "geçersiz veya süresi dolmuş yenileme token'ı"})
            if entry["ch"] == "mobile":
                # Mobil: cihaz hâlâ ACTIVE mi (iptal/kilit yenilemeyi durdurur). Fortuna monolit denetler.
                st, dst = call_upstream(FORTUNA_URL + "/fortuna/device/status",
                                        {"customerId": entry["cust"], "deviceId": entry["dev"]})
                if st != 200 or dst.get("status") != "ACTIVE":
                    return self._json(403, {"error": "cihaz aktif değil", "deviceStatus": dst.get("status")})
            now = int(time.time())
            token = sign({"sub": entry["cust"], "customerId": entry["cust"], "ch": CHANNEL, "iat": now,
                          "exp": now + LOGIN_TTL, "typ": "client", "iss": f"janus-{CHANNEL}"})
            return self._json(200, {"status": "REFRESHED", "token": token, "expiresIn": LOGIN_TTL,
                                    "customerId": entry["cust"], "channel": CHANNEL,
                                    "refreshToken": issue_refresh(entry["cust"], entry["dev"])})
        return self._json(404, {"error": "bilinmeyen uç nokta"})

    def log_message(self, fmt, *args):
        print(fmt % args, flush=True)


if __name__ == "__main__":
    if not SECRET:
        raise SystemExit("JANUS_KEY tanımlı değil")
    print(f"janus ({CHANNEL}) dinliyor (port {PORT})", flush=True)
    tracing.instrument(Handler)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
