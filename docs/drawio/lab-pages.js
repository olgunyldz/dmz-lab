// Lab mimarisi: cluster / namespace / pod yapısı ve kanal uçtan uca sayfaları.
// Kaynak: apps/*/manifests, infra/clusters, infra/vault, observability/agents, platform/docker-compose.yml.
// Replika ve port değerleri manifest'lerden alındı (bkz. docs/altyapi.md).
// Referans düzeni: inter-labs.drawio (başlık, kesikli bölge çerçeveleri, namespace kutuları, pod satırları).

const TITLE = "text;html=1;whiteSpace=nowrap;align=left;verticalAlign=middle;spacing=0;fontSize=25;fontColor=#1f1f1f;fontStyle=1;fontFamily=Segoe UI;";
const SUB = "text;html=1;whiteSpace=nowrap;align=left;verticalAlign=middle;spacing=0;fontSize=16;fontColor=#5f5f5a;fontStyle=0;fontFamily=Segoe UI;";
const NOTE = "text;html=1;whiteSpace=wrap;align=left;verticalAlign=top;spacing=0;fontSize=12.5;fontColor=#1f1f1f;fontFamily=Segoe UI;";

function clusterStructure(Page) {
  const p = new Page("Lab · Cluster ve namespace yapısı");
  p.text(40, 14, 1800, 36, "Lab · cluster, namespace ve pod yapısı", TITLE);
  p.text(40, 52, 1800, 24, "Her kutu bir namespace; satırlar pod'lar (Deployment ×replika · port). Değerler manifest'lerden. Lab'da tek node (kind).", SUB);

  // bank-prod
  p.zone(20, 90, 700, 610, "CLUSTER bank-prod (kind)", "internal");
  p.ns(40, 130, 320, 70, "ns: ingress-nginx", "#64748B");
  p.node("bp-ing", 56, 160, 290, 30, "ingress-nginx-controller ×1 · NodePort 30081 / 30543", "ops", 10);
  p.ns(40, 215, 320, 130, "ns: auth", "#7C3AED");
  p.node("auth", 56, 250, 290, 40, "auth-server ×1 · :8443 HTTPS, :8080 iç, :9100 metrik", "identity", 10);
  p.node("pgauth", 56, 300, 290, 36, "postgres-auth ×1 · :5432 · PVC postgres-auth-data", "mgmt", 10);
  p.ns(380, 215, 320, 260, "ns: channel", "#2563EB");
  p.node("cg", 396, 250, 290, 34, "channel-gateway ×1 · :8443 · NodePort 30990", "internal", 10);
  p.node("cgu", 396, 292, 290, 34, "fortuna-users-cgw ×1 · :8443 · NodePort 30880", "internal", 10);
  p.node("cga", 396, 334, 290, 34, "fortuna-user-api ×1 · :8443", "internal", 10);
  p.node("cgc", 396, 376, 290, 34, "fortuna-user-acl ×1 · :8443", "internal", 10);
  p.node("sms", 396, 418, 290, 34, "sms-otp-cgw ×1 · :8443 · NodePort 30881", "internal", 10);
  p.ns(40, 365, 320, 90, "ns: secrets", "#15803D");
  p.node("vault", 56, 400, 290, 40, "vault ×1 · :8200 · KV v2 (secret/)", "mgmt", 10);
  p.ns(40, 475, 660, 110, "ns: observability", "#0F766E");
  p.node("alloyB", 56, 510, 300, 46, "alloy ×1 · :12345 · log → Loki", "mgmt", 10);
  p.node("promB", 380, 510, 300, 46, "prometheus-agent ×1 · :9090 · metrik → Prometheus", "mgmt", 10);

  // bank-dmz-prod
  p.zone(740, 90, 560, 610, "CLUSTER bank-dmz-prod (kind)", "dmz");
  p.ns(760, 130, 520, 70, "ns: ingress-nginx", "#64748B");
  p.node("dmz-ing", 776, 160, 490, 30, "ingress-nginx-controller ×1 · NodePort 30802 (HTTP) / 30443", "ops", 10);
  p.ns(760, 215, 520, 150, "ns: janus", "#EA580C");
  p.node("jweb", 776, 250, 490, 46, "janus-web ×1 · :8080 · ingress web.lab.local", "dmz", 10);
  p.node("jmob", 776, 306, 490, 46, "janus-mobile ×1 · :8080 · ingress mobile-api.lab.local", "dmz", 10);
  p.ns(760, 385, 520, 90, "ns: observability", "#0F766E");
  p.node("alloyD", 776, 420, 240, 46, "alloy ×1 · log", "mgmt", 10);
  p.node("promD", 1030, 420, 240, 46, "prometheus-agent ×1 · metrik", "mgmt", 10);

  // codevo-dmz
  p.zone(1320, 90, 560, 610, "CLUSTER codevo-dmz (kind)", "dmz");
  p.ns(1340, 130, 520, 70, "ns: ingress-nginx", "#64748B");
  p.node("cv-ing", 1356, 160, 490, 30, "ingress-nginx-controller ×1 · NodePort 30456 (passthrough) / 30080", "ops", 10);
  p.ns(1340, 215, 520, 110, "ns: seal-intranet", "#EA580C");
  p.node("sint", 1356, 250, 490, 46, "seal-intranet ×1 · :8443 · ingress seal-intranet.lab.local (passthrough)", "dmz", 10);
  p.ns(1340, 340, 520, 110, "ns: seal-mobile", "#EA580C");
  p.node("smob", 1356, 375, 490, 46, "seal-mobile ×1 · :8443 · ingress seal.lab.local (passthrough)", "dmz", 10);
  p.ns(1340, 465, 520, 110, "ns: observability", "#0F766E");
  p.node("alloyC", 1356, 500, 240, 46, "alloy ×1 · log", "mgmt", 10);
  p.node("promC", 1610, 500, 240, 46, "prometheus-agent ×1 · metrik", "mgmt", 10);

  // platform (host, compose)
  p.zone(20, 720, 1860, 190, "PLATFORM (host, docker compose · ağ lab-platform)", "host");
  const pn = [
    ["legacydb", "legacydb ×1 · PostgreSQL 16 · :5432"],
    ["fmock", "fortuna-mock ×1 · monolit mock · :8443"],
    ["prom", "prometheus ×1 · :9090 · remote_write"],
    ["loki", "loki ×1 · :3100 · log"],
    ["jaeger", "jaeger ×1 · OTLP :4318 · UI :16686"],
    ["graf", "grafana ×1 · :3000 · panolar"],
  ];
  pn.forEach(([k, label], i) => p.node("pl-" + k, 40 + i * 300, 760, 280, 60, label, "host", 10));
  p.node("br", 40, 830, 1820, 60, "Köprüler (bridge-*, kind ağı üzerinden): bridge-auth → 30543 · bridge-si → 30456 · bridge-fortuna → 30890 · bridge-legacydb → 30432 · bridge-prometheus → 30090 · bridge-loki → 30100 · bridge-jaeger → 30318", "host", 10);

  // ilişkiler
  p.edge("dmz-ing", "jweb", "web.lab.local", "request");
  p.edge("dmz-ing", "jmob", "mobile-api.lab.local", "request");
  p.edge("jweb", "cgu", "müşteri doğrulama :30880", "request");
  p.edge("jweb", "sms", "OTP :30881", "request");
  p.edge("jweb", "cg", "server token :30990", "internal");
  p.edge("jmob", "cg", "server token :30990", "internal");
  p.edge("cgu", "cga", "", "request");
  p.edge("cga", "cgc", "", "request");
  p.edge("cgc", "pl-legacydb", "parola ve durum", "request");
  p.edge("cg", "pl-fmock", "BALANCE (bridge-fortuna)", "request");
  p.edge("sint", "auth", "JWKS (bridge / hostAlias)", "request");
  p.edge("smob", "auth", "introspection (:30543)", "request");
  p.edge("smob", "pl-fmock", "PIN (/seal-pm/*)", "request");
  p.edge("auth", "pgauth", "", "request");
  p.edge("auth", "pl-fmock", "token exchange", "request");
  p.edge("promB", "pl-prom", "remote_write", "telemetry");
  p.edge("promD", "pl-prom", "remote_write", "telemetry");
  p.edge("promC", "pl-prom", "remote_write", "telemetry");
  p.edge("alloyB", "pl-loki", "log", "telemetry");
  p.edge("alloyD", "pl-loki", "log", "telemetry");
  p.edge("alloyC", "pl-loki", "log", "telemetry");
  return p.build();
}

