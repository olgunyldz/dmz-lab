#!/usr/bin/env python3
"""Mobil kimlik akışı uçtan uca testi (IdP = kimlik, OTP, aktivasyon, login durumu; Seal = cihaz + PIN).

Gerçek IdP token'ları: mobil (mobile-app, PKCE + DPoP) ve web (web-app), alice ile.
Yollar:
  - Test -> IdP (port-forward 18449, SNI id.bank.lab.local, iç CA)
  - Cihaz -> HAProxy (127.0.0.1:8443, SNI seal.lab.local, passthrough) -> seal-mobile (cihaz mTLS)
  - Test (DMZ istemcisi) -> gw-internal (port-forward 19543, mTLS dmz-client) -> /internal/auth/*, /seal-pm/
Gereken: kubectl context kind-identity/internal/dmz; HAProxy ayakta; edge/certs/{seal,device,dmz-client}.
"""
import base64
import hashlib
import http.client
import json
import os
import re
import secrets
import socket
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.parse
import uuid

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
CERTS = os.path.join(REPO, "edge", "certs")
CA = os.path.join(CERTS, "internal-ca.crt")
GW_PORT, IDP_PORT, HAPROXY_PORT = 19543, 18449, 8443
IDP_HOST = "id.bank.lab.local"
REALM = "/realms/bank/protocol/openid-connect"
passed = failed = 0


def check(name, ok, detail=""):
    global passed, failed
    if ok:
        passed += 1
        print("PASS  " + name)
    else:
        failed += 1
        print("FAIL  " + name + "  " + str(detail)[:220])


def secret(name):
    out = subprocess.check_output(["kubectl", "--context", "kind-identity", "-n", "idp", "get", "secret",
                                   "idp-secrets", "-o", f"jsonpath={{.data.{name}}}"])
    return base64.b64decode(out).decode()


def tls_request(host, port, sni, method, path, body=None, headers=None, client=None, ca=CA, form=False):
    """Yanıt: (status | 'TLS', json-ya-da-ham, set-cookie listesi, location)."""
    ctx = ssl.create_default_context(cafile=ca)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    if client:
        ctx.load_cert_chain(client[0], client[1])
    try:
        sock = ctx.wrap_socket(socket.create_connection((host, port), timeout=20), server_hostname=sni)
        conn = http.client.HTTPConnection(sni, timeout=20)
        conn.sock = sock
        if form:
            data = body.encode() if isinstance(body, str) else body
            hdrs = {"Content-Type": "application/x-www-form-urlencoded", "Host": sni, **(headers or {})}
        else:
            data = json.dumps(body).encode() if body is not None else None
            hdrs = {"Content-Type": "application/json", "Host": sni, **(headers or {})}
        conn.request(method, path, body=data, headers=hdrs)
        resp = conn.getresponse()
        raw = resp.read()
        cookies = [v for k, v in resp.getheaders() if k.lower() == "set-cookie"]
        loc = resp.getheader("Location", "")
        conn.close()
        try:
            parsed = json.loads(raw or b"{}")
        except ValueError:
            parsed = {"raw": raw.decode("utf-8", "replace")}
        return resp.status, parsed, cookies, loc
    except (ssl.SSLError, OSError) as e:
        return "TLS", {"error": f"{type(e).__name__}: {e}"}, [], ""


def dmz_client():
    return (os.path.join(CERTS, "dmz-client.crt"), os.path.join(CERTS, "dmz-client.key"))


def dev_client(name):
    return (os.path.join(CERTS, "device", name + ".crt"), os.path.join(CERTS, "device", name + ".key"))


