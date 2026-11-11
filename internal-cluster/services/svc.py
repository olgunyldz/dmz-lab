"""İç servis (BFF / core): gelen isteğin iç JWT'sini KENDİSİ doğrular (savunma derinliği, design.md 4.3).

- Gateway başlıklarına (x-channel, x-user-id vb.) GÜVENMEZ. Kanal, kullanıcı ve yöntem yalnızca token claim'lerinden alınır.
- İmza: iç Keycloak JWKS (RS256). iss, aud (kgateway-internal), exp ve kanal kontrol edilir.
- PUBLIC_PATHS=1 ise GET /public/* token gerektirmez (design 5.0a).

Dummy iş API'si (LAB, veritabanı YOK):
  core : /api/v1/accounts, /api/v1/accounts/{id}, /api/v1/accounts/{id}/transactions, POST /api/v1/transfers
         Hesaplar ve işlemler token'daki sub'a göre deterministik üretilir ve bellekte tutulur (restart'ta sıfırlanır).
  bff  : /bff/<kanal>/accounts, /bff/<kanal>/accounts/{id}/transactions, POST /bff/<kanal>/transfers
         Kanal yoldan değil token'dan doğrulanır. Yanıt kanala göre şekillenir ve core'a iç token ile iletilir.
Eski echo endpoint'leri (/bff/accounts, /partner/payments, /public/*) testler için korunur.

Env: SERVICE_NAME, ALLOWED_CHANNELS (csv), EXPECTED_ISSUER, AUDIENCE, JWKS_URL, PUBLIC_PATHS, PORT, CORE_URL (bff).

LAB SINIRI: RS256 stdlib ile doğrulanır. Üretimde kütüphane, JWKS önbellek politikası, mTLS (bff->core) ve kalıcı veri kullanılmalı.
"""
import base64
import hashlib
import hmac
import json
import os
import re
import secrets
import threading
import time
import urllib.error
import urllib.request
from datetime import date
from decimal import Decimal, InvalidOperation
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import tracing  # ConfigMap ile /app/tracing.py (shared/tracing.py)
import metrics  # ConfigMap ile /app/metrics.py (shared/metrics.py)

REQUESTS = metrics.Counter("svc_requests_total", "Servis istek sayısı", ["service", "route", "status"])
LATENCY = metrics.Histogram("svc_request_duration_seconds", "Servis istek süresi", ["service", "route"])
TRANSFERS = metrics.Counter("core_transfers_total", "Transfer sonuçları", ["channel", "result"])
TRANSFER_CENTS = metrics.Counter("core_transfer_amount_cents_total", "Başarılı transferlerin toplam tutarı (kuruş)",
                                 ["channel", "currency"])
KNOWN_ROUTES = ("/bff/", "/api/v1/", "/partner/", "/public/", "/metrics")


def metric_route(route):
    """Etiket kardinalitesini sınırla: bilinmeyen yollar tek etikette toplanır."""
    return route if route.startswith(KNOWN_ROUTES) else "other"

SERVICE = os.environ["SERVICE_NAME"]
ALLOWED = set(os.environ["ALLOWED_CHANNELS"].split(","))
EXPECTED_ISSUER = os.environ["EXPECTED_ISSUER"]
AUDIENCE = os.environ.get("AUDIENCE", "kgateway-internal")
JWKS_URL = os.environ["JWKS_URL"]
PUBLIC_PATHS = os.environ.get("PUBLIC_PATHS", "0") == "1"
PORT = int(os.environ.get("PORT", "8080"))
CORE_URL = os.environ.get("CORE_URL", "")
# /api/v1 ve /bff/* kanalları: BFF ve core aynı iş kanallarını kabul eder. Partner salt okunur (kodda kontrol).
API_CHANNELS = set(os.environ.get("API_CHANNELS", "web,mobile,branch,partner").split(","))

DIGEST_INFO_SHA256 = bytes.fromhex("3031300d060960864801650304020105000420")
_jwks = {}

# Kanal başına tek işlem limiti (kuruş). Partner salt okunur.
CHANNEL_LIMITS = {"web": 10_000_000, "mobile": 1_000_000, "branch": 5_000_000}


