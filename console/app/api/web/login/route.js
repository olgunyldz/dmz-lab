import { session } from "../../../../lib/sessions.js";
import { janus } from "../../../../lib/janus.js";
import { newTrace, withTrace } from "../../../../lib/trace.js";

export const dynamic = "force-dynamic";

const DEMO_CAPTCHA = "lab-captcha";

// Web: login-user (müşteri no + parola + captcha + SMS kodu)
export async function POST(req) {
  const trace = newTrace("POST /api/web/login");
  const sess = await session();
  const w = sess.web;
  const body = await req.json().catch(() => ({}));
  if (!w.splash) return withTrace({ error: "önce OTP isteyin" }, trace, 400);
  const r = await janus("web", "/janus/login-user", {
    flowId: w.flow, customerId: body.customerId, password: body.password,
    captcha: DEMO_CAPTCHA, smsCode: body.smsCode,
  }, w.splash, undefined, trace);
  if (r.status !== 200) return withTrace({ error: r.data.error || "giriş reddedildi (" + r.status + ")" }, trace, 401);
  Object.assign(w, { token: r.data.token, customerId: r.data.customerId, fullName: r.data.fullName, refresh: r.data.refreshToken });
  return withTrace({ customerId: r.data.customerId, fullName: r.data.fullName }, trace);
}
