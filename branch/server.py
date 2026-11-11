#!/usr/bin/env python3
"""Şube (branch) zone çalışan arayüzü: veznedar girişi, hesap sorgusu, güvenlik kontrolleri. YALNIZ LAB.

Çalıştırma (repo kökünden):  PYTHONIOENCODING=utf-8 python branch/server.py  ->  http://127.0.0.1:9100
Ön koşul: edge ayakta, gw-branch kurulu (dmz-cluster/scripts/load-branch.sh), identity kurulu (setup-realm.sh).

Akış: şube UI (branch cluster, pod) -> WAN -> gw-branch (DMZ NodePort 30449, cihaz sertifikası mTLS, F10)
      -> /bff/* ext-authz (branch) -> token exchange -> iç gateway -> BFF.
HAProxy kullanılmaz. Bu sunucu şube iş istasyonunun yerine geçer: cihaz sertifikasını (branch-device) kullanır.

Ortam değişkenleri (pod'da verilir; host'ta yoksa varsayılanlar kullanılır):
  BRANCH_GW_HOST   gw-branch'in erişildiği DMZ node IP'si (zorunlu pod'da)
  BRANCH_GW_PORT   gw-branch NodePort (varsayılan 30449)
  BRANCH_CERT_DIR  cihaz ve internal-ca sertifikaları (varsayılan edge/certs)
  BRANCH_LISTEN    dinleme adresi (varsayılan 127.0.0.1; pod'da 0.0.0.0)
  BRANCH_APP_SECRET, TELLER_PASSWORD  verilmezse kubectl ile identity'den okunur (host modu)

Güvenlik notları (lab): client secret ve parola yalnız bellekte; tarayıcıya gönderilmez. Token'lar tarayıcıya ham gitmez.
"""
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
import threading
import urllib.parse
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CERTS = Path(os.environ.get("BRANCH_CERT_DIR", ROOT / "edge" / "certs"))
# gw-branch doğrudan (HAProxy yok). SNI ve sertifika doğrulaması teller.lab.local ile (gw-branch sertifikası bunu içerir).
EDGE = (os.environ.get("BRANCH_GW_HOST", "127.0.0.1"), int(os.environ.get("BRANCH_GW_PORT", "30449")))
HOST = "teller.lab.local"
INTERNAL_CA = str(CERTS / "internal-ca.crt")
DEVICE = (str(CERTS / "branch-device.crt"), str(CERTS / "branch-device.key"))
REALM = "/realms/bank/protocol/openid-connect"
PORT = 9100
LISTEN = os.environ.get("BRANCH_LISTEN", "127.0.0.1")

SECRETS = {}
SESSIONS = {}
LOCK = threading.Lock()


def b64u(raw):
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def decode_claims(token):
    try:
        s = token.split(".")[1]
        return json.loads(base64.urlsafe_b64decode(s + "=" * (-len(s) % 4)))
    except Exception:
        return {}


def summarize(token):
    c = decode_claims(token)
    return {"iss": c.get("iss"), "aud": c.get("aud"), "azp": c.get("azp"), "channel": c.get("channel"),
            "sender_constrained": "cnf" in c, "exp": c.get("exp")}


def load_secrets():
    # Pod modu: secret'lar ortam değişkeninden gelir (branch-app-secrets). Host modu: kubectl ile identity'den okunur.
    if os.environ.get("BRANCH_APP_SECRET") and os.environ.get("TELLER_PASSWORD"):
        SECRETS["branch-app"] = os.environ["BRANCH_APP_SECRET"]
        SECRETS["teller-password"] = os.environ["TELLER_PASSWORD"]
        return
    out = subprocess.run(["kubectl", "--context", "kind-identity", "-n", "auth", "get", "secret",
                          "keycloak-client-secrets", "-o", "json"], capture_output=True, text=True, check=True).stdout
    data = json.loads(out)["data"]
    SECRETS["branch-app"] = base64.b64decode(data["branch-app"]).decode()
    SECRETS["teller-password"] = base64.b64decode(data["teller-password"]).decode()


def teller_request(method, path, headers=None, body=None, cert=True):
    """teller.lab.local'a (edge, SNI passthrough) istek. cert=False: cihaz sertifikası sunulmaz (güvenlik testi)."""
    ctx = ssl.create_default_context(cafile=INTERNAL_CA)
    if cert:
        ctx.load_cert_chain(DEVICE[0], DEVICE[1])

    class SNIConnection(http.client.HTTPSConnection):
        def connect(self):
            sock = socket.create_connection(EDGE, timeout=20)
            self.sock = self._context.wrap_socket(sock, server_hostname=HOST)

    conn = SNIConnection(EDGE[0], EDGE[1], context=ctx, timeout=20)
    h = {"Host": HOST, "Connection": "close"}
    h.update(headers or {})
    conn.request(method, path, body=body, headers=h)
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


