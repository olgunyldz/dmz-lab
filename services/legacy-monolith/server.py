# Fortuna monolith mock (lab): eski (Windows) Fortuna'nın davranışını taklit eder. Gerçek Fortuna değildir.
# Seal entegrasyonu: Fortuna, Seal Intranet'ten getLoginStatus / createTimestamp / updateDevice /
# createActivationToken / getActivationStatus çağrılarını yapar (seal-b2b token'ı auth-server'dan alınır).
# Müşteri ve hesap verisi LegacyDB (PostgreSQL, ibdb_fortuna: customers, accounts) üzerindedir; psycopg kullanır.
import base64
import hashlib
import hmac
import http.client
import psycopg
from decimal import Decimal
import secrets
import json
import os
import ssl
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import re
os.environ.setdefault("SERVICE_NAME", "fortuna-mock")
import tracing  # compose'da shared/tracing.py -> /app/tracing.py

PORT = int(os.environ.get("PORT", "8080"))
SYSTEM = os.environ.get("LEGACY_SYSTEM", "fortuna")
CA = os.environ.get("CA_FILE", "/certs/internal-ca.crt")
SI_HOST = os.environ.get("SI_HOST", "seal-intranet.lab.local")
SI_PORT = int(os.environ.get("SI_PORT", "30456"))
AUTH_HOST = os.environ.get("AUTH_HOST", "id.bank.lab.local")
AUTH_PORT = int(os.environ.get("AUTH_PORT", "30543"))
B2B_SECRET = os.environ.get("SEAL_B2B_SECRET", "")
DB_DSN = os.environ.get("DB_DSN", "")


class _Traced:
    """psycopg bağlantısını sarar: her execute() bir db span'i olur (SQL değerleri yazılmaz)."""

    def __init__(self, conn):
        self._c = conn

    def __enter__(self):
        self._c.__enter__()
        return self

    def __exit__(self, *exc):
        return self._c.__exit__(*exc)

    def execute(self, sql, *args, **kwargs):
        s = " ".join(sql.split())
        op = s.split(" ", 1)[0].upper()
        m = re.search(r"\b(?:FROM|INTO|UPDATE|TABLE|JOIN)\s+([a-zA-Z_]+)", s, re.I)
        with tracing.db_span(op, m.group(1).lower() if m else None):
            return self._c.execute(sql, *args, **kwargs)


def db():
    return _Traced(psycopg.connect(DB_DSN, autocommit=True))


def customer_owner(customer_id):
    # Müşteri numarası -> Seal kullanıcı kimliği (owner); pasif müşteri None
    with db() as c:
        row = c.execute("SELECT seal_owner_id, status FROM customers WHERE customer_id = %s", (customer_id,)).fetchone()
    return row[0] if row and row[1] == "ACTIVE" else None


def customer_name(customer_id):
    # Müşteri numarası -> ad soyad (customers.full_name); bulunamazsa None
    with db() as c:
        row = c.execute("SELECT full_name FROM customers WHERE customer_id = %s", (customer_id,)).fetchone()
    return row[0] if row else None


def device_status(customer_id, device_id):
    # Cihaz durumunun TEK KAYNAĞI Seal Intranet (device-api/get-device). LegacyDB'de cihaz durumu tutulmaz.
    st, d = si_call("device-api/get-device", {"deviceId": device_id})
    if st == 404:
        return None
    if st != 200:
        raise RuntimeError(f"Seal cihaz durumu okunamadı (HTTP {st})")
    if d.get("ownerId") != customer_owner(customer_id):
        return None
    return d.get("status")


