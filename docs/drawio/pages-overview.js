// Genel sayfalar: 1) mimari genel bakış, 2) I/O ve araçlar, 3) tüm cluster'lar ve namespace'ler.
const { Page } = require("./builder.js");

// ---------------------------------------------------------------------------
// 1) Genel mimari: 4 cluster + edge + host + gözlemlenebilirlik
// ---------------------------------------------------------------------------
function architecture() {
  const p = new Page("1 Genel mimari");
  p.text(20, 12, 1400, 34, "DMZ Lab: Mimari genel bakış (4 cluster, edge, host, şube zone)",
    "text;html=1;fontStyle=1;fontSize=18;align=left;verticalAlign=middle;fontColor=#0F172A;");
  p.text(20, 40, 1600, 22, "Lab durumu: kind cluster'ları ve docker compose edge. Prod farkları için design.md bölüm 15.2.",
    "text;html=1;fontSize=11;align=left;verticalAlign=middle;fontColor=#64748B;");

  // Bölgeler
  p.zone(20, 80, 205, 630, "İnternet / istemciler", "internet");
  p.zone(245, 80, 235, 630, "DMZ Edge (docker compose)", "edge");
  p.zone(500, 80, 415, 630, "DMZ cluster (kind-dmz)", "dmz");
  p.zone(935, 80, 395, 630, "İç cluster (kind-internal)", "internal");
  p.zone(1350, 80, 330, 630, "Operasyon (planlı / prod)", "ops");
  p.zone(500, 735, 415, 245, "Identity cluster (kind-identity)", "identity");
  p.zone(935, 735, 395, 245, "Mgmt / gözlemlenebilirlik (kind-mgmt)", "mgmt");
  p.zone(20, 735, 455, 245, "Şube cluster (kind-branch) · WAN üzerinden, HAProxy yok", "branch");
  p.zone(1350, 735, 330, 245, "Host (Windows): konsol ve testler", "host");

  // İstemciler
  p.node("c_web", 40, 125, 165, 52, "Web tarayıcı\n(PKCE, Bearer)", "client");
  p.node("c_mob", 40, 200, 165, 52, "Mobil uygulama\n(PKCE + DPoP)", "client");
  p.node("c_par", 40, 275, 165, 52, "Partner\n(mTLS + client credentials)", "client");
  p.node("c_any", 40, 350, 165, 52, "Anonim kullanıcı\n(token yok)", "client");

  // Edge
  p.node("ha", 265, 125, 195, 96, "HAProxy 3.0\nSNI passthrough · TLS · L7 limit\nhost yönlendirme", "edge");
  p.node("waf", 265, 245, 195, 58, "Coraza WAF\nOWASP CRS · SPOE", "edge");
  p.node("ddos", 265, 330, 195, 58, "DDoS / CDN\n[prod]", "planned");
  p.node("vip", 265, 415, 195, 58, "HA çifti · VRRP\n[prod]", "planned");

  // DMZ cluster
  p.node("gw_web", 515, 125, 180, 56, "gw-web\nTLS · route · ext-authz", "dmz");
  p.node("gw_mob", 720, 125, 180, 56, "gw-mobile\nTLS · route · ext-authz", "dmz");
  p.node("gw_par", 515, 200, 180, 56, "gw-partner\nmTLS (istemci sertifikası)", "dmz");
  p.node("gw_br", 720, 200, 180, 56, "gw-branch\nmTLS (cihaz sertifikası)", "dmz");
  p.node("ext", 515, 280, 385, 84, "ext-authz (ns: auth)\nRS256 (JWKS) · DPoP proof · token exchange (mTLS)\nkanal profilleri: web · mobile · partner · branch", "dmz");
  p.node("dmz_note", 515, 380, 385, 62, "Default deny: tanımsız yol 404.\n/public/* ve /realms/* iç gateway'e; /bff/* ve /partner/* ext-authz'den geçer.", "note");

  // İç cluster
  p.node("gi", 950, 125, 365, 78, "gw-internal\niç JWT doğrulama · RBAC (x-channel) · mTLS (DMZ kimliği)", "internal");
  p.node("bff", 950, 230, 170, 80, "BFF (app-bff)\n/bff/{web,mobile,branch}\nkanal şekillendirme", "internal");
  p.node("core", 1145, 230, 170, 80, "Core (app-core)\n/api/v1 · /partner · /public\nhesap, işlem, transfer", "internal");
  p.node("int_note", 950, 330, 365, 62, "İç token yalnız DMZ→iç bağlantıda ve iç ağda dolaşır; istemciye hiç dönmez.", "note");

  // Operasyon (planlı / prod)
  p.node("argo", 1370, 125, 290, 52, "Argo CD (GitOps) [planlı]", "planned");
  p.node("kyv", 1370, 190, 290, 52, "Kyverno (politika) [planlı]", "planned");
  p.node("eso", 1370, 255, 290, 52, "External Secrets (ESO) [prod]", "planned");
  p.node("pki", 1370, 320, 290, 52, "Vault PKI · kısa ömürlü sertifika [prod]", "planned");
  p.node("hsm", 1370, 385, 290, 52, "HSM / KMS · realm imza anahtarı (D-12) [prod]", "planned");

  // Identity
  p.node("kc", 520, 780, 375, 78, "Keycloak 26.6\nrealm bank · token exchange (standart V2 + SPI) · client-x509 · OTel", "identity");
  p.node("pg", 520, 880, 175, 62, "PostgreSQL 16\n[lab: emptyDir]", "identity");

  // Mgmt
  p.node("vault", 950, 780, 170, 70, "Vault 1.18\nKV v2 · identity secret'ları", "mgmt");
  p.node("prom", 1135, 780, 185, 70, "Prometheus\nmetrikler (cluster, namespace)", "mgmt");
  p.node("graf", 950, 880, 170, 70, "Grafana\ndashboard · Explore", "mgmt");
  p.node("tempo", 1135, 880, 185, 70, "Grafana Tempo\ntrace (OTLP HTTP/gRPC)", "mgmt");

  // Host
  p.node("branch", 40, 790, 420, 60, "Şube UI pod (branch-ui, kind-branch)\nistemci sertifikası (branch-device, CN=branch-ws-01)", "branch", 10);
  p.node("console", 1370, 780, 290, 56, "Operasyon konsolu\nport 9000 · organizer", "host");
  p.node("pf", 1370, 850, 290, 50, "kubectl port-forward\n18081 · 14318 · 3000", "host");
  p.node("tests", 1370, 915, 290, 50, "Test süitleri\nrun-all.sh (11 süit)", "host");

  // Firewall'lar
  p.fw("F1", 495, 150, "F1");
  p.fw("F2", 915, 150, "F2");
  p.fw("F8", 890, 760, "F8");
  p.fw("F9", 1105, 760, "F9");
  p.fw("F10", 468, 780, "F10");

  // İstemci → edge
  p.edge("c_web", "ha", "HTTPS 443 · dış token");
  p.edge("c_mob", "ha", "HTTPS 443 · DPoP");
  p.edge("c_par", "ha", "mTLS passthrough");
  p.edge("c_any", "ha", "HTTPS 443 · public");

  // Şube: HAProxy'den geçmez, doğrudan gw-branch (F10, cihaz mTLS)
  p.edge("branch", "gw_br", "WAN · F10 · mTLS (cihaz sertifikası)", "internal");

  // Edge → DMZ
  p.edge("ha", "gw_web", "F1 · TLS re-encrypt");
  p.edge("ha", "gw_mob", "F1 · TLS re-encrypt");
  p.edge("ha", "gw_par", "F1 · TCP passthrough");
  p.edge("ha", "gw_br", "F1 · TCP passthrough");
  p.edge("ha", "waf", "SPOE");

  // DMZ içi
  p.edge("gw_web", "ext", "ext-authz");
  p.edge("gw_mob", "ext", "ext-authz");
  p.edge("gw_par", "ext", "ext-authz");
  p.edge("gw_br", "ext", "ext-authz");
  p.edge("ext", "gi", "token exchange (mTLS) → iç JWT", "internal");
  p.edge("gw_web", "gi", "F2 · mTLS + iç JWT", "internal");
  p.edge("gw_mob", "gi", "F2 · mTLS + iç JWT", "internal");
  p.edge("gw_par", "gi", "F2 · mTLS + iç JWT", "internal");
  p.edge("gw_br", "gi", "F2 · mTLS + iç JWT", "internal");

  // İç
  p.edge("gi", "bff", "iç JWT", "internal");
  p.edge("gi", "core", "iç JWT", "internal");
  p.edge("bff", "core", "iç token (forward)", "internal");
  p.edge("gi", "kc", "/realms · JWKS · exchange · F8", "response");
  p.edge("kc", "pg", "JDBC");
  p.edge("vault", "kc", "identity secret (bootstrap)", "response");
  p.edge("ext", "kc", "exchange (client-x509)", "response");

  // Telemetri
  p.edge("ext", "tempo", "OTLP trace", "telemetry");
  p.edge("bff", "tempo", "OTLP trace", "telemetry");
  p.edge("core", "tempo", "OTLP trace", "telemetry");
  p.edge("prom", "ext", "scrape /metrics", "telemetry");
  p.edge("prom", "bff", "scrape /metrics", "telemetry");
  p.edge("graf", "prom", "PromQL", "telemetry");
  p.edge("graf", "tempo", "TraceQL", "telemetry");

  // Host
  p.edge("console", "ha", "HTTPS (kanal API'leri)");
  p.edge("pf", "kc", "admin / port-forward", "response");
  p.edge("pf", "tempo", "OTLP 14318 · Grafana 3000", "telemetry");
  p.edge("tests", "ha", "smoke / waf / lb", "response");

  // Lejant
  p.text(20, 995, 1660, 110,
    "<b>Lejant</b><br>" +
    "<span style='color:#334155'>━━ istek (HTTP/TLS)</span><br>" +
    "<span style='color:#B91C1C'><b>━━ iç JWT (yalnız iç ağda)</b></span><br>" +
    "<span style='color:#64748B'>╍╍ yanıt / bağımlılık</span><br>" +
    "<span style='color:#2563EB'>╍╍ telemetri (OTLP / metrik)</span><br>" +
    "<span style='color:#9CA3AF'>╍╍ planlı veya prod'a özgü</span><br>" +
    "<span style='color:#B91C1C'>■ F1 edge→DMZ · F2 DMZ→iç mTLS · F8 identity · F9 Vault</span>",
    "rounded=1;whiteSpace=wrap;html=1;align=left;verticalAlign=top;fillColor=#FFFFFF;strokeColor=#CBD5E1;fontSize=11;spacing=10;fontColor=#1F2937;");

  return p.build(20);
}

