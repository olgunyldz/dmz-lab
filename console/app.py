#!/usr/bin/env python3
"""DMZ lab organizer ve kanal sayfaları (YALNIZ LAB).

Çalıştırma (repo kökünden):  PYTHONIOENCODING=utf-8 python console/app.py  ->  http://127.0.0.1:9000
  /              organizer: tüm kanallara linkler, oturum durumu
  /ch/<kanal>    kanal sayfası: giriş ve çıkış (her zaman görünür), kanala özel çağrılar
Kanallar: web, mobile, partner, branch (şube), public.

Ön koşullar: edge ayakta (docker compose), gw-branch kurulu (load-branch.sh), identity kurulu (setup-realm.sh),
kubectl erişimi. Sunucu identity IdP'ye port-forward açar (mobil login için).

Güvenlik notları (lab): client secret ve parolalar yalnız bellekte; tarayıcıya gönderilmez. Token'lar
tarayıcıya ham gitmez, yalnız claim özeti. Token imzası burada doğrulanmaz.
"""
import atexit
import base64
import hashlib
import html
import http.client
import http.server
import json
import os
import re
import secrets
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# İzleme: span'ler kendi kurulan port-forward üzerinden mgmt cluster'daki Jaeger OTLP girişine gider
os.environ.setdefault("OTLP_ENDPOINT", "http://127.0.0.1:14318")
os.environ.setdefault("SERVICE_NAME", "console")
sys.path.insert(0, str(ROOT / "shared"))
import tracing  # noqa: E402  (shared/tracing.py)

# İstek başına trace kimliği. Tarayıcı X-Trace-Id gönderirse aynen kullanılır (üzerine yazılmaz).
_req = threading.local()
TID_RE = re.compile(r"^[0-9a-f]{32}$")


def inbound_trace_id(headers):
    # Öncelik: X-Trace-Id (tarayıcı), sonra W3C traceparent; ikisi de yoksa yeni üretilir.
    v = (headers.get("X-Trace-Id") or "").strip().lower()
    if TID_RE.match(v):
        return v
    parts = (headers.get("traceparent") or "").strip().lower().split("-")
    if len(parts) == 4 and TID_RE.match(parts[1]) and parts[1] != "0" * 32:
        return parts[1]
    return secrets.token_hex(16)


def child_traceparent(tid):
    return f"00-{tid}-{secrets.token_hex(8)}-01"
GRAFANA = "http://127.0.0.1:3000"


def trace_link(trace_id):
    """Tempo izini Grafana Explore'da açan bağlantı (Tempo veri kaynağı uid: tempo)."""
    left = {"datasource": "tempo", "queries": [{"refId": "A", "datasource": {"type": "tempo", "uid": "tempo"},
            "queryType": "traceql", "query": trace_id}], "range": {"from": "now-6h", "to": "now"}}
    return f"{GRAFANA}/explore?orgId=1&left={urllib.parse.quote(json.dumps(left))}"
HERE = Path(__file__).resolve().parent
CERTS = ROOT / "edge" / "certs"
EDGE = ("127.0.0.1", 8443)
PUBLIC_CA = str(CERTS / "public-ca.crt")
INTERNAL_CA = str(CERTS / "internal-ca.crt")
PORT = 9000
IDENTITY_PORT = 18081  # 18080 test süitlerine ayrılmış; organizer kendi port-forward'ını bu porta açar
REALM = "/realms/bank/protocol/openid-connect"
IDENTITY_TOKEN_URL = f"http://127.0.0.1:{IDENTITY_PORT}{REALM}/token"