def device_set(customer_id, device_id, status, reason):
    # Durum Seal'e yazılır; LegacyDB yalnızca denetim kaydı tutar (device_events)
    owner = customer_owner(customer_id)
    if not owner:
        raise RuntimeError("müşteri bulunamadı veya pasif")
    prev = device_status(customer_id, device_id)
    st, _ = si_call("device-api/update-device", {"ownerId": owner, "deviceId": device_id, "status": status})
    if st != 200:
        raise RuntimeError(f"Seal cihaz durumu yazılamadı (HTTP {st})")
    with db() as c:
        c.execute("INSERT INTO device_events (customer_id, device_id, from_status, to_status, reason) "
                  "VALUES (%s, %s, %s, %s, %s)", (customer_id, device_id, prev, status, reason))


def customer_accounts(customer_id):
    with db() as c:
        rows = c.execute("SELECT account_no, account_type, balance, currency FROM accounts WHERE customer_id = %s",
                         (customer_id,)).fetchall()
    return [{"id": r[0], "type": r[1], "balance": str(r[2]), "currency": r[3]} for r in rows]


# ---- Bankacılık işlemleri (lab): hesap hareketleri ve havale. Tek transaction, satır kilidi ile. ----
TRANSFER_LIMIT = 50000  # TRY, tek işlem üst sınırı (lab)

# ---- Müşteri oluşturma (Janus üzerinden, lab): müşteri + hesaplar + açılış hareketi tek transaction ----
CUSTOMER_ID_RE = re.compile(r"^C\d{9}$")
ACCOUNT_TYPES = ("vadesiz", "birikim")


def customer_create(req):
    cid = str(req.get("customerId", ""))
    name = str(req.get("fullName", "")).strip()
    accts = req.get("accounts") or []
    if not CUSTOMER_ID_RE.match(cid):
        return 400, {"error": "müşteri no geçersiz"}
    if not (3 <= len(name) <= 60):
        return 400, {"error": "ad geçersiz"}
    if not isinstance(accts, list) or not (1 <= len(accts) <= 3):
        return 400, {"error": "hesap listesi geçersiz"}
    rows = []
    for a in accts:
        t = str(a.get("type", ""))
        if t not in ACCOUNT_TYPES:
            return 400, {"error": "hesap türü geçersiz"}
        try:
            bal = Decimal(str(a.get("balance"))).quantize(Decimal("0.01"))
        except Exception:
            return 400, {"error": "bakiye geçersiz"}
        if bal < 0 or bal > Decimal("1000000000"):
            return 400, {"error": "bakiye aralık dışı"}
        rows.append((t, bal))
    out = []
    with psycopg.connect(DB_DSN) as conn:  # tek transaction: hata olursa hiçbir satır kalmaz
        if conn.execute("SELECT 1 FROM customers WHERE customer_id = %s", (cid,)).fetchone():
            return 409, {"error": "müşteri zaten var"}
        conn.execute("INSERT INTO customers (customer_id, seal_owner_id, full_name, status) "
                     "VALUES (%s, %s, %s, 'ACTIVE')", (cid, cid.lower(), name))
        for t, bal in rows:
            no = None
            for _ in range(10):
                cand = "TR" + f"{secrets.randbelow(10 ** 12):012d}"
                if not conn.execute("SELECT 1 FROM accounts WHERE account_no = %s", (cand,)).fetchone():
                    no = cand
                    break
            if no is None:
                raise RuntimeError("hesap numarası üretilemedi")
            conn.execute("INSERT INTO accounts (account_no, customer_id, account_type, balance, currency) "
                         "VALUES (%s, %s, %s, %s, 'TRY')", (no, cid, t, bal))
            conn.execute("INSERT INTO transactions (account_no, direction, counterpart, amount, balance_after, description) "
                         "VALUES (%s, 'CREDIT', 'AÇILIŞ', %s, %s, 'Hesap açılış bakiyesi')", (no, bal, bal))
            out.append({"id": no, "type": t, "balance": str(bal), "currency": "TRY"})
    return 201, {"customerId": cid, "fullName": name, "accounts": out}