def fresh_device():
    """Her çalıştırmada kayıtsız yeni cihaz sertifikası (device CA ile). Dönüş: (crt, key, cn)."""
    cn = "device-test-" + secrets.token_hex(4)
    td = tempfile.mkdtemp()
    crt, key = os.path.join(td, "d.crt"), os.path.join(td, "d.key")
    dev_ca = os.path.join(CERTS, "device")
    ext = os.path.join(td, "d.ext")
    with open(ext, "w") as fh:
        fh.write(f"subjectAltName=DNS:{cn}\nextendedKeyUsage=clientAuth\nbasicConstraints=CA:FALSE\n")
    csr = os.path.join(td, "d.csr")
    subprocess.run(["openssl", "req", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", csr,
                    "-subj", f"/CN={cn}"], check=True, capture_output=True)
    subprocess.run(["openssl", "x509", "-req", "-in", csr, "-CA", os.path.join(dev_ca, "device-ca.crt"),
                    "-CAkey", os.path.join(dev_ca, "device-ca.key"), "-CAcreateserial", "-out", crt,
                    "-days", "1", "-extfile", ext], check=True, capture_output=True)
    return (crt, key, cn)


def gw(method, path, body=None, headers=None):
    return tls_request("127.0.0.1", GW_PORT, "gw-internal", method, path, body, headers, client=dmz_client())


MOBILE_KEYS = {}  # mobil access token -> (anahtar yolu, x, y)


def seal(path, body, token=None, device="device-lab-01"):
    h = {"Authorization": f"Bearer {token}"} if token else {}
    if token in MOBILE_KEYS:
        key, x, y = MOBILE_KEYS[token]
        h["DPoP"] = dpop_proof(key, x, y, "POST", f"https://seal.lab.local{path}", access_token=token)
    client = device if isinstance(device, tuple) else dev_client(device)
    return tls_request("127.0.0.1", HAPROXY_PORT, "seal.lab.local", "POST", path, body, h, client=(client[0], client[1]))


def sign_nonce(device, nonce):
    """Cihaz anahtarıyla challenge imzası (RS256 / PKCS1v15 SHA-256), base64. device: ad ya da (crt, key, cn)."""
    key = device[1] if isinstance(device, tuple) else os.path.join(CERTS, "device", device + ".key")
    with tempfile.TemporaryDirectory() as td:
        inp, sig = os.path.join(td, "n"), os.path.join(td, "s")
        open(inp, "wb").write(nonce.encode())
        subprocess.run(["openssl", "dgst", "-sha256", "-sign", key, "-out", sig, inp], check=True, capture_output=True)
        return base64.b64encode(open(sig, "rb").read()).decode()


