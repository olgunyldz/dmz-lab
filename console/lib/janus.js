// Janus kanal çağrıları (web.lab.local / mobile-api.lab.local üzerinden edge).
import { edgeCall } from "./edge.js";
import { newTrace, traceHeaders } from "./trace.js";

export const CHANNELS = {
  web: { host: "web.lab.local" },
  mobile: { host: "mobile-api.lab.local" },
};

export function splash(channel, deviceId, trace = newTrace()) {
  return edgeCall(CHANNELS[channel].host, "POST", "/janus/splash", traceHeaders(trace), { deviceId });
}

export function janus(channel, urlPath, obj, splashToken, token, trace = newTrace()) {
  const h = { "X-Splash-Token": splashToken, ...traceHeaders(trace) };
  if (token) h.Authorization = "Bearer " + token;
  return edgeCall(CHANNELS[channel].host, "POST", urlPath, h, obj);
}
