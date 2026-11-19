// İstek başına izleme kimliği (W3C traceparent). Konsol her HTTP isteği için bir iz açar;
// bu kimlik edge üzerinden Janus ve arkadaki servislere traceparent olarak taşınır, servisler
// alt span'leri aynı iz altına yazar. Tarayıcıya X-Trace-Id olarak döner (Grafana/Jaeger linki için).
// Konsol ayrıca kendi kök span'ini (OTLP -> Jaeger) ve iz kimliği içeren bir log satırını (Loki) yollar;
// böylece istek, alt servis çağrısı olmasa bile Jaeger ve Grafana'da görünür.
import { randomBytes } from "node:crypto";

const OTLP_URL = process.env.CONSOLE_OTLP_URL || "http://127.0.0.1:14318";  // Jaeger OTLP (platform, host süreçleri)
const LOKI_URL = process.env.CONSOLE_LOKI_URL || "http://127.0.0.1:13100";  // Loki (platform)

export function newTrace(name = "console") {
  const tid = randomBytes(16).toString("hex");
  const sid = randomBytes(8).toString("hex");
  return { tid, sid, name, start: Date.now(), traceparent: `00-${tid}-${sid}-01` };
}

export function traceHeaders(trace) {
  return { traceparent: trace.traceparent };
}

// Yanıt: gövde + X-Trace-Id başlığı. Span ve log best-effort gönderilir; yanıtı geciktirmez.
export function withTrace(body, trace, status = 200) {
  const end = Date.now();
  sendSpan(trace, status, end);
  sendLog(trace, status, end);
  return Response.json(body, { status, headers: { "X-Trace-Id": trace.tid } });
}

function sendSpan(trace, status, end) {
  const startNs = BigInt(trace.start) * 1000000n;
  const endNs = BigInt(end) * 1000000n;
  const payload = {
    resourceSpans: [{
      resource: { attributes: [{ key: "service.name", value: { stringValue: "console" } }] },
      scopeSpans: [{
        scope: { name: "dmz-lab" },
        spans: [{
          traceId: trace.tid,
          spanId: trace.sid,
          name: "console " + trace.name,
          kind: 2, // SERVER
          startTimeUnixNano: startNs.toString(),
          endTimeUnixNano: endNs.toString(),
          attributes: [
            { key: "http.status_code", value: { intValue: String(status) } },
            { key: "service.name", value: { stringValue: "console" } },
          ],
          status: { code: status >= 500 ? 2 : 1 },
        }],
      }],
    }],
  };
  fetch(OTLP_URL + "/v1/traces", {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(payload),
  }).catch(() => {});
}

function sendLog(trace, status, end) {
  const ns = (BigInt(end) * 1000000n).toString();
  const line = `traceId=${trace.tid} ${trace.name} status=${status} ms=${end - trace.start}`;
  const payload = { streams: [{ stream: { app: "console", level: status >= 500 ? "error" : "info" }, values: [[ns, line]] }] };
  fetch(LOKI_URL + "/loki/api/v1/push", {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(payload),
  }).catch(() => {});
}
