"""Dağıtık izleme (W3C traceparent + OTLP/HTTP JSON). Yalnız standart kütüphane; pip bağımlılığı yok.

Kullanım:
  span = start_server_span("bff GET /bff/web/accounts", request.headers.get("traceparent"), {"channel": "web"})
  child = start_client_span("bff->core GET /api/v1/accounts", span, {"peer.service": "core"})
  headers["traceparent"] = child.header()        # alt çağrıya taşı
  child.end(http_status=200); span.end(http_status=200)

Ortam değişkenleri:
  OTLP_ENDPOINT  örn. http://172.18.0.12:30318  (boşsa dışa aktarım kapalı; span üretimi yine çalışır)
  SERVICE_NAME   servis adı (Jaeger'da görünür)

Güvenlik: span özniteliklerine token, parola veya Authorization değeri YAZILMAZ. Kullanıcı yalnız hash'lenmiş
kimlik olarak eklenir (user.hash). Bu, lab sınırıdır; prod'da örnekleme ve veri sınıflandırma politikası gerekir.
"""
import hashlib
import json
import os
import queue
import secrets
import sys
import threading
import time
import urllib.error
import urllib.request

OTLP_ENDPOINT = os.environ.get("OTLP_ENDPOINT", "").rstrip("/")
SERVICE = os.environ.get("SERVICE_NAME", "unknown")
_queue = queue.Queue(maxsize=10000)
_warned = False

KIND_SERVER, KIND_CLIENT = 2, 3


def parse_traceparent(value):
    """W3C traceparent: 00-<32 hex trace>-<16 hex parent>-<2 hex flags>. Geçersizse None."""
    if not value:
        return None
    parts = value.strip().split("-")
    if len(parts) != 4 or parts[0] != "00":
        return None
    trace_id, span_id = parts[1], parts[2]
    if len(trace_id) != 32 or len(span_id) != 16 or trace_id == "0" * 32 or span_id == "0" * 16:
        return None
    try:
        int(trace_id, 16)
        int(span_id, 16)
    except ValueError:
        return None
    return trace_id, span_id


def user_hash(sub):
    return hashlib.sha256(str(sub).encode()).hexdigest()[:12] if sub else None


class Span:
    def __init__(self, name, kind, trace_id, parent_id, attrs=None):
        self.name = name
        self.kind = kind
        self.trace_id = trace_id
        self.parent_id = parent_id
        self.span_id = secrets.token_hex(8)
        self.start_ns = time.time_ns()
        self.end_ns = None
        self.attrs = {"service.name": SERVICE}
        for k, v in (attrs or {}).items():
            if v is not None:
                self.attrs[k] = str(v)
        self.status = 1  # OTel: 1 = OK, 2 = ERROR

    def set(self, key, value):
        if value is not None:
            self.attrs[key] = str(value)

    def header(self):
        """Alt çağrıya giden traceparent (bu span kimliğiyle)."""
        return f"00-{self.trace_id}-{self.span_id}-01"

    def end(self, http_status=None):
        if self.end_ns is not None:
            return
        if http_status is not None:
            self.set("http.status_code", http_status)
            if int(http_status) >= 500:
                self.status = 2
        self.end_ns = time.time_ns()
        _enqueue(self)


def start_server_span(name, traceparent, attrs=None):
    """Gelen istek için kök ya da alt span. traceparent yoksa yeni iz başlatılır."""
    ids = parse_traceparent(traceparent)
    if ids:
        trace_id, parent_id = ids
    else:
        trace_id, parent_id = secrets.token_hex(16), None
    return Span(name, KIND_SERVER, trace_id, parent_id, attrs)


def start_client_span(name, parent, attrs=None):
    """Giden çağrı için istemci span'i; parent bir Span ya da (trace_id, span_id) çifti olabilir."""
    if isinstance(parent, Span):
        return Span(name, KIND_CLIENT, parent.trace_id, parent.span_id, attrs)
    trace_id, span_id = parent
    return Span(name, KIND_CLIENT, trace_id, span_id, attrs)


def _enqueue(span):
    if not OTLP_ENDPOINT:
        return
    try:
        _queue.put_nowait(span)
    except queue.Full:
        pass  # lab: yoğun yükte iz düşürülür, istek etkilenmez


