// Konsol API istemcisi. Her çağrı X-Trace-Id ile döner ve akış panelinde kaydedilir.
const listeners = new Set();
let calls = [];
let seq = 0;

export function subscribeCalls(fn) {
  listeners.add(fn);
  return () => listeners.delete(fn);
}
export function getCalls() {
  return calls;
}

function record(entry) {
  calls = [{ id: ++seq, at: new Date().toLocaleTimeString("tr-TR"), ...entry }, ...calls].slice(0, 60);
  listeners.forEach((f) => f());
}

export async function api(path, body) {
  const method = body === undefined ? "GET" : "POST";
  const t0 = performance.now();
  let r;
  try {
    r = await fetch(path, {
      method,
      headers: { "Content-Type": "application/json" },
      credentials: "same-origin",
      body: body === undefined ? undefined : JSON.stringify(body),
    });
  } catch {
    record({ method, path, status: 0, ms: Math.round(performance.now() - t0), tid: "" });
    return { ok: false, status: 0, data: { error: "Konsol sunucusuna ulaşılamadı" }, tid: "" };
  }
  const tid = r.headers.get("X-Trace-Id") || "";
  const data = await r.json().catch(() => ({}));
  record({ method, path, status: r.status, ms: Math.round(performance.now() - t0), tid });
  return { ok: r.ok, status: r.status, data, tid };
}