def customer_delete(req):
    # Yalnız bu akışla oluşturulmuş müşteriler (seal_owner_id = küçük harf müşteri no) silinir; seed verisi korunur.
    cid = str(req.get("customerId", ""))
    if not CUSTOMER_ID_RE.match(cid):
        return 400, {"error": "müşteri no geçersiz"}
    with psycopg.connect(DB_DSN) as conn:
        ok = conn.execute("SELECT 1 FROM customers WHERE customer_id = %s AND seal_owner_id = %s",
                          (cid, cid.lower())).fetchone()
        if not ok:
            return 404, {"error": "silinecek müşteri bulunamadı"}
        conn.execute("DELETE FROM transactions WHERE account_no IN (SELECT account_no FROM accounts WHERE customer_id = %s)", (cid,))
        conn.execute("DELETE FROM accounts WHERE customer_id = %s", (cid,))
        conn.execute("DELETE FROM customers WHERE customer_id = %s", (cid,))
    return 200, {"deleted": cid}


class TxError(Exception):
    def __init__(self, code, msg):
        super().__init__(msg)
        self.code = code
        self.msg = msg


def _amount(v):
    from decimal import Decimal, InvalidOperation
    try:
        a = Decimal(str(v)).quantize(Decimal("0.01"))
    except (InvalidOperation, ValueError):
        raise TxError(400, "tutar geçersiz")
    if a <= 0:
        raise TxError(400, "tutar sıfırdan büyük olmalı")
    if a > TRANSFER_LIMIT:
        raise TxError(400, f"tek işlem üst sınırı {TRANSFER_LIMIT} TRY")
    return a


def account_history(customer, account, limit):
    with db() as c:
        if not c.execute("SELECT 1 FROM accounts WHERE account_no = %s AND customer_id = %s",
                         (account, customer)).fetchone():
            raise TxError(404, "hesap bulunamadı")
        rows = c.execute("SELECT id, direction, counterpart, amount, balance_after, description, at "
                         "FROM transactions WHERE account_no = %s ORDER BY id DESC LIMIT %s",
                         (account, limit)).fetchall()
    return [{"ref": str(r[0]), "direction": r[1], "counterpart": r[2], "amount": str(r[3]),
             "balanceAfter": str(r[4]), "description": r[5], "at": r[6].isoformat()} for r in rows]


def transfer(customer, src, dst, amount_raw, desc):
    amount = _amount(amount_raw)
    if src == dst:
        raise TxError(400, "kaynak ve alıcı hesap aynı olamaz")
    desc = (desc or "Havale").strip()[:140] or "Havale"
    with _Traced(psycopg.connect(DB_DSN)) as conn:  # bağlam çıkışında commit; hata olursa tamamı geri alınır
        s = conn.execute("SELECT customer_id, balance, currency FROM accounts WHERE account_no = %s FOR UPDATE",
                         (src,)).fetchone()
        if not s or s[0] != customer:
            raise TxError(404, "kaynak hesap bulunamadı")
        if s[2] != "TRY":
            raise TxError(400, "yalnız TRY hesaplar")
        if s[1] < amount:
            raise TxError(422, "yetersiz bakiye")
        d = conn.execute("SELECT balance FROM accounts WHERE account_no = %s FOR UPDATE", (dst,)).fetchone()
        new_src = s[1] - amount
        conn.execute("UPDATE accounts SET balance = %s WHERE account_no = %s", (new_src, src))
        ref = conn.execute("INSERT INTO transactions (account_no, direction, counterpart, amount, balance_after, "
                           "description) VALUES (%s, 'DEBIT', %s, %s, %s, %s) RETURNING id",
                           (src, dst, amount, new_src, desc)).fetchone()[0]
        if d:  # bankadaki hesap: alıcıya da yaz; değilse dış hesap (yalnız borç kaydı)
            new_dst = d[0] + amount
            conn.execute("UPDATE accounts SET balance = %s WHERE account_no = %s", (new_dst, dst))
            conn.execute("INSERT INTO transactions (account_no, direction, counterpart, amount, balance_after, "
                         "description) VALUES (%s, 'CREDIT', %s, %s, %s, %s)",
                         (dst, src, amount, new_dst, desc))
    return {"status": "OK", "reference": str(ref), "amount": str(amount), "toAccount": dst,
            "internal": bool(d), "balanceAfter": str(new_src)}

