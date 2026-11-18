// V2 mimari sayfaları (güncel): (1) genel mimari, (2) namespace yerleşimi.
// Yerleşim kararları: Mobil kimlik süreçleri (OTP, yeni cihaz, aktivasyon, throttling, login durumu, kısıtlı token)
// IdP'de (identity). Seal Intranet ve Password Manager identity'de (yalnız IdP / gw-internal çağırır).
// Seal Mobile DMZ'de (cihaz mTLS passthrough). Core mobile iş API'leri app-bff (internal). bank-backend kaldırıldı.
const { Page } = require("./builder.js");

// ---------------------------------------------------------------------------
// V2-1) Genel mimari
// ---------------------------------------------------------------------------
function v2Architecture() {
  const p = new Page("V2 genel mimari");
  // Ok etiketleri: okun ortasında numara, sayfa altında açıklama listesi (etiketler düğümleri örtmesin)
  const flows = [];
  const E = (src, tgt, label, kind) => {
    flows.push([src, tgt, label || "", kind]);
    p.edge(src, tgt, "", kind);
  };
  p.text(20, 12, 1600, 34, "DMZ Lab V2: genel mimari (güncel durum, cluster'lar, workload'lar, TLS yolları)",
    "text;html=1;fontStyle=1;fontSize=18;align=left;verticalAlign=middle;fontColor=#0F172A;");
  p.text(20, 40, 1700, 22,
    "Düz çizgi: çalışan. Kesikli: planlı. Kırmızı kalın: mTLS / passthrough (TLS açılmaz). Seal ürünleri vendor mock.",
    "text;html=1;fontSize=11;align=left;verticalAlign=middle;fontColor=#64748B;");

  // Bölgeler
  p.zone(20, 80, 205, 560, "İstemciler", "internet");
  p.zone(245, 80, 250, 560, "DMZ Edge (docker compose)", "edge");
  p.zone(515, 80, 520, 520, "DMZ cluster (kind-dmz)", "dmz");
  p.zone(1055, 80, 520, 520, "İç cluster (kind-internal)", "internal");
  p.zone(1600, 80, 260, 520, "Host (Windows)", "host");
  p.zone(515, 620, 520, 330, "Identity cluster (kind-identity)", "identity");
  p.zone(1055, 620, 520, 260, "Mgmt (kind-mgmt)", "mgmt");
  p.zone(20, 660, 475, 220, "Şube cluster (kind-branch) · WAN, HAProxy yok", "branch");

  // İstemciler
  p.node("c_web", 40, 125, 165, 52, "Web tarayıcı\nPKCE · Bearer", "client");
  p.node("c_mob", 40, 195, 165, 52, "Mobil uygulama\nSeal SDK · PKCE + DPoP", "client");
  p.node("c_dev", 40, 265, 165, 52, "Cihaz istemcisi\nmTLS (cihaz CA sertifikası)", "client");
  p.node("c_par", 40, 335, 165, 52, "Partner\nmTLS + client credentials", "client");
  p.node("br_ui", 40, 700, 165, 60, "branch-ui (ns branch)\nveznedar · PKCE", "branch");

  // Edge
  p.node("ha", 265, 125, 210, 110, "HAProxy 3.0\nL7 TLS sonlandırma: web.lab.local, mobile-api.lab.local\nL4 SNI passthrough: partner-api, seal", "edge");
  p.node("pt", 265, 260, 210, 70, "SNI yönlendirme (L4)\npartner-api · seal.lab.local", "edge");
  p.node("waf", 265, 350, 210, 50, "WAF (mock, demo)\nuygulama katmanı yok", "edge");

  // DMZ cluster
  p.node("gw_web", 530, 125, 150, 56, "gw-web\nTLS · route · ext-authz", "dmz");
  p.node("gw_mob", 690, 125, 150, 56, "gw-mobile\nTLS · route · ext-authz", "dmz");
  p.node("gw_par", 850, 125, 170, 56, "gw-partner\nmTLS (partner-ca)", "dmz");
  p.node("gw_seal", 690, 200, 150, 56, "gw-seal\nTLS passthrough", "dmz");
  p.node("gw_br", 850, 200, 170, 56, "gw-branch\nmTLS cihaz · F10", "dmz");
  p.node("ext", 530, 280, 330, 70, "ext-authz (ns auth)\nRS256 · DPoP · KISIT (restricted → 403) · token exchange", "dmz");
  p.node("seal_mob", 530, 370, 490, 90, "seal-mobile (ns seal-mobile) [vendor mock]\nSDK arka ucu · cihaz mTLS · IdP token + DPoP doğrulama\nPIN (PM) · cihaz imzası · yeni cihaz / aktivasyon çağrıları IdP'ye", "dmz");
  p.node("dmz_note", 530, 480, 490, 50, "Default deny: tanımsız yol 404. /public ve /realms iç gateway'e; /bff ve /partner ext-authz'den geçer.", "note");

  // İç cluster
  p.node("gi", 1070, 125, 250, 80, "gw-internal (ns gw-internal)\nmTLS (DMZ kimliği) · iç JWT · /bff /realms /internal/auth /seal-pm", "internal");
  p.node("bff", 1070, 225, 160, 70, "app-bff (core mobile iş)\n/bff/{web,mobile,branch}", "internal");
  p.node("core", 1240, 225, 160, 70, "core (app-core)\nhesap · işlem · transfer", "internal");
  p.node("int_note", 1070, 410, 490, 60, "Kimlik süreçleri (OTP, aktivasyon, throttling, login durumu) IdP'de. bank-backend kaldırıldı. Düz HTTP: bff → core (mevcut açık).", "note");

  // Identity
  p.node("idp", 530, 660, 250, 90, "spring-idp (ns idp)\nparola · token · PKCE/DPoP · exchange · tek aktif giriş\nOTP · aktivasyon · throttling · akış durumu · kısıtlı token", "identity");
  p.node("pg", 800, 660, 110, 60, "postgres-idp\nPVC", "identity");
  p.node("si", 530, 770, 230, 60, "seal-intranet (ns seal-intranet) [mock]\nIdP çağırır · küme içi HTTPS", "identity");
  p.node("pm", 780, 770, 250, 60, "password-manager (ns seal-pm) [mock]\nyalnız PIN doğrulayıcı", "identity");

  // Mgmt
  p.node("vault", 1070, 660, 230, 70, "Vault (ns secrets)\nKV v2 · secret/identity, secret/seal", "mgmt");
  p.node("obs", 1320, 660, 240, 70, "Grafana · Prometheus · Tempo\n(ns observability)", "mgmt");
  p.node("mgmt_note", 1070, 750, 490, 60, "Tüm servisler OTLP ile Tempo'ya gider. Sırlar Vault'tan türetilir (ESO yok, lab sapması).", "note");

  // Host
  p.node("h_con", 1615, 125, 230, 70, "konsol (console/app.py)\nport-forward ile test", "host");
  p.node("h_test", 1615, 215, 230, 80, "Testler\nseal_v3.py · extauth.sh · api.sh\ndevice path · firewall", "host");

  // Akışlar
  E("c_web", "ha", "HTTPS :443 (web.lab.local)");
  E("c_mob", "ha", "HTTPS (mobile-api.lab.local)");
  E("c_dev", "pt", "SNI seal (cihaz mTLS)", "internal");
  E("c_par", "pt", "SNI partner-api");
  E("br_ui", "gw_br", "WAN · cihaz mTLS (F10)", "internal");
  E("ha", "gw_web", "yeniden şifreleme · mTLS");
  E("ha", "gw_mob", "yeniden şifreleme · mTLS");
  E("pt", "gw_par", "L4 TCP");
  E("pt", "gw_seal", "L4 passthrough", "internal");
  E("gw_web", "ext", "ext-authz");
  E("gw_mob", "ext", "ext-authz");
  E("gw_br", "ext", "ext-authz (branch)");
  E("ext", "idp", "token exchange · introspection (mTLS)", "response");
  E("gw_web", "gi", "mTLS (BackendTLSPolicy)", "internal");
  E("gw_mob", "gi", "mTLS (BackendTLSPolicy)", "internal");
  E("gw_par", "gi", "mTLS", "internal");
  E("gw_seal", "seal_mob", "TLS passthrough (cihaz mTLS)", "internal");
  E("seal_mob", "gi", "/internal/auth · /seal-pm (DMZ mTLS)", "internal");
  E("gi", "bff", "HTTP (mevcut açık)");
  E("bff", "core", "HTTP (mevcut açık)");
  E("gi", "idp", "/internal/auth (HTTPS, CN=gw-internal)", "internal");
  E("gi", "pm", "/seal-pm (HTTPS)", "internal");
  E("idp", "si", "timestamp · aktivasyon token'ı (HTTPS, seal-b2b JWT)");
  E("si", "idp", "JWKS (HTTPS, küme içi)");
  E("seal_mob", "idp", "introspection (HTTPS)");
  E("idp", "pg", "JDBC");

  flows.forEach((f, i) => p.edgeMarker(f[0], f[1], i + 1));
  const half = Math.ceil(flows.length / 2);
  const line = (f, i) => `${i + 1}. ${f[2]}`;
  p.text(20, 1000, 900, 20, "Ok açıklamaları", "text;html=1;fontStyle=1;fontSize=12;align=left;verticalAlign=middle;fontColor=#0F172A;");
  p.text(20, 1022, 900, 14 * half + 10, flows.slice(0, half).map(line).join("\n"),
    "text;html=1;fontSize=10;align=left;verticalAlign=top;fontColor=#1F2937;");
  p.text(960, 1022, 900, 14 * (flows.length - half) + 10, flows.slice(half).map((f, i) => line(f, i + half)).join("\n"),
    "text;html=1;fontSize=10;align=left;verticalAlign=top;fontColor=#1F2937;");
  return p.build(20);
}

