"""İç servis (BFF / core): gelen isteğin iç JWT'sini KENDİSİ doğrular (savunma derinliği, design.md 4.3).

- Gateway başlıklarına (x-channel, x-user-id vb.) GÜVENMEZ. Kanal, kullanıcı ve yöntem yalnızca token claim'lerinden alınır.
- İmza: iç Keycloak JWKS (RS256). iss, aud (kgateway-internal), exp ve kanal kontrol edilir.
- PUBLIC_PATHS=1 ise GET /public/* token gerektirmez (design 5.0a).

Env: SERVICE_NAME, ALLOWED_CHANNELS (csv), EXPECTED_ISSUER, AUDIENCE, JWKS_URL, PUBLIC_PATHS, PORT.

LAB SINIRI: RS256 stdlib ile doğrulanır. Üretimde kütüphane ve JWKS önbellek politikası kullanılmalı.
"""
import base64
import hashlib
import hmac
import json
import os
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SERVICE = os.environ["SERVICE_NAME"]
ALLOWED = set(os.environ["ALLOWED_CHANNELS"].split(","))
EXPECTED_ISSUER = os.environ["EXPECTED_ISSUER"]
AUDIENCE = os.environ.get("AUDIENCE", "kgateway-internal")
JWKS_URL = os.environ["JWKS_URL"]
PUBLIC_PATHS = os.environ.get("PUBLIC_PATHS", "0") == "1"
PORT = int(os.environ.get("PORT", "8080"))

DIGEST_INFO_SHA256 = bytes.fromhex("3031300d060960864801650304020105000420")
_jwks = {}


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


def verify(token):
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
    if claims.get("channel") not in ALLOWED:
        raise Denied(403, "channel not allowed for this service")
    return claims


class Handler(BaseHTTPRequestHandler):
    def _send(self, status, body):
        data = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _handle(self):
        path = self.path.split("?", 1)[0]
        if PUBLIC_PATHS and self.command == "GET" and path.startswith("/public/"):
            return self._send(200, f"service={SERVICE} public path={self.path}\n")
        auth = self.headers.get("Authorization", "")
        try:
            if not auth.startswith("Bearer "):
                raise Denied(401, "missing bearer token")
            claims = verify(auth[len("Bearer "):])
        except Denied as d:
            return self._send(d.status, d.message + "\n")
        self._send(200, f"service={SERVICE} channel={claims.get('channel')} user={claims.get('sub')} "
                        f"auth_method={claims.get('auth_method')} path={self.path}\n")

    do_GET = do_POST = do_PUT = do_DELETE = do_PATCH = _handle

    def log_message(self, fmt, *args):
        print(f"{SERVICE} {self.command} {self.path} {fmt % args}", flush=True)


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