function ingressRules(Page) {
  const p = new Page("Lab · Ingress ve giriş kuralları");
  p.text(40, 14, 1800, 36, "Lab · ingress kuralları ve giriş yolları", TITLE);
  p.text(40, 52, 1800, 24, "Edge (HAProxy, 127.0.0.1:8443) hostname'e göre yönlendirir; cluster ingress'leri host ve SNI'a göre dağıtır.", SUB);
  const rows = [
    ["Host / SNI", "Cluster", "Ingress", "Namespace", "Backend", "Mod", "Giriş (edge → NodePort)"],
    ["web.lab.local", "bank-dmz-prod", "janus-web", "janus", "janus-web:8080", "TLS edge'de sonlanır (HTTP ingress)", "edge → 30802"],
    ["mobile-api.lab.local", "bank-dmz-prod", "janus-mobile", "janus", "janus-mobile:8080", "TLS edge'de sonlanır (HTTP ingress)", "edge → 30802"],
    ["seal.lab.local", "codevo-dmz", "seal-mobile", "seal-mobile", "seal-mobile:8443", "SNI passthrough (cihaz mTLS pod'da)", "edge → 30456"],
    ["seal-intranet.lab.local", "codevo-dmz", "seal-intranet", "seal-intranet", "seal-intranet:8443", "SNI passthrough", "bridge-si → 30456"],
    ["id.bank.lab.local", "bank-prod", "auth-server", "auth", "auth-server:8443", "SNI passthrough", "bridge-auth / Seal → 30543"],
  ];
  const cell = (t, h) => h
    ? `<th style="border:1px solid #CBD5E1;padding:6px 10px;background:#F1F5F9;text-align:left">${t}</th>`
    : `<td style="border:1px solid #CBD5E1;padding:6px 10px">${t}</td>`;
  const html = `<table style="border-collapse:collapse;font-size:13px;font-family:Segoe UI;color:#1f1f1f">` +
    rows.map((r, i) => `<tr>${r.map((c) => cell(c, i === 0)).join("")}</tr>`).join("") + `</table>`;
  p.text(40, 100, 1820, 260, html, "text;html=1;align=left;verticalAlign=top;whiteSpace=wrap;");
  p.text(40, 390, 1820, 200,
    "NodePort'lar (kind extraPortMappings ile host'a yalnız 30802 ve 30456 açıktır; diğerleri kind ağı üzerinden erişilir):\n" +
    "30081 / 30543 bank-prod ingress (30543: auth, passthrough) · 30880 / 30881 / 30990 channel NodePort'ları (Janus → bank-prod)\n" +
    "30802 / 30443 bank-dmz-prod ingress · 30080 / 30456 codevo-dmz ingress · 30644 Seal Intranet metrik NodePort (kullanılmıyor)\n" +
    "Ingress manifest'leri her uygulamanın klasöründedir: apps/<ad>/manifests/ingress.yaml.",
    NOTE);
  return p.build();
}