// ---------------------------------------------------------------------------
// 2) I/O, agent ve araçlar: her bileşen için girdi → bileşen → çıktı, yanında araçlar
// ---------------------------------------------------------------------------
const IO_ROWS = [
  { k: "ha", name: "HAProxy 3.0 (edge)", kind: "edge",
    inp: "TLS 443 istemci bağlantısı, SNI, HTTP istek; kanal ve host kuralları",
    out: "Yeniden şifrelenmiş istek → gw-web, gw-mobile\nTCP geçiş → gw-partner, gw-branch\nSPOE isteği → WAF",
    tools: "haproxy 3.0 · stick table (L4/L7 hız) · health check GET /public/branches" },
  { k: "waf", name: "Coraza WAF (SPOA)", kind: "edge",
    inp: "SPOE: HTTP başlık ve gövde",
    out: "allow / deny (403 waf-block)",
    tools: "coraza-spoa 0.9.1 · OWASP CRS" },
  { k: "gw", name: "kgateway gw-web / mobile / partner / branch", kind: "dmz",
    inp: "HTTPS istek; partner ve branch: istemci sertifikası (mTLS)",
    out: "/bff ve /partner → ext-authz çağrısı\n/public ve /realms → iç gateway (mTLS)",
    tools: "kgateway v2.5 (Envoy) · Gateway API v1.7 · HTTPRoute · TrafficPolicy" },
  { k: "ext", name: "ext-authz (auth, DMZ)", kind: "dmz",
    inp: "Bearer (web) veya DPoP proof + token (mobile); dış JWT (RS256, JWKS)",
    out: "İç JWT (exchange sonucu, yalnız iç ağda)\nHata: JSON gövde 401 / 403 / 5xx",
    tools: "Python stdlib · Keycloak token exchange (client-x509, mTLS) · OTLP · metrik" },
  { k: "gwi", name: "kgateway gw-internal", kind: "internal",
    inp: "DMZ mTLS istemci sertifikası + iç JWT",
    out: "Doğrulanmış kimlik; RBAC kararı (x-channel)\n/bff/* → BFF, /api/v1 → core",
    tools: "kgateway v2.5 · JWT authz · ListenerPolicy (mTLS, OTel tracing)" },
  { k: "bff", name: "BFF (app-bff)", kind: "internal",
    inp: "İç JWT + kanal (x-channel) + istek gövdesi",
    out: "Kanala göre yanıt (mobil sade, şube teller görünümü)\nCore çağrısı (iç token ile)",
    tools: "Python stdlib (svc.py) · shared/tracing.py · shared/metrics.py" },
  { k: "core", name: "Core (app-core), dummy API", kind: "internal",
    inp: "BFF veya partner isteği; Idempotency-Key (transfer)",
    out: "Hesap, işlem, transfer yanıtları (JSON)\nMetrik: transfer sayısı ve tutarı",
    tools: "Python stdlib · bellekte, sub bazlı deterministik hesap deposu" },
  { k: "kc", name: "Keycloak 26.6 (identity)", kind: "identity",
    inp: "Login (PKCE), client credentials, token exchange (client-x509), DPoP proof",
    out: "Access token (RS256), JWKS, exchange token; realm bank",
    tools: "Keycloak 26.6 · SPI dmz-dpop-mobile-exchange · PostgreSQL 16 · OTel" },
  { k: "vault", name: "Vault 1.18 (mgmt, secrets)", kind: "mgmt",
    inp: "init / unseal; KV v2 yazma (Keycloak parolaları)",
    out: "Identity secret'ları (load-vault.sh türetir)",
    tools: "vault CLI (betik) · KV v2 · keycloak politikası" },
  { k: "prom", name: "Prometheus 2.55 (mgmt)", kind: "mgmt",
    inp: "/metrics scrape: bff, core, ext-authz, kube-state-metrics",
    out: "PromQL sonuçları (Grafana'ya)",
    tools: "prom/prometheus v2.55.1 · static_configs (cluster, namespace etiketleri)" },
  { k: "tempo", name: "Grafana Tempo 2.6 (mgmt)", kind: "mgmt",
    inp: "OTLP span'ları: HTTP 30318, gRPC 30317",
    out: "TraceQL sonuçları; iz kimliğiyle erişim",
    tools: "grafana/tempo 2.6.1 · block_retention 48 saat" },
  { k: "graf", name: "Grafana 11.3 (mgmt)", kind: "mgmt",
    inp: "PromQL ve TraceQL sorguları; dashboard JSON (provizyon)",
    out: "Dashboard'lar: Genel Bakış, Dağıtık İzleme; Explore",
    tools: "grafana/grafana 11.3.0 · provisioned datasources (prometheus, tempo)" },
  { k: "ksm", name: "kube-state-metrics (internal, kube-system)", kind: "internal",
    inp: "API sunucusu list/watch (kısıtlı RBAC, secret okumaz)",
    out: "Cluster durum metrikleri (/metrics, NodePort 30904)",
    tools: "kube-state-metrics v2.13.0" },
  { k: "console", name: "Operasyon konsolu (host, :9000)", kind: "host",
    inp: "Organizer ve kanal girişleri, kullanıcı işlemleri",
    out: "Kanal API çağrıları (traceparent ile), Grafana iz bağlantısı",
    tools: "Python http.server · kubectl port-forward · shared/tracing.py" },
  { k: "branch", name: "Şube UI pod (branch cluster)", kind: "branch",
    inp: "Veznedar girişi (PKCE, branch-app); cihaz sertifikası (branch-device)",
    out: "gw-branch'e WAN üzerinden mTLS istek (F10, HAProxy yok)",
    tools: "branch-ui pod (python:3.12-alpine) · PKCE · probe.py (test) · cihaz sertifikası (branch-ca)" },
  { k: "gwbr", name: "kgateway gw-branch", kind: "dmz",
    inp: "Şube mTLS istemcisi (cihaz sertifikası, branch-ca doğrulama)",
    out: "/bff/* → ext-authz (branch profili); /realms/* → login",
    tools: "kgateway v2.5 (Envoy) · BackendTLSPolicy · ConfigMap branch-ca" },
  { k: "extb", name: "ext-authz branch profili (auth)", kind: "dmz",
    inp: "Dış token (aud channel-branch, RS256), X-Dmz-Channel=branch",
    out: "Token exchange sonucu iç JWT (channel=branch, auth_method=branch_cert)",
    tools: "Python stdlib · Keycloak exchange (dmz-exchange-branch, client-x509)" },
  { k: "tests", name: "Test süitleri (run-all.sh)", kind: "host",
    inp: "Çalışan cluster'lar, port-forward, sırlar",
    out: "Süit başına PASS / FAIL tablosu",
    tools: "bash · curl · openssl · kubectl exec" },
];

