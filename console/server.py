#!/usr/bin/env python3
"""DMZ lab test konsolu (YALNIZ LAB). Web, mobil, partner ve public senaryolarını tarayıcıdan çalıştırır.

Çalıştırma (repo kökünden):  python console/server.py   ->  http://127.0.0.1:9000
Ön koşul: edge ayakta (cd edge && docker compose up -d), kind-identity erişilebilir (kubectl).

Güvenlik notları (lab):
- Sunucu yalnız 127.0.0.1'e bağlanır.
- Client secret'ları kubectl ile okunur, yalnız bellekte tutulur; tarayıcıya gönderilmez.
- Token'lar sunucu oturumunda tutulur; tarayıcıya yalnız özet (claim'ler, uzunluk) gider. Ham token gösterilmez.
- Token imzası bu konsolda doğrulanmaz (yalnız decode). Doğrulama ext-authz ve iç servislerde yapılır.
- Parola alanı boş bırakılırsa lab test kullanıcısının parolası (keycloak-client-secrets) kullanılır; diske yazılmaz.
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
import tempfile
import threading
import time
import urllib.parse
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CERTS = ROOT / "edge" / "certs"
EDGE = ("127.0.0.1", 8443)               # HAProxy (edge)
PUBLIC_CA = str(CERTS / "public-ca.crt")  # web.lab.local, mobile-api.lab.local
INTERNAL_CA = str(CERTS / "internal-ca.crt")  # partner-api.lab.local (gw-partner sunucu sertifikası)
PARTNER_CERT = (str(CERTS / "partner-client.crt"), str(CERTS / "partner-client.key"))
HOSTS = {"web": "web.lab.local", "mobile": "mobile-api.lab.local", "partner": "partner-api.lab.local"}
REALM = "/realms/bank/protocol/openid-connect"
IDENTITY_PORT = 18080  # kubectl port-forward svc/keycloak (server başlarken açılır)
# Mobil login DPoP htu'su Keycloak'ın gördüğü URL ile birebir olmalı: identity port-forward üzerinden.
IDENTITY_TOKEN_URL = f"http://127.0.0.1:{IDENTITY_PORT}{REALM}/token"
PORT = 9000

SECRETS = {}          # client secret'ları ve test parolası (yalnız bellek)
SESSIONS = {}         # sid -> {"web": {...}, "mobile": {...}, "partner": {...}}
LOCK = threading.Lock()


# ---------------------------------------------------------------------------
# Yardımcılar
# ---------------------------------------------------------------------------
def b64u(raw):
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def b64u_dec(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def load_secrets():
    out = subprocess.run(
        ["kubectl", "--context", "kind-identity", "-n", "auth", "get", "secret", "keycloak-client-secrets", "-o", "json"],
        capture_output=True, text=True, check=True).stdout
    data = json.loads(out)["data"]
    for key in ("web-app", "partner-acme", "alice-password"):
        SECRETS[key] = base64.b64decode(data[key]).decode()


def decode_claims(token):
    """Yalnız decode (imza doğrulanmaz)."""
    try:
        return json.loads(b64u_dec(token.split(".")[1]))
    except Exception:
        return {}


def summarize_token(token):
    c = decode_claims(token)
    return {
        "iss": c.get("iss"), "aud": c.get("aud"), "azp": c.get("azp"), "channel": c.get("channel"),
        "sub": c.get("sub"), "auth_method": c.get("auth_method"),
        "sender_constrained": "cnf" in c, "exp": c.get("exp"), "length": len(token),
    }


def sni_request(sni, cafile, method, path, headers=None, body=None, client_cert=None):
    """Edge'e 127.0.0.1:8443 üzerinden, verilen SNI/Host ile istek. Yanıt: (status, headers, body)."""
    ctx = ssl.create_default_context(cafile=cafile)
    if client_cert:
        ctx.load_cert_chain(client_cert[0], client_cert[1])

    class SNIConnection(http.client.HTTPSConnection):
        def connect(self):
            sock = socket.create_connection(EDGE, timeout=20)
            self.sock = self._context.wrap_socket(sock, server_hostname=sni)

    conn = SNIConnection(EDGE[0], EDGE[1], context=ctx, timeout=20)
    h = {"Host": sni, "Connection": "close"}
    h.update(headers or {})
    conn.request(method, path, body=body, headers=h)
    resp = conn.getresponse()
    data = resp.read().decode("utf-8", "replace")
    hdrs = resp.getheaders()
    conn.close()
    return resp.status, hdrs, data


