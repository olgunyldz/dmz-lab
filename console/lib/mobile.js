// Mobil giriş akışları (sunucu tarafı). Eski Python konsolunun sırası korunur:
//   Yeni cihaz : parola (IdP) -> PIN + cihaz imzası (Seal) -> secure-login -> OTP üretimi
//                -> SMS doğrulama -> aktivasyon -> PIN kaydı (Seal) -> PIN + imza -> secure-login -> mobile-login
//   Mevcut     : IdP yenileme token'ı -> PIN + cihaz imzası -> secure-login -> mobile-login
// Parola yalnız IdP'ye iletilir; konsol saklamaz. IdP yenileme token'ı oturumda tutulur.
import { edgeCall } from "./edge.js";
import { CHANNELS, splash as janusSplash } from "./janus.js";
import { createDeviceCert, newDeviceId, signNonce } from "./device.js";
import { traceHeaders } from "./trace.js";
import { rememberSms } from "./sms.js";

const SEAL_HOST = "seal.lab.local";
const PIN_MESSAGES = {
  PIN_INVALID: "PIN hatalı. Doğru PIN'i girin.",
  PIN_LOCKED: "PIN, çok sayıda hatalı denemeden dolayı kilitli. Bir süre sonra tekrar deneyin.",
  PIN_EXPIRED: "PIN süresi dolmuş. PIN'i yeniden tanımlamanız gerekir.",
};

export class FlowError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

const mobileHost = CHANNELS.mobile.host;

// Janus (mobil) çağrısı; splash token varsa başlığa konur.
function janus(path, obj, trace, splash) {
  const h = { ...traceHeaders(trace), ...(splash ? { "X-Splash-Token": splash } : {}) };
  return edgeCall(mobileHost, "POST", path, h, obj);
}

// Seal çağrısı: IdP access token (Bearer) + cihaz istemci sertifikası (mTLS, edge passthrough), iç CA.
function seal(path, access, cert, obj, trace) {
  return edgeCall(SEAL_HOST, "POST", path,
    { Authorization: "Bearer " + access, ...traceHeaders(trace) }, obj,
    { ca: "internal", cert: cert.cert, key: cert.key });
}

async function idpToken(body, trace) {
  const r = await janus("/janus/mobile/idp-token", body, trace);
  if (r.status !== 200) throw new FlowError(r.status === 401 ? 401 : 502, r.data.error || "IdP token alınamadı");
  return r.data;
}

// Seal: login/begin -> login/pin -> login/authorize (cihaz imzası). Döner: flowId.
async function authorizeDevice(access, cert, pin, trace) {
  const b = await seal("/seal/mobile/v1/login/begin", access, cert, {}, trace);
  if (b.status !== 200) throw new FlowError(502, "Seal login/begin: " + b.status);
  const flowId = b.data.flowId;
  const p = await seal("/seal/mobile/v1/login/pin", access, cert, { flowId, pin }, trace);
  if (p.status !== 200 || !["PIN_OK", "NEW_DEVICE"].includes(p.data.status)) {
    throw new FlowError(401, PIN_MESSAGES[p.data.status] || "PIN doğrulanamadı (" + (p.data.status || p.status) + ")");
  }
  const a = await seal("/seal/mobile/v1/login/authorize", access, cert,
    { flowId, authorizationId: p.data.authorizationId, signature: signNonce(cert.key, p.data.nonce) }, trace);
  if (a.status !== 200) throw new FlowError(401, "cihaz yetkisi reddedildi (" + a.status + ")");
  return flowId;
}

// secure-login + mobile-login: oturum belirteci al ve mobil oturumu kaydet.
async function completeLogin(m, device, flowId, customer, splash, trace) {
  const sl = await janus("/janus/secure-login", { flowId }, trace, splash);
  if (sl.status !== 200) throw new FlowError(401, sl.data.error || "secure-login: " + sl.status);
  const ml = await janus("/janus/mobile-login", { flowId, customerId: customer }, trace, splash);
  if (ml.status !== 200) throw new FlowError(401, ml.data.error || "mobile-login: " + ml.status);
  Object.assign(m, {
    device, splash, token: ml.data.token, refresh: ml.data.refreshToken,
    customerId: ml.data.customerId, fullName: ml.data.fullName,
  });
  return { loggedIn: true, customerId: ml.data.customerId, fullName: ml.data.fullName };
}

