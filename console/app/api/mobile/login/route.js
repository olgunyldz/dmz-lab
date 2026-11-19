import { session } from "../../../../lib/sessions.js";
import { newTrace, withTrace } from "../../../../lib/trace.js";
import { FlowError, startNewDevice, finishNewDevice, existingDeviceLogin } from "../../../../lib/mobile.js";

export const dynamic = "force-dynamic";

// Mobil giriş: { customerId, pin, newDevice, password?, smsCode? }
export async function POST(req) {
  const trace = newTrace("POST /api/mobile/login");
  const sess = await session();
  const m = sess.mobile;
  const body = await req.json().catch(() => ({}));
  const customer = String(body.customerId || "").trim().toUpperCase();
  const pin = String(body.pin || "");
  if (!/^C\d{9}$/.test(customer)) return withTrace({ error: "müşteri no geçersiz" }, trace, 400);
  if (!/^\d{4,6}$/.test(pin)) return withTrace({ error: "PIN 4-6 haneli olmalı" }, trace, 400);
  try {
    let out;
    if (body.newDevice && body.smsCode) out = await finishNewDevice(m, customer, pin, String(body.smsCode).trim(), trace);
    else if (body.newDevice) out = await startNewDevice(m, customer, pin, String(body.password || ""), trace);
    else out = await existingDeviceLogin(m, customer, pin, trace);
    return withTrace(out, trace);
  } catch (e) {
    if (e instanceof FlowError) return withTrace({ error: e.message }, trace, e.status);
    return withTrace({ error: "mobil giriş hatası: " + (e.message || "bilinmiyor") }, trace, 502);
  }
}