def cookies_from(hdrs, jar):
    for name, value in hdrs:
        if name.lower() == "set-cookie":
            pair = value.split(";", 1)[0]
            if "=" in pair:
                k, v = pair.split("=", 1)
                jar[k.strip()] = v.strip()
    return jar


def cookie_header(jar):
    return "; ".join(f"{k}={v}" for k, v in jar.items())


def pkce_pair():
    verifier = secrets.token_urlsafe(48)
    challenge = b64u(hashlib.sha256(verifier.encode()).digest())
    return verifier, challenge


def edge_req(channel):
    """Login isteklerini edge (DMZ) üzerinden gönderir."""
    cafile = INTERNAL_CA if channel == "partner" else PUBLIC_CA
    return lambda method, path, headers=None, body=None: sni_request(HOSTS[channel], cafile, method, path,
                                                                     headers=headers, body=body)


def identity_req(method, path, headers=None, body=None):
    """Identity Keycloak'a doğrudan (kubectl port-forward, 127.0.0.1:18080). Mobil login için (DPoP htu)."""
    conn = http.client.HTTPConnection("127.0.0.1", IDENTITY_PORT, timeout=20)
    conn.request(method, path, body=body, headers=headers or {})
    resp = conn.getresponse()
    data = resp.read().decode("utf-8", "replace")
    hdrs = resp.getheaders()
    conn.close()
    return resp.status, hdrs, data


def keycloak_login(req, client_id, redirect, username, password, client_secret=None, dpop_for_token=None):
    """Authorization Code + PKCE. req: login isteklerini gönderen fonksiyon. Dönüş: token yanıtı (dict)."""
    verifier, challenge = pkce_pair()
    jar = {}
    params = urllib.parse.urlencode({
        "client_id": client_id, "redirect_uri": redirect, "response_type": "code", "scope": "openid",
        "state": secrets.token_hex(4), "code_challenge": challenge, "code_challenge_method": "S256"})
    st, hdrs, page = req("GET", f"{REALM}/auth?{params}")
    cookies_from(hdrs, jar)
    m = re.search(r'action="([^"]*login-actions[^"]*)"', page)
    if not m:
        raise RuntimeError(f"login formu bulunamadı (HTTP {st})")
    action = urllib.parse.urlparse(html.unescape(m.group(1)))
    st, hdrs, _ = req("POST", action.path + ("?" + action.query if action.query else ""),
                              headers={"Cookie": cookie_header(jar),
                                       "Content-Type": "application/x-www-form-urlencoded"},
                              body=urllib.parse.urlencode({"username": username, "password": password,
                                                           "credentialId": ""}))
    loc = next((v for k, v in hdrs if k.lower() == "location"), "")
    code = urllib.parse.parse_qs(urllib.parse.urlparse(loc).query).get("code", [None])[0]
    if not code:
        raise RuntimeError(f"giriş başarısız (HTTP {st}); parola veya kullanıcı hatalı olabilir")

    form = {"grant_type": "authorization_code", "client_id": client_id, "code": code,
            "redirect_uri": redirect, "code_verifier": verifier}
    if client_secret:
        form["client_secret"] = client_secret
    headers = {"Content-Type": "application/x-www-form-urlencoded"}
    if dpop_for_token:
        headers["DPoP"] = dpop_for_token
    st, _, body = req("POST", f"{REALM}/token", headers=headers,
                              body=urllib.parse.urlencode(form))
    tok = json.loads(body)
    if "access_token" not in tok:
        raise RuntimeError(f"token alınamadı (HTTP {st}): {tok.get('error_description', tok.get('error'))}")
    return tok


# --- ES256 DPoP (OpenSSL ile imza; PKCS/DER -> r||s) ----------------------
def ec_new_key(tmpdir):
    key = os.path.join(tmpdir, "dpop-ec.pem")
    subprocess.run(["openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", key],
                   check=True, capture_output=True)
    der = subprocess.run(["openssl", "ec", "-in", key, "-pubout", "-outform", "DER"],
                         check=True, capture_output=True).stdout
    pub = der[-65:]  # 04 || x || y
    return key, b64u(pub[1:33]), b64u(pub[33:65])


def der_to_raw(der):
    """ECDSA DER imzası -> 64 bayt r||s (RFC 7518 §3.4)."""
    i = 2
    if der[1] & 0x80:  # uzun uzunluk (nadiren gerekir)
        i = 2 + (der[1] & 0x7F)
    out = b""
    for _ in range(2):
        assert der[i] == 2
        ln = der[i + 1]
        val = der[i + 2:i + 2 + ln]
        i += 2 + ln
        out += val.lstrip(b"\x00").rjust(32, b"\x00")
    return out


