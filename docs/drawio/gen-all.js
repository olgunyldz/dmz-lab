// Lab mimarisinin draw.io sayfalarını TEK dosyada üretir: docs/dmz-lab.drawio (her sayfa bir tab).
// Çalıştırma (repo kökünden):  node docs/drawio/gen-all.js
// Ortak yardımcılar: builder.js (sayfa/kutu/ok), palette.js (renk ve stiller). Kaynak gerçeği: docs/servisler.md ve design.md.
const fs = require("fs");
const path = require("path");
const { Page, mxfile } = require("./builder.js");
const { SEQ } = require("./palette.js");

// ---------------------------------------------------------------------------
// Genel mimari (cluster bölgeleri ve trafik)
// ---------------------------------------------------------------------------
function overview() {
  const p = new Page("Genel mimari (lab)");

  p.zone(20, 60, 190, 840, "İstemciler", "internet");
  p.node("web", 40, 150, 150, 80, "Web tarayıcı\n(web.lab.local)", "client");
  p.node("mob", 40, 300, 150, 80, "Mobil uygulama\n(mobile-api.lab.local,\nseal.lab.local)", "client");

  p.zone(240, 60, 230, 840, "edge (docker compose, HAProxy)", "edge");
  p.node("edge", 260, 150, 190, 110, "HAProxy\n8443 host portu\nSNI passthrough: seal\nTLS sonlandırma: web, mobil", "edge");

  p.zone(500, 60, 300, 400, "codevo-dmz", "dmz");
  p.node("seal", 520, 130, 260, 100, "Seal Mobile\ncihaz mTLS, PIN, cihaz imzası", "dmz");
  p.node("sint", 520, 290, 260, 100, "Seal Intranet\ncihaz kaydı ve durumu (tek kaynak)\nakış uçları (B2B bearer)", "dmz");

  p.zone(500, 500, 300, 400, "bank-dmz-prod", "dmz");
  p.node("jweb", 520, 570, 260, 80, "Janus web\nsplash, OTP, login, client token,\nserver token üretimi", "dmz");
  p.node("jmob", 520, 710, 260, 80, "Janus mobil\nsecure-login, mobile-login,\naktivasyon", "dmz");

  p.zone(850, 60, 430, 840, "bank-prod", "internal");
  p.ns(870, 110, 390, 130, "ns: auth", "#7C3AED");
  p.node("idp", 890, 150, 350, 70, "auth-server (IdP)\nmobile-app: PKCE, access token", "identity");
  p.ns(870, 270, 390, 205, "ns: channel", "#2563EB");
  p.node("cgw", 890, 300, 350, 35, "FortunaUsersCGW (captcha)", "internal", 10);
  p.node("api", 890, 342, 350, 35, "FortunaUserAPI", "internal", 10);
  p.node("acl", 890, 384, 350, 35, "FortunaUserACL (parola, durum)", "internal", 10);
  p.node("sms", 890, 426, 350, 35, "SmsOtpCGW (mock, OTP)", "internal", 10);
  p.node("cg", 890, 520, 350, 70, "channel-gateway\nserver token doğrulama, BALANCE", "internal");
  p.node("vault", 890, 620, 350, 50, "Vault (ns secrets): sırlar", "mgmt", 10);

  p.zone(1310, 60, 280, 400, "legacy-demo", "internal");
  p.node("fm", 1330, 130, 240, 110, "Fortuna monolit mock\n/fortuna/accounts, mobile-login,\nsecure-login, activation\nPIN doğrulayıcı (/seal-pm/*)", "internal");

  p.zone(1310, 500, 280, 400, "mgmt", "mgmt");
  p.node("ldb", 1330, 560, 240, 70, "LegacyDB (PostgreSQL)\ncustomers, accounts,\nfortuna_users, customer_devices", "mgmt");
  p.node("obs", 1330, 650, 240, 70, "Observability\nPrometheus, Loki, Tempo, Grafana", "mgmt");
  p.node("redis", 1330, 740, 240, 50, "Redis (kullanılmıyor)", "planned", 10);

  // Trafik
  p.edge("web", "edge", "HTTPS", "request");
  p.edge("mob", "edge", "HTTPS", "request");
  p.edge("edge", "jweb", "web.lab.local → HTTP", "request");
  p.edge("edge", "jmob", "mobile-api.lab.local → HTTP", "request");
  p.edge("edge", "seal", "seal.lab.local (passthrough, mTLS)", "internal");
  p.edge("seal", "fm", "PIN doğrulama (/seal-pm/*)", "request");
  p.edge("seal", "idp", "introspection", "request");
  p.edge("sint", "idp", "JWKS (B2B doğrulama)", "request");
  p.edge("jweb", "cgw", "müşteri doğrulama", "request");
  p.edge("jmob", "cgw", "müşteri doğrulama", "request");
  p.edge("jweb", "cg", "server token (60 sn)", "internal");
  p.edge("jmob", "cg", "server token (60 sn)", "internal");
  p.edge("cg", "fm", "BALANCE → /fortuna/accounts", "request");
  p.edge("cgw", "api", "", "request");
  p.edge("api", "acl", "", "request");
  p.edge("acl", "ldb", "parola ve durum", "request");
  p.edge("fm", "ldb", "müşteri, cihaz, denetim", "request");

  p.text(20, 920, 1600, 40,
    "Lab notları: SMS mock (OTP yanıtta). Captcha sabit (lab-captcha). Janus ↔ alt servis düz HTTP. " +
    "channel-gateway Janus anahtarını secret'tan alır (prod: JWKS). Loglar Alloy → Loki, metrikler Prometheus.",
    "text;html=1;fontSize=11;align=left;fontColor=#1F2937;whiteSpace=wrap;");
  return p.build();
}

