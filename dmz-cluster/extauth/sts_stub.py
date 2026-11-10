"""İç STS (lab stub). Gerçekte iç Keycloak'un token-exchange endpoint'i olur (RFC 8693).

Girdi : subject_token (dış token), channel, sub, partner_id
Kontrol: X-Exchange-Client kanala eşleşmeli (dmz-exchange-<channel>),
         dış token'ın imzası ve channel claim'i kontrol edilir.
Çıktı  : iç JWT (iss=lab-internal, aud=kgateway-internal), 300 sn ömürlü.

LAB SINIRI: HS256 kullanılır. Üretimde iç Keycloak RS256/ES256 ile imzalar.
"""
import base64
import hashlib
import hmac
import json
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

EXT_KEY = os.environ["EXT_ISSUER_KEY"].encode()
INTERNAL_KEY = os.environ["INTERNAL_ISSUER_KEY"].encode()

CLIENT_CHANNEL = {
    "dmz-exchange-web": "web",
    "dmz-exchange-mobile": "mobile",
    "dmz-exchange-partner": "partner",
}
AUTH_METHOD = {
    "web": "pwd_otp",
    "mobile": "dpop_device",
    "partner": "mtls_partner",
}
TTL = 300


def b64url_encode(raw):
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def b64url_decode(data):
    return base64.urlsafe_b64decode(data + "=" * (-len(data) % 4))


def verify_hs256(token, key):
    h_b64, p_b64, s_b64 = token.split(".")
    expected = hmac.new(key, f"{h_b64}.{p_b64}".encode(), hashlib.sha256).digest()
    if not hmac.compare_digest(expected, b64url_decode(s_b64)):
        raise ValueError("bad signature")
    return json.loads(b64url_decode(p_b64))


def mint_internal(sub, channel, partner_id):
    now = int(time.time())
    header = b64url_encode(json.dumps({"alg": "HS256", "typ": "JWT"}).encode())
    claims = {
        "iss": "lab-internal",
        "aud": ["kgateway-internal"],
        "sub": sub,
        "channel": channel,
        "auth_method": AUTH_METHOD[channel],
        "scope": "api",
        "iat": now,
        "exp": now + TTL,
    }
    if partner_id:
        claims["partner_id"] = partner_id
    payload = b64url_encode(json.dumps(claims).encode())
    sig = hmac.new(INTERNAL_KEY, f"{header}.{payload}".encode(), hashlib.sha256).digest()
    return f"{header}.{payload}.{b64url_encode(sig)}"


class Handler(BaseHTTPRequestHandler):
    def _json(self, status, obj):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if self.path != "/exchange":
            return self._json(404, {"error": "not_found"})
        client = self.headers.get("X-Exchange-Client", "")
        channel = CLIENT_CHANNEL.get(client)
        if channel is None:
            return self._json(403, {"error": "unauthorized_client"})
        length = int(self.headers.get("Content-Length", "0"))
        try:
            req = json.loads(self.rfile.read(length) or b"{}")
            subject = req["subject_token"]
            claims = verify_hs256(subject, EXT_KEY)
        except Exception:
            return self._json(400, {"error": "invalid_subject_token"})
        if req.get("channel") != channel or claims.get("channel") != channel:
            return self._json(403, {"error": "channel_not_allowed"})
        token = mint_internal(claims.get("sub"), channel, claims.get("partner_id"))
        self._json(200, {"access_token": token, "token_type": "Bearer", "expires_in": TTL})

    def log_message(self, fmt, *args):
        print(f"sts {self.command} {self.path} {fmt % args}", flush=True)


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
