"use client";
// İzleme bileşenleri: son yanıtın iz linkleri ve istek akışı paneli.
import { useSyncExternalStore } from "react";
import { subscribeCalls, getCalls } from "./api.js";

export const JAEGER = "http://127.0.0.1:16686";
export const GRAFANA = "http://127.0.0.1:3000";

// Her konsol yolunun geçtiği hatlar (akış panelinde gösterilir)
const HOPS = {
  "/api/state": "konsol (oturum durumu)",
  "/api/sms": "konsol (SMS kutusu)",
  "/api/web/otp": "konsol → edge → Janus (splash, OTP) → SMS mock",
  "/api/web/login": "konsol → edge → Janus → Fortuna ACL + SMS OTP",
  "/api/transaction": "konsol → edge → Janus → channel-gateway → Fortuna",
  "/api/logout": "konsol (oturum temizleme)",
  "/api/mobile/login": "konsol → edge → Janus (mobil) → Seal / auth-server (planlı)",
};

export function grafanaLogUrl(tid) {
  return GRAFANA + "/d/dmz-lab-trace-lookup?orgId=1&from=now-1h&to=now&var-traceId=" + encodeURIComponent(tid);
}
export function jaegerUrl(tid) {
  return JAEGER + "/trace/" + encodeURIComponent(tid);
}

// İz bağlantısı: Grafana'da Loki günlüğü, Jaeger'da span ağacı
export function TraceLinks({ tid, label }) {
  if (!tid) return null;
  return (
    <p className="trace small muted">
      {label ? label + ": " : ""}
      <a href={grafanaLogUrl(tid)} target="_blank" rel="noopener">Grafana log</a>
      {" · "}
      <a href={jaegerUrl(tid)} target="_blank" rel="noopener">Jaeger iz</a>
      {" "}<code title={tid}>{tid.slice(0, 12)}…</code>
    </p>
  );
}

// Sayfa altındaki akış paneli: her konsol isteği, geçtiği hatlar, durum, süre ve iz linki
export function TraceFlow() {
  const calls = useSyncExternalStore(subscribeCalls, getCalls, getCalls);
  return (
    <details className="trace-flow">
      <summary>İstek akışı ({calls.length})</summary>
      {calls.length === 0 ? (
        <p className="muted small">Henüz istek yok. Bir işlem yapın; her isteğin izi burada listelenir.</p>
      ) : (
        <div className="table-wrap">
          <table className="flow-table">
            <thead><tr><th>Saat</th><th>İstek</th><th>Hatlar</th><th>Durum</th><th className="num">ms</th><th>İz</th></tr></thead>
            <tbody>
              {calls.map((c) => (
                <tr key={c.id} className={c.status >= 400 || c.status === 0 ? "bad-row" : ""}>
                  <td>{c.at}</td>
                  <td><code>{c.method} {c.path}</code></td>
                  <td className="small">{HOPS[c.path] || c.path}</td>
                  <td>{c.status || "ağ hatası"}</td>
                  <td className="num">{c.ms}</td>
                  <td>
                    {c.tid ? (
                      <span className="small">
                        <a href={grafanaLogUrl(c.tid)} target="_blank" rel="noopener">Log</a>
                        {" · "}
                        <a href={jaegerUrl(c.tid)} target="_blank" rel="noopener">Jaeger</a>
                        {" "}<code title={c.tid}>{c.tid.slice(0, 8)}</code>
                      </span>
                    ) : "—"}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </details>
  );
}