_TOKEN = {"value": "", "exp": 0.0}
_TLOCK = threading.Lock()


def _https(host, port, sni, method, path, headers, body=None):
    peer = "seal-intranet" if host == SI_HOST else "auth"
    with tracing.client_span(f"fortuna-mock->{peer} {method} {path.split('?')[0]}", peer=peer) as sp:
        ctx = ssl.create_default_context(cafile=CA)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2
        conn = http.client.HTTPSConnection(host, port, timeout=10, context=ctx)
        conn.request(method, path, body=body, headers=tracing.inject({"Host": sni, **headers}))
        resp = conn.getresponse()
        data = resp.read()
        conn.close()
        if sp is not None:
            sp.set("http.status_code", resp.status)
        try:
            return resp.status, json.loads(data or b"{}")
        except ValueError:
            return resp.status, {"raw": data[:200].decode("utf-8", "replace")}


def b2b_token():
    # seal-b2b istemcisi (client_credentials); süresi dolana kadar önbellekte
    with _TLOCK:
        if _TOKEN["value"] and _TOKEN["exp"] > time.time() + 30:
            return _TOKEN["value"]
        basic = base64.b64encode(f"seal-b2b:{B2B_SECRET}".encode()).decode()
        st, d = _https(AUTH_HOST, AUTH_PORT, AUTH_HOST, "POST", "/realms/bank/protocol/openid-connect/token",
                       {"Authorization": "Basic " + basic, "Content-Type": "application/x-www-form-urlencoded"},
                       b"grant_type=client_credentials")
        if st != 200 or "access_token" not in d:
            raise RuntimeError(f"seal-b2b token alınamadı (HTTP {st})")
        _TOKEN.update(value=d["access_token"], exp=time.time() + int(d.get("expires_in", 60)))
        return _TOKEN["value"]


def si_call(op, body):
    # Seal Intranet v3 integration uçları (seal-b2b bearer ile)
    return _https(SI_HOST, SI_PORT, SI_HOST, "POST", f"/seal-v3/server/integration/{op}",
                  {"Authorization": "Bearer " + b2b_token(), "Content-Type": "application/json"},
                  json.dumps(body).encode())


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


# mTLS (lab): TLS_CERT/TLS_KEY/TLS_CA verilirse HTTPS. POST uçları istemci sertifikası CN'i ALLOWED_CLIENTS içinde olmalı.
TLS_CERT = os.environ.get("TLS_CERT", "")
TLS_KEY = os.environ.get("TLS_KEY", "")
TLS_CA = os.environ.get("TLS_CA", "")
TLS_ON = bool(TLS_CERT and TLS_KEY and TLS_CA)
ALLOWED_CLIENTS = set(filter(None, os.environ.get("ALLOWED_CLIENTS", "janus-web,janus-mobile,channel-gateway,seal-mobile").split(",")))


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


def tls_wrap(httpd):
    import ssl
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(TLS_CERT, TLS_KEY)
    ctx.load_verify_locations(TLS_CA)
    ctx.verify_mode = ssl.CERT_OPTIONAL  # sağlık uçları sertifikasız; POST'ta uygulama katmanı zorunlu kılar
    httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)