function ioTools() {
  const p = new Page("2 I/O, agent ve araçlar");
  p.text(20, 12, 1400, 34, "Bileşenler: girdi, çıktı ve araçlar",
    "text;html=1;fontStyle=1;fontSize=18;align=left;verticalAlign=middle;fontColor=#0F172A;");
  p.text(20, 40, 1500, 22, "Her satır bir agent/servis. Oklar: girdi → bileşen → çıktı. Sağda kullanılan araçlar.",
    "text;html=1;fontSize=11;align=left;verticalAlign=middle;fontColor=#64748B;");

  const COL = { inp: [20, 400], comp: [440, 230], out: [690, 420], tool: [1130, 330] };
  p.text(COL.inp[0], 70, COL.inp[1], 22, "<b>GİRDİ (input)</b>", "text;html=1;fontSize=12;align=left;fontColor=#334155;");
  p.text(COL.comp[0], 70, COL.comp[1], 22, "<b>BİLEŞEN (agent / servis)</b>", "text;html=1;fontSize=12;align=left;fontColor=#334155;");
  p.text(COL.out[0], 70, COL.out[1], 22, "<b>ÇIKTI (output)</b>", "text;html=1;fontSize=12;align=left;fontColor=#334155;");
  p.text(COL.tool[0], 70, COL.tool[1], 22, "<b>ARAÇLAR (tools)</b>", "text;html=1;fontSize=12;align=left;fontColor=#334155;");

  const Y0 = 100, PITCH = 78, H = 64;
  IO_ROWS.forEach((r, i) => {
    const y = Y0 + i * PITCH;
    const inId = p.io(`in_${r.k}`, COL.inp[0], y, COL.inp[1], H, r.inp, "input");
    const compId = p.node(r.k, COL.comp[0], y, COL.comp[1], H, r.name, r.kind, 11);
    const outId = p.io(`out_${r.k}`, COL.out[0], y, COL.out[1], H, r.out, "output");
    p.io(`tool_${r.k}`, COL.tool[0], y, COL.tool[1], H, r.tools, "tool");
    p.link(inId, compId, "", "endArrow=classic;html=1;strokeColor=#334155;strokeWidth=1.3;edgeStyle=none;");
    p.link(compId, outId, "", "endArrow=classic;html=1;strokeColor=#15803D;strokeWidth=1.3;edgeStyle=none;");
  });

  return p.build(20);
}

