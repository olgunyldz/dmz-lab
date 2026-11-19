# Janus (lab): kanal ağ geçidi. CHANNEL=web|mobile. Splash token'ı Janus kendi anahtarıyla (HS256) imzalar.
# Bu aşama: sağlık ve splash uçları. Login/OTP/işlem uçları sonraki adımda (Fortuna mock'ları ile birlikte).
import hashlib
import hmac
import base64
import http.client
import re
import json
import os
import secrets
import ssl
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError
from urllib.parse import parse_qs, urlencode, urlparse, urlsplit
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
IDP_USERS_URL = os.environ.get("IDP_USERS_URL", "")  # auth-server kullanıcı oluşturma (HTTPS, Janus CN'i ile mTLS)
SERVER_TTL = 60  # iç (server) token: kısa ömürlü, yalnız Janus -> channel-gateway
_PENDING = {}  # flowId -> {customerId, exp}; tek replika (lab)
_PLOCK = threading.Lock()


FIRST_NAMES = ["Ayşe", "Mehmet", "Elif", "Ahmet", "Zeynep", "Mustafa", "Fatma", "Emre", "Derya", "Can",
               "Selin", "Burak", "Merve", "Kerem", "Gizem", "Oğuz", "Ceren", "Tolga", "Hande", "Serkan"]
LAST_NAMES = ["Yılmaz", "Kaya", "Demir", "Çelik", "Şahin", "Öztürk", "Aydın", "Arslan", "Doğan", "Kılıç",
              "Aslan", "Çetin", "Koç", "Kurt", "Özdemir", "Polat", "Güneş", "Erdoğan", "Acar", "Tuncer"]


def random_amount(lo, hi):
    """lo..hi arası rastgele TL tutarı (kuruş dahil), metin olarak."""
    cents = secrets.randbelow((hi - lo) * 100 + 1)
    return f"{lo + cents // 100}.{cents % 100:02d}"


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


# ---- IdP (auth-server) token: yalnız mobil kanal. Parola bu süreçte geçici kullanılır, saklanmaz/loglanmaz. ----
IDP_HOST = os.environ.get("IDP_HOST", "id.bank.lab.local")
IDP_PORT = int(os.environ.get("IDP_PORT", "30543"))
IDP_REALM = "/realms/bank/protocol/openid-connect"
IDP_CLIENTS = {"web": ("web-app", "https://web.lab.local:8443/callback"),
               "mobile": ("mobile-app", "com.bank.app:/callback")}
IDP_CLIENT, IDP_REDIRECT = IDP_CLIENTS.get(CHANNEL, IDP_CLIENTS["mobile"])  # kanala göre IdP istemcisi (PKCE zorunlu)
# Yenileme token'ı yalnız mobilde (web: oturum Janus client token'ı ile yürür)
IDP_SCOPE = "openid profile offline_access" if CHANNEL == "mobile" else "openid profile"
IDP_CLIENT_SECRET = os.environ.get("IDP_CLIENT_SECRET", "")  # mobile-app gizli anahtarı (Janus'ta; konsolda yok)


class IdpError(Exception):
    pass


def _idp_conn():
    ctx = ssl.create_default_context(cafile=TLS_CA)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    return http.client.HTTPSConnection(IDP_HOST, IDP_PORT, context=ctx, timeout=15)


def _idp_token(form):
    basic = base64.b64encode(f"{IDP_CLIENT}:{IDP_CLIENT_SECRET}".encode()).decode()
    conn = _idp_conn()
    try:
        conn.request("POST", IDP_REALM + "/token", body=urlencode(form),
                     headers={"Content-Type": "application/x-www-form-urlencoded", "Authorization": "Basic " + basic})
        r = conn.getresponse()
        data = r.read()
    finally:
        conn.close()
    if r.status != 200:
        raise IdpError(r.status)
    return json.loads(data or b"{}")


