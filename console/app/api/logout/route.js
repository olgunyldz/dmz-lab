import { session } from "../../../lib/sessions.js";
import { newTrace, withTrace } from "../../../lib/trace.js";

export const dynamic = "force-dynamic";

// Çıkış: kanal oturumunu temizle (cihaz kimliği kalır)
export async function POST(req) {
  const trace = newTrace("POST /api/logout");
  const sess = await session();
  const body = await req.json().catch(() => ({}));
  const channel = body.channel === "mobile" ? "mobile" : "web";
  const c = sess[channel] || {};
  for (const k of ["token", "refresh", "customerId", "fullName", "splash"]) delete c[k];
  return withTrace({ ok: true }, trace);
}