# PIN doğrulayıcıları (eski Password Manager, Fortuna'nın parçası). Yalnız seal-mobile çağırır (CN + X-Seal-Key).
# Kapsam: kullanıcı parolası burada YOK (Fortuna'da, fortuna_users). Düz PIN saklanmaz: scrypt doğrulayıcı.
# Doğrulayıcılar LegacyDB'de (pin_verifiers); yeniden başlatmada kalır.
PM_KEY = os.environ.get("PM_KEY", "")
PM_MAX_FAILS = 5
PM_VALIDITY = int(os.environ.get("PM_VALIDITY_SECONDS", str(90 * 24 * 3600)))
PM_LOCK = threading.Lock()


def _pm_derive(pin, salt):
    return hashlib.scrypt(pin.encode(), salt=salt, n=2 ** 14, r=8, p=1, dklen=32)


def pm_handle(sent_key, path, req):
    if not PM_KEY or not hmac.compare_digest(sent_key.encode(), PM_KEY.encode()):
        return 401, {"error": "anahtar geçersiz"}
    if path not in ("/seal-pm/v1/pin/set", "/seal-pm/v1/pin/verify"):
        return 404, {"error": "bulunamadı"}
    user, dev, pin = str(req.get("userId", "")), str(req.get("deviceId", "")), str(req.get("pin", ""))
    if not user or not dev or not pin:
        return 400, {"error": "userId, deviceId ve pin gerekli"}
    key = (user, dev)
    with PM_LOCK, db() as c:
        if path == "/seal-pm/v1/pin/set":
            salt = secrets.token_bytes(16)
            validity = int(req.get("validitySeconds") or PM_VALIDITY)
            c.execute("INSERT INTO pin_verifiers (user_id, device_id, salt, hash, fails, expires) "
                      "VALUES (%s, %s, %s, %s, 0, %s) "
                      "ON CONFLICT (user_id, device_id) DO UPDATE SET salt = EXCLUDED.salt, hash = EXCLUDED.hash, "
                      "fails = 0, expires = EXCLUDED.expires",
                      (user, dev, salt, _pm_derive(pin, salt), time.time() + validity))
            return 200, {"status": "ok"}
        row = c.execute("SELECT salt, hash, fails, expires FROM pin_verifiers WHERE user_id = %s AND device_id = %s",
                        (user, dev)).fetchone()
        if not row:
            return 200, {"ok": False, "locked": False, "enrolled": False, "expired": False}
        salt, stored, fails, expires = bytes(row[0]), bytes(row[1]), int(row[2]), float(row[3])
        if fails >= PM_MAX_FAILS:
            return 200, {"ok": False, "locked": True, "enrolled": True, "expired": False}
        if time.time() > expires:
            return 200, {"ok": False, "locked": False, "enrolled": True, "expired": True}
        good = hmac.compare_digest(_pm_derive(pin, salt), stored)
        fails = 0 if good else fails + 1
        c.execute("UPDATE pin_verifiers SET fails = %s WHERE user_id = %s AND device_id = %s", (fails, user, dev))
        return 200, {"ok": good, "locked": fails >= PM_MAX_FAILS, "enrolled": True, "expired": False}


