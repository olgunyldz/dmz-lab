import { edgeCall } from "../../../../lib/edge.js";
import { CHANNELS } from "../../../../lib/janus.js";
import { newTrace, traceHeaders, withTrace } from "../../../../lib/trace.js";

export const dynamic = "force-dynamic";

// Müşteri ekleme: Janus (mobile-api) -> auth-server (IdP). Parola yalnız IdP'ye iletilir; konsol saklamaz, loglamaz.
export async function POST(req) {
  const trace = newTrace("POST /api/customer/create");
  const body = await req.json().catch(() => ({}));
  const password = String(body.password || "");
  if (password.length < 8) return withTrace({ error: "parola en az 8 karakter olmalı" }, trace, 400);
  const r = await edgeCall(CHANNELS.mobile.host, "POST", "/janus/customer/create", traceHeaders(trace), { password });
  if (r.status !== 201) return withTrace({ error: r.data.error || "müşteri oluşturulamadı" }, trace, r.status);
  return withTrace({ customerId: r.data.customerId, fullName: r.data.fullName, accounts: r.data.accounts || [] }, trace, 201);
}