# Kanal yapılandırması. host: edge'e SNI/Host; cert: istemci sertifikası (mTLS); login: giriş yöntemi.
CHANNELS = {
    "web": {"title": "Web kanalı", "host": "web.lab.local", "ca": PUBLIC_CA, "cert": None,
            "login": "pkce", "client": "web-app", "secret": "web-app", "redirect": "https://web.lab.local:8443/callback",
            "user": "alice", "password": "alice-password", "dpop": False},
    "mobile": {"title": "Mobil kanal", "host": "mobile-api.lab.local", "ca": PUBLIC_CA, "cert": None,
               "login": "pkce_dpop", "client": "mobile-app", "secret": None, "redirect": "com.bank.app:/callback",
               "user": "alice", "password": "alice-password", "dpop": True},
    "partner": {"title": "Partner kanalı", "host": "partner-api.lab.local", "ca": INTERNAL_CA,
                "cert": (str(CERTS / "partner-client.crt"), str(CERTS / "partner-client.key")),
                "login": "client_credentials", "client": "partner-acme", "secret": "partner-acme", "redirect": None,
                "user": None, "password": None, "dpop": False},
    "branch": {"title": "Şube (çalışan) kanalı", "via": "branch-ui", "host": "teller.lab.local", "ca": INTERNAL_CA,
               "cert": (str(CERTS / "branch-device.crt"), str(CERTS / "branch-device.key")),
               "login": "pkce", "client": "branch-app", "secret": "branch-app", "redirect": "https://teller.lab.local/callback",
               "user": "teller", "password": "teller-password", "dpop": False},
    "public": {"title": "Public (oturumsuz)", "host": "web.lab.local", "ca": PUBLIC_CA, "cert": None,
               "login": None, "dpop": False},
}

SECRETS = {}
SESSIONS = {}
LOCK = threading.Lock()