def login(username, password):
    redirect = "https://teller.lab.local/callback"
    verifier = secrets.token_urlsafe(48)
    challenge = b64u(hashlib.sha256(verifier.encode()).digest())
    jar = {}
    params = urllib.parse.urlencode({"client_id": "branch-app", "redirect_uri": redirect, "response_type": "code",
                                     "scope": "openid", "state": secrets.token_hex(4),
                                     "code_challenge": challenge, "code_challenge_method": "S256"})
    st, hdrs, page = teller_request("GET", f"{REALM}/auth?{params}")
    cookies_from(hdrs, jar)
    m = re.search(r'action="([^"]*login-actions[^"]*)"', page)
    if not m:
        raise RuntimeError(f"login formu alınamadı (HTTP {st})")
    act = urllib.parse.urlparse(html.unescape(m.group(1)))
    st, hdrs, _ = teller_request("POST", act.path + ("?" + act.query if act.query else ""),
                                 headers={"Cookie": "; ".join(f"{k}={v}" for k, v in jar.items()),
                                          "Content-Type": "application/x-www-form-urlencoded"},
                                 body=urllib.parse.urlencode({"username": username, "password": password,
                                                              "credentialId": ""}))
    loc = next((v for k, v in hdrs if k.lower() == "location"), "")
    code = urllib.parse.parse_qs(urllib.parse.urlparse(loc).query).get("code", [None])[0]
    if not code:
        raise RuntimeError(f"giriş başarısız (HTTP {st}); parola veya kullanıcı hatalı olabilir")
    st, _, body = teller_request("POST", f"{REALM}/token",
                                 headers={"Content-Type": "application/x-www-form-urlencoded"},
                                 body=urllib.parse.urlencode({"grant_type": "authorization_code",
                                                              "client_id": "branch-app",
                                                              "client_secret": SECRETS["branch-app"],
                                                              "code": code, "redirect_uri": redirect,
                                                              "code_verifier": verifier}))
    tok = json.loads(body)
    if "access_token" not in tok:
        raise RuntimeError(f"token alınamadı: {tok.get('error_description', tok.get('error'))}")
    return tok


class Handler(http.server.BaseHTTPRequestHandler):
    def _sid(self):
        m = re.search(r"branch_sid=([^;]+)", self.headers.get("Cookie", ""))
        return (m.group(1), False) if m else (secrets.token_hex(16), True)

    def _json(self, status, obj, sid, new):
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        if new:
            self.send_header("Set-Cookie", f"branch_sid={sid}; HttpOnly; SameSite=Strict; Path=/")
        self.end_headers()
        self.wfile.write(body)

    def _session(self, sid):
        with LOCK:
            return SESSIONS.setdefault(sid, {"tok": None, "user": None})

    def do_GET(self):
        sid, new = self._sid()
        if self.path == "/":
            body = (Path(__file__).parent / "index.html").read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            if new:
                self.send_header("Set-Cookie", f"branch_sid={sid}; HttpOnly; SameSite=Strict; Path=/")
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path == "/api/state":
            s = self._session(sid)
            info = summarize(s["tok"]["access_token"]) if s["tok"] else None
            return self._json(200, {"logged_in": bool(s["tok"]), "user": s["user"], "token": info}, sid, new)
        self._json(404, {"error": "not found"}, sid, new)

    def do_POST(self):
        sid, new = self._sid()
        s = self._session(sid)
        n = int(self.headers.get("Content-Length", "0") or 0)
        try:
            req = json.loads(self.rfile.read(n) or b"{}")
        except json.JSONDecodeError:
            return self._json(400, {"error": "geçersiz JSON"}, sid, new)
        try:
            if self.path == "/api/login":
                user = req.get("username") or "teller"
                pw = req.get("password") or SECRETS["teller-password"]
                s["tok"] = login(user, pw)
                s["user"] = user
                return self._json(200, {"ok": True, "token": summarize(s["tok"]["access_token"])}, sid, new)
            if self.path == "/api/logout":
                status = None
                if s["tok"]:
                    status, _, _ = teller_request("POST", f"{REALM}/logout",
                                                  headers={"Content-Type": "application/x-www-form-urlencoded"},
                                                  body=urllib.parse.urlencode({
                                                      "client_id": "branch-app",
                                                      "client_secret": SECRETS["branch-app"],
                                                      "refresh_token": s["tok"].get("refresh_token", "")}))
                s["tok"] = None
                s["user"] = None
                return self._json(200, {"ok": status in (None, 204), "keycloak_status": status}, sid, new)
            if self.path == "/api/call":
                method = req.get("method", "GET")
                path = req.get("path", "/")
                headers = {}
                if req.get("auth", "session") == "session" and s["tok"]:
                    headers["Authorization"] = f"Bearer {s['tok']['access_token']}"
                st, _, body = teller_request(method, path, headers=headers, cert=bool(req.get("cert", True)))
                expect = req.get("expect")
                return self._json(200, {"status": st, "body": body[:600],
                                        "pass": None if expect is None else str(st) == str(expect),
                                        "expect": expect}, sid, new)
            self._json(404, {"error": "not found"}, sid, new)
        except ssl.SSLError as e:
            # Cihaz sertifikası olmadan TLS el sıkışması reddedilir: bu bir güvenlik sonucudur
            self._json(200, {"status": "TLS", "body": str(e)[:200], "pass": req.get("expect") == "TLS",
                             "expect": req.get("expect")}, sid, new)
        except Exception as exc:
            self._json(500, {"error": str(exc)}, sid, new)

    def log_message(self, fmt, *args):
        print("branch", self.command, self.path, fmt % args, flush=True)


if __name__ == "__main__":
    load_secrets()
    print(f"Şube arayüzü: http://{LISTEN}:{PORT} -> gw-branch {EDGE[0]}:{EDGE[1]} (yalniz lab, cihaz sertifikası: branch-device)", flush=True)
    http.server.ThreadingHTTPServer((LISTEN, PORT), Handler).serve_forever()