class Denied(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message


def b64url_decode(data):
    return base64.urlsafe_b64decode(data + "=" * (-len(data) % 4))


def rsa_verify(n, e, signing_input, sig):
    k = (n.bit_length() + 7) // 8
    if len(sig) != k:
        return False
    recovered = pow(int.from_bytes(sig, "big"), e, n).to_bytes(k, "big")
    t = DIGEST_INFO_SHA256 + hashlib.sha256(signing_input).digest()
    expected = b"\x00\x01" + b"\xff" * (k - len(t) - 3) + b"\x00" + t
    return hmac.compare_digest(recovered, expected)


def load_jwks():
    global _jwks
    with urllib.request.urlopen(JWKS_URL, timeout=5) as resp:
        data = json.loads(resp.read())
    _jwks = {
        k["kid"]: (int.from_bytes(b64url_decode(k["n"]), "big"), int.from_bytes(b64url_decode(k["e"]), "big"))
        for k in data["keys"] if k.get("kty") == "RSA"
    }


def verify(token, allowed_channels):
    try:
        h_b64, p_b64, s_b64 = token.split(".")
        header = json.loads(b64url_decode(h_b64))
        claims = json.loads(b64url_decode(p_b64))
        sig = b64url_decode(s_b64)
    except Exception:
        raise Denied(401, "malformed token")
    if header.get("alg") != "RS256":
        raise Denied(401, "unsupported alg")
    kid = header.get("kid")
    if kid not in _jwks:
        try:
            load_jwks()
        except Exception:
            raise Denied(503, "jwks unavailable")
    if kid not in _jwks:
        raise Denied(401, "unknown kid")
    n, e = _jwks[kid]
    if not rsa_verify(n, e, f"{h_b64}.{p_b64}".encode(), sig):
        raise Denied(401, "bad signature")

    if claims.get("iss") != EXPECTED_ISSUER:
        raise Denied(401, "issuer mismatch")
    aud = claims.get("aud")
    auds = aud if isinstance(aud, list) else [aud]
    if AUDIENCE not in auds:
        raise Denied(401, "audience mismatch")
    if int(claims.get("exp", 0)) <= int(time.time()):
        raise Denied(401, "token expired")
    if claims.get("channel") not in allowed_channels:
        raise Denied(403, "channel not allowed for this service")
    return claims


# ---------------------------------------------------------------------------
# Dummy veri deposu (core). Bellekte; deterministik seed (sub'a göre).
# ---------------------------------------------------------------------------
STORE_LOCK = threading.Lock()
ACCOUNTS = {}      # hesap id -> hesap
OWNERS = {}        # sub -> [hesap id, ...]
TXS = {}           # hesap id -> [işlem, ...]
IDEMPOTENT = {}    # (sub, Idempotency-Key) -> yanıt gövdesi


def _h(text, n):
    return hashlib.sha256(text.encode()).hexdigest()[:n].upper()


def fmt_money(cents):
    sign = "-" if cents < 0 else ""
    cents = abs(cents)
    return f"{sign}{cents // 100}.{cents % 100:02d}"


def _seed_counterparties():
    names = ["Elektrik İdaresi", "Su İdaresi", "Market Zinciri", "Kira Hesabı", "Sigorta Şirketi"]
    for i, name in enumerate(names):
        aid = f"EXT-{100001 + i}"
        ACCOUNTS[aid] = {"id": aid, "owner": None, "name": name, "currency": "TRY", "balance": 0}


def _seed_owner(sub):
    """Kullanıcıya iki dummy hesap ve üç dummy işlem ekler (ilk erişimde, deterministik)."""
    if sub in OWNERS:
        return
    specs = [("chk", "Vadesiz TRY", 1_250_000 + int(_h(sub, 4), 16) * 10),
             ("sav", "Birikim TRY", 8_400_000 + int(_h(sub + "s", 4), 16) * 10)]
    ids = []
    for tag, name, balance in specs:
        aid = "TR" + _h(sub + tag, 12)
        ACCOUNTS[aid] = {"id": aid, "owner": sub, "name": name, "currency": "TRY", "balance": balance}
        seed_tx = [("maaş", 4_500_000), ("market", -185_050), ("fatura", -62_300)]
        TXS[aid] = [{"id": "TX" + _h(aid + str(k), 8), "date": f"2026-11-0{k + 1}", "type": t,
                     "amount": fmt_money(a), "currency": "TRY", "counterparty": None,
                     "description": t.capitalize()} for k, (t, a) in enumerate(seed_tx)]
        ids.append(aid)
    OWNERS[sub] = ids


def _account_view(acc):
    return {"id": acc["id"], "name": acc["name"], "currency": acc["currency"],
            "balance": fmt_money(acc["balance"])}


def _own_account(sub, aid):
    acc = ACCOUNTS.get(aid)
    if not acc or acc["owner"] != sub:
        raise Denied(404, "hesap bulunamadı")  # varlığını sızdırmamak için yetkisiz hesap da 404
    return acc


def parse_amount(value):
    try:
        d = Decimal(str(value))
    except (InvalidOperation, ValueError):
        raise Denied(400, "tutar geçersiz")
    if d <= 0 or d.as_tuple().exponent < -2:
        raise Denied(400, "tutar pozitif ve en fazla 2 ondalıklı olmalı")
    return int(d * 100)


def core_accounts(claims):
    with STORE_LOCK:
        _seed_owner(claims["sub"])
        return {"accounts": [_account_view(ACCOUNTS[a]) for a in OWNERS[claims["sub"]]]}


def core_account(claims, aid):
    with STORE_LOCK:
        _seed_owner(claims["sub"])
        return _account_view(_own_account(claims["sub"], aid))


def core_transactions(claims, aid):
    with STORE_LOCK:
        _seed_owner(claims["sub"])
        _own_account(claims["sub"], aid)
        return {"account_id": aid, "transactions": list(TXS.get(aid, []))}


def core_transfer(claims, body, idem):
    ch = claims.get("channel")
    sub = claims["sub"]
    if ch == "partner":
        raise Denied(403, "partner kanalı salt okunur")
    if not idem:
        raise Denied(400, "Idempotency-Key başlığı zorunlu")
    src_id, dst_id = body.get("from"), body.get("to")
    if not src_id or not dst_id:
        raise Denied(400, "from ve to zorunlu")
    cents = parse_amount(body.get("amount"))
    with STORE_LOCK:
        key = (sub, idem)
        if key in IDEMPOTENT:
            return IDEMPOTENT[key]  # aynı istek tekrarı: önceki yanıt (çift işlem yok)
        _seed_owner(sub)
        src = _own_account(sub, src_id)
        dst = ACCOUNTS.get(dst_id)
        if not dst:
            raise Denied(404, "hedef hesap bulunamadı")
        currency = body.get("currency", src["currency"])
        if currency != src["currency"] or dst["currency"] != src["currency"]:
            raise Denied(422, "para birimi uyuşmuyor")
        limit = CHANNEL_LIMITS.get(ch, 0)
        if cents > limit:
            raise Denied(422, f"kanal limiti aşıldı (limit {fmt_money(limit)} {src['currency']})")
        if src["balance"] < cents:
            raise Denied(422, "yetersiz bakiye")
        src["balance"] -= cents
        dst["balance"] += cents
        tid = "TX" + secrets.token_hex(4).upper()
        today = date.today().isoformat()
        desc = str(body.get("description", "havale"))[:120]
        TXS.setdefault(src_id, []).insert(0, {"id": tid, "date": today, "type": "havale", "amount": fmt_money(-cents),
                                              "currency": src["currency"], "counterparty": dst_id, "description": desc})
        if dst["owner"]:
            TXS.setdefault(dst_id, []).insert(0, {"id": tid, "date": today, "type": "havale",
                                                  "amount": fmt_money(cents), "currency": dst["currency"],
                                                  "counterparty": src_id, "description": desc})
        resp = {"transfer_id": tid, "status": "completed", "from": src_id, "to": dst_id,
                "amount": fmt_money(cents), "currency": src["currency"], "balance_after": fmt_money(src["balance"])}
        IDEMPOTENT[key] = resp
        return resp


_seed_counterparties()


# ---------------------------------------------------------------------------
# BFF: kanal şekillendirme ve core çağrısı
# ---------------------------------------------------------------------------
def call_core(method, path, auth, body=None, idem=None, span=None):
    """BFF -> core çağrısı; istemci span'i ve traceparent ile izlenir."""
    child = tracing.start_client_span(f"{SERVICE} -> core {method} {path.split('?')[0]}", span,
                                      {"peer.service": "core"}) if span else None
    status = None
    try:
        status, payload = _call_core(method, path, auth, body, idem, child.header() if child else None)
        return status, payload
    finally:
        if child:
            child.end(http_status=status)


def _call_core(method, path, auth, body=None, idem=None, tp=None):
    if not CORE_URL:
        raise Denied(503, "core adresi tanımlı değil")
    req = urllib.request.Request(CORE_URL + path, data=body, method=method)
    req.add_header("Authorization", auth)  # iç token iletilir (forwardToken); core kendisi de doğrular
    if tp:
        req.add_header("traceparent", tp)
    if idem:
        req.add_header("Idempotency-Key", idem)
    if body is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.status, json.loads(resp.read() or b"{}")
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read() or b"{}")
        except json.JSONDecodeError:
            return e.code, {"error": "core_error"}
    except urllib.error.URLError:
        raise Denied(503, "core servisine ulaşılamadı")