# ---------------------------------------------------------------------------
# Yardımcılar
# ---------------------------------------------------------------------------
def b64u(raw):
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def b64u_dec(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


# Test adı -> Spring IdP secret anahtarı (idp/idp-secrets). branch-app istemcisi WEB_APP_SECRET ile kayıtlı.
IDP_SECRET_KEYS = {"web-app": "WEB_APP_SECRET", "partner-acme": "PARTNER_ACME_SECRET", "branch-app": "WEB_APP_SECRET",
                   "alice-password": "ALICE_PASSWORD", "teller-password": "TELLER_PASSWORD",
                   "idp-internal-key": "IDP_INTERNAL_API_KEY"}


def load_secrets():
    out = subprocess.run(["kubectl", "--context", "kind-identity", "-n", "idp", "get", "secret",
                          "idp-secrets", "-o", "json"], capture_output=True, text=True, check=True).stdout
    data = json.loads(out)["data"]
    for name, key in IDP_SECRET_KEYS.items():
        if key in data:
            SECRETS[name] = base64.b64decode(data[key]).decode()


def start_identity_forward():
    # Spring IdP iç HTTP portu (8080): mobil login DPoP htu'su http://127.0.0.1:<port>/... ile eşleşir
    proc = subprocess.Popen(["kubectl", "--context", "kind-identity", "-n", "idp", "port-forward",
                             "svc/spring-idp", f"{IDENTITY_PORT}:8080"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    atexit.register(proc.terminate)
    time.sleep(3)
    return proc


def decode_claims(token):
    try:
        return json.loads(b64u_dec(token.split(".")[1]))
    except Exception:
        return {}


def summarize(token):
    c = decode_claims(token)
    return {"iss": c.get("iss"), "aud": c.get("aud"), "azp": c.get("azp"), "channel": c.get("channel"),
            "auth_method": c.get("auth_method"), "sub": c.get("sub"),
            "sender_constrained": "cnf" in c, "exp": c.get("exp")}


def sni_request(host, cafile, method, path, headers=None, body=None, client_cert=None):
    ctx = ssl.create_default_context(cafile=cafile)
    if client_cert:
        ctx.load_cert_chain(client_cert[0], client_cert[1])

    class SNIConnection(http.client.HTTPSConnection):
        def connect(self):
            sock = socket.create_connection(EDGE, timeout=20)
            self.sock = self._context.wrap_socket(sock, server_hostname=host)

    conn = SNIConnection(EDGE[0], EDGE[1], context=ctx, timeout=20)
    h = {"Host": host, "Connection": "close"}
    h.update(headers or {})
    conn.request(method, path, body=body, headers=h)
    resp = conn.getresponse()
    data = resp.read().decode("utf-8", "replace")
    hdrs = resp.getheaders()
    conn.close()
    return resp.status, hdrs, data


def identity_req(method, path, headers=None, body=None):
    conn = http.client.HTTPConnection("127.0.0.1", IDENTITY_PORT, timeout=20)
    conn.request(method, path, body=body, headers=headers or {})
    resp = conn.getresponse()
    data = resp.read().decode("utf-8", "replace")
    hdrs = resp.getheaders()
    conn.close()
    return resp.status, hdrs, data


def cookies_from(hdrs, jar):
    for k, v in hdrs:
        if k.lower() == "set-cookie":
            pair = v.split(";", 1)[0]
            if "=" in pair:
                a, b = pair.split("=", 1)
                jar[a.strip()] = b.strip()
    return jar


def ec_new_key(tmpdir):
    key = os.path.join(tmpdir, "dpop-ec.pem")
    subprocess.run(["openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", key],
                   check=True, capture_output=True)
    der = subprocess.run(["openssl", "ec", "-in", key, "-pubout", "-outform", "DER"],
                         check=True, capture_output=True).stdout
    pub = der[-65:]
    return key, b64u(pub[1:33]), b64u(pub[33:65])


def der_to_raw(der):
    i = 2
    if der[1] & 0x80:
        i = 2 + (der[1] & 0x7F)
    out = b""
    for _ in range(2):
        ln = der[i + 1]
        out += der[i + 2:i + 2 + ln].lstrip(b"\x00").rjust(32, b"\x00")
        i += 2 + ln
    return out


def dpop_proof(key_path, x, y, htm, htu, access_token=None):
    header = {"typ": "dpop+jwt", "alg": "ES256", "jwk": {"kty": "EC", "crv": "P-256", "x": x, "y": y}}
    payload = {"htm": htm, "htu": htu, "iat": int(time.time()), "jti": secrets.token_hex(8)}
    if access_token:
        payload["ath"] = b64u(hashlib.sha256(access_token.encode()).digest())
    h = b64u(json.dumps(header, separators=(",", ":")).encode())
    p = b64u(json.dumps(payload, separators=(",", ":")).encode())
    with tempfile.TemporaryDirectory() as td:
        inp, sig = os.path.join(td, "in"), os.path.join(td, "sig.der")
        open(inp, "wb").write(f"{h}.{p}".encode())
        subprocess.run(["openssl", "dgst", "-sha256", "-sign", key_path, "-out", sig, inp],
                       check=True, capture_output=True)
        raw = der_to_raw(open(sig, "rb").read())
    return f"{h}.{p}.{b64u(raw)}"


def pkce_pair():
    verifier = secrets.token_urlsafe(48)
    return verifier, b64u(hashlib.sha256(verifier.encode()).digest())


def request_for(cfg):
    """Kanal isteği fonksiyonu: edge veya identity (mobil login)."""
    return lambda m, p, h=None, b=None: sni_request(cfg["host"], cfg["ca"], m, p, headers=h, body=b,
                                                    client_cert=cfg["cert"])


def cookie_header(jar):
    return "; ".join(f"{k}={v}" for k, v in jar.items())


def location_path(hdrs):
    """Location başlığını yol+sorgu olarak döndürür (absolute ise host atılır)."""
    loc = next((v for k, v in hdrs if k.lower() == "location"), "")
    p = urllib.parse.urlparse(loc)
    return loc, (p.path + ("?" + p.query if p.query else ""))


def idp_pkce(req, cfg, username, password, client_secret=None, dpop_for_token=None):
    """Authorization Code + PKCE (Spring IdP): yetkilendirme -> /login (CSRF) -> devam -> code -> token."""
    verifier, challenge = pkce_pair()
    jar = {}
    params = urllib.parse.urlencode({"client_id": cfg["client"], "redirect_uri": cfg["redirect"],
                                     "response_type": "code", "scope": "openid", "state": secrets.token_hex(4),
                                     "code_challenge": challenge, "code_challenge_method": "S256"})
    st, hdrs, _ = req("GET", f"{REALM}/auth?{params}")
    cookies_from(hdrs, jar)
    # Yetkilendirme isteği oturumda saklanır, kullanıcı /login'e yönlendirilir
    st, hdrs, page = req("GET", "/login", {"Cookie": cookie_header(jar)}, None)
    cookies_from(hdrs, jar)
    m = re.search(r'name="_csrf"[^>]*value="([^"]*)"', page)
    if not m:
        raise RuntimeError(f"login formu alınamadı (HTTP {st})")
    st, hdrs, _ = req("POST", "/login",
                      {"Cookie": cookie_header(jar), "Content-Type": "application/x-www-form-urlencoded"},
                      urllib.parse.urlencode({"username": username, "password": password, "_csrf": m.group(1)}))
    cookies_from(hdrs, jar)
    _, target = location_path(hdrs)
    if not target or "/login" in target:
        raise RuntimeError(f"giriş başarısız (HTTP {st}); kullanıcı veya parola hatalı olabilir")
    # Yetkilendirmeye devam: redirect_uri?code=...
    st, hdrs, _ = req("GET", target, {"Cookie": cookie_header(jar)}, None)
    loc, _ = location_path(hdrs)
    code = urllib.parse.parse_qs(urllib.parse.urlparse(loc).query).get("code", [None])[0]
    if not code:
        raise RuntimeError(f"code alınamadı (HTTP {st})")
    form = {"grant_type": "authorization_code", "client_id": cfg["client"], "code": code,
            "redirect_uri": cfg["redirect"], "code_verifier": verifier}
    headers = {"Content-Type": "application/x-www-form-urlencoded"}
    if client_secret:
        headers["Authorization"] = "Basic " + base64.b64encode(f"{cfg['client']}:{client_secret}".encode()).decode()
    if dpop_for_token:
        headers["DPoP"] = dpop_for_token
    st, _, body = req("POST", f"{REALM}/token", headers, urllib.parse.urlencode(form))
    tok = json.loads(body)
    if "access_token" not in tok:
        raise RuntimeError(f"token alınamadı (HTTP {st}): {tok.get('error_description', tok.get('error'))}")
    return tok


# ---------------------------------------------------------------------------
# Kanal işlemleri
# ---------------------------------------------------------------------------
def session_for(sid):
    with LOCK:
        return SESSIONS.setdefault(sid, {"channels": {}, "tmp": tempfile.mkdtemp()})


def do_login(sess, ch, username, password):
    cfg = CHANNELS[ch]
    if not cfg.get("login"):
        raise RuntimeError("bu kanalda giriş yok (public)")
    user = username or cfg["user"]
    if cfg.get("via") == "branch-ui":
        return branch_login(sess, ch, user, password)
    pw = password or (SECRETS.get(cfg["password"]) if cfg["password"] else "")
    if cfg["login"] == "client_credentials":
        basic = base64.b64encode(f"{cfg['client']}:{SECRETS[cfg['secret']]}".encode()).decode()
        st, _, body = sni_request(cfg["host"], cfg["ca"], "POST", f"{REALM}/token",
                                  headers={"Content-Type": "application/x-www-form-urlencoded",
                                           "Authorization": "Basic " + basic},
                                  body=urllib.parse.urlencode({"grant_type": "client_credentials"}),
                                  client_cert=cfg["cert"])
        tok = json.loads(body)
        if "access_token" not in tok:
            raise RuntimeError(f"token alınamadı (HTTP {st})")
        sess["channels"][ch] = {"access": tok["access_token"], "user": None}
        return summarize(tok["access_token"])
    if cfg["login"] == "pkce_dpop":
        key, x, y = ec_new_key(sess["tmp"])
        proof = dpop_proof(key, x, y, "POST", IDENTITY_TOKEN_URL)
        tok = idp_pkce(identity_req_fn, cfg, user, pw, None, proof)
        sess["channels"][ch] = {"access": tok["access_token"], "refresh": tok.get("refresh_token"), "user": user,
                                "key": key, "x": x, "y": y}
        return summarize(tok["access_token"])
    # pkce (confidential)
    secret = SECRETS.get(cfg["secret"]) if cfg["secret"] else None
    tok = idp_pkce(request_for(cfg), cfg, user, pw, secret)
    sess["channels"][ch] = {"access": tok["access_token"], "refresh": tok.get("refresh_token"), "user": user}
    return summarize(tok["access_token"])


def identity_req_fn(method, path, headers=None, body=None):
    return identity_req(method, path, headers, body)


# ---------------------------------------------------------------------------
# Demo kayıt (OTP gibi, SMS YOK). Kod yalnızca bu konsolda gösterilir; lab içi demo.
# ---------------------------------------------------------------------------
REG_PENDING = {}          # kullanıcı adı -> {code, password, exp, tries}
REG_LOCK = threading.Lock()
REG_TTL = 300             # saniye
REG_MAX_TRIES = 5
USERNAME_RE = re.compile(r"^[a-z][a-z0-9_]{2,31}$")


def register_start(username, password):
    if not USERNAME_RE.match(username or ""):
        raise ValueError("kullanıcı adı: küçük harfle başlar, 3-32 karakter (a-z, 0-9, _)")
    if not (8 <= len(password or "") <= 128):
        raise ValueError("parola en az 8 karakter olmalı")
    code = f"{secrets.randbelow(1000000):06d}"
    with REG_LOCK:
        REG_PENDING[username] = {"code": code, "password": password, "exp": time.time() + REG_TTL, "tries": 0}
    return code


def register_verify(username, code):
    with REG_LOCK:
        pend = REG_PENDING.get(username)
        if not pend or time.time() > pend["exp"]:
            REG_PENDING.pop(username, None)
            raise ValueError("kod yok veya süresi doldu; yeniden kod üretin")
        if pend["tries"] >= REG_MAX_TRIES:
            REG_PENDING.pop(username, None)
            raise ValueError("çok fazla hatalı deneme; yeniden kod üretin")
        if not secrets.compare_digest(pend["code"], code or ""):
            pend["tries"] += 1
            raise ValueError("kod hatalı")
        REG_PENDING.pop(username)
    body = json.dumps({"username": username, "password": pend["password"]})
    st, _, data = identity_req("POST", "/internal/users",
                               {"Content-Type": "application/json", "X-Internal-Key": SECRETS.get("idp-internal-key", "")},
                               body)
    if st != 201:
        raise RuntimeError(f"IdP kayıt hatası (HTTP {st}): {data[:120]}")
    return username


def do_logout(sess, ch):
    cfg = CHANNELS[ch]
    entry = sess["channels"].get(ch)
    if cfg.get("via") == "branch-ui":
        status = None
        if entry:
            status, _, _ = branch_ui_req("POST", "/api/logout", entry.get("cookie"))
        sess["channels"][ch] = None
        return status
    status = None
    if entry and cfg.get("login") == "pkce_dpop":
        proof = dpop_proof(entry["key"], entry["x"], entry["y"], "POST", f"{IDENTITY_TOKEN_URL[:-6]}/revoke")
        status, _, _ = identity_req("POST", f"{REALM}/revoke",
                                    headers={"Content-Type": "application/x-www-form-urlencoded", "DPoP": proof},
                                    body=urllib.parse.urlencode({"client_id": cfg["client"],
                                                                 "token": entry.get("refresh") or "",
                                                                 "token_type_hint": "refresh_token"}))
    elif entry and cfg.get("login") == "pkce":
        # RFC 7009 token iptali (Spring IdP /revoke); gizli anahtarlı istemci Basic auth ile
        headers = {"Content-Type": "application/x-www-form-urlencoded"}
        if cfg.get("secret"):
            headers["Authorization"] = "Basic " + base64.b64encode(
                f"{cfg['client']}:{SECRETS[cfg['secret']]}".encode()).decode()
        status, _, _ = sni_request(cfg["host"], cfg["ca"], "POST", f"{REALM}/revoke", headers=headers,
                                   body=urllib.parse.urlencode({"token": entry.get("refresh") or "",
                                                                "token_type_hint": "refresh_token"}),
                                   client_cert=cfg["cert"])
    sess["channels"][ch] = None
    return status


def do_call(sess, ch, method, path, auth, dpop, cert, token_from=None, body=None, idem=None):
    cfg = CHANNELS[ch]
    if cfg.get("via") == "branch-ui":
        return branch_call(sess, ch, method, path, auth, cert, body)
    headers = {}
    payload = None
    if body is not None:
        payload = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    if idem:
        headers["Idempotency-Key"] = idem
    src = token_from or ch
    entry = sess["channels"].get(src) or {}
    token = entry.get("access") if auth == "session" else None
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if dpop and cfg["dpop"] and token and entry.get("key"):
        headers["DPoP"] = dpop_proof(entry["key"], entry["x"], entry["y"], method,
                                     f"https://{cfg['host']}{path}", token)
    # Her çağrının kök span'i: traceparent ile zincirin tamamına (edge, ext-authz, BFF, core) taşınır
    root = tracing.start_server_span(f"console {method} {path}", child_traceparent(_req.tid),
                                     {"channel": ch, "auth": auth, "http.method": method, "http.target": path})
    headers["traceparent"] = root.header()
    st = None
    try:
        st, _, resp_body = sni_request(cfg["host"], cfg["ca"], method, path, headers=headers,
                                       body=payload, client_cert=cfg["cert"] if cert else None)
    finally:
        root.end(http_status=st)
    return {"status": st, "body": resp_body[:600], "trace_id": root.trace_id,
            "trace_url": trace_link(root.trace_id)}


# Şube kanalı: şube UI pod'u (branch-cluster, port 9100). Cihaz sertifikası ve token pod'da; konsol yalnız çerezi tutar.
BRANCH_UI_HOST, BRANCH_UI_PORT = "127.0.0.1", 9100


def branch_ui_req(method, path, cookie=None, payload=None):
    conn = http.client.HTTPConnection(BRANCH_UI_HOST, BRANCH_UI_PORT, timeout=40)
    headers = {}
    data = None
    if payload is not None:
        data = json.dumps(payload).encode()
        headers["Content-Type"] = "application/json"
    if cookie:
        headers["Cookie"] = cookie
    if getattr(_req, "tid", None):
        headers["X-Trace-Id"] = _req.tid  # şube UI aynı trace kimliğini zincire taşır
    conn.request(method, path, body=data, headers=headers)
    r = conn.getresponse()
    body = r.read().decode("utf-8", "replace")
    hdrs = r.getheaders()
    conn.close()
    return r.status, hdrs, body


def branch_cookie(hdrs, fallback):
    for k, v in hdrs:
        if k.lower() == "set-cookie" and v.startswith("branch_sid="):
            return v.split(";", 1)[0]
    return fallback


def branch_login(sess, ch, user, pw):
    payload = {"username": user}
    if pw:
        payload["password"] = pw
    st, hdrs, body = branch_ui_req("POST", "/api/login", None, payload)
    res = json.loads(body) if body.startswith("{") else {}
    if st != 200 or not res.get("ok"):
        raise RuntimeError(f"şube girişi başarısız (HTTP {st}): {res.get('error', body[:200])}")
    sess["channels"][ch] = {"ui": True, "user": user, "cookie": branch_cookie(hdrs, None), "info": res.get("token")}
    return res.get("token")


def branch_call(sess, ch, method, path, auth, cert, body):
    entry = sess["channels"].get(ch)
    if body is not None:
        raise RuntimeError("şube kanalında gövdeli istek bu konsolda desteklenmiyor (şube UI /api/call yalnız GET ve gövdesiz çağrı)")
    payload = {"method": method, "path": path, "auth": "session" if auth == "session" and entry else "none",
               "cert": bool(cert)}
    st, _, resp = branch_ui_req("POST", "/api/call", entry.get("cookie") if entry else None, payload)
    res = json.loads(resp) if resp.startswith("{") else {"status": st, "body": resp[:600]}
    return {"status": res.get("status"), "body": str(res.get("body", ""))[:600], "trace_id": None, "trace_url": None}


def state_of(sess):
    out = {}
    for ch in CHANNELS:
        e = sess["channels"].get(ch)
        if not e:
            out[ch] = None
        elif e.get("ui"):
            out[ch] = {"user": e.get("user"), "token": e.get("info")}
        else:
            out[ch] = {"user": e.get("user"), "token": summarize(e["access"])}
    return out


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------
class Handler(http.server.BaseHTTPRequestHandler):
    def _sid(self):
        m = re.search(r"console_sid=([^;]+)", self.headers.get("Cookie", ""))
        return (m.group(1), False) if m else (secrets.token_hex(16), True)

    def _send(self, status, body, ctype, sid, new):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        if new:
            self.send_header("Set-Cookie", f"console_sid={sid}; HttpOnly; SameSite=Strict; Path=/")
        self.send_header("X-Trace-Id", getattr(_req, "tid", "") or "")
        self.end_headers()
        self.wfile.write(body)

    def _json(self, status, obj, sid, new):
        self._send(status, json.dumps(obj, ensure_ascii=False).encode(), "application/json; charset=utf-8", sid, new)

    def do_GET(self):
        _req.tid = inbound_trace_id(self.headers)
        sid, new = self._sid()
        path = urllib.parse.urlparse(self.path).path
        if path == "/":
            return self._send(200, (HERE / "organizer.html").read_bytes(), "text/html; charset=utf-8", sid, new)
        if path == "/ops.js":
            return self._send(200, (HERE / "ops.js").read_bytes(), "application/javascript; charset=utf-8", sid, new)
        m = re.fullmatch(r"/ch/([a-z]+)", path)
        if m and m.group(1) in CHANNELS:
            return self._send(200, (HERE / "channel.html").read_bytes(), "text/html; charset=utf-8", sid, new)
        if path == "/api/state":
            return self._json(200, state_of(session_for(sid)), sid, new)
        if path == "/api/channels":
            return self._json(200, {k: {"title": v["title"], "login": bool(v.get("login"))}
                                    for k, v in CHANNELS.items()}, sid, new)
        self._json(404, {"error": "not found"}, sid, new)

    def do_POST(self):
        _req.tid = inbound_trace_id(self.headers)
        sid, new = self._sid()
        sess = session_for(sid)
        n = int(self.headers.get("Content-Length", "0") or 0)
        try:
            req = json.loads(self.rfile.read(n) or b"{}")
        except json.JSONDecodeError:
            return self._json(400, {"error": "geçersiz JSON"}, sid, new)
        try:
            if self.path == "/api/login":
                ch = req.get("channel")
                span = tracing.start_server_span(f"console login {ch}", child_traceparent(_req.tid),
                                                 {"channel": ch, "http.target": "/api/login"})
                try:
                    info = do_login(sess, ch, req.get("username"), req.get("password"))
                finally:
                    span.end()
                return self._json(200, {"ok": True, "token": info}, sid, new)
            if self.path == "/api/register/start":
                try:
                    code = register_start((req.get("username") or "").strip().lower(), req.get("password") or "")
                except ValueError as e:
                    return self._json(400, {"error": str(e)}, sid, new)
                return self._json(200, {"ok": True, "demo_otp": code,
                                        "note": "DEMO: SMS gönderilmez; kod yalnızca bu ekranda gösterilir"}, sid, new)
            if self.path == "/api/register/verify":
                try:
                    user = register_verify((req.get("username") or "").strip().lower(), (req.get("code") or "").strip())
                except ValueError as e:
                    return self._json(400, {"error": str(e)}, sid, new)
                except RuntimeError as e:
                    return self._json(502, {"error": str(e)}, sid, new)
                return self._json(200, {"ok": True, "username": user}, sid, new)
            if self.path == "/api/logout":
                ch = req.get("channel")
                if not sess["channels"].get(ch):
                    return self._json(200, {"ok": True, "idp_status": None, "note": "oturum yoktu"}, sid, new)
                span = tracing.start_server_span(f"console logout {ch}", child_traceparent(_req.tid),
                                                 {"channel": ch, "http.target": "/api/logout"})
                try:
                    kc = do_logout(sess, ch)
                finally:
                    span.end(http_status=200)
                return self._json(200, {"ok": kc in (200, 204, None), "idp_status": kc}, sid, new)
            if self.path == "/api/call":
                res = do_call(sess, req.get("channel"), req.get("method", "GET"), req.get("path", "/"),
                              req.get("auth", "session"), bool(req.get("dpop")), req.get("cert", True),
                              req.get("token_from"), req.get("body"), req.get("idem"))
                expect = req.get("expect")
                res["expect"] = expect
                res["pass"] = None if expect is None else str(res["status"]) == str(expect)
                return self._json(200, res, sid, new)
            self._json(404, {"error": "not found"}, sid, new)
        except ssl.SSLError as e:
            self._json(200, {"status": "TLS", "body": str(e)[:200], "expect": req.get("expect"),
                             "pass": req.get("expect") == "TLS"}, sid, new)
        except Exception as exc:
            self._json(500, {"error": str(exc)}, sid, new)

    def log_message(self, fmt, *args):
        print("console", self.command, self.path, fmt % args, flush=True)


def start_observability_forwards():
    """Jaeger OTLP (14318), Jaeger UI (16686) ve Grafana (3000) için port-forward; kapanışta sonlandırılır."""
    procs = []
    for svc, local, remote in (("tempo", 14318, 4318), ("grafana", 3000, 3000)):
        p = subprocess.Popen(["kubectl", "--context", "kind-mgmt", "-n", "observability", "port-forward",
                              f"svc/{svc}", f"{local}:{remote}"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        atexit.register(p.terminate)
        procs.append(p)
    time.sleep(3)
    return procs


if __name__ == "__main__":
    load_secrets()
    start_identity_forward()
    start_observability_forwards()
    print(f"DMZ lab organizer: http://127.0.0.1:{PORT}  (yalniz lab)", flush=True)
    http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
