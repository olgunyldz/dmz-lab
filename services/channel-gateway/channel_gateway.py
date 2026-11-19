# channel-gateway (lab mock, bank-prod). Janus'un ürettiği SERVER token'ı doğrular (iss janus-<kanal>, aud channel-gateway),
# işlemi çalıştırır ve sonucu Janus'a döner. BALANCE: hesapları Fortuna monolith'inden alır.
# Lab notu: Janus anahtarları (HS256) bu servise secret ile verilir; prod'da Janus açık anahtarı (JWKS) kullanılır.
import base64
import hashlib
import hmac
import json
import os
import ssl
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError
from urllib.parse import urlencode, urlparse
from urllib.request import Request, urlopen

os.environ.setdefault("SERVICE_NAME", "channel-gateway")
import tracing  # ConfigMap ile /app/tracing.py (shared/tracing.py)

PORT = int(os.environ.get("PORT", "8080"))
# mTLS (lab): TLS_CERT/TLS_KEY/TLS_CA verilirse HTTPS. İstemci sertifikası ALLOWED_CLIENTS içindeki CN olmalı.
TLS_CERT = os.environ.get("TLS_CERT", "")
TLS_KEY = os.environ.get("TLS_KEY", "")
TLS_CA = os.environ.get("TLS_CA", "")
TLS_ON = bool(TLS_CERT and TLS_KEY and TLS_CA)
ALLOWED_CLIENTS = {"janus-web", "janus-mobile"}
FORTUNA_URL = os.environ.get("FORTUNA_URL", "")
KEYS = {
    "janus-web": os.environ.get("JANUS_KEY_WEB", "").encode(),
    "janus-mobile": os.environ.get("JANUS_KEY_MOBILE", "").encode(),
}


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