def idp_password_login(customer, password):
    """Authorization Code + PKCE: giriş formu IdP'de doldurulur, kod token'a çevrilir."""
    verifier = b64u(secrets.token_bytes(32))
    challenge = b64u(hashlib.sha256(verifier.encode()).digest())
    q = urlencode({"response_type": "code", "client_id": IDP_CLIENT, "redirect_uri": IDP_REDIRECT,
                   "scope": IDP_SCOPE, "state": "janus", "code_challenge": challenge,
                   "code_challenge_method": "S256"})
    conn = _idp_conn()
    cookies, code, posted = {}, None, False
    try:
        path, method, body, headers = IDP_REALM + "/auth?" + q, "GET", None, {}
        for _ in range(15):
            if cookies:
                headers["Cookie"] = "; ".join(f"{k}={v}" for k, v in cookies.items())
            conn.request(method, path, body=body, headers=headers)
            r = conn.getresponse()
            data = r.read()
            for sc in r.headers.get_all("Set-Cookie") or []:
                k, v = sc.split(";")[0].split("=", 1)
                cookies[k] = v
            if r.status in (301, 302, 303, 307):
                loc = r.getheader("Location") or ""
                if loc.startswith(IDP_REDIRECT):
                    qs = parse_qs(urlsplit(loc).query)
                    if "code" not in qs:
                        raise IdpError(400)     # IdP hata döndü (örn. istemci/kapsam reddi)
                    code = qs["code"][0]
                    break
                p = urlsplit(loc)
                path, method, body, headers = p.path + ("?" + p.query if p.query else ""), "GET", None, {}
                continue
            if r.status == 200 and b'name="_csrf"' in data:
                if posted:
                    raise IdpError(401)          # giriş formu tekrar geldi: parola yanlış
                m = re.search(rb'name="_csrf"[^>]*value="([^"]+)"', data) or re.search(rb'value="([^"]+)"[^>]*name="_csrf"', data)
                if not m:
                    raise IdpError(502)
                body = urlencode({"username": customer.lower(), "password": password, "_csrf": m.group(1).decode()})
                path, method, headers, posted = "/login", "POST", {"Content-Type": "application/x-www-form-urlencoded"}, True
                continue
            raise IdpError(r.status)
    finally:
        conn.close()
    if not code:
        raise IdpError(502)
    return _idp_token({"grant_type": "authorization_code", "code": code, "redirect_uri": IDP_REDIRECT,
                       "code_verifier": verifier})


def idp_refresh(refresh_token):
    return _idp_token({"grant_type": "refresh_token", "refresh_token": refresh_token})


