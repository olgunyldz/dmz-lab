import { session } from "../../../lib/sessions.js";
import { splash, janus } from "../../../lib/janus.js";
import { newTrace, withTrace } from "../../../lib/trace.js";

export const dynamic = "force-dynamic";

// Client token süresi dolunca: yenileme token'ı ile yeni token ve yeni splash (bir kez dener).
async function renew(c, channel, device, trace) {
  if (!c.refresh || !device) return false;
  const r = await janus(channel, "/janus/token/refresh", { refreshToken: c.refresh }, "", undefined, trace);
  if (r.status !== 200) return false;
  const sp = await splash(channel, device, trace);
  if (sp.status !== 200) return false;
  Object.assign(c, { token: r.data.token, refresh: r.data.refreshToken, splash: sp.data.splashToken });
  return true;
}

export async function POST(req) {
  const trace = newTrace("POST /api/transaction");
  const sess = await session();
  const body = await req.json().catch(() => ({}));
  const channel = body.channel === "mobile" ? "mobile" : "web";
  const c = sess[channel];
  if (!c || !c.token) return withTrace({ error: "oturum yok" }, trace, 401);
  const payload = { code: body.code, params: body.params || {} };
  const device = channel === "web" ? sess.web.device : c.device;
  let r = await janus(channel, "/janus/transaction", payload, c.splash, c.token, trace);
  if (r.status === 401 && (await renew(c, channel, device, trace))) {
    r = await janus(channel, "/janus/transaction", payload, c.splash, c.token, trace);
  }
  if (r.status === 401) {
    delete c.token; delete c.refresh;
    return withTrace({ error: "oturum süresi doldu; yeniden giriş yapın", expired: true }, trace, 401);
  }
  return withTrace(r.data, trace, r.status);
}
