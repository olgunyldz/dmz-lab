"""DMZ auth servisi (kgateway HTTP ext-authz hedefi).

Her istek için:
  1. X-Dmz-Channel başlığından kanal profilini seç.
  2. Dış token: RS256 imza (Keycloak JWKS), iss, aud, channel, exp.
  3. Sender constraint (RFC 9449 DPoP): token cnf.jkt içeriyorsa veya kanal mobile ise,
     DPoP proof doğrulanır: imza, htm, htu, iat, jti tekrarı, ath, cnf.jkt eşleşmesi.
  4. Token exchange: kanal sertifikasıyla (mTLS, Keycloak client-x509) iç JWT.
  5. 200 + Authorization: Bearer <iç JWT>. İç token istemciye dönmez.

LAB SINIRI: RSA (RS256) imzaları stdlib ile doğrulanır. ES256 DPoP proof'ları için
bir kriptografi kütüphanesi gerekir (üretimde önerilir). DPoP jti tekrar kontrolü
süreç içi bellektedir; çoklu replikada paylaşılan bir store gerekir.
"""
import base64
import hashlib
import hmac
import json
import os
import ssl
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

EXPECTED_ISSUER = os.environ["EXPECTED_ISSUER"]
JWKS_URL = os.environ["JWKS_URL"]
STS_URL = os.environ["STS_URL"]
INTERNAL_AUDIENCE = "kgateway-internal"
INTERNAL_CA = os.environ["INTERNAL_CA_FILE"]


def _tls_ctx(cert, key):
    ctx = ssl.create_default_context(cafile=INTERNAL_CA)
    ctx.load_cert_chain(cert, key)
    return ctx


# JWKS çağrısı: DMZ gateway kimliği (iç gateway mTLS ister)
TLS_CTX = _tls_ctx(os.environ["CLIENT_CERT_FILE"], os.environ["CLIENT_KEY_FILE"])
# Token exchange: her kanal kendi sertifikasıyla bağlanır (Keycloak client-x509, CN=dmz-exchange-<kanal>)
EXCHANGE_CTX = {
    c: _tls_ctx(os.environ[f"EXCHANGE_CERT_{c.upper()}"], os.environ[f"EXCHANGE_KEY_{c.upper()}"])
    for c in ("web", "mobile", "partner")
}

# Kanal profilleri: beklenen audience
PROFILES = {
    "web":     {"aud": "channel-web"},
    "mobile":  {"aud": "channel-mobile"},
    "partner": {"aud": "channel-partner"},
}

# SHA-256 DigestInfo öneki (RFC 8017)
DIGEST_INFO_SHA256 = bytes.fromhex("3031300d060960864801650304020105000420")

# DPoP zaman penceresi (saniye)
DPOP_MAX_AGE = 300
DPOP_MAX_FUTURE = 60

_jwks = {}
_jwks_at = 0.0
_replay = {}  # jti -> son geçerlilik zamanı
_replay_lock = threading.Lock()