function channelWeb(Page) {
  const p = new Page("Lab · Kanal: web (uçtan uca)");
  p.text(40, 14, 1800, 36, "Lab · web kanalı: uçtan uca", TITLE);
  p.text(40, 52, 1800, 24, "Tarayıcı → edge → Janus web → channel-gateway / Fortuna zinciri → monolit ve LegacyDB. Her kutunun namespace'i ve portu yazılı.", SUB);

  p.zone(20, 90, 260, 560, "İSTEMCİ", "internet");
  p.node("w-br", 40, 140, 220, 110, "Tarayıcı (web)\nC000000001 · parola · SMS kodu", "client", 11);
  p.node("w-sms", 40, 290, 220, 90, "SMS kutusu (/sms)\nlab OTP", "client", 11);
  p.node("w-kon", 40, 420, 220, 90, "Konsol (127.0.0.1:9000)\n/web sayfası", "client", 11);

  p.zone(300, 90, 260, 560, "EDGE (host)", "edge");
  p.node("w-edge", 320, 140, 220, 140, "HAProxy 127.0.0.1:8443\nweb.lab.local: TLS sonlanır\n→ ingress 30802", "edge", 10);

  p.zone(580, 90, 320, 560, "bank-dmz-prod · ns janus", "dmz");
  p.node("w-jweb", 600, 140, 280, 120, "janus-web ×1 · :8080\n/janus/otp/request\n/janus/login-user\n/janus/transaction", "dmz", 10);

  p.zone(920, 90, 320, 560, "bank-prod · ns channel", "internal");
  p.node("w-sms2", 940, 140, 280, 70, "sms-otp-cgw ×1 · :8443\nOTP üretir ve doğrular", "internal", 10);
  p.node("w-cgu", 940, 240, 280, 70, "fortuna-users-cgw ×1 · :8443\nverifyUserPin (captcha, parola)", "internal", 10);
  p.node("w-cga", 940, 340, 280, 60, "fortuna-user-api ×1 · :8443", "internal", 10);
  p.node("w-cgc", 940, 430, 280, 60, "fortuna-user-acl ×1 · :8443\nparola ve durum", "internal", 10);
  p.node("w-cg", 940, 520, 280, 60, "channel-gateway ×1 · :8443\nserver token doğrulama", "internal", 10);

  p.zone(1280, 90, 320, 560, "PLATFORM (host)", "host");
  p.node("w-fm", 1300, 140, 280, 110, "fortuna-mock (monolit) ×1 · :8443\nbridge-fortuna → 30890\n/fortuna/accounts, /fortuna/history, /fortuna/transfer", "host", 10);
  p.node("w-ldb", 1300, 290, 280, 90, "legacydb ×1 · PostgreSQL 16 · :5432\nbridge-legacydb → 30432", "mgmt", 10);

  p.edge("w-br", "w-edge", "HTTPS :8443", "request");
  p.edge("w-kon", "w-edge", "web girişi", "request");
  p.edge("w-edge", "w-jweb", "web.lab.local → ingress :30802", "request");
  p.edge("w-jweb", "w-sms2", "OTP isteği :30881", "request");
  p.edge("w-jweb", "w-cgu", "müşteri doğrulama :30880", "request");
  p.edge("w-jweb", "w-cg", "server token :30990", "internal");
  p.edge("w-cgu", "w-cga", "", "request");
  p.edge("w-cga", "w-cgc", "", "request");
  p.edge("w-cgc", "w-ldb", "parola ve durum", "request");
  p.edge("w-cg", "w-fm", "BALANCE / HISTORY / TRANSFER", "request");
  p.edge("w-fm", "w-ldb", "hesap, defter", "request");
  p.edge("w-sms", "w-sms2", "kod okuma", "planned");

  p.text(40, 700, 1820, 60,
    "Akış: 1) OTP iste (/api/web/otp → /janus/otp/request → SmsOtpCGW)  2) giriş (/api/web/login → /janus/login-user → CGW → API → ACL → LegacyDB)  " +
    "3) client token  4) işlem (/api/transaction → /janus/transaction → channel-gateway → monolit). Lab: SMS kodu yanıtta değil /sms sayfasında.",
    NOTE);
  return p.build();
}