// ---------------------------------------------------------------------------
// V2-2) Namespace yerleşimi
// ---------------------------------------------------------------------------
function v2Namespaces() {
  const p = new Page("V2 namespace yerleşimi");
  p.text(20, 12, 1400, 34, "DMZ Lab V2: namespace ve workload yerleşimi (güncel)",
    "text;html=1;fontStyle=1;fontSize=18;align=left;verticalAlign=middle;fontColor=#0F172A;");
  p.text(20, 40, 1400, 22, "Her kutu bir namespace. Kesikli çerçeve: namespace, içindeki kutu: workload.",
    "text;html=1;fontSize=11;align=left;verticalAlign=middle;fontColor=#64748B;");

  // DMZ
  p.zone(20, 70, 560, 450, "DMZ cluster (kind-dmz)", "dmz");
  p.ns(40, 100, 240, 60, "ns gw-web", "#C2410C");
  p.node("d_gweb", 52, 124, 216, 26, "gw-web (kgateway proxy)", "dmz", 9);
  p.ns(300, 100, 260, 60, "ns gw-mobile", "#C2410C");
  p.node("d_gmob", 312, 124, 236, 26, "gw-mobile (kgateway proxy)", "dmz", 9);
  p.ns(40, 175, 240, 60, "ns gw-partner", "#C2410C");
  p.node("d_gpar", 52, 199, 216, 26, "gw-partner (kgateway proxy)", "dmz", 9);
  p.ns(300, 175, 260, 60, "ns gw-branch", "#C2410C");
  p.node("d_gbr", 312, 199, 236, 26, "gw-branch (kgateway proxy)", "dmz", 9);
  p.ns(300, 250, 260, 60, "ns gw-seal (passthrough)", "#C2410C");
  p.node("d_gseal", 312, 274, 236, 26, "gw-seal (TLS passthrough)", "dmz", 9);
  p.ns(40, 325, 240, 60, "ns auth", "#C2410C");
  p.node("d_ext", 52, 349, 216, 26, "ext-authz (kısıt kontrolü)", "dmz", 9);
  p.ns(300, 325, 260, 60, "ns seal-mobile [mock]", "#C2410C");
  p.node("d_sm", 312, 349, 236, 26, "seal-mobile (cihaz mTLS)", "dmz", 9);
  p.ns(40, 400, 520, 60, "ns gw-internal istemcisi: internal-gw Service → 30444 (DMZ istemci sertifikası)", "#C2410C");
  p.text(50, 428, 500, 22, "gw-web, gw-mobile, gw-partner, seal-mobile → iç gateway (mTLS)", "text;html=1;fontSize=9;fontColor=#9A3412;");

  // İç
  p.zone(600, 70, 560, 450, "İç cluster (kind-internal)", "internal");
  p.ns(620, 100, 240, 110, "ns gw-internal", "#1D4ED8");
  p.node("i_gi", 632, 124, 216, 26, "gw-internal (kgateway proxy)", "internal", 9);
  p.node("i_gpm", 632, 186, 216, 18, "route: /internal/auth · /seal-pm → identity", "note", 8);
  p.ns(880, 100, 260, 60, "ns app-bff", "#1D4ED8");
  p.node("i_bff", 892, 124, 236, 26, "app-bff (core mobile iş API'leri)", "internal", 9);
  p.ns(880, 175, 260, 60, "ns app-core", "#1D4ED8");
  p.node("i_core", 892, 199, 236, 26, "core", "internal", 9);
  p.text(620, 300, 520, 150,
    "<b>Notlar</b><br>• bank-backend kaldırıldı; kimlik süreçleri IdP'de.<br>" +
    "• app-bff ve core arasında düz HTTP sürüyor (mevcut açık).<br>" +
    "• gw-internal, DMZ'den yalnız mTLS istemci sertifikasıyla kabul eder; IdP'ye kendi sertifikasıyla gider.",
    "text;html=1;fontSize=11;align=left;verticalAlign=top;fontColor=#1F2937;");

  // Identity
  p.zone(20, 540, 560, 330, "Identity cluster (kind-identity)", "identity");
  p.ns(40, 570, 240, 110, "ns idp", "#6D28D9");
  p.node("g_idp", 52, 594, 216, 26, "spring-idp (OIDC, OTP, aktivasyon)", "identity", 9);
  p.node("g_pg", 52, 626, 216, 26, "postgres-idp (PVC)", "identity", 9);
  p.ns(300, 645, 260, 60, "ns seal-pm [mock]", "#6D28D9");
  p.node("g_pm", 312, 669, 236, 26, "password-manager (PIN)", "identity", 9);
  p.ns(40, 700, 240, 60, "ns seal-intranet [mock]", "#6D28D9");
  p.node("g_si", 52, 724, 216, 26, "seal-intranet (IdP çağırır)", "identity", 9);
  p.text(300, 720, 260, 60, "PIN yalnız doğrulayıcı; kullanıcı parolası IdP'de.",
    "text;html=1;fontSize=10;align=left;verticalAlign=top;fontColor=#5B21B6;");

  // Mgmt
  p.zone(600, 540, 560, 260, "Mgmt (kind-mgmt)", "mgmt");
  p.ns(620, 570, 240, 60, "ns secrets", "#15803D");
  p.node("g_vault", 632, 594, 216, 26, "vault (KV v2)", "mgmt", 9);
  p.ns(880, 570, 260, 60, "ns observability", "#15803D");
  p.node("g_obs", 892, 594, 236, 26, "grafana · prometheus · tempo", "mgmt", 9);
  p.text(620, 650, 520, 120, "Sırlar: secret/identity/idp, secret/seal/v3. Tüm servislerin OTLP izleri Tempo'ya gider.",
    "text;html=1;fontSize=10;align=left;verticalAlign=top;fontColor=#166534;");

  // Şube
  p.zone(1180, 70, 380, 200, "Şube cluster (kind-branch)", "branch");
  p.ns(1200, 100, 340, 60, "ns branch", "#0F766E");
  p.node("b_ui", 1212, 124, 316, 26, "branch-ui (veznedar)", "branch", 9);
  p.text(1200, 170, 350, 90, "WAN üzerinden gw-branch'e (F10). HAProxy yok.",
    "text;html=1;fontSize=10;align=left;verticalAlign=top;fontColor=#115E59;");

  // Host
  p.zone(1180, 300, 380, 200, "Host (Windows)", "host");
  p.node("h_k", 1200, 340, 340, 40, "konsol (console/app.py) · port-forward", "host", 10);
  p.node("h_t", 1200, 395, 340, 50, "testler: seal_v3.py, extauth.sh, api.sh, firewall", "host", 10);

  return p.build(20);
}

module.exports = { v2Architecture, v2Namespaces };