def dpop_proof(key_path, x, y, htm, htu, access_token=None):
    header = {"typ": "dpop+jwt", "alg": "ES256", "jwk": {"kty": "EC", "crv": "P-256", "x": x, "y": y}}
    payload = {"htm": htm, "htu": htu, "iat": int(time.time()), "jti": secrets.token_hex(8)}
    if access_token:
        payload["ath"] = b64u(hashlib.sha256(access_token.encode()).digest())
    h = b64u(json.dumps(header, separators=(",", ":")).encode())
    p = b64u(json.dumps(payload, separators=(",", ":")).encode())
    signing = f"{h}.{p}".encode()
    with tempfile.TemporaryDirectory() as td:
        inp, sig = os.path.join(td, "in"), os.path.join(td, "sig.der")
        with open(inp, "wb") as f:
            f.write(signing)
        subprocess.run(["openssl", "dgst", "-sha256", "-sign", key_path, "-out", sig, inp],
                       check=True, capture_output=True)
        raw = der_to_raw(open(sig, "rb").read())
    return f"{h}.{p}.{b64u(raw)}"


# ---------------------------------------------------------------------------
# Oturum ve senaryo işlemleri
# ---------------------------------------------------------------------------
def session_for(sid):
    with LOCK:
        return SESSIONS.setdefault(sid, {"web": None, "mobile": None, "partner": None, "tmp": tempfile.mkdtemp()})


def do_login(sess, channel, username, password):
    pw = password or SECRETS["alice-password"]
    user = username or "alice"
    if channel == "web":
        tok = keycloak_login(edge_req("web"), "web-app", "https://web.lab.local:8443/callback", user, pw,
                             client_secret=SECRETS["web-app"])
        sess["web"] = {"access": tok["access_token"], "refresh": tok.get("refresh_token"), "user": user}
    elif channel == "mobile":
        key, x, y = ec_new_key(sess["tmp"])
        redirect = "com.bank.app:/callback"
        proof = dpop_proof(key, x, y, "POST", IDENTITY_TOKEN_URL)
        tok = keycloak_login(identity_req, "mobile-app", redirect, user, pw, dpop_for_token=proof)
        sess["mobile"] = {"access": tok["access_token"], "refresh": tok.get("refresh_token"), "user": user,
                          "key": key, "x": x, "y": y}
    elif channel == "partner":
        st, _, body = sni_request(HOSTS["partner"], INTERNAL_CA, "POST", f"{REALM}/token",
                                  headers={"Content-Type": "application/x-www-form-urlencoded"},
                                  body=urllib.parse.urlencode({"grant_type": "client_credentials",
                                                               "client_id": "partner-acme",
                                                               "client_secret": SECRETS["partner-acme"]}),
                                  client_cert=PARTNER_CERT)
        tok = json.loads(body)
        if "access_token" not in tok:
            raise RuntimeError(f"partner token alınamadı (HTTP {st})")
        sess["partner"] = {"access": tok["access_token"]}
    else:
        raise RuntimeError("bilinmeyen kanal")
    return summarize_token(sess[channel]["access"])


def do_logout(sess, channel):
    """Keycloak oturumunu kapatır (refresh token ile). Dönüş: Keycloak HTTP kodu (204 beklenir) veya None.
    Not: access token'lar exp'e kadar geçerlidir; ext-authz introspection yapmaz (bkz. design.md)."""
    entry = sess.get(channel)
    status = None
    if channel == "web" and entry:
        status, _, _ = sni_request(HOSTS["web"], PUBLIC_CA, "POST", f"{REALM}/logout",
                                   headers={"Content-Type": "application/x-www-form-urlencoded"},
                                   body=urllib.parse.urlencode({"client_id": "web-app",
                                                                "client_secret": SECRETS["web-app"],
                                                                "refresh_token": entry.get("refresh") or ""}))
    elif channel == "mobile" and entry:
        # DPoP'a bağlı refresh token: /logout ucu DPoP'u kabul etmiyor (invalid_grant), /revoke ucu kabul ediyor (200).
        # Bu yüzden mobil çıkış refresh token'ı revoke eder; aynı anahtarla imzalı proof gönderilir.
        proof = dpop_proof(entry["key"], entry["x"], entry["y"], "POST",
                           f"http://127.0.0.1:{IDENTITY_PORT}{REALM}/revoke")
        status, _, _ = identity_req("POST", f"{REALM}/revoke",
                                    headers={"Content-Type": "application/x-www-form-urlencoded", "DPoP": proof},
                                    body=urllib.parse.urlencode({"client_id": "mobile-app",
                                                                 "token": entry.get("refresh") or "",
                                                                 "token_type_hint": "refresh_token"}))
    sess[channel] = None  # yerel token silinir (partner için de)
    return status


