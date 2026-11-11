"""Prometheus metrikleri (stdlib, metin formatı 0.0.4). Pip bağımlılığı yok.

Kullanım:
  REQS = Counter("app_requests_total", "İstek sayısı", ["route", "status"])
  LAT = Histogram("app_request_duration_seconds", "İstek süresi", ["route"])
  REQS.inc(route="/bff/{id}", status="200")
  with LAT.time(route="/bff/{id}"): ...
  start_metrics_server(9100)   # ayrı porttan /metrics (API portundan bağımsız)

Etiket kuralı (kardinalite): yalnızca düşük kardinaliteli değerler (route şablonu, kanal, durum kodu, kararlar).
Kullanıcı kimliği, hesap no, transfer kimliği gibi değerler ETİKET OLAMAZ.
"""
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

_REGISTRY = []
_LOCK = threading.Lock()


def _escape(v):
    return str(v).replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')


def _labels(names, values):
    if not names:
        return ""
    return "{" + ",".join(f'{n}="{_escape(v)}"' for n, v in zip(names, values)) + "}"


class Counter:
    def __init__(self, name, help_text, labels=()):
        self.name, self.help, self.label_names = name, help_text, tuple(labels)
        self._values = {}
        _REGISTRY.append(self)

    def inc(self, amount=1, **labels):
        key = tuple(str(labels.get(n, "")) for n in self.label_names)
        with _LOCK:
            self._values[key] = self._values.get(key, 0) + amount

    def render(self):
        lines = [f"# HELP {self.name} {self.help}", f"# TYPE {self.name} counter"]
        with _LOCK:
            for key, v in sorted(self._values.items()):
                lines.append(f"{self.name}{_labels(self.label_names, key)} {v}")
        return lines


class Histogram:
    BUCKETS = (0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0)

    def __init__(self, name, help_text, labels=()):
        self.name, self.help, self.label_names = name, help_text, tuple(labels)
        self._data = {}  # key -> {"buckets": [...], "sum": x, "count": n}
        _REGISTRY.append(self)

    def observe(self, value, **labels):
        key = tuple(str(labels.get(n, "")) for n in self.label_names)
        with _LOCK:
            d = self._data.setdefault(key, {"buckets": [0] * len(self.BUCKETS), "sum": 0.0, "count": 0})
            for i, b in enumerate(self.BUCKETS):
                if value <= b:
                    d["buckets"][i] += 1
            d["sum"] += value
            d["count"] += 1

    def time(self, **labels):
        hist, start = self, None

        class _Timer:
            def __enter__(self_inner):
                self_inner.t0 = time.perf_counter()
                return self_inner

            def __exit__(self_inner, *exc):
                hist.observe(time.perf_counter() - self_inner.t0, **labels)
                return False
        return _Timer()

    def render(self):
        lines = [f"# HELP {self.name} {self.help}", f"# TYPE {self.name} histogram"]
        with _LOCK:
            for key, d in sorted(self._data.items()):
                base = list(zip(self.label_names, key))
                for i, b in enumerate(self.BUCKETS):
                    lbl = base + [("le", str(b))]
                    lines.append(f"{self.name}_bucket{_labels([n for n, _ in lbl], [v for _, v in lbl])} {d['buckets'][i]}")
                lbl = base + [("le", "+Inf")]
                lines.append(f"{self.name}_bucket{_labels([n for n, _ in lbl], [v for _, v in lbl])} {d['count']}")
                lines.append(f"{self.name}_sum{_labels(self.label_names, key)} {d['sum']}")
                lines.append(f"{self.name}_count{_labels(self.label_names, key)} {d['count']}")
        return lines


def render_all():
    out = []
    for m in _REGISTRY:
        out.extend(m.render())
    return "\n".join(out) + "\n"


class _MetricsHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.split("?", 1)[0] != "/metrics":
            self.send_response(404)
            self.end_headers()
            return
        body = render_all().encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        pass


def start_metrics_server(port):
    """Yalnız /metrics sunan ayrı HTTP sunucusu (API portundan bağımsız, arka plan iş parçacığı)."""
    srv = ThreadingHTTPServer(("0.0.0.0", port), _MetricsHandler)
    threading.Thread(target=srv.serve_forever, daemon=True, name="metrics").start()
    return srv