def shape_for_channel(channel, payload):
    """Kanala göre yanıt: mobil sadeleşir, şube kayda 'teller' görünümü ekler."""
    if channel == "mobile" and "accounts" in payload:
        return {"accounts": [{"id": a["id"], "name": a["name"], "balance": a["balance"]} for a in payload["accounts"]]}
    if channel == "mobile" and "transactions" in payload:
        return {**payload, "transactions": payload["transactions"][:5]}
    if channel == "branch":
        return {**payload, "view": "teller"}
    return payload


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------
ERROR_CODES = {400: "invalid_request", 401: "unauthorized", 403: "forbidden", 404: "not_found",
               422: "unprocessable", 500: "server_error", 503: "service_unavailable"}
ROUTE_CORE = re.compile(r"^/api/v1/accounts(?:/([A-Za-z0-9-]+)(/transactions)?)?$")
ROUTE_BFF = re.compile(r"^/bff/(web|mobile|branch)/(accounts(?:/([A-Za-z0-9-]+)/transactions)?|transfers)$")


class Handler(BaseHTTPRequestHandler):
    def _send(self, status, body):
        self._status = status
        if status >= 400:
            # Hata gövdesi yapılandırılmış JSON: iç servis reddi nedeniyle birlikte döner
            message = body.strip()
            data = json.dumps({"error": ERROR_CODES.get(status, "error"), "error_description": message,
                               "layer": f"internal-service:{SERVICE}", "status": status},
                              ensure_ascii=False).encode()
            ctype = "application/json; charset=utf-8"
        else:
            data = body.encode()
            ctype = "text/plain"
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        if status == 401:
            self.send_header("WWW-Authenticate", f'Bearer error="invalid_token", error_description="{message}"')
        self.end_headers()
        self.wfile.write(data)

    def _json(self, status, obj):
        self._status = status
        data = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _body(self):
        n = int(self.headers.get("Content-Length", "0") or 0)
        raw = self.rfile.read(n) if n else b""
        try:
            return json.loads(raw or b"{}"), raw
        except json.JSONDecodeError:
            raise Denied(400, "geçersiz JSON")

    def _route_core(self, claims, path, method):
        m = ROUTE_CORE.match(path)
        if not m:
            raise Denied(404, "bulunamadı")
        aid, tx = m.group(1), m.group(2)
        if aid is None:
            if method != "GET":
                raise Denied(405, "izin verilmeyen yöntem")
            return 200, core_accounts(claims)
        if tx:
            if method != "GET":
                raise Denied(405, "izin verilmeyen yöntem")
            return 200, core_transactions(claims, aid)
        if method != "GET":
            raise Denied(405, "izin verilmeyen yöntem")
        return 200, core_account(claims, aid)

    def _route_transfer(self, claims, method, raw_body, body, idem):
        if method != "POST":
            raise Denied(405, "izin verilmeyen yöntem")
        ch = claims.get("channel", "unknown")
        try:
            resp = core_transfer(claims, body, idem)
        except Denied as d:
            TRANSFERS.inc(channel=ch, result=f"http_{d.status}")
            raise
        TRANSFERS.inc(channel=ch, result="ok")
        cents = int(Decimal(resp["amount"]) * 100)
        TRANSFER_CENTS.inc(cents, channel=ch, currency=resp["currency"])
        return 200, resp

    def _route_bff(self, claims, path, method, auth, body_obj, raw_body, idem, span=None):
        m = ROUTE_BFF.match(path)
        if not m:
            raise Denied(404, "bulunamadı")
        ch = m.group(1)
        if claims.get("channel") != ch:
            raise Denied(403, "kanal yolu token kanalıyla uyuşmuyor")
        rest = m.group(2)
        if rest == "transfers":
            if method != "POST":
                raise Denied(405, "izin verilmeyen yöntem")
            status, payload = call_core("POST", "/api/v1/transfers", auth, raw_body, idem, span)
            return status, payload
        if method != "GET":
            raise Denied(405, "izin verilmeyen yöntem")
        if m.group(3):
            status, payload = call_core("GET", f"/api/v1/accounts/{m.group(3)}/transactions", auth, span=span)
        else:
            status, payload = call_core("GET", "/api/v1/accounts", auth, span=span)
        if status == 200:
            payload = shape_for_channel(ch, payload)
        return status, payload

    def _handle(self):
        path = self.path.split("?", 1)[0]
        # Span adında kimlikleri maskele (TR..., EXT-...); tam yol http.target'ta kalır
        route = re.sub(r"/(TR[0-9A-F]{12}|EXT-\d+)(?=/|$)", "/{id}", path)
        span = tracing.start_server_span(f"{SERVICE} {self.command} {route}", self.headers.get("traceparent"),
                                         {"http.method": self.command, "http.target": path,
                                          "x-request-id": self.headers.get("X-Request-ID")})
        self._status = None
        started = time.perf_counter()
        try:
            self._dispatch(span)
        finally:
            code = self._status or 200
            span.end(http_status=code)
            labels = {"service": SERVICE, "route": metric_route(route)}
            REQUESTS.inc(status=str(code), **labels)
            LATENCY.observe(time.perf_counter() - started, **labels)

    def _dispatch(self, span):
        path = self.path.split("?", 1)[0]
        if PUBLIC_PATHS and self.command == "GET" and path.startswith("/public/"):
            return self._send(200, f"service={SERVICE} public path={self.path}\n")
        auth = self.headers.get("Authorization", "")
        idem = self.headers.get("Idempotency-Key", "")
        try:
            if not auth.startswith("Bearer "):
                raise Denied(401, "missing bearer token")
            is_api = (path.startswith("/api/v1/") and SERVICE == "core") or \
                     (path.startswith("/bff/") and SERVICE == "bff" and ROUTE_BFF.match(path))
            claims = verify(auth[len("Bearer "):], API_CHANNELS if is_api else ALLOWED)
            span.set("channel", claims.get("channel"))
            span.set("auth_method", claims.get("auth_method"))
            span.set("user.hash", tracing.user_hash(claims.get("sub")))
            if path.startswith("/api/v1/") and SERVICE == "core":
                body_obj, raw = ({}, b"")
                if self.command == "POST":
                    body_obj, raw = self._body()
                if path == "/api/v1/transfers":
                    status, payload = self._route_transfer(claims, self.command, raw, body_obj, idem)
                else:
                    status, payload = self._route_core(claims, path, self.command)
                return self._json(status, payload)
            if path.startswith("/bff/") and SERVICE == "bff" and ROUTE_BFF.match(path):
                body_obj, raw = ({}, b"")
                if self.command == "POST":
                    body_obj, raw = self._body()
                status, payload = self._route_bff(claims, path, self.command, auth, body_obj, raw, idem, span)
                return self._json(status, payload)
        except Denied as d:
            return self._send(d.status, d.message + "\n")
        self._send(200, f"service={SERVICE} channel={claims.get('channel')} user={claims.get('sub')} "
                        f"auth_method={claims.get('auth_method')} path={self.path}\n")

    do_GET = do_POST = do_PUT = do_DELETE = do_PATCH = _handle

    def log_message(self, fmt, *args):
        print(f"{SERVICE} {self.command} {self.path} {fmt % args}", flush=True)


if __name__ == "__main__":
    metrics.start_metrics_server(int(os.environ.get("METRICS_PORT", "9100")))  # metrikler API portundan ayrı
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