// ---------------------------------------------------------------------------
// 3) Tüm cluster'lar ve namespace'ler (yüksek seviye)
// ---------------------------------------------------------------------------
function allClusters() {
  const p = new Page("3 Tüm cluster'lar ve namespace'ler");
  p.text(20, 12, 1600, 34, "Tüm cluster'lar: namespace ve pod düzeyi (yüksek seviye)",
    "text;html=1;fontStyle=1;fontSize=18;align=left;verticalAlign=middle;fontColor=#0F172A;");
  p.text(20, 40, 1600, 22, "Her kutu bir namespace; içindeki kutular pod'lar. Detay için sonraki sayfalara bakın.",
    "text;html=1;fontSize=11;align=left;verticalAlign=middle;fontColor=#64748B;");

  // Cluster bölgeleri ve sütunları
  const cols = [
    { zone: "edge", title: "Edge (docker compose, host)", x: 20, w: 230, h: 900, color: "#B45309", kind: "edge",
      nss: [
        { name: "docker: dmz-edge-lab", color: "#B45309", pods: [
          { k: "e_ha", label: "haproxy (HAProxy 3.0)" },
          { k: "e_waf", label: "coraza-spoa (WAF)" },
        ] },
      ] },
    { zone: "dmz", title: "DMZ cluster (kind-dmz)", x: 270, w: 370, h: 900, color: "#C2410C", kind: "dmz",
      nss: [
        { name: "kgateway-system", color: "#C2410C", pods: [{ k: "d_kgw", label: "kgateway controller" }] },
        { name: "gw-web", color: "#C2410C", pods: [{ k: "d_gw_web", label: "gw-web (Envoy)" }] },
        { name: "gw-mobile", color: "#C2410C", pods: [{ k: "d_gw_mob", label: "gw-mobile (Envoy)" }] },
        { name: "gw-partner", color: "#C2410C", pods: [{ k: "d_gw_par", label: "gw-partner (Envoy)" }] },
        { name: "gw-branch", color: "#C2410C", pods: [{ k: "d_gw_br", label: "gw-branch (Envoy)" }] },
        { name: "auth", color: "#C2410C", pods: [{ k: "d_ext", label: "ext-authz (Python)" }] },
      ] },
    { zone: "internal", title: "İç cluster (kind-internal)", x: 660, w: 330, h: 900, color: "#1D4ED8", kind: "internal",
      nss: [
        { name: "kgateway-system", color: "#1D4ED8", pods: [{ k: "i_kgw", label: "kgateway controller" }] },
        { name: "gw-internal", color: "#1D4ED8", pods: [{ k: "i_gwi", label: "gw-internal (Envoy)" }] },
        { name: "app-bff", color: "#1D4ED8", pods: [{ k: "i_bff", label: "bff (svc.py)" }] },
        { name: "app-core", color: "#1D4ED8", pods: [{ k: "i_core", label: "core (svc.py)" }] },
        { name: "kube-system", color: "#1D4ED8", pods: [{ k: "i_ksm", label: "kube-state-metrics" }] },
      ] },
    { zone: "identity", title: "Identity cluster (kind-identity)", x: 1000, w: 240, h: 900, color: "#6D28D9", kind: "identity",
      nss: [
        { name: "auth", color: "#6D28D9", pods: [
          { k: "id_kc", label: "keycloak 26.6 (SPI)" },
          { k: "id_pg", label: "postgres 16" },
        ] },
      ] },
    { zone: "mgmt", title: "Mgmt cluster (kind-mgmt)", x: 1250, w: 300, h: 900, color: "#15803D", kind: "mgmt",
      nss: [
        { name: "secrets", color: "#15803D", pods: [{ k: "m_vault", label: "vault 1.18" }] },
        { name: "observability", color: "#15803D", pods: [
          { k: "m_prom", label: "prometheus 2.55" },
          { k: "m_tempo", label: "tempo 2.6" },
          { k: "m_graf", label: "grafana 11.3" },
        ] },
      ] },
    { zone: "host", title: "Host (Windows)", x: 1560, w: 300, h: 900, color: "#475569", kind: "host",
      nss: [
        { name: "konsol", color: "#475569", pods: [
          { k: "h_console", label: "operasyon konsolu :9000" },
          { k: "h_pf", label: "port-forward 18081/14318/3000" },
        ] },
        { name: "testler", color: "#475569", pods: [{ k: "h_tests", label: "run-all.sh (11 süit)" }] },
      ] },
    { zone: "branch", title: "Şube cluster (kind-branch)", x: 1880, w: 300, h: 900, color: "#0F766E", kind: "branch",
      nss: [
        { name: "branch", color: "#0F766E", pods: [
          { k: "b_ui", label: "şube UI pod (branch-ui) :9100" },
          { k: "b_dev", label: "cihaz sertifikası (branch-ws-01)" },
        ] },
      ] },
  ];

  const POD_H = 40, POD_GAP = 10, NS_PAD = 40, NS_GAP = 16;
  for (const c of cols) {
    p.zone(c.x, 80, c.w, c.h, c.title, c.zone);
    let y = 120;
    for (const ns of c.nss) {
      const nsH = NS_PAD + ns.pods.length * (POD_H + POD_GAP) + 8;
      p.ns(c.x + 20, y, c.w - 40, nsH, ns.name, ns.color);
      let py = y + NS_PAD;
      for (const pod of ns.pods) {
        p.node(pod.k, c.x + 36, py, c.w - 72, POD_H, pod.label, c.kind, 10);
        py += POD_H + POD_GAP;
      }
      y += nsH + NS_GAP;
    }
  }

  // Firewall rozetleri (kendi cluster sınırında)
  p.fw("F1_", 230, 150, "F1");
  p.fw("F2_", 620, 150, "F2");
  p.fw("F8_", 1040, 150, "F8");
  p.fw("F9_", 1300, 150, "F9");

  return p.build(20);
}

module.exports = { architecture, ioTools, allClusters };