class Handler(BaseHTTPRequestHandler):
    server_version = "fortuna-mock"

    def _json(self, code, obj):
        _count(self.command, self.path, code)
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _body(self):
        n = int(self.headers.get("Content-Length", "0") or 0)
        try:
            return json.loads(self.rfile.read(n) or b"{}")
        except ValueError:
            return None

    def do_GET(self):
        if self.path.split('?')[0] == '/metrics':
            return _send_metrics(self, "fortuna-mock")
        url = urlparse(self.path)
        if url.path == "/fortuna/health":
            return self._json(200, {"status": "ok", "system": SYSTEM})
        if url.path == "/fortuna/accounts":
            customer = parse_qs(url.query).get("customer", [""])[0]
            if not customer_owner(customer):
                return self._json(404, {"error": "müşteri bulunamadı"})
            return self._json(200, {"customer": customer, "accounts": customer_accounts(customer)})
        if url.path == "/fortuna/history":
            if TLS_ON and peer_cn(self.connection) not in ALLOWED_CLIENTS:
                return self._json(401, {"error": "istemci sertifikası yok veya yetkisiz"})
            q = parse_qs(url.query)
            try:
                limit = min(max(int(q.get("limit", ["20"])[0]), 1), 50)
                rows = account_history(q.get("customer", [""])[0], q.get("account", [""])[0], limit)
            except ValueError:
                return self._json(400, {"error": "limit geçersiz"})
            except TxError as e:
                return self._json(e.code, {"error": e.msg})
            return self._json(200, {"transactions": rows})
        return self._json(404, {"error": "bilinmeyen uç nokta"})

    def do_POST(self):
        if TLS_ON and peer_cn(self.connection) not in ALLOWED_CLIENTS:
            return self._json(401, {"error": "istemci sertifikası yok veya yetkisiz"})
        path = urlparse(self.path).path
        req = self._body()
        if req is None:
            return self._json(400, {"error": "geçersiz JSON"})
        if path == "/fortuna/customer/profile":
            cid = str(req.get("customerId", ""))
            name = customer_name(cid) if CUSTOMER_ID_RE.match(cid) else None
            if not name:
                return self._json(404, {"error": "müşteri bulunamadı"})
            return self._json(200, {"customerId": cid, "fullName": name})
        if path == "/fortuna/customer/create":
            code, out = customer_create(req)
            return self._json(code, out)
        if path == "/fortuna/customer/delete":
            code, out = customer_delete(req)
            return self._json(code, out)
        if path.startswith("/seal-pm/"):
            code, out = pm_handle(self.headers.get("X-Seal-Key", ""), path, req)
            return self._json(code, out)
        try:
            if path == "/fortuna/transfer":
                try:
                    out = transfer(str(req.get("customer", "")), str(req.get("fromAccount", "")),
                                   str(req.get("toAccount", "")), req.get("amount"), str(req.get("description", "")))
                except TxError as e:
                    return self._json(e.code, {"error": e.msg})
                return self._json(200, out)
            if path == "/fortuna/device/status":
                return self._json(200, {"status": device_status(req.get("customerId", ""), req.get("deviceId", ""))})
            if path == "/fortuna/device/set":
                # Kilit / iptal / aktif yapma (destek veya kural motoru); denetim kaydı yazılır
                if req.get("status") not in ("PENDING", "ACTIVE", "LOCKED", "REVOKED"):
                    return self._json(400, {"error": "geçersiz durum"})
                device_set(req.get("customerId", ""), req.get("deviceId", ""), req["status"],
                           str(req.get("reason", "manuel")))
                return self._json(200, {"status": req["status"]})
            if path == "/fortuna/secure-login":
                # Janus SecureServerLoginUser: Seal'de PIN/cihaz yetkisi var mı?
                st, d = si_call("login-api/get-login-status", {"flowId": req.get("flowId", "")})
                if st != 200:
                    return self._json(409, {"error": "akış yok"})
                ok = d.get("status") in ("PIN_AUTHORIZED", "SEAL_AUTHORIZED")
                return self._json(200 if ok else 409, {"status": d.get("status"), "newDevice": d.get("newDevice")})
            if path == "/fortuna/mobile-login":
                # Janus MobileUserLogin: aktif müşteri (SEAL_AUTHORIZED) + zaman damgası + cihaz güncelleme
                owner = customer_owner(req.get("customerId", ""))
                if not owner:
                    return self._json(404, {"error": "müşteri bulunamadı"})
                dst = device_status(req["customerId"], str(req.get("deviceId", "")))
                if dst != "ACTIVE":
                    return self._json(403, {"error": "cihaz aktif değil", "deviceStatus": dst})
                st, d = si_call("login-api/get-login-status", {"flowId": req.get("flowId", "")})
                if st != 200 or d.get("status") != "SEAL_AUTHORIZED":
                    return self._json(409, {"error": "Seal yetkisi yok", "status": d.get("status")})
                _, ts = si_call("timestamp-api/create-timestamp", {"flowId": req.get("flowId", "")})
                st2, _ = si_call("device-api/update-device", {"flowId": req.get("flowId", ""), "ownerId": owner,
                                                              "deviceId": str(req.get("deviceId", ""))})
                if st2 != 200:
                    return self._json(502, {"error": "cihaz güncellenemedi"})
                return self._json(200, {"customerId": req["customerId"], "ownerId": owner,
                                        "fullName": customer_name(req["customerId"]),
                                        "timestamp": ts.get("timestamp")})
            if path == "/fortuna/activation/token":
                owner = customer_owner(req.get("customerId", ""))
                if not owner:
                    return self._json(404, {"error": "müşteri bulunamadı"})
                st, d = si_call("activation-api/create-activation-token",
                                {"ownerId": owner, "userIdentifiers": {"customerId": req["customerId"]},
                                 "pinRequestType": "NEW"})
                if st != 200:
                    return self._json(502, {"error": "aktivasyon token üretilemedi"})
                if req.get("deviceId"):
                    device_set(req["customerId"], str(req["deviceId"]), "PENDING", "aktivasyon token üretildi")
                return self._json(200, {"activationToken": d.get("activationToken")})
            if path == "/fortuna/activation/status":
                st, d = si_call("activation-api/get-activation-status",
                                {"activationToken": req.get("activationToken", "")})
                if st != 200:
                    return self._json(404, {"error": "token bulunamadı"})
                if d.get("status") == "ACTIVATED" and req.get("customerId") and req.get("deviceId"):
                    device_set(req["customerId"], str(req["deviceId"]), "ACTIVE", "aktivasyon tamamlandı")
                return self._json(200, {"status": d.get("status")})
        except (OSError, RuntimeError, ssl.SSLError, http.client.HTTPException) as e:
            return self._json(502, {"error": f"Seal/auth-server erişilemedi: {type(e).__name__}"})
        return self._json(404, {"error": "bilinmeyen uç nokta"})

    def log_message(self, fmt, *args):
        print(fmt % args, flush=True)