// ---------------------------------------------------------------------------
// Sıra diyagramı yardımcısı: katılımcılar üstte, yaşam çizgileri, etiketli oklar
// ---------------------------------------------------------------------------
function sequence(name, participants, messages, footnote) {
  const p = new Page(name);
  const X0 = 40, STEP = 190, BOX_W = 160, BOX_H = 50, TOP = 40;
  const x = {};
  participants.forEach((pt, i) => {
    x[pt.key] = X0 + i * STEP + BOX_W / 2;
    p.node(pt.key, X0 + i * STEP, TOP, BOX_W, BOX_H, pt.label, pt.kind || "internal", 10);
  });
  const ROW0 = TOP + BOX_H + 40, ROW = 46;
  const bottom = ROW0 + messages.length * ROW + 40;
  // yaşam çizgileri
  participants.forEach((pt) => {
    p.box(null, x[pt.key] - 0.5, TOP + BOX_H, 1, bottom - (TOP + BOX_H),
      "", "shape=rectangle;fillColor=#CBD5E1;strokeColor=none;");
  });
  messages.forEach((m, i) => {
    const y = ROW0 + i * ROW;
    const a = p.box(null, x[m.from] - 4, y - 4, 8, 8, "", "shape=ellipse;fillColor=none;strokeColor=none;");
    const b = p.box(null, x[m.to] - 4, y - 4, 8, 8, "", "shape=ellipse;fillColor=none;strokeColor=none;");
    const style = m.type === "ret" ? SEQ.ret : m.type === "internal" ? SEQ.internal : SEQ.normal;
    p.link(a, b, "", style);
    const left = Math.min(x[m.from], x[m.to]), right = Math.max(x[m.from], x[m.to]);
    p.text(left + 6, y - 20, right - left - 12, 16,
      `${i + 1}. ${m.label}`,
      "text;html=1;fontSize=10;align=center;verticalAlign=bottom;whiteSpace=wrap;fontColor=#1F2937;");
  });
  if (footnote) {
    p.text(40, bottom, Math.max(900, participants.length * STEP), 40, footnote,
      "text;html=1;fontSize=11;align=left;verticalAlign=top;whiteSpace=wrap;fontColor=#1F2937;");
  }
  return p.build();
}

// ---------------------------------------------------------------------------
// Sıra diyagramları
// ---------------------------------------------------------------------------
const web = sequence("Web girişi ve işlem",
  [
    { key: "t", label: "Tarayıcı", kind: "client" },
    { key: "j", label: "Janus web", kind: "dmz" },
    { key: "cgw", label: "FortunaUsersCGW", kind: "internal" },
    { key: "sms", label: "SmsOtpCGW (mock)", kind: "internal" },
    { key: "cg", label: "channel-gateway", kind: "internal" },
    { key: "fm", label: "Fortuna monolit", kind: "internal" },
  ],
  [
    { from: "t", to: "j", label: "POST /janus/splash {deviceId}" },
    { from: "j", to: "t", label: "splash token (15 dk)", type: "ret" },
    { from: "t", to: "j", label: "POST /janus/otp/request" },
    { from: "j", to: "sms", label: "OTP isteği" },
    { from: "sms", to: "j", label: "demoOtp (lab: yanıtta)", type: "ret" },
    { from: "t", to: "j", label: "POST /janus/login-user (no, parola, captcha, OTP)" },
    { from: "j", to: "cgw", label: "verifyUserPin" },
    { from: "cgw", to: "j", label: "ok (ACL: parola, durum, ad)", type: "ret" },
    { from: "j", to: "sms", label: "OTP doğrulama" },
    { from: "sms", to: "j", label: "OK", type: "ret" },
    { from: "j", to: "t", label: "client token (typ client, 15 dk)", type: "ret" },
    { from: "t", to: "j", label: "POST /janus/transaction (Bearer client)" },
    { from: "j", to: "cg", label: "server token (typ server, aud channel-gateway, 60 sn)", type: "internal" },
    { from: "cg", to: "fm", label: "/fortuna/accounts" },
    { from: "fm", to: "cg", label: "hesaplar", type: "ret" },
    { from: "cg", to: "j", label: "BALANCE sonucu", type: "ret" },
    { from: "j", to: "t", label: "200 OK (bakiye)", type: "ret" },
  ],
  "Client token dışarıda kalır. Janus içeri giderken doğrular ve server token üretir; channel-gateway yalnızca server token kabul eder.");

