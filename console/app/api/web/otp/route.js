import { session } from "../../../../lib/sessions.js";
import { splash, janus } from "../../../../lib/janus.js";
import { rememberSms } from "../../../../lib/sms.js";
import { newTrace, withTrace } from "../../../../lib/trace.js";

export const dynamic = "force-dynamic";

// Web: splash -> OTP isteği (lab: kod yanıtta değil, /sms kutusunda)
export async function POST() {
  const trace = newTrace("POST /api/web/otp");
  const sess = await session();
  const w = sess.web;
  const sp = await splash("web", w.device, trace);
  if (sp.status !== 200) return withTrace({ error: "splash: " + sp.status }, trace, 502);
  w.splash = sp.data.splashToken;
  const r = await janus("web", "/janus/otp/request", { flowId: w.flow }, w.splash, undefined, trace);
  if (r.status !== 200) return withTrace({ error: r.data.error || "OTP isteği: " + r.status }, trace, 502);
  rememberSms("web", r.data.demoOtp || "");
  return withTrace({ sent: true, channel: "web" }, trace);
}