# ---------------- IdP: PKCE (+ mobil DPoP) ----------------
def b64u(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def idp(method, path, headers=None, body=None):
    return tls_request("127.0.0.1", IDP_PORT, IDP_HOST, method, path, body, headers, form=isinstance(body, str))


def jar_header(jar):
    return "; ".join(f"{k}={v}" for k, v in jar.items())


def cookies_into(jar, set_cookies):
    for c in set_cookies:
        kv = c.split(";", 1)[0]
        if "=" in kv:
            k, v = kv.split("=", 1)
            jar[k.strip()] = v.strip()


def ec_key(tmp):
    key = os.path.join(tmp, "dpop.pem")
    subprocess.run(["openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", key],
                   check=True, capture_output=True)
    der = subprocess.run(["openssl", "ec", "-in", key, "-pubout", "-outform", "DER"],
                         check=True, capture_output=True).stdout
    return key, b64u(der[-64:-32]), b64u(der[-32:])


def der_to_raw(der):
    i = 2 + (der[1] & 0x7F) if der[1] & 0x80 else 2
    out = b""
    for _ in range(2):
        ln = der[i + 1]
        out += der[i + 2:i + 2 + ln].lstrip(b"\x00").rjust(32, b"\x00")
        i += 2 + ln
    return out


def dpop_proof(key, x, y, htm, htu, access_token=None):
    header = {"typ": "dpop+jwt", "alg": "ES256", "jwk": {"kty": "EC", "crv": "P-256", "x": x, "y": y}}
    payload = {"htm": htm, "htu": htu, "iat": int(time.time()), "jti": secrets.token_hex(8)}
    if access_token:
        payload["ath"] = b64u(hashlib.sha256(access_token.encode()).digest())
    h = b64u(json.dumps(header, separators=(",", ":")).encode())
    p = b64u(json.dumps(payload, separators=(",", ":")).encode())
    with tempfile.TemporaryDirectory() as td:
        inp, sig = os.path.join(td, "in"), os.path.join(td, "sig.der")
        open(inp, "wb").write(f"{h}.{p}".encode())
        subprocess.run(["openssl", "dgst", "-sha256", "-sign", key, "-out", sig, inp], check=True, capture_output=True)
        raw = der_to_raw(open(sig, "rb").read())
    return f"{h}.{p}.{b64u(raw)}"


def idp_token(client, redirect, username, password, client_secret=None, mobile=False):
    verifier = secrets.token_urlsafe(48)
    challenge = b64u(hashlib.sha256(verifier.encode()).digest())
    jar = {}
    q = urllib.parse.urlencode({"client_id": client, "redirect_uri": redirect, "response_type": "code",
                                "scope": "openid", "state": secrets.token_hex(4),
                                "code_challenge": challenge, "code_challenge_method": "S256"})
    st, _, sc, _ = idp("GET", f"{REALM}/auth?{q}")
    cookies_into(jar, sc)
    st, page, sc, _ = idp("GET", "/login", {"Cookie": jar_header(jar)})
    cookies_into(jar, sc)
    m = re.search(r'name="_csrf"[^>]*value="([^"]*)"', page.get("raw", ""))
    if not m:
        raise RuntimeError(f"login formu alınamadı ({st})")
    form = urllib.parse.urlencode({"username": username, "password": password, "_csrf": m.group(1)})
    st, _, sc, loc = idp("POST", "/login", {"Cookie": jar_header(jar)}, form)
    cookies_into(jar, sc)
    target = urllib.parse.urlparse(loc)
    if not target.path or "/login" in target.path:
        raise RuntimeError("giriş başarısız (kullanıcı/parola)")
    st, _, sc, loc = idp("GET", target.path + ("?" + target.query if target.query else ""),
                         {"Cookie": jar_header(jar)})
    code = urllib.parse.parse_qs(urllib.parse.urlparse(loc).query).get("code", [None])[0]
    if not code:
        raise RuntimeError("code alınamadı")
    headers = {}
    token_form = {"grant_type": "authorization_code", "client_id": client, "code": code,
                  "redirect_uri": redirect, "code_verifier": verifier}
    if client_secret:
        headers["Authorization"] = "Basic " + base64.b64encode(f"{client}:{client_secret}".encode()).decode()
    key = x = y = None
    if mobile:
        key, x, y = ec_key(tempfile.mkdtemp())
        headers["DPoP"] = dpop_proof(key, x, y, "POST", f"https://{IDP_HOST}{REALM}/token")
    st, body, _, _ = idp("POST", f"{REALM}/token", headers, urllib.parse.urlencode(token_form))
    if "access_token" not in body:
        raise RuntimeError(f"token alınamadı ({st}): {body.get('error_description', body.get('error'))}")
    if mobile:
        MOBILE_KEYS[body["access_token"]] = (key, x, y)
    return body["access_token"]


def introspect_full(token):
    """IdP introspection (seal-mobile istemcisi): tüm yanıt."""
    basic = base64.b64encode(f"seal-mobile:{secret('SEAL_MOBILE_SECRET')}".encode()).decode()
    s, b, _, _ = idp("POST", f"{REALM}/token/introspect", {"Authorization": "Basic " + basic},
                     urllib.parse.urlencode({"token": token}))
    return b


def introspect(token):
    return introspect_full(token).get("active") is True


def forged_token():
    import jwt as pyjwt
    return pyjwt.encode({"sub": "alice", "channel": "mobile", "aud": "channel-mobile",
                         "iss": "https://id.bank.lab.local/realms/bank", "exp": int(time.time()) + 300,
                         "cnf": {"jkt": "x"}}, "gizli", algorithm="HS256")


def main():
    pfs = [subprocess.Popen(["kubectl", "--context", "kind-internal", "-n", "gw-internal",
                             "port-forward", "svc/gw-internal", f"{GW_PORT}:443"],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL),
           subprocess.Popen(["kubectl", "--context", "kind-identity", "-n", "idp",
                             "port-forward", "svc/spring-idp", f"{IDP_PORT}:8443"],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)]
    try:
        time.sleep(5)
        alice_pw = secret("ALICE_PASSWORD")
        web_secret = secret("WEB_APP_SECRET")
        user = "alice"

        # 0) Parola yalnız IdP'de; mobil token (DPoP) ve web token
        m1 = idp_token("mobile-app", "com.bank.app:/callback", user, alice_pw, mobile=True)
        check("IdP mobil token (DPoP, channel=mobile)", bool(m1))

        # 1) Cihaz kaydı (mobil token + PIN)
        s, b, _, _ = seal("/seal/mobile/v1/device/enroll", {"pin": "4321"}, token=m1)
        check("enroll device-lab-01 -> ENROLLED", s == 200 and b.get("status") == "ENROLLED", (s, b))
        s, b, _, _ = seal("/seal/mobile/v1/device/enroll", {"pin": "1111"}, token=m1, device="device-lab-02")
        check("enroll device-lab-02 -> ENROLLED", s == 200, (s, b))
        s, b, _, _ = seal("/seal/mobile/v1/device/enroll", {"pin": "4321"}, token=None)
        check("enroll: IdP token yok -> 401", s == 401, (s, b))

        # 2) PIN -> PIN_OK (challenge) -> cihaz imzası -> PIN_AUTHORIZED
        s, b, _, _ = seal("/seal/mobile/v1/login/begin", {}, token=m1)
        flow = b.get("flowId", "")
        check("login/begin -> flowId", s == 200 and bool(flow), (s, b))
        s, b, _, _ = seal("/seal/mobile/v1/login/pin", {"flowId": flow, "pin": "9999"}, token=m1)
        check("yanlış PIN -> PIN_INVALID", b.get("status") == "PIN_INVALID", (s, b))
        s, b, _, _ = seal("/seal/mobile/v1/login/pin", {"flowId": flow, "pin": "4321"}, token=m1)
        check("doğru PIN -> PIN_OK + challenge", s == 200 and b.get("status") == "PIN_OK" and b.get("nonce"), (s, b))
        auth_id, nonce = b.get("authorizationId", ""), b.get("nonce", "")
        s, b, _, _ = seal("/seal/mobile/v1/login/authorize",
                          {"flowId": flow, "authorizationId": auth_id, "signature": sign_nonce("device-lab-02", nonce)},
                          token=m1)
        check("yanlış cihaz imzası (device-lab-02 anahtarı) -> 401", s == 401, (s, b))
        s, b, _, _ = seal("/seal/mobile/v1/login/pin", {"flowId": flow, "pin": "4321"}, token=m1)
        auth_id, nonce = b.get("authorizationId", ""), b.get("nonce", "")
        s, b, _, _ = seal("/seal/mobile/v1/login/authorize",
                          {"flowId": flow, "authorizationId": auth_id, "signature": sign_nonce("device-lab-01", nonce)},
                          token=m1)
        check("cihaz imzası (device-lab-01) -> PIN_AUTHORIZED", s == 200 and b.get("status") == "PIN_AUTHORIZED", (s, b))
        s, b, _, _ = seal("/seal/mobile/v1/login/authorize",
                          {"flowId": flow, "authorizationId": auth_id, "signature": sign_nonce("device-lab-01", nonce)},
                          token=m1)
        check("yetkilendirme tek kullanımlık (tekrar -> 409/403)", s in (403, 409), (s, b))

        # 3) IdP login durumu (gw-internal /internal/auth/login/status)
        s, b, _, _ = gw("POST", "/internal/auth/login/status", {"username": user, "flowId": flow})
        check("IdP login/status PIN_AUTHORIZED + timestamp", s == 200 and b.get("status") == "PIN_AUTHORIZED"
              and b.get("timestamp"), (s, b))
        s, b, _, _ = gw("POST", "/internal/auth/login/status", {"username": "teller", "flowId": flow})
        check("login/status: başka kullanıcının flow'u -> 403", s == 403, (s, b))

        # 4) Yeni cihaz (bu çalıştırmaya özel, kayıtsız) -> NEW_DEVICE + OTP
        newdev = fresh_device()
        s, b, _, _ = seal("/seal/mobile/v1/login/begin", {}, token=m1, device=newdev)
        nflow = b.get("flowId", "")
        s, b, _, _ = seal("/seal/mobile/v1/login/pin", {"flowId": nflow, "pin": "1234"}, token=m1, device=newdev)
        check("kayıtsız cihaz -> NEW_DEVICE + demoOtp", b.get("status") == "NEW_DEVICE" and b.get("demoOtp"), (s, b))
        otp = b.get("demoOtp", "")
        s, b, _, _ = gw("POST", "/internal/auth/login/status", {"username": user, "flowId": nflow})
        check("IdP login/status NEW_DEVICE (newDevice=true)", b.get("status") == "NEW_DEVICE" and b.get("newDevice") is True,
              (s, b))
        wrong = "000000" if otp != "000000" else "111111"
        s, b, _, _ = seal("/seal/mobile/v1/device/otp", {"flowId": nflow, "otp": wrong}, token=m1, device=newdev)
        check("yanlış OTP -> 401", s == 401, (s, b))
        s, b, _, _ = seal("/seal/mobile/v1/device/otp", {"flowId": nflow, "otp": otp}, token=m1, device=newdev)
        check("doğru OTP -> OTP_OK, aktivasyon gerekli", s == 200 and b.get("activationRequired") is True, (s, b))

        # 5) OTP sonrası token kısıtlı (scope=activation, restricted=true)
        m2 = idp_token("mobile-app", "com.bank.app:/callback", user, alice_pw, mobile=True)
        intro = introspect_full(m2)
        check("kısıtlı token: restricted=true, scope=activation",
              intro.get("restricted") is True and "activation" in str(intro.get("scope", "")), intro)

        # 5b) Kısıtlı token iş API'sinde reddedilir (ext-authz): HAProxy -> gw-mobile -> ext-authz
        s, b, _, _ = tls_request("127.0.0.1", HAPROXY_PORT, "mobile-api.lab.local", "GET", "/bff/mobile/accounts", None,
                                 {"Authorization": f"Bearer {m2}",
                                  "DPoP": dpop_proof(*MOBILE_KEYS[m2], "GET", "https://mobile-api.lab.local/bff/mobile/accounts",
                                                     access_token=m2)},
                                 client=None, ca=os.path.join(CERTS, "public-ca.crt"))
        check("kısıtlı token iş API'sinde 403 (ext-authz)", s == 403 and "kısıtlı" in str(b), (s, b))

        # 6) Aktivasyon: IdP token üretir, SDK tamamlar, kısıt kalkar
        s, b, _, _ = seal("/seal/mobile/v1/activation/start", {}, token=m2, device=newdev)
        tok = b.get("activationToken", "")
        check("aktivasyon token üretildi (IdP)", s == 200 and bool(tok), (s, b))
        s, b, _, _ = seal("/seal/mobile/v1/device/enroll", {"pin": "1234"}, token=m2, device=newdev)
        check("aktivasyon: yeni cihaz PIN kaydı -> ENROLLED", s == 200, (s, b))
        s, b, _, _ = seal("/seal/mobile/v1/activation/complete", {"activationToken": tok}, token=m2, device=newdev)
        check("aktivasyon tamamlandı -> ACTIVATED", s == 200 and b.get("status") == "ACTIVATED", (s, b))
        m3 = idp_token("mobile-app", "com.bank.app:/callback", user, alice_pw, mobile=True)
        check("aktivasyon sonrası token kısıtsız", introspect_full(m3).get("restricted") is None, introspect_full(m3))

        # 7) PIN_EXPIRED: süresi kısa kayıt
        s, b, _, _ = gw("POST", "/seal-pm/v1/pin/set",
                        {"userId": user, "deviceId": "device-lab-02", "pin": "5555", "validitySeconds": 1}, {"X-Seal-Key": pm_key()})
        time.sleep(2)
        s, b, _, _ = seal("/seal/mobile/v1/login/begin", {}, token=m3, device="device-lab-02")
        eflow = b.get("flowId", "")
        s, b, _, _ = seal("/seal/mobile/v1/login/pin", {"flowId": eflow, "pin": "5555"}, token=m3, device="device-lab-02")
        check("süresi dolmuş PIN -> PIN_EXPIRED", b.get("status") == "PIN_EXPIRED", (s, b))

        # 8) Aktivasyon uçları: IdP token'ı olmadan 401; başka kullanıcı token'ı ile aynı uç çalışmaz
        s, b, _, _ = seal("/seal/mobile/v1/activation/start", {}, token=None)
        check("aktivasyon başlatma: IdP token yok -> 401", s == 401, (s, b))
        check("aktivasyon: sahte token -> 401", seal("/seal/mobile/v1/activation/start", {}, token=forged_token())[0] == 401)

        # 8b) OTP kilidi: yeni cihazda 5 yanlış OTP -> 401; sonra doğru kod bile -> 423 (kilitli)
        lockdev = fresh_device()
        s, b, _, _ = seal("/seal/mobile/v1/login/begin", {}, token=m3, device=lockdev)
        lflow = b.get("flowId", "")
        s, b, _, _ = seal("/seal/mobile/v1/login/pin", {"flowId": lflow, "pin": "1234"}, token=m3, device=lockdev)
        lotp = b.get("demoOtp", "")
        wrong = "000000" if lotp != "000000" else "111111"
        wrongs = [seal("/seal/mobile/v1/device/otp", {"flowId": lflow, "otp": wrong}, token=m3, device=lockdev)[0]
                  for _ in range(5)]
        check("OTP: 5 yanlış deneme -> 401", all(x == 401 for x in wrongs), wrongs)
        s, b, _, _ = seal("/seal/mobile/v1/device/otp", {"flowId": lflow, "otp": lotp}, token=m3, device=lockdev)
        check("OTP kilitli: doğru kod bile -> 423", s == 423, (s, b))

        # 8c) Throttling (teller hesabı; alice'in akışını etkilemez): yeni cihaz talebi ve OTP denemesi sınırlanır
        codes = [gw("POST", "/internal/auth/device/new", {"username": "teller", "flowId": str(uuid.uuid4())})[0]
                 for _ in range(25)]
        check("throttling: yeni cihaz talebi sınırlanır (429)", 429 in codes, codes)
        codes = [gw("POST", "/internal/auth/otp/verify",
                    {"username": "teller", "flowId": str(uuid.uuid4()), "code": "000000"})[0]
                 for _ in range(35)]
        check("throttling: OTP doğrulama denemeleri sınırlanır (429)", 429 in codes, codes[-5:])

        # 9) Web girişi: mobil oturumu düşürür (tek aktif giriş)
        w = idp_token("web-app", "https://web.lab.local:8443/callback", user, alice_pw, web_secret)
        check("web girişi sonrası mobil token pasif", introspect(m3) is False)
        check("web token aktif", introspect(w) is True)

        # 10) TLS negatifleri
        s, b, _, _ = tls_request("127.0.0.1", HAPROXY_PORT, "seal.lab.local", "POST", "/seal/mobile/v1/login/begin",
                                 {}, {"Authorization": f"Bearer {m3}"}, client=None)
        check("seal-mobile: cihaz sertifikası yok -> TLS reddi", s == "TLS", (s, b))
        s, b, _, _ = tls_request("127.0.0.1", GW_PORT, "gw-internal", "POST", "/internal/auth/login/status",
                                 {"username": user, "flowId": flow}, client=None)
        check("gw-internal /internal/auth: DMZ istemci sertifikası yok -> TLS reddi", s == "TLS", (s, b))
        s, b, _, _ = tls_request("127.0.0.1", GW_PORT, "gw-internal", "POST", "/seal-pm/v1/pin/verify",
                                 {}, {"X-Seal-Key": "x"}, client=None)
        check("gw-internal /seal-pm: DMZ istemci sertifikası yok -> TLS reddi", s == "TLS", (s, b))
    finally:
        for p in pfs:
            p.terminate()
            p.wait(timeout=10)
    print(f"\nSonuç: {passed} geçti, {failed} kaldı (toplam {passed + failed})")
    return 0 if failed == 0 else 1


def pm_key():
    out = subprocess.check_output(["kubectl", "--context", "kind-identity", "-n", "seal-pm", "get", "secret",
                                   "pm-key", "-o", "jsonpath={.data.PM_KEY}"])
    return base64.b64decode(out).decode()


if __name__ == "__main__":
    sys.exit(main())