function channelMobile(Page) {
  const p = new Page("Lab · Kanal: mobil (uçtan uca)");
  p.text(40, 14, 1800, 36, "Lab · mobil kanalı: uçtan uca", TITLE);
  p.text(40, 52, 1800, 24, "Mobil → edge → Janus mobil ve Seal Mobile → auth-server (PKCE, introspection) → monolit (PIN, cihaz kaydı).", SUB);

  p.zone(20, 90, 260, 560, "İSTEMCİ", "internet");
  p.node("m-app", 40, 140, 220, 110, "Mobil uygulama\nmobile-api · seal\nPKCE, cihaz sertifikası", "client", 10);
  p.node("m-kon", 40, 290, 220, 100, "Konsol (127.0.0.1:9000)\n/mobil sihirbaz", "client", 10);
  p.node("m-sms", 40, 430, 220, 90, "SMS kutusu (/sms)\nyeni cihaz OTP", "client", 10);

  p.zone(300, 90, 260, 560, "EDGE (host)", "edge");
  p.node("m-edge", 320, 140, 220, 160, "HAProxy 127.0.0.1:8443\nmobile-api.lab.local: TLS sonlanır → 30802\nseal.lab.local: SNI passthrough → 30456", "edge", 10);

  p.zone(580, 90, 320, 230, "bank-dmz-prod · ns janus", "dmz");
  p.node("m-jmob", 600, 140, 280, 120, "janus-mobile ×1 · :8080\n/janus/splash\n/janus/secure-login\n/janus/mobile-login", "dmz", 10);

  p.zone(580, 340, 320, 310, "codevo-dmz · ns seal-mobile", "dmz");
  p.node("m-seal", 600, 400, 280, 150, "seal-mobile ×1 · :8443\nlogin/begin, login/pin, login/authorize\ncihaz mTLS, PIN, cihaz imzası", "dmz", 10);

  p.zone(920, 90, 320, 560, "bank-prod · ns auth", "identity");
  p.node("m-auth", 940, 140, 280, 160, "auth-server ×1 · :8443\nPKCE /auth, /token\nintrospection (oturum aktif mi)\ntek aktif giriş", "identity", 10);

  p.zone(1280, 90, 320, 560, "PLATFORM (host)", "host");
  p.node("m-fm", 1300, 140, 280, 130, "fortuna-mock (monolit) ×1 · :8443\nbridge-fortuna → 30890\n/seal-pm/* (PIN), secure-login,\nmobile-login, cihaz kaydı", "host", 10);
  p.node("m-ldb", 1300, 300, 280, 90, "legacydb ×1 · :5432\ncustomer_devices, pin_verifiers", "mgmt", 10);

  p.edge("m-app", "m-edge", "HTTPS :8443", "request");
  p.edge("m-kon", "m-edge", "mobil akışı", "request");
  p.edge("m-edge", "m-jmob", "mobile-api → ingress :30802", "request");
  p.edge("m-edge", "m-seal", "seal.lab.local → ingress :30456 (passthrough)", "request");
  p.edge("m-app", "m-auth", "PKCE, token (id.bank.lab.local :30543)", "request");
  p.edge("m-jmob", "m-fm", "secure-login, mobile-login", "request");
  p.edge("m-seal", "m-auth", "introspection :30543", "request");
  p.edge("m-seal", "m-fm", "PIN (/seal-pm/*) :30890", "request");
  p.edge("m-fm", "m-ldb", "cihaz kaydı, PIN", "request");
  p.edge("m-sms", "m-fm", "yeni cihaz OTP", "planned");

  p.text(40, 700, 1820, 60,
    "Akış: 1) splash (/janus/splash)  2) PKCE ile token (auth-server)  3) Seal: login/pin (PIN monolitte), login/authorize (cihaz imzası)  " +
    "4) secure-login ve mobile-login  5) client token. Yeni cihazda SMS kodu /sms sayfasından alınır, aktivasyon sonrası aynı akış tekrarlanır.",
    NOTE);
  return p.build();
}