if __name__ == "__main__":
    with db() as c:
        c.execute("CREATE TABLE IF NOT EXISTS pin_verifiers (user_id TEXT NOT NULL, device_id TEXT NOT NULL, "
                  "salt BYTEA NOT NULL, hash BYTEA NOT NULL, fails INT NOT NULL DEFAULT 0, "
                  "expires DOUBLE PRECISION NOT NULL, PRIMARY KEY (user_id, device_id))")
        # Hesap hareketleri: her hareket bir satır; açılış bakiyesi yoksa (ilk kurulum) bir açılış kaydı eklenir
        c.execute("CREATE TABLE IF NOT EXISTS transactions (id BIGSERIAL PRIMARY KEY, account_no TEXT NOT NULL "
                  "REFERENCES accounts(account_no), direction TEXT NOT NULL, counterpart TEXT NOT NULL, "
                  "amount NUMERIC(16,2) NOT NULL, balance_after NUMERIC(16,2) NOT NULL, "
                  "description TEXT NOT NULL, at TIMESTAMPTZ NOT NULL DEFAULT now())")
        c.execute("INSERT INTO transactions (account_no, direction, counterpart, amount, balance_after, description) "
                  "SELECT a.account_no, 'CREDIT', 'AÇILIŞ', a.balance, a.balance, 'Hesap açılış bakiyesi' FROM accounts a "
                  "WHERE NOT EXISTS (SELECT 1 FROM transactions t WHERE t.account_no = a.account_no)")
    print(f"{SYSTEM} mock dinliyor (port {PORT})", flush=True)
    tracing.instrument(Handler)
    httpd = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    if TLS_ON:
        tls_wrap(httpd)
    print(f"mTLS={'evet' if TLS_ON else 'hayır'}", flush=True)
    httpd.serve_forever()
