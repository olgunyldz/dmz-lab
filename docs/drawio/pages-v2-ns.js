// V2 kuzey-güney mimari sayfası: dış istemciler en üstte (kuzey), iç katmanlar aşağıya doğru (güney).
// Her bant bir katman: İstemci -> Edge -> DMZ -> İç -> Identity -> Mgmt. Oklar numaralı; açıklamalar sağda.
// Aynı bant içindeki yatay oklar doğu-batı (aynı katman) trafiğidir.
const { Page } = require("./builder.js");

const NL = String.fromCharCode(10); // satır sonu (etiketler tek satır; yalnızca açıklama listesi çok satırlı)

function v2NorthSouth() {
  const p = new Page("V2 kuzey-güney mimari");
  const flows = [];
  const E = (src, tgt, label, kind) => {
    flows.push([src, tgt, label, kind]);
    p.edge(src, tgt, "", kind);
  };

  p.text(20, 12, 1300, 34, "DMZ Lab V2: kuzey-güney mimari (dış → iç katmanlar)",
    "text;html=1;fontStyle=1;fontSize=18;align=left;verticalAlign=middle;fontColor=#0F172A;");
  p.text(20, 46, 1300, 22,
    "Yukarıdan aşağıya: dış trafik (kuzey) → edge → DMZ → iç → identity → mgmt. Numaralar oklarda; açıklamalar sağda.",
    "text;html=1;fontSize=11;align=left;verticalAlign=middle;fontColor=#64748B;");

  // --- Katmanlar (bantlar) ---
  p.zone(20, 70, 1300, 110, "KUZEY · dış istemciler", "internet");
  p.zone(20, 200, 1300, 90, "EDGE · HAProxy (docker compose)", "edge");
  p.zone(20, 310, 1300, 150, "DMZ cluster (kind-dmz)", "dmz");
  p.zone(20, 480, 1300, 120, "İÇ cluster (kind-internal)", "internal");
  p.zone(20, 620, 1300, 150, "IDENTITY cluster (kind-identity)", "identity");
  p.zone(20, 790, 1300, 90, "MGMT (kind-mgmt)", "mgmt");

  // --- Dış istemciler ---
  p.node("c_web", 40, 110, 200, 56, "Web tarayıcı · PKCE · Bearer", "client");
  p.node("c_mob", 260, 110, 200, 56, "Mobil uygulama · Seal SDK · PKCE", "client");
  p.node("c_dev", 480, 110, 200, 56, "Cihaz istemcisi · cihaz mTLS", "client");
  p.node("c_par", 700, 110, 200, 56, "Partner · mTLS + client credentials", "client");
  p.node("c_br", 920, 110, 200, 56, "Şube UI (branch-ui) · WAN · F10", "branch");

  // --- Edge ---
  p.node("ha", 40, 230, 420, 46, "HAProxy L7: web.lab.local, mobile-api.lab.local · TLS sonlandırma · mTLS", "edge");
  p.node("pt", 480, 230, 420, 46, "HAProxy L4: SNI passthrough · partner-api, seal.lab.local", "edge");

  // --- DMZ ---
  p.node("gw_web", 40, 340, 180, 56, "gw-web · TLS · route · ext-authz", "dmz");
  p.node("gw_mob", 240, 340, 180, 56, "gw-mobile · TLS · route · ext-authz", "dmz");
  p.node("gw_par", 440, 340, 180, 56, "gw-partner · mTLS (partner-ca)", "dmz");
  p.node("gw_br", 640, 340, 180, 56, "gw-branch · mTLS cihaz · F10", "dmz");
  p.node("gw_seal", 840, 340, 180, 56, "gw-seal · TLS passthrough", "dmz");
  p.node("ext", 40, 412, 380, 36, "ext-authz: RS256 · kısıt · exchange", "dmz");
  p.node("sm", 440, 412, 580, 36, "seal-mobile: cihaz mTLS · IdP token · PIN / cihaz imzası", "dmz");

  // --- İç ---
  p.node("gwi", 40, 510, 380, 60, "gw-internal · mTLS (DMZ kimliği) · iç JWT · /internal/auth · /seal-pm", "internal");
  p.node("bff", 440, 510, 280, 60, "app-bff · core mobile iş API'leri", "internal");
  p.node("core", 740, 510, 280, 60, "core (app-core) · hesap · işlem · transfer", "internal");

  // --- Identity ---
  p.node("idp", 40, 650, 420, 80, "spring-idp · parola · token · PKCE · exchange · OTP · aktivasyon · throttling · kısıtlı token", "identity");
  p.node("pg", 500, 650, 160, 80, "postgres-idp · PVC", "identity");
  p.node("si", 700, 650, 200, 80, "seal-intranet [mock] · IdP çağırır (HTTPS)", "identity");
  p.node("pm", 940, 650, 240, 80, "password-manager [mock] · yalnız PIN doğrulayıcı", "identity");

  // --- Mgmt ---
  p.node("vault", 40, 820, 320, 46, "Vault (KV v2) · secret/identity, secret/seal", "mgmt");
  p.node("obs", 400, 820, 500, 46, "Grafana · Prometheus · Tempo · OTLP izleri tüm servislerden", "mgmt");

  // --- Kuzey → güney akışları ---
  E("c_web", "ha", "HTTPS :443 (web.lab.local)");
  E("c_mob", "ha", "HTTPS (mobile-api.lab.local)");
  E("c_dev", "pt", "SNI seal · cihaz mTLS", "internal");
  E("c_par", "pt", "SNI partner-api");
  E("c_br", "gw_br", "WAN · cihaz mTLS (F10)", "internal");
  E("ha", "gw_web", "yeniden şifreleme · mTLS");
  E("ha", "gw_mob", "yeniden şifreleme · mTLS");
  E("pt", "gw_par", "L4 TCP");
  E("pt", "gw_seal", "L4 passthrough (cihaz mTLS)", "internal");
  E("gw_web", "ext", "ext-authz");
  E("gw_mob", "ext", "ext-authz");
  E("gw_seal", "sm", "TLS passthrough", "internal");
  E("gw_web", "gwi", "mTLS (BackendTLSPolicy)", "internal");
  E("gw_par", "gwi", "mTLS", "internal");
  E("sm", "gwi", "/internal/auth · /seal-pm (DMZ mTLS)", "internal");
  E("ext", "idp", "token exchange (HTTPS, XFCC ile istemci sertifikası)", "response");
  E("gwi", "bff", "HTTPS (iç CA)", "internal");
  E("bff", "core", "HTTPS (iç CA)", "internal");
  E("gwi", "idp", "/realms · /internal/auth (HTTPS, CN=gw-internal)", "internal");
  E("gwi", "pm", "/seal-pm (HTTPS)", "internal");
  E("idp", "si", "timestamp · aktivasyon (seal-b2b JWT)");
  E("idp", "pg", "JDBC");

  flows.forEach((f, i) => p.edgeMarker(f[0], f[1], i + 1));

  // --- Açıklama listesi (sağ sütun, iki kolon) ---
  const half = Math.ceil(flows.length / 2);
  const line = (f, i) => `${i + 1}. ${f[2]}`;
  p.text(1340, 70, 540, 22, "Kuzey → güney akışları", "text;html=1;fontStyle=1;fontSize=12;align=left;verticalAlign=middle;fontColor=#0F172A;");
  p.text(1340, 96, 540, 14 * half + 10, flows.slice(0, half).map(line).join(NL),
    "text;html=1;fontSize=10;align=left;verticalAlign=top;fontColor=#1F2937;");
  p.text(1340, 96 + 14 * half + 24, 540, 14 * (flows.length - half) + 10,
    flows.slice(half).map((f, i) => line(f, i + half)).join(NL),
    "text;html=1;fontSize=10;align=left;verticalAlign=top;fontColor=#1F2937;");

  return p.build(20);
}

module.exports = { v2NorthSouth };
