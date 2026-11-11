"""DMZ auth servisi (kgateway HTTP ext-authz hedefi).

Her istek için:
  1. X-Dmz-Channel başlığından kanal profilini seç.
  2. Dış token: RS256 imza (Keycloak JWKS), iss, aud, channel, exp.
  3. Sender constraint (RFC 9449 DPoP): token cnf.jkt içeriyorsa veya kanal mobile ise,
     DPoP proof doğrulanır: imza, htm, htu, iat, jti tekrarı, ath, cnf.jkt eşleşmesi.
  4. Token exchange: kanal sertifikasıyla (mTLS, Keycloak client-x509) iç JWT.
  5. 200 + Authorization: Bearer <iç JWT>. İç token istemciye dönmez.

DPoP proof imzaları: RS256 (RSA-2048+) ve ES256 (P-256). İkisi de stdlib ile doğrulanır
(ECDSA için aşağıda P-256 aritmetiği). Üretimde kütüphane tabanlı doğrulama önerilir.
DPoP jti tekrar kontrolü süreç içi bellektedir; çoklu replikada paylaşılan bir store gerekir.
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

import tracing  # ConfigMap ile /app/tracing.py (shared/tracing.py)
import metrics  # ConfigMap ile /app/metrics.py (shared/metrics.py)

DECISIONS = metrics.Counter("authz_decisions_total", "Yetkilendirme kararları", ["channel", "decision", "status"])
EXCHANGES = metrics.Counter("authz_exchange_total", "Token exchange sonuçları", ["channel", "status"])
DECISION_LATENCY = metrics.Histogram("authz_decision_duration_seconds", "Karar süresi", ["channel"])

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
    for c in ("web", "mobile", "partner", "branch")
}

# Kanal profilleri: beklenen audience
PROFILES = {
    "web":     {"aud": "channel-web"},
    "mobile":  {"aud": "channel-mobile"},
    "partner": {"aud": "channel-partner"},
    "branch":  {"aud": "channel-branch"},
}

# SHA-256 DigestInfo öneki (RFC 8017)
DIGEST_INFO_SHA256 = bytes.fromhex("3031300d060960864801650304020105000420")

# DPoP zaman penceresi (saniye)
DPOP_MAX_AGE = 300
DPOP_MAX_FUTURE = 60

# HTTP durumu -> OAuth benzeri hata kodu (hata gövdesi için)
ERROR_CODES = {400: "invalid_request", 401: "unauthorized", 403: "forbidden", 404: "not_found",
               500: "server_error", 503: "service_unavailable"}

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


# P-256 (secp256r1) parametreleri (SEC 2 / FIPS 186-4)
P256_P = 0xffffffff00000001000000000000000000000000ffffffffffffffffffffffff
P256_A = P256_P - 3
P256_B = 0x5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b
P256_N = 0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551
P256_G = (0x6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296,
          0x4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5)


def _ec_add(p1, p2):
    """Affin nokta toplama (None = sonsuz nokta)."""
    if p1 is None:
        return p2
    if p2 is None:
        return p1
    x1, y1 = p1
    x2, y2 = p2
    if x1 == x2 and (y1 + y2) % P256_P == 0:
        return None
    if p1 == p2:
        lam = (3 * x1 * x1 + P256_A) * pow(2 * y1, -1, P256_P) % P256_P
    else:
        lam = (y2 - y1) * pow(x2 - x1, -1, P256_P) % P256_P
    x3 = (lam * lam - x1 - x2) % P256_P
    y3 = (lam * (x1 - x3) - y1) % P256_P
    return (x3, y3)


def _ec_mul(k, point):
    result, addend = None, point
    while k:
        if k & 1:
            result = _ec_add(result, addend)
        addend = _ec_add(addend, addend)
        k >>= 1
    return result


def ec_p256_verify(qx, qy, signing_input, raw_sig):
    """ECDSA P-256 + SHA-256 (JWS ES256, RFC 7518 §3.4: imza = r || s, her biri 32 bayt)."""
    if len(raw_sig) != 64:
        return False
    r = int.from_bytes(raw_sig[:32], "big")
    s = int.from_bytes(raw_sig[32:], "big")
    if not (1 <= r < P256_N and 1 <= s < P256_N):
        return False
    # Genel anahtar eğri üzerinde olmalı
    if (qy * qy - (qx * qx * qx + P256_A * qx + P256_B)) % P256_P != 0:
        return False
    z = int.from_bytes(hashlib.sha256(signing_input).digest(), "big")
    w = pow(s, -1, P256_N)
    point = _ec_add(_ec_mul(z * w % P256_N, P256_G), _ec_mul(r * w % P256_N, (qx, qy)))
    return point is not None and point[0] % P256_N == r


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
    """RFC 7638: RSA veya EC public key thumbprint (SHA-256, kanonik JSON)."""
    if jwk.get("kty") == "EC":
        members = {"crv": jwk["crv"], "kty": "EC", "x": jwk["x"], "y": jwk["y"]}
    else:
        members = {"e": jwk["e"], "kty": "RSA", "n": jwk["n"]}
    canon = json.dumps(members, separators=(",", ":"), sort_keys=True)
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
    jwk = header.get("jwk") or {}
    if "d" in jwk:
        raise Denied(401, "dpop: private key in proof")
    alg = header.get("alg")
    signing_input = f"{h_b64}.{p_b64}".encode()
    try:
        if alg == "RS256" and jwk.get("kty") == "RSA":
            n = int.from_bytes(b64url_decode(jwk["n"]), "big")
            e = int.from_bytes(b64url_decode(jwk["e"]), "big")
            ok = rsa_verify(n, e, signing_input, sig)
        elif alg == "ES256" and jwk.get("kty") == "EC" and jwk.get("crv") == "P-256":
            qx = b64url_decode(jwk["x"])
            qy = b64url_decode(jwk["y"])
            if len(qx) != 32 or len(qy) != 32:
                raise Denied(401, "dpop: invalid EC point size")
            ok = ec_p256_verify(int.from_bytes(qx, "big"), int.from_bytes(qy, "big"), signing_input, sig)
        else:
            raise Denied(401, "dpop: unsupported alg/kty (RS256+RSA, ES256+P-256)")
    except (KeyError, ValueError):
        raise Denied(401, "dpop: invalid public jwk")
    if not ok:
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


def exchange(subject_token, channel, span=None):
    # Kanala özel exchange istemcisi: dmz-exchange-<channel>. Kimlik doğrulama mTLS sertifikası ile.
    form = urllib.parse.urlencode({
        "grant_type": "urn:ietf:params:oauth:grant-type:token-exchange",
        "client_id": f"dmz-exchange-{channel}",
        "subject_token": subject_token,
        "subject_token_type": "urn:ietf:params:oauth:token-type:access_token",
        "requested_token_type": "urn:ietf:params:oauth:token-type:access_token",
        "audience": INTERNAL_AUDIENCE,
    }).encode()
    child = tracing.start_client_span("ext-authz -> token exchange", span,
                                      {"peer.service": "keycloak", "exchange.channel": channel}) if span else None
    headers = {"Content-Type": "application/x-www-form-urlencoded"}
    if child:
        headers["traceparent"] = child.header()
    req = urllib.request.Request(STS_URL, data=form, method="POST", headers=headers)
    status = None
    try:
        with urllib.request.urlopen(req, timeout=5, context=EXCHANGE_CTX[channel]) as resp:
            status = resp.status
            return json.loads(resp.read())["access_token"]
    except urllib.error.HTTPError as e:
        status = e.code
        raise Denied(403, f"exchange rejected ({e.code})")
    except Exception:
        status = 503
        raise Denied(503, "exchange unavailable")
    finally:
        EXCHANGES.inc(channel=channel if channel in PROFILES else "unknown", status=str(status or "error"))
        if child:
            child.end(http_status=status)


class Handler(BaseHTTPRequestHandler):
    def _handle(self):
        path = self.path.split("?", 1)[0]
        channel = self.headers.get("X-Dmz-Channel", "")
        span = tracing.start_server_span(f"ext-authz {self.command} {path}", self.headers.get("traceparent"),
                                         {"http.method": self.command, "http.target": path, "channel": channel,
                                          "x-request-id": self.headers.get("X-Request-ID")})
        self._status = None
        started = time.perf_counter()
        label = channel if channel in PROFILES else "unknown"  # kardinalite sınırı
        try:
            self._decide(span, channel)
        finally:
            code = self._status or 200
            span.end(http_status=code)
            DECISIONS.inc(channel=label, decision="allow" if code == 200 else "deny", status=str(code))
            DECISION_LATENCY.observe(time.perf_counter() - started, channel=label)

    def _decide(self, span, channel):
        auth = self.headers.get("Authorization", "")
        try:
            if channel not in PROFILES:
                raise Denied(500, "unknown channel")
            if not auth.startswith("Bearer "):
                raise Denied(401, "missing bearer token")
            token = auth[len("Bearer "):]
            claims = verify_rs256(token)
            check_claims(claims, channel)
            span.set("user.hash", tracing.user_hash(claims.get("sub")))

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

            internal = exchange(token, channel, span)
        except Denied as d:
            span.set("decision", f"deny:{d.status}")
            self._send(d.status, d.message, None)
            return
        span.set("decision", "allow")
        self._send(200, "ok", internal)

    def _send(self, status, message, internal):
        self._status = status
        if status >= 400:
            # Hata gövdesi yapılandırılmış JSON: neden reddedildiği istemciye ve konsola döner.
            # Mesaj metni error_description'da aynen kalır (testler ve loglar için).
            body = json.dumps({"error": ERROR_CODES.get(status, "error"), "error_description": message,
                               "layer": "dmz-ext-authz", "status": status}, ensure_ascii=False).encode()
            ctype = "application/json; charset=utf-8"
        else:
            body = message.encode()
            ctype = "text/plain"
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        if status == 401:
            self.send_header("WWW-Authenticate", f'Bearer error="invalid_token", error_description="{message}"')
        if internal:
            self.send_header("Authorization", f"Bearer {internal}")
        self.end_headers()
        self.wfile.write(body)

    do_GET = do_POST = do_PUT = do_DELETE = do_PATCH = _handle

    def log_message(self, fmt, *args):
        print(f"ext-authz {self.command} {self.path} {fmt % args}", flush=True)


if __name__ == "__main__":
    metrics.start_metrics_server(int(os.environ.get("METRICS_PORT", "9100")))  # metrikler API portundan ayrı
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