def b64u(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def verify_server_token(token):
    try:
        head, body, sig = token.split(".")
        claims = json.loads(base64.urlsafe_b64decode(body + "=" * (-len(body) % 4)))
    except (ValueError, TypeError):
        return None
    key = KEYS.get(claims.get("iss", ""))
    if not key:
        return None
    expect = b64u(hmac.new(key, f"{head}.{body}".encode(), hashlib.sha256).digest())
    if not hmac.compare_digest(expect, sig):
        return None
    if claims.get("typ") != "server" or claims.get("aud") != "channel-gateway":
        return None
    if claims.get("exp", 0) < time.time():
        return None
    return claims


# fortuna-mock'a mTLS istemci bağlamı (channel-gateway-client sertifikası)
FORTUNA_TLS_CERT = os.environ.get("FORTUNA_TLS_CERT", "")
FORTUNA_TLS_KEY = os.environ.get("FORTUNA_TLS_KEY", "")
FORTUNA_TLS_CA = os.environ.get("FORTUNA_TLS_CA", "")
_FORTUNA_CTX = None


def _fortuna_ctx():
    global _FORTUNA_CTX
    if _FORTUNA_CTX is None:
        ctx = ssl.create_default_context(cafile=FORTUNA_TLS_CA)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2
        ctx.load_cert_chain(FORTUNA_TLS_CERT, FORTUNA_TLS_KEY)
        _FORTUNA_CTX = ctx
    return _FORTUNA_CTX


def fortuna_accounts(customer_id):
    with tracing.client_span("channel-gateway->fortuna GET /fortuna/accounts", peer="fortuna-mock") as sp:
        req = Request(FORTUNA_URL + "/fortuna/accounts?customer=" + customer_id, method="GET",
                      headers=tracing.inject({}))
        try:
            with urlopen(req, timeout=10, context=_fortuna_ctx() if FORTUNA_URL.startswith("https://") else None) as r:
                if sp is not None:
                    sp.set("http.status_code", r.status)
                return r.status, json.loads(r.read() or b"{}")
        except HTTPError as e:
            if sp is not None:
                sp.set("http.status_code", e.code)
            return e.code, {"error": "Fortuna hatası"}
        except Exception as e:
            return 502, {"error": f"Fortuna erişilemedi: {type(e).__name__}"}


def fortuna_call(method, path, body=None):
    """Fortuna'ya GET/POST; Fortuna'nın hata mesajı (ör. yetersiz bakiye) istemciye iletilir."""
    data = None if body is None else json.dumps(body).encode()
    with tracing.client_span(f"channel-gateway->fortuna {method} {path.split('?')[0]}", peer="fortuna-mock") as sp:
        req = Request(FORTUNA_URL + path, data=data, method=method,
                      headers=tracing.inject({"Content-Type": "application/json"}))
        try:
            with urlopen(req, timeout=10, context=_fortuna_ctx() if FORTUNA_URL.startswith("https://") else None) as r:
                if sp is not None:
                    sp.set("http.status_code", r.status)
                return r.status, json.loads(r.read() or b"{}")
        except HTTPError as e:
            if sp is not None:
                sp.set("http.status_code", e.code)
            try:
                return e.code, json.loads(e.read() or b"{}")
            except ValueError:
                return e.code, {"error": "Fortuna hatası"}
        except Exception as e:
            return 502, {"error": f"Fortuna erişilemedi: {type(e).__name__}"}


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


class Handler(BaseHTTPRequestHandler):
    server_version = "channel-gateway"

    def _json(self, code, obj):
        _count(self.command, self.path, code)
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.split('?')[0] == '/metrics':
            return _send_metrics(self, "channel-gateway")
        if urlparse(self.path).path == "/cg/health":
            return self._json(200, {"status": "ok"})
        return self._json(404, {"error": "bilinmeyen uç nokta"})

    def do_POST(self):
        if urlparse(self.path).path != "/cg/transaction":
            return self._json(404, {"error": "bilinmeyen uç nokta"})
        if TLS_ON and peer_cn(self.connection) not in ALLOWED_CLIENTS:
            return self._json(401, {"error": "istemci sertifikası yok veya yetkisiz"})
        token = self.headers.get("Authorization", "").removeprefix("Bearer ")
        claims = verify_server_token(token)
        if not claims:
            return self._json(401, {"error": "geçersiz server token"})
        n = int(self.headers.get("Content-Length", "0") or 0)
        try:
            req = json.loads(self.rfile.read(n) or b"{}")
        except ValueError:
            return self._json(400, {"error": "geçersiz JSON"})
        code = req.get("code")
        if code == "BALANCE":
            st, out = fortuna_accounts(claims["customerId"])
            if st != 200:
                return self._json(st, out)
            return self._json(200, {"status": "OK", "code": code, "channel": claims["ch"],
                                    "customerId": claims["customerId"], "accounts": out.get("accounts", [])})
        if code == "HISTORY":
            params = req.get("params") or {}
            query = urlencode({"customer": claims["customerId"], "account": str(params.get("account", "")),
                               "limit": str(params.get("limit", 20))})
            st, out = fortuna_call("GET", "/fortuna/history?" + query)
            if st != 200:
                return self._json(st, out)
            return self._json(200, {"status": "OK", "code": code, "channel": claims["ch"],
                                    "customerId": claims["customerId"], "transactions": out.get("transactions", [])})
        if code == "TRANSFER":
            params = req.get("params") or {}
            st, out = fortuna_call("POST", "/fortuna/transfer", {
                "customer": claims["customerId"], "fromAccount": str(params.get("fromAccount", "")),
                "toAccount": str(params.get("toAccount", "")), "amount": params.get("amount"),
                "description": str(params.get("description", ""))})
            if st != 200:
                return self._json(st, out)
            return self._json(200, {"status": "OK", "code": code, "channel": claims["ch"], **out})
        return self._json(400, {"error": f"desteklenmeyen işlem: {code}"})

    def log_message(self, fmt, *args):
        print(fmt % args, flush=True)


if __name__ == "__main__":
    tracing.instrument(Handler)
    httpd = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    if TLS_ON:
        # CERT_OPTIONAL: probe ve Prometheus istemci sertifikası sunmaz; /cg/transaction uygulama katmanında zorunlu kılınır.
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2
        ctx.load_cert_chain(TLS_CERT, TLS_KEY)
        ctx.load_verify_locations(TLS_CA)
        ctx.verify_mode = ssl.CERT_OPTIONAL
        httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
    print(f"channel-gateway dinliyor (port {PORT}, tls={'evet' if TLS_ON else 'hayır'})", flush=True)
    httpd.serve_forever()