def do_call(sess, channel, method, path, auth, dpop):
    """auth: none | session | web-token. dpop: mobil için DPoP proof gönderilsin mi."""
    headers = {}
    token = None
    if auth == "session":
        token = (sess.get(channel) or {}).get("access")
    elif auth == "web-token":
        token = (sess.get("web") or {}).get("access")
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if channel == "mobile" and dpop and token:
        m = sess.get("mobile") or {}
        if m.get("key"):
            headers["DPoP"] = dpop_proof(m["key"], m["x"], m["y"], method, f"https://{HOSTS['mobile']}{path}", token)
    cert = PARTNER_CERT if channel == "partner" else None
    cafile = INTERNAL_CA if channel == "partner" else PUBLIC_CA
    st, _, body = sni_request(HOSTS[channel], cafile, method, path, headers=headers, client_cert=cert)
    return {"status": st, "body": body[:600]}


# ---------------------------------------------------------------------------
# HTTP sunucusu
# ---------------------------------------------------------------------------
class Handler(http.server.BaseHTTPRequestHandler):
    def _sid(self):
        raw = self.headers.get("Cookie", "")
        m = re.search(r"console_sid=([^;]+)", raw)
        if m:
            return m.group(1), False
        return secrets.token_hex(16), True

    def _json(self, status, obj, sid=None, new=False):
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        if new and sid:
            self.send_header("Set-Cookie", f"console_sid={sid}; HttpOnly; SameSite=Strict; Path=/")
        self.end_headers()
        self.wfile.write(body)

    def _state(self, sess):
        out = {}
        for ch in ("web", "mobile", "partner"):
            e = sess.get(ch)
            out[ch] = summarize_token(e["access"]) if e else None
            if e and e.get("user"):
                out[ch]["user"] = e["user"]
        return out

    def do_GET(self):
        sid, new = self._sid()
        sess = session_for(sid)
        if self.path == "/":
            body = (Path(__file__).parent / "index.html").read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            if new:
                self.send_header("Set-Cookie", f"console_sid={sid}; HttpOnly; SameSite=Strict; Path=/")
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path == "/api/state":
            return self._json(200, self._state(sess), sid, new)
        self._json(404, {"error": "not found"}, sid, new)

    def do_POST(self):
        sid, new = self._sid()
        sess = session_for(sid)
        length = int(self.headers.get("Content-Length", "0") or 0)
        try:
            req = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError:
            return self._json(400, {"error": "geçersiz JSON"}, sid, new)
        try:
            if self.path == "/api/login":
                info = do_login(sess, req.get("channel"), req.get("username"), req.get("password"))
                return self._json(200, {"ok": True, "token": info}, sid, new)
            if self.path == "/api/logout":
                ch = req.get("channel")
                kc = do_logout(sess, ch)
                # Keycloak 204 döner; partner'da Keycloak oturumu yoktur (yalnız yerel token silinir)
                ok = kc in (200, 204, None)
                return self._json(200, {"ok": ok, "keycloak_status": kc}, sid, new)
            if self.path == "/api/call":
                res = do_call(sess, req.get("channel"), req.get("method", "GET"), req.get("path", "/"),
                              req.get("auth", "none"), bool(req.get("dpop")))
                expect = req.get("expect")
                res["pass"] = None if expect is None else str(res["status"]) == str(expect)
                res["expect"] = expect
                return self._json(200, res, sid, new)
            self._json(404, {"error": "not found"}, sid, new)
        except Exception as exc:  # lab konsolu: hata mesajını göster
            self._json(500, {"error": str(exc)}, sid, new)

    def log_message(self, fmt, *args):
        print("console", self.command, self.path, fmt % args, flush=True)


def start_identity_forward():
    """Mobil login için identity Keycloak'a port-forward (127.0.0.1:18080). Kapanışta sonlandırılır."""
    proc = subprocess.Popen(["kubectl", "--context", "kind-identity", "-n", "auth", "port-forward",
                             "svc/keycloak", f"{IDENTITY_PORT}:8080"],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    atexit.register(proc.terminate)
    time.sleep(3)
    return proc


if __name__ == "__main__":
    load_secrets()
    start_identity_forward()
    print(f"DMZ lab konsolu: http://127.0.0.1:{PORT}  (yalniz lab)", flush=True)
    http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