class Denied(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message


def b64url_decode(data):
    return base64.urlsafe_b64decode(data + "=" * (-len(data) % 4))


def b64url_encode(raw):
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def rsa_verify(n, e, signing_input, sig):
    """RSASSA-PKCS1-v1_5 + SHA-256 imza doğrulaması (RFC 8017)."""
    k = (n.bit_length() + 7) // 8
    if len(sig) != k:
        return False
    recovered = pow(int.from_bytes(sig, "big"), e, n).to_bytes(k, "big")
    t = DIGEST_INFO_SHA256 + hashlib.sha256(signing_input).digest()
    expected = b"\x00\x01" + b"\xff" * (k - len(t) - 3) + b"\x00" + t
    return hmac.compare_digest(recovered, expected)


def load_jwks():
    global _jwks, _jwks_at
    with urllib.request.urlopen(JWKS_URL, timeout=5, context=TLS_CTX) as resp:
        data = json.loads(resp.read())
    _jwks = {
        k["kid"]: (int.from_bytes(b64url_decode(k["n"]), "big"), int.from_bytes(b64url_decode(k["e"]), "big"))
        for k in data["keys"] if k.get("kty") == "RSA"
    }
    _jwks_at = time.time()


def verify_rs256(token):
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
        # Bilinmeyen kid: anahtar rotasyonu olmuş olabilir, JWKS'i yenile
        try:
            load_jwks()
        except Exception:
            raise Denied(503, "jwks unavailable")
    if kid not in _jwks:
        raise Denied(401, "unknown kid")

    n, e = _jwks[kid]
    if not rsa_verify(n, e, f"{h_b64}.{p_b64}".encode(), sig):
        raise Denied(401, "bad signature")
    return claims


def check_claims(claims, channel):
    if claims.get("iss") != EXPECTED_ISSUER:
        raise Denied(403, "issuer mismatch")
    aud = claims.get("aud")
    auds = aud if isinstance(aud, list) else [aud]
    if PROFILES[channel]["aud"] not in auds:
        raise Denied(403, "audience mismatch")
    if claims.get("channel") != channel:
        raise Denied(403, "channel mismatch")
    if int(claims.get("exp", 0)) <= int(time.time()):
        raise Denied(401, "token expired")


def jwk_thumbprint(jwk):
    """RFC 7638: RSA public key thumbprint (SHA-256, kanonik JSON)."""
    canon = json.dumps({"e": jwk["e"], "kty": "RSA", "n": jwk["n"]}, separators=(",", ":"), sort_keys=True)
    return b64url_encode(hashlib.sha256(canon.encode()).digest())


def verify_dpop(proof, method, htu, access_token, expected_jkt):
    """RFC 9449 DPoP proof doğrulaması."""
    try:
        h_b64, p_b64, s_b64 = proof.split(".")
        header = json.loads(b64url_decode(h_b64))
        payload = json.loads(b64url_decode(p_b64))
        sig = b64url_decode(s_b64)
    except Exception:
        raise Denied(401, "malformed dpop proof")

    if header.get("typ") != "dpop+jwt":
        raise Denied(401, "dpop: wrong typ")
    if header.get("alg") != "RS256":
        raise Denied(401, "dpop: unsupported alg (lab: RS256)")
    jwk = header.get("jwk") or {}
    if jwk.get("kty") != "RSA" or "d" in jwk:
        raise Denied(401, "dpop: invalid public jwk")

    n = int.from_bytes(b64url_decode(jwk["n"]), "big")
    e = int.from_bytes(b64url_decode(jwk["e"]), "big")
    if not rsa_verify(n, e, f"{h_b64}.{p_b64}".encode(), sig):
        raise Denied(401, "dpop: bad signature")

    if payload.get("htm") != method:
        raise Denied(401, "dpop: htm mismatch")
    if payload.get("htu") != htu:
        raise Denied(401, "dpop: htu mismatch")

    now = time.time()
    iat = payload.get("iat")
    if not isinstance(iat, int) or iat < now - DPOP_MAX_AGE or iat > now + DPOP_MAX_FUTURE:
        raise Denied(401, "dpop: stale or future iat")

    expected_ath = b64url_encode(hashlib.sha256(access_token.encode()).digest())
    if payload.get("ath") != expected_ath:
        raise Denied(401, "dpop: ath mismatch")

    if jwk_thumbprint(jwk) != expected_jkt:
        raise Denied(401, "dpop: key does not match token cnf.jkt")

    jti = payload.get("jti")
    if not isinstance(jti, str) or not jti:
        raise Denied(401, "dpop: missing jti")
    with _replay_lock:
        for k in [k for k, exp in _replay.items() if exp < now]:
            del _replay[k]
        if jti in _replay:
            raise Denied(401, "dpop: replayed proof")
        _replay[jti] = iat + DPOP_MAX_AGE + DPOP_MAX_FUTURE


def exchange(subject_token, channel):
    # Kanala özel exchange istemcisi: dmz-exchange-<channel>. Kimlik doğrulama mTLS sertifikası ile.
    form = urllib.parse.urlencode({
        "grant_type": "urn:ietf:params:oauth:grant-type:token-exchange",
        "client_id": f"dmz-exchange-{channel}",
        "subject_token": subject_token,
        "subject_token_type": "urn:ietf:params:oauth:token-type:access_token",
        "requested_token_type": "urn:ietf:params:oauth:token-type:access_token",
        "audience": INTERNAL_AUDIENCE,
    }).encode()
    req = urllib.request.Request(
        STS_URL, data=form, method="POST",
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    try:
        with urllib.request.urlopen(req, timeout=5, context=EXCHANGE_CTX[channel]) as resp:
            return json.loads(resp.read())["access_token"]
    except urllib.error.HTTPError as e:
        raise Denied(403, f"exchange rejected ({e.code})")
    except Exception:
        raise Denied(503, "exchange unavailable")


class Handler(BaseHTTPRequestHandler):
    def _handle(self):
        channel = self.headers.get("X-Dmz-Channel", "")
        auth = self.headers.get("Authorization", "")
        try:
            if channel not in PROFILES:
                raise Denied(500, "unknown channel")
            if not auth.startswith("Bearer "):
                raise Denied(401, "missing bearer token")
            token = auth[len("Bearer "):]
            claims = verify_rs256(token)
            check_claims(claims, channel)

            jkt = (claims.get("cnf") or {}).get("jkt")
            if channel == "mobile" and not jkt:
                raise Denied(401, "mobile token not sender-constrained")
            if jkt:
                proof = self.headers.get("DPoP", "")
                if not proof:
                    raise Denied(401, "missing dpop proof")
                # htu: istemcinin çağırdığı tam URL (query hariç)
                htu = f"https://{self.headers.get('Host', '')}{self.path.split('?', 1)[0]}"
                verify_dpop(proof, self.command, htu, token, jkt)

            internal = exchange(token, channel)
        except Denied as d:
            self._send(d.status, d.message, None)
            return
        self._send(200, "ok", internal)

    def _send(self, status, message, internal):
        body = message.encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        if internal:
            self.send_header("Authorization", f"Bearer {internal}")
        self.end_headers()
        self.wfile.write(body)

    do_GET = do_POST = do_PUT = do_DELETE = do_PATCH = _handle

    def log_message(self, fmt, *args):
        print(f"ext-authz {self.command} {self.path} {fmt % args}", flush=True)


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