const mobile = sequence("Mobil giriş (mevcut cihaz)",
  [
    { key: "m", label: "Mobil uygulama", kind: "client" },
    { key: "idp", label: "auth-server (IdP)", kind: "identity" },
    { key: "seal", label: "Seal Mobile", kind: "dmz" },
    { key: "j", label: "Janus mobil", kind: "dmz" },
    { key: "fm", label: "Fortuna monolit", kind: "internal" },
  ],
  [
    { from: "m", to: "j", label: "POST /janus/splash (cihaz ACTIVE)" },
    { from: "j", to: "m", label: "splash token", type: "ret" },
    { from: "m", to: "idp", label: "PKCE: /auth, /token (mobile-app)" },
    { from: "idp", to: "m", label: "access token (aud channel-mobile)", type: "ret" },
    { from: "m", to: "seal", label: "login/begin (mTLS + Bearer)" },
    { from: "seal", to: "m", label: "flowId", type: "ret" },
    { from: "m", to: "seal", label: "login/pin" },
    { from: "seal", to: "fm", label: "pin/verify (/seal-pm/*)" },
    { from: "fm", to: "seal", label: "ok", type: "ret" },
    { from: "seal", to: "m", label: "PIN_OK, nonce", type: "ret" },
    { from: "m", to: "seal", label: "login/authorize (cihaz imzası)" },
    { from: "seal", to: "idp", label: "introspection (oturum aktif mi)" },
    { from: "idp", to: "seal", label: "active", type: "ret" },
    { from: "seal", to: "m", label: "PIN_AUTHORIZED", type: "ret" },
    { from: "m", to: "j", label: "secure-login (flowId)" },
    { from: "j", to: "fm", label: "secure-login" },
    { from: "fm", to: "j", label: "SEAL_AUTHORIZED", type: "ret" },
    { from: "m", to: "j", label: "mobile-login (customerId)" },
    { from: "j", to: "fm", label: "mobile-login (cihaz ACTIVE kontrolü)" },
    { from: "fm", to: "j", label: "ok (ad dahil)", type: "ret" },
    { from: "j", to: "m", label: "client token (typ client, 15 dk)", type: "ret" },
  ],
  "Seal Mobile cihaz sertifikası (device CA) ve PIN'i doğrular. Janus cihaz ACTIVE değilse mobile-login reddedilir.");

const newDevice = sequence("Yeni cihaz aktivasyonu",
  [
    { key: "m", label: "Mobil uygulama", kind: "client" },
    { key: "seal", label: "Seal Mobile", kind: "dmz" },
    { key: "j", label: "Janus mobil", kind: "dmz" },
    { key: "sms", label: "SmsOtpCGW (mock)", kind: "internal" },
    { key: "fm", label: "Fortuna monolit", kind: "internal" },
    { key: "si", label: "Seal Intranet", kind: "dmz" },
  ],
  [
    { from: "m", to: "seal", label: "login/pin (cihaz yeni: NEW_DEVICE)" },
    { from: "seal", to: "m", label: "NEW_DEVICE", type: "ret" },
    { from: "m", to: "seal", label: "login/authorize (cihaz imzası)" },
    { from: "seal", to: "m", label: "PIN_AUTHORIZED", type: "ret" },
    { from: "m", to: "j", label: "secure-login" },
    { from: "j", to: "fm", label: "secure-login" },
    { from: "m", to: "j", label: "otp/request" },
    { from: "j", to: "sms", label: "OTP isteği" },
    { from: "sms", to: "m", label: "demoOtp (lab)", type: "ret" },
    { from: "m", to: "j", label: "login-user (parola, captcha, OTP)" },
    { from: "j", to: "fm", label: "müşteri doğrulama (CGW → ACL)" },
    { from: "m", to: "j", label: "activation/token" },
    { from: "j", to: "fm", label: "activation/token" },
    { from: "fm", to: "si", label: "create-activation-token" },
    { from: "si", to: "fm", label: "activationToken", type: "ret" },
    { from: "m", to: "j", label: "activation/complete" },
    { from: "j", to: "fm", label: "activation/status" },
    { from: "fm", to: "si", label: "get-activation-status" },
    { from: "si", to: "fm", label: "ACTIVATED", type: "ret" },
    { from: "fm", to: "m", label: "cihaz ACTIVE (LegacyDB)", type: "ret" },
    { from: "m", to: "seal", label: "device/enroll (PIN kaydı)" },
    { from: "seal", to: "m", label: "ENROLLED", type: "ret" },
  ],
  "Aktivasyondan sonra normal mobil giriş (Mobil giriş diyagramı) yapılır. Lab: her çalıştırmada yeni cihaz kimliği üretilir ve LegacyDB'de kalır.");

const pages = [overview(), web, mobile, newDevice];

const out = path.join(__dirname, "..", "dmz-lab.drawio");
fs.writeFileSync(out, mxfile(pages, "dmz-lab gen-all.js"), "utf8");
console.log(`yazıldı: ${out} (${pages.length} sayfa)`);
pages.forEach((pg, i) => console.log(`  ${i + 1}. ${pg.name}`));