// Yeni cihaz 1. aşama: parola ile IdP token, PIN + cihaz imzası, OTP üretimi (lab: kod /sms kutusunda).
export async function startNewDevice(m, customer, pin, password, trace) {
  if (password.length < 8) throw new FlowError(400, "parola gerekli");
  const device = newDeviceId();
  const sp = await janusSplash("mobile", device, trace);
  if (sp.status !== 200) throw new FlowError(502, "splash: " + sp.status);
  const splash = sp.data.splashToken;
  const idp = await idpToken({ grant: "password", customerId: customer, password }, trace);
  const cert = createDeviceCert(device);
  const flowId = await authorizeDevice(idp.accessToken, cert, pin, trace);
  const sl = await janus("/janus/secure-login", { flowId }, trace, splash);
  if (sl.status !== 200) throw new FlowError(401, sl.data.error || "secure-login: " + sl.status);
  const otp = await janus("/janus/otp/request", { flowId }, trace, splash);
  if (otp.status !== 200) throw new FlowError(502, otp.data.error || "OTP isteği: " + otp.status);
  rememberSms("mobile", otp.data.demoOtp || "");
  m.idpRefresh = idp.refreshToken;
  m.pending = { device, customer, pin, flowId, splash, access: idp.accessToken, cert };
  return { needOtp: true };
}

// Yeni cihaz 2. aşama: SMS doğrulama, aktivasyon, PIN kaydı, giriş.
export async function finishNewDevice(m, customer, pin, smsCode, trace) {
  const p = m.pending;
  if (!p || p.customer !== customer) throw new FlowError(400, "önce 'SMS kodu gönder' adımını tamamlayın");
  const v = await janus("/janus/otp/verify", { flowId: p.flowId, smsCode }, trace, p.splash);
  if (v.status !== 200) throw new FlowError(400, v.data.error || "SMS kodu doğrulanamadı");
  const at = await janus("/janus/activation/token", { customerId: customer }, trace, p.splash);
  if (at.status !== 200) throw new FlowError(502, at.data.error || "aktivasyon tokenı: " + at.status);
  const ac = await janus("/janus/activation/complete",
    { activationToken: at.data.activationToken, customerId: customer }, trace, p.splash);
  if (ac.status !== 200 || ac.data.status !== "ACTIVATED") {
    throw new FlowError(502, "aktivasyon tamamlanmadı: " + (ac.data.status || ac.status));
  }
  const en = await seal("/seal/mobile/v1/device/enroll", p.access, p.cert, { pin }, trace);
  if (en.status !== 200) throw new FlowError(502, "PIN kaydı: " + en.status);
  const flowId = await authorizeDevice(p.access, p.cert, pin, trace);
  m.enrolledCustomer = customer;
  m.pending = null;
  return completeLogin(m, p.device, flowId, customer, p.splash, trace);
}

// Mevcut cihaz: IdP yenileme token'ı ile giriş (parola istenmez).
export async function existingDeviceLogin(m, customer, pin, trace) {
  if (!m.device || !m.idpRefresh || m.enrolledCustomer !== customer) {
    throw new FlowError(400, "bu tarayıcıda bu müşteri için aktive edilmiş cihaz yok; 'Yeni cihaz' ile aktive edin");
  }
  const idp = await idpToken({ grant: "refresh", refreshToken: m.idpRefresh }, trace);
  m.idpRefresh = idp.refreshToken;
  const sp = await janusSplash("mobile", m.device, trace);
  if (sp.status !== 200) throw new FlowError(502, "splash: " + sp.status);
  const cert = createDeviceCert(m.device);
  const flowId = await authorizeDevice(idp.accessToken, cert, pin, trace);
  return completeLogin(m, m.device, flowId, customer, sp.data.splashToken, trace);
}