def call_upstream(url, body, headers=None):
    path = urlparse(url).path
    peer = ("channel-gateway" if path.startswith("/cg/") else "sms-otp" if path.startswith("/sms/")
            else "fortuna" if path.startswith("/fortuna/") else "auth-server" if path.startswith("/internal/")
            else "upstream")
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
            # Web girişi: parola IdP'de doğrulanır (web-app istemcisi, PKCE); ardından SMS OTP (SmsOtpCGW).
            # Janus client token'ı kanal anahtarıyla (JANUS_KEY_WEB) imzalanır; IdP token'ı saklanmaz.
            flow = str(req.get("flowId", ""))
            cust = str(req.get("customerId", "")).strip().upper()
            try:
                idp_password_login(cust, str(req.get("password", "")))
            except IdpError as e:
                code = e.args[0] if e.args else 502
                if code in (400, 401):
                    return self._json(401, {"error": "kimlik doğrulanamadı"})
                return self._json(502, {"error": "IdP erişilemedi (" + str(code) + ")"})
            st2, out2 = call_upstream(SMS_OTP_URL + "/sms/otp/verify", {"flowId": flow, "code": str(req.get("smsCode", ""))})
            if st2 != 200:
                return self._json(st2, out2)
            st3, prof = call_upstream(FORTUNA_URL + "/fortuna/customer/profile", {"customerId": cust})
            full = prof.get("fullName") if st3 == 200 else None
            now = int(time.time())
            token = sign({"sub": cust, "customerId": cust, "ch": CHANNEL, "sid": splash.get("sid"),
                          "iat": now, "exp": now + LOGIN_TTL, "typ": "client", "iss": f"janus-{CHANNEL}"})
            return self._json(200, {"status": "OTP_OK", "customerId": cust, "channel": CHANNEL,
                                    "fullName": full, "token": token, "expiresIn": LOGIN_TTL,
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
        if path == "/janus/mobile/idp-token":
            # IdP access/refresh token (yalnız mobil). grant=password: yeni cihaz aktivasyonu; grant=refresh: sonraki girişler.
            if CHANNEL != "mobile":
                return self._json(404, {"error": "bilinmeyen uç nokta"})
            try:
                if req.get("grant") == "refresh":
                    tok = idp_refresh(str(req.get("refreshToken", "")))
                else:
                    tok = idp_password_login(str(req.get("customerId", "")), str(req.get("password", "")))
            except IdpError as e:
                code = e.args[0] if e.args else 502
                if code in (400, 401):
                    return self._json(401, {"error": "kimlik doğrulanamadı veya oturum yenilenemedi"})
                return self._json(502, {"error": "IdP erişilemedi (" + str(code) + ")"})
            return self._json(200, {"accessToken": tok["access_token"], "refreshToken": tok.get("refresh_token"),
                                    "expiresIn": tok.get("expires_in")})
        if path == "/janus/customer/create":
            # Müşteri ekleme: Fortuna (müşteri, hesaplar, açılış bakiyesi) -> IdP (kullanıcı, parola).
            # Parola yalnız IdP'ye iletilir; Janus saklamaz, loglamaz. IdP başarısızsa Fortuna kaydı geri alınır.
            if not (IDP_USERS_URL and FORTUNA_URL):
                return self._json(503, {"error": "müşteri uç noktaları tanımlı değil"})
            password = str(req.get("password", ""))
            if len(password) < 8:
                return self._json(400, {"error": "parola en az 8 karakter olmalı"})
            for _ in range(5):
                cust = "C" + f"{secrets.randbelow(10 ** 9):09d}"
                name = f"{secrets.choice(FIRST_NAMES)} {secrets.choice(LAST_NAMES)}"
                accounts = [{"type": "vadesiz", "balance": random_amount(1000, 60000)},
                            {"type": "birikim", "balance": random_amount(500, 25000)}]
                st, out = call_upstream(FORTUNA_URL + "/fortuna/customer/create",
                                        {"customerId": cust, "fullName": name, "accounts": accounts})
                if st == 409:
                    continue
                if st != 201:
                    return self._json(st if st < 500 else 502, {"error": out.get("error") or "Fortuna hatası"})
                st2, out2 = call_upstream(IDP_USERS_URL, {"username": cust.lower(), "password": password})
                if st2 == 201:
                    return self._json(201, {"customerId": cust, "fullName": name, "accounts": out.get("accounts", []),
                                            "channel": CHANNEL})
                # IdP yazılamadı: Fortuna kaydını geri al (yarım müşteri kalmasın)
                call_upstream(FORTUNA_URL + "/fortuna/customer/delete", {"customerId": cust})
                if st2 == 409:
                    continue
                return self._json(st2 if st2 < 500 else 502, {"error": out2.get("error") or "IdP hatası"})
            return self._json(409, {"error": "müşteri no üretilemedi, yeniden deneyin"})
        return self._json(404, {"error": "bilinmeyen uç nokta"})

    def log_message(self, fmt, *args):
        print(fmt % args, flush=True)


if __name__ == "__main__":
    if not SECRET:
        raise SystemExit("JANUS_KEY tanımlı değil")
    print(f"janus ({CHANNEL}) dinliyor (port {PORT})", flush=True)
    tracing.instrument(Handler)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