function secretsAndData(Page) {
  const p = new Page("Lab · Sırlar ve veri");
  p.text(40, 14, 1800, 36, "Lab · sırlar, sertifikalar ve veri", TITLE);
  p.text(40, 52, 1800, 24, "Repoda sır yoktur. Sırlar Vault'ta ve Kubernetes secret'larında; sertifikalar iç CA ile üretilir (edge/certs, gitignore).", SUB);
  const rows = [
    ["Kaynak", "Yer", "İçerik", "Üreten / kullanan"],
    ["Vault KV v2 secret/auth/auth-server", "bank-prod · ns secrets", "IdP sırları (AUTH_* anahtarları, SEAL_B2B_SECRET, SEAL_MOBILE_SECRET)", "auth hook, up.sh / auth-server"],
    ["Vault KV v2 secret/seal/v3", "bank-prod · ns secrets", "SEAL_PM_KEY, SEAL_MOCK_KEY", "scripts/seal-keys.sh / seal-mobile, monolit"],
    ["auth-secrets, auth-tls, auth-signing", "bank-prod · ns auth", "k8s secret: sırlar, TLS keystore/truststore, imzalama anahtarı", "apps/auth-server/hook.sh"],
    ["janus-keys, janus-mtls-web/-mobile", "bank-dmz-prod · ns janus", "Janus server anahtarları (JANUS_KEY_*), istemci mTLS", "apps/janus/hook.sh"],
    ["channel-gateway-tls/-client, janus-verify", "bank-prod · ns channel", "mTLS sertifikaları, Janus doğrulama anahtarları", "apps/channel-gateway/hook.sh"],
    ["fortuna-*-tls, fortuna-*-client, fortuna-db, fortuna-seed", "bank-prod · ns channel", "Fortuna zinciri mTLS, DB parolası (.env), seed parolası", "apps/fortuna/hook.sh"],
    ["sm-tls, sm-device-ca, sm-internal-ca, sm-auth-client, sm-keys", "codevo-dmz · ns seal-mobile", "Seal Mobile sunucu, cihaz CA, istemci sertifikası, paylaşılan anahtarlar", "apps/seal-mobile/hook.sh"],
    ["seal-intranet-tls, si-mock, internal-ca-backend", "codevo-dmz · ns seal-intranet", "Seal Intranet sunucu sertifikası, mock anahtar, iç CA", "apps/seal-intranet/hook.sh"],
    ["platform/.env", "host", "LEGACYDB_PASSWORD, GRAFANA_ADMIN_PASSWORD, PM_KEY, SEAL_B2B_SECRET, düğüm IP'leri", "platform/scripts/up.sh (gitignore)"],
    ["LegacyDB (lab: PostgreSQL 16 · as-is: MSSQL)", "platform", "customers, accounts, fortuna_users, customer_devices, pin_verifiers, transactions", "monolit (services/legacy-monolith)"],
  ];
  const cell = (t, h) => h
    ? `<th style="border:1px solid #CBD5E1;padding:6px 10px;background:#F1F5F9;text-align:left">${t}</th>`
    : `<td style="border:1px solid #CBD5E1;padding:6px 10px;vertical-align:top">${t}</td>`;
  const html = `<table style="border-collapse:collapse;font-size:12.5px;font-family:Segoe UI;color:#1f1f1f">` +
    rows.map((r, i) => `<tr>${r.map((c) => cell(c, i === 0)).join("")}</tr>`).join("") + `</table>`;
  p.text(40, 100, 1820, 640, html, "text;html=1;align=left;verticalAlign=top;whiteSpace=wrap;");
  return p.build();
}

module.exports = { clusterStructure, ingressRules, channelWeb, channelMobile, secretsAndData };