def _otlp_payload(spans):
    out = []
    for s in spans:
        rec = {
            "traceId": s.trace_id,
            "spanId": s.span_id,
            "name": s.name,
            "kind": s.kind,
            "startTimeUnixNano": str(s.start_ns),
            "endTimeUnixNano": str(s.end_ns),
            "attributes": [{"key": k, "value": {"stringValue": v}} for k, v in s.attrs.items()],
            "status": {"code": s.status},
        }
        if s.parent_id:
            rec["parentSpanId"] = s.parent_id
        out.append(rec)
    return {"resourceSpans": [{
        "resource": {"attributes": [{"key": "service.name", "value": {"stringValue": SERVICE}}]},
        "scopeSpans": [{"scope": {"name": "dmz-lab"}, "spans": out}],
    }]}


def _send(spans):
    global _warned
    body = json.dumps(_otlp_payload(spans)).encode()
    req = urllib.request.Request(OTLP_ENDPOINT + "/v1/traces", data=body, method="POST",
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=3):
            pass
    except (urllib.error.URLError, OSError) as e:
        if not _warned:
            _warned = True
            print(f"tracing: dışa aktarım başarısız ({e}); izler düşürülüyor", file=sys.stderr, flush=True)


def _worker():
    while True:
        batch = [_queue.get()]
        deadline = time.time() + 1.0
        while len(batch) < 100 and time.time() < deadline:
            try:
                batch.append(_queue.get(timeout=max(0.0, deadline - time.time())))
            except queue.Empty:
                break
        _send(batch)


if OTLP_ENDPOINT:
    threading.Thread(target=_worker, daemon=True, name="otlp-export").start()


# ---- Aktif span bağlamı ve otomatik yayılım (iç çağrılar tek izde birleşir) ----
# instrument(Handler): gelen GET/POST için sunucu span'i açar ve aktif yapar.
# client_span(...): giden çağrı için alt span; inject(headers) aktif span'in traceparent'ını ekler.
# db_span(...): veritabanı sorgusu için istemci span'i (SQL değerleri yazılmaz, yalnız işlem adı).
import contextlib as _contextlib

_tls = threading.local()


def current():
    stack = getattr(_tls, "stack", None)
    return stack[-1] if stack else None


def _push(span):
    if not hasattr(_tls, "stack"):
        _tls.stack = []
    _tls.stack.append(span)


def _pop():
    _tls.stack.pop()


def inject(headers=None):
    """Aktif span varsa giden isteğe traceparent ekler. Aktif span yoksa headers değişmeden döner."""
    headers = {} if headers is None else headers
    cur = current()
    if cur is not None:
        headers["traceparent"] = cur.header()
    return headers


@_contextlib.contextmanager
def client_span(name, peer=None, attrs=None):
    """İstemci çağrısı için alt span. Aktif bir iz yoksa no-op."""
    parent = current()
    if parent is None:
        yield None
        return
    sp = Span(name, KIND_CLIENT, parent.trace_id, parent.span_id, {"peer.service": peer, **(attrs or {})})
    _push(sp)
    try:
        yield sp
    except Exception:
        sp.status = 2
        raise
    finally:
        _pop()
        sp.end()


def db_span(operation, table=None, peer="postgresql"):
    """Veritabanı sorgusu span'i. SQL değerleri yazılmaz; yalnız işlem ve tablo."""
    return client_span(f"db {operation} {table or ''}".strip(), peer=peer,
                       attrs={"db.system": "postgresql", "db.operation": operation, "db.sql.table": table})


_SKIP_SUFFIX = ("health", "/metrics")


def instrument(handler_cls):
    """BaseHTTPRequestHandler sınıfını izler. Durum kodu send_response'tan alınır."""
    orig_send = handler_cls.send_response

    def send_response(self, code, message=None):
        self._trace_status = code
        return orig_send(self, code, message)

    handler_cls.send_response = send_response

    def wrap(method, orig):
        def inner(self, *args, **kwargs):
            path = self.path.split("?")[0]
            if path.endswith(_SKIP_SUFFIX):
                return orig(self, *args, **kwargs)
            span = start_server_span(f"{SERVICE} {method} {path}", self.headers.get("traceparent"),
                                     {"http.method": method, "http.target": path})
            self._trace_status = None
            _push(span)
            try:
                return orig(self, *args, **kwargs)
            except Exception:
                span.status = 2
                raise
            finally:
                _pop()
                span.end(http_status=getattr(self, "_trace_status", None))
        return inner

    for m in ("GET", "POST", "PUT", "DELETE"):
        name = "do_" + m
        if hasattr(handler_cls, name):
            setattr(handler_cls, name, wrap(m, getattr(handler_cls, name)))
    return handler_cls
