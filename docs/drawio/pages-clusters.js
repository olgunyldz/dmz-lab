// Cluster içi sayfalar: DMZ, internal, identity, mgmt (namespace + pod) ve pod içi detay (container + bağlı kaynaklar).
const { Page } = require("./builder.js");

// ---------------------------------------------------------------------------
// 4) DMZ cluster içi
// ---------------------------------------------------------------------------
function dmzCluster() {
  const p = new Page("4 DMZ cluster içi");
  p.text(20, 12, 1300, 34, "DMZ cluster içi: namespace ve pod'lar (kind-dmz)",
    "text;html=1;fontStyle=1;fontSize=18;align=left;verticalAlign=middle;fontColor=#0F172A;");
  p.text(20, 40, 1300, 22, "Node'lar: 172.18.0.2, .3, .4. Girişi yalnız HAProxy edge'den (F1, NodePort 30446–30449).",
    "text;html=1;fontSize=11;align=left;verticalAlign=middle;fontColor=#64748B;");

  p.zone(20, 70, 1240, 640, "DMZ cluster (kind-dmz)", "dmz");
  p.fw("f1", 36, 100, "F1");

  p.ns(40, 120, 250, 110, "kgateway-system", "#C2410C");
  p.node("kgw", 60, 160, 210, 50, "kgateway controller\nGatewayClass kgateway · v2.5.0", "dmz", 10);

  p.ns(310, 120, 300, 150, "gw-web", "#C2410C");
  p.node("gw_web", 330, 160, 260, 70, "gw-web pod (Envoy)\nlistener 443 · TLS sonlandırma (gw-web-tls)", "dmz", 10);
  p.resource("gw_web_r", 330, 238, 260, 25, "HTTPRoute: /bff, /partner, /public, /realms");

  p.ns(310, 290, 300, 110, "gw-mobile", "#C2410C");
  p.node("gw_mob", 330, 330, 260, 60, "gw-mobile pod (Envoy)\nlistener 443 · DPoP yolu", "dmz", 10);

  p.ns(630, 120, 260, 110, "gw-partner", "#C2410C");
  p.node("gw_par", 650, 160, 220, 50, "gw-partner pod\nmTLS (partner-ca)", "dmz", 10);

  p.ns(630, 250, 260, 110, "gw-branch", "#C2410C");
  p.node("gw_br", 650, 290, 220, 50, "gw-branch pod\nmTLS (branch-ca) · NodePort 30449", "dmz", 10);

  p.ns(910, 120, 330, 300, "auth", "#C2410C");
  p.node("ext", 930, 160, 290, 70, "ext-authz pod (Python stdlib)\n:8080 API · :9100 metrik", "dmz", 10);
  p.resource("ext_r", 930, 250, 290, 150,
    "Bağlı kaynaklar:\nConfigMap ext-authz-code\nSecret dmz-exchange-client-tls\nConfigMap internal-ca\nSecret dmz-gateway-client-tls\nService ext-authz-metrics (NodePort 30903)");

  // Zone dışı: iç cluster ve identity (bağlantı noktaları)
  p.node("ext_gwi", 1290, 140, 220, 70, "gw-internal\n(kind-internal)\nF2: mTLS + iç JWT", "internal", 10);
  p.node("ext_kc", 1290, 300, 220, 70, "Keycloak\n(kind-identity)\ntoken exchange", "identity", 10);
  p.node("ext_branch", 1290, 440, 220, 70, "Şube cluster (kind-branch)\nWAN · HAProxy yok · F10 mTLS", "branch", 10);

  p.edge("gw_web", "ext", "ext-authz");
  p.edge("gw_mob", "ext", "ext-authz");
  p.edge("gw_par", "ext", "ext-authz");
  p.edge("gw_br", "ext", "ext-authz (branch profili)");
  p.edge("ext_branch", "gw_br", "F10 · mTLS (cihaz sertifikası)");
  p.edge("ext", "ext_gwi", "token exchange → iç JWT (mTLS)", "internal");
  p.edge("gw_web", "ext_gwi", "/public, /realms (F2 mTLS)", "internal");
  p.edge("ext", "ext_kc", "exchange (client-x509)", "response");

  p.text(40, 400, 1200, 300,
    "<b>Notlar</b><br>" +
    "• Varsayılan deny: tanımsız yol 404. /bff/* ve /partner/* ext-authz'den geçer; /public/* (yalnız GET) ve /realms/* ext-authz'siz iç gateway'e gider.<br>" +
    "• Kanal NodePort'ları: web 30446, mobile 30447, partner 30448, branch 30449. F1 kuralı yalnız edge IP'sinden bu portlara izin verir.<br>" +
    "• İç backend: Service/Endpoints 172.18.0.10:30444 (gw-internal NodePort), BackendTLSPolicy hostname gw-internal.<br>" +
    "• ext-authz hata yanıtları JSON gövdeyle döner (error, error_description, layer: dmz-ext-authz).<br>" +
    "• Tracing: gateway'ler ListenerPolicy ile OTLP/gRPC span gönderir (Tempo, 30317). traceparent ve x-request-id ext-authz'e iletilir.",
    "text;html=1;fontSize=12;align=left;verticalAlign=top;fontColor=#1F2937;");

  return p.build(20);
}

// ---------------------------------------------------------------------------
// 5) İç cluster içi
// ---------------------------------------------------------------------------
function internalCluster() {
  const p = new Page("5 İç cluster içi");
  p.text(20, 12, 1300, 34, "İç cluster içi: namespace ve pod'lar (kind-internal)",
    "text;html=1;fontStyle=1;fontSize=18;align=left;verticalAlign=middle;fontColor=#0F172A;");
  p.text(20, 40, 1300, 22, "Node'lar: 172.18.0.8, .9, .10. Girişi yalnız DMZ'den (F2 mTLS, NodePort 30444).",
    "text;html=1;fontSize=11;align=left;verticalAlign=middle;fontColor=#64748B;");

  p.zone(20, 70, 1040, 640, "İç cluster (kind-internal)", "internal");
  p.fw("f2", 1000, 100, "F2");

  p.ns(40, 120, 240, 110, "kgateway-system", "#1D4ED8");
  p.node("kgw", 60, 160, 200, 50, "kgateway controller\nv2.5.0", "internal", 10);

  p.ns(300, 120, 330, 190, "gw-internal", "#1D4ED8");
  p.node("gwi", 320, 160, 290, 80, "gw-internal pod (Envoy)\nlistener 443 · istemci sertifikası zorunlu\nRBAC: x-channel eşleşmesi", "internal", 10);
  p.resource("gwi_r", 320, 250, 290, 50, "Secret gw-internal-tls · ConfigMap dmz-client-ca\nService identity-keycloak → 172.18.0.5:30080");

  p.ns(650, 120, 180, 190, "app-bff", "#1D4ED8");
  p.node("bff", 665, 160, 150, 80, "bff (svc.py)\nkanal şekillendirme\n:8080 · :9100", "internal", 10);
  p.resource("bff_r", 665, 250, 150, 50, "ConfigMap svc-code");

  p.ns(850, 120, 190, 190, "app-core", "#1D4ED8");
  p.node("core", 865, 160, 160, 80, "core (svc.py)\ndummy API · :8080 · :9100", "internal", 10);
  p.resource("core_r", 865, 250, 160, 50, "ConfigMap svc-code\nbellek deposu");

  p.ns(40, 260, 240, 110, "kube-system", "#1D4ED8");
  p.node("ksm", 60, 300, 200, 50, "kube-state-metrics\n:8080 · NodePort 30904", "internal", 10);

  // Zone dışı bağlantılar
  p.node("x_dmz", 1100, 400, 200, 60, "DMZ gateway'leri\n(kind-dmz)", "dmz", 10);
  p.node("x_kc", 1100, 520, 200, 60, "Keycloak\n(kind-identity)", "identity", 10);
  p.node("x_prom", 1100, 130, 200, 70, "Prometheus\n(kind-mgmt)\nscrape 30901 / 30902 / 30904", "mgmt", 10);
  p.node("x_tempo", 1100, 250, 200, 70, "Grafana Tempo\n(kind-mgmt)\nOTLP 30318", "mgmt", 10);

  p.edge("x_dmz", "gwi", "F2 · mTLS + iç JWT", "internal");
  p.edge("gwi", "bff", "iç JWT (/bff/web|mobile|branch)", "internal");
  p.edge("gwi", "core", "iç JWT (/api/v1, /partner, /public)", "internal");
  p.edge("bff", "core", "iç token (forward)", "internal");
  p.edge("gwi", "x_kc", "/realms · JWKS", "response");
  p.edge("x_prom", "bff", "scrape /metrics", "telemetry");
  p.edge("x_prom", "core", "scrape /metrics", "telemetry");
  p.edge("x_prom", "ksm", "scrape /metrics", "telemetry");
  p.edge("bff", "x_tempo", "OTLP trace", "telemetry");
  p.edge("core", "x_tempo", "OTLP trace", "telemetry");
  p.edge("gwi", "x_tempo", "OTLP trace (gateway)", "telemetry");

  p.text(40, 400, 1000, 300,
    "<b>Notlar</b><br>" +
    "• Yetkilendirme: /bff/web, /bff/mobile, /bff/branch yolları her biri yalnız kendi x-channel değerini kabul eder.<br>" +
    "• Her servis iç JWT'yi kendisi de doğrular (iss, aud, exp, kanal); hata gövdesi JSON (layer: internal-service).<br>" +
    "• Dummy iş API'si (core): hesap, işlem ve transfer. Transfer için Idempotency-Key zorunlu; kanal limitleri CHANNEL_LIMITS ile.<br>" +
    "• NodePort'lar: gw-internal 30444 (DMZ'den), bff metrik 30901, core metrik 30902, kube-state-metrics 30904.<br>" +
    "• İç token bu cluster'dan dışarı çıkmaz (yalnız iç ağda dolaşır).",
    "text;html=1;fontSize=12;align=left;verticalAlign=top;fontColor=#1F2937;");

  return p.build(20);
}

// ---------------------------------------------------------------------------
// 6) Identity cluster içi
// ---------------------------------------------------------------------------
function identityCluster() {
  const p = new Page("6 Identity cluster içi");
  p.text(20, 12, 1300, 34, "Identity cluster içi: namespace ve pod'lar (kind-identity)",
    "text;html=1;fontStyle=1;fontSize=18;align=left;verticalAlign=middle;fontColor=#0F172A;");
  p.text(20, 40, 1300, 22, "Node'lar: 172.18.0.5, .6, .7. Keycloak yalnız iç node'lardan ve DMZ'nin iç kanalından erişilir (F8).",
    "text;html=1;fontSize=11;align=left;verticalAlign=middle;fontColor=#64748B;");

  p.zone(20, 70, 800, 500, "Identity cluster (kind-identity)", "identity");
  p.fw("f8", 36, 100, "F8");

  p.ns(40, 130, 740, 300, "auth", "#6D28D9");
  p.node("kc", 60, 170, 380, 110, "Keycloak 26.6 pod\nimaj: dmz-lab/keycloak-dpop:26.6\nrealm bank · SPI · OTel · :8080", "identity", 10);
  p.resource("kc_r", 60, 300, 380, 110, "Secret keycloak-db, keycloak-admin (Vault türevi)\nNodePort keycloak-nodeport 30080\nSPI: dmz-dpop-mobile-exchange (order 100)");
  p.node("pg", 460, 170, 260, 110, "PostgreSQL 16 pod\nemptyDir (lab)\n:5432", "identity", 10);
  p.resource("pg_r", 460, 300, 260, 110, "Secret keycloak-db (JDBC parolası)\nlab: restart'ta veri gider");

  p.node("x_vault", 900, 130, 220, 70, "Vault 1.18\n(kind-mgmt)\nidentity secret bootstrap", "mgmt", 10);
  p.node("x_gwi", 900, 250, 220, 70, "gw-internal\n(kind-internal)\n/realms · JWKS · exchange", "internal", 10);
  p.node("x_ext", 900, 370, 220, 70, "ext-authz\n(kind-dmz)\ntoken exchange (client-x509)", "dmz", 10);
  p.node("x_pf", 900, 470, 220, 50, "Konsol / admin\nport-forward 18081", "host", 10);

  p.edge("kc", "pg", "JDBC");
  p.edge("x_vault", "kc", "identity secret (bootstrap)", "response");
  p.edge("x_gwi", "kc", "/realms · JWKS · exchange", "response");
  p.edge("x_ext", "kc", "exchange (client-x509, mTLS)", "response");
  p.edge("x_pf", "kc", "admin / port-forward", "response");

  p.text(40, 590, 800, 150,
    "<b>Notlar</b><br>" +
    "• Realm bank client'ları: web-app, mobile-app (PKCE + DPoP), branch-app, partner-acme (client credentials), dmz-exchange-{web,mobile,partner,branch} (client-x509), bff, core-svc, kgateway-internal.<br>" +
    "• Kullanıcılar (lab): alice, teller. Parolalar keycloak-client-secrets secret'ında, repo'da yok.",
    "text;html=1;fontSize=12;align=left;verticalAlign=top;fontColor=#1F2937;");

  return p.build(20);
}

// ---------------------------------------------------------------------------
// 7) Mgmt cluster içi
// ---------------------------------------------------------------------------
function mgmtCluster() {
  const p = new Page("7 Mgmt cluster içi");
  p.text(20, 12, 1300, 34, "Mgmt cluster içi: namespace ve pod'lar (kind-mgmt)",
    "text;html=1;fontStyle=1;fontSize=18;align=left;verticalAlign=middle;fontColor=#0F172A;");
  p.text(20, 40, 1300, 22, "Node'lar: 172.18.0.12, .13, .14. Vault yalnız identity ve internal node'lardan erişilir (F9).",
    "text;html=1;fontSize=11;align=left;verticalAlign=middle;fontColor=#64748B;");

  p.zone(20, 70, 960, 540, "Mgmt cluster (kind-mgmt)", "mgmt");
  p.fw("f9", 36, 100, "F9");

  p.ns(40, 130, 260, 220, "secrets", "#15803D");
  p.node("vault", 60, 170, 220, 70, "Vault 1.18 pod\nKV v2 · :8200 · NodePort 30200", "mgmt", 10);
  p.resource("vault_r", 60, 260, 220, 70, "emptyDir (lab)\nSecret vault-bootstrap (unseal anahtarı, root token)");

  p.ns(330, 130, 650, 440, "observability", "#15803D");
  p.node("prom", 350, 170, 190, 110, "Prometheus 2.55 pod\nNodePort 30090 · retention 2 gün", "mgmt", 10);
  p.resource("prom_r", 350, 300, 190, 80, "ConfigMap prometheus-config\n(5 scrape hedefi)");
  p.node("tempo", 560, 170, 190, 110, "Grafana Tempo 2.6 pod\nOTLP 4318 / 4317\nNodePort 30318 / 30317", "mgmt", 10);
  p.resource("tempo_r", 560, 300, 190, 80, "ConfigMap tempo.yaml\nemptyDir · block_retention 48 saat");
  p.node("graf", 770, 170, 190, 110, "Grafana 11.3 pod\nNodePort 30300", "mgmt", 10);
  p.resource("graf_r", 770, 300, 190, 80, "ConfigMap grafana-datasources, grafana-dashboards\nSecret grafana-admin");

  p.node("x_metrics", 1020, 130, 240, 90, "Metrik kaynakları\nbff 30901 · core 30902\next-authz 30903 · kube-state 30904", "internal", 10);
  p.node("x_otlp", 1020, 250, 240, 80, "OTLP kaynakları\next-authz · bff · core · Keycloak · konsol", "client", 10);
  p.node("x_identity", 1020, 360, 240, 70, "Keycloak (kind-identity)\nidentity secret alır", "identity", 10);
  p.node("x_host", 1020, 460, 240, 60, "Tarayıcı (host)\nGrafana :3000 port-forward", "host", 10);

  p.edge("vault", "x_identity", "identity secret (bootstrap)", "response");
  p.edge("x_metrics", "prom", "scrape /metrics", "telemetry");
  p.edge("x_otlp", "tempo", "OTLP trace", "telemetry");
  p.edge("graf", "prom", "PromQL", "telemetry");
  p.edge("graf", "tempo", "TraceQL", "telemetry");
  p.edge("x_host", "graf", "Explore / dashboard", "telemetry");

  p.text(40, 620, 940, 80,
    "<b>Notlar</b><br>" +
    "• Grafana datasource uid'leri: prometheus, tempo. Dashboard'lar: DMZ Lab – Genel Bakış, DMZ Lab – Dağıtık İzleme.<br>" +
    "• Lab: Vault, Prometheus, Tempo ve Grafana emptyDir kullanır; mgmt cluster silinince bu veriler gider.",
    "text;html=1;fontSize=12;align=left;verticalAlign=top;fontColor=#1F2937;");

  return p.build(20);
}

// ---------------------------------------------------------------------------
// 8) Pod içi detay: her pod'un container'ları ve bağlı kaynakları
// ---------------------------------------------------------------------------
function podDetail() {
  const p = new Page("8 Pod içi detay");
  p.text(20, 12, 1300, 34, "Pod içi detay: container'lar ve bağlı kaynaklar (ConfigMap, Secret, Service)",
    "text;html=1;fontStyle=1;fontSize=18;align=left;verticalAlign=middle;fontColor=#0F172A;");
  p.text(20, 40, 1300, 22, "Kesikli kutular pod'a bağlı kaynaklardır (mount veya env). Oklar pod'lar arası iletişimdir.",
    "text;html=1;fontSize=11;align=left;verticalAlign=middle;fontColor=#64748B;");

  const PW = 400, PH = 250;
  const COLS = [40, 470, 900];
  const ROWS = [70, 350, 630];

  // Bir pod paneli: dış pod kutusu, içinde container kutuları ve bağlı kaynak kutusu
  const pod = (key, col, row, title, kind, containers, resources) => {
    const x = COLS[col], y = ROWS[row];
    p.node(key, x, y, PW, PH, title, kind, 11);
    let cy = y + 44;
    for (const c of containers) {
      p.container(`${key}_c${cy}`, x + 14, cy, PW - 28, 38, c);
      cy += 44;
    }
    const rh = PH - (cy - y) - 14;
    p.resource(`${key}_r`, x + 14, cy, PW - 28, rh, resources);
  };

  pod("p_gwweb", 0, 0, "Pod: gw-web-xxx (ns gw-web, kind-dmz)", "dmz",
    ["envoy · kgateway v2.5.0 · listener :443"],
    "Secret gw-web-tls (frontend TLS)\nSecret dmz-gateway-client-tls (backend mTLS)\nConfigMap internal-ca-backend\nHTTPRoute: /bff, /partner, /public, /realms");
  pod("p_ext", 0, 1, "Pod: ext-authz-xxx (ns auth, kind-dmz)", "dmz",
    ["ext-authz · Python 3 stdlib · :8080 API · :9100 metrik"],
    "ConfigMap ext-authz-code (ext_authz.py, tracing.py, metrics.py)\nSecret dmz-exchange-client-tls (web/mobile/partner/branch)\nConfigMap internal-ca · Secret dmz-gateway-client-tls\nENV: OTLP_ENDPOINT, SERVICE_NAME=ext-authz");
  pod("p_gwbr", 0, 2, "Pod: gw-branch-xxx (ns gw-branch, kind-dmz)", "dmz",
    ["envoy · kgateway v2.5.0 · listener :443"],
    "Secret gw-branch-tls (frontend TLS)\nConfigMap branch-ca (istemci sertifikası doğrulama)\nSecret dmz-gateway-client-tls\nNodePort 30449 (F1 ile sınırlı)");

  pod("p_gwi", 1, 0, "Pod: gw-internal-xxx (ns gw-internal, kind-internal)", "internal",
    ["envoy · kgateway v2.5.0 · listener :443 mTLS"],
    "Secret gw-internal-tls (sunucu)\nConfigMap dmz-client-ca (istemci doğrulama)\nListenerPolicy: clientCertificateValidation, OTel tracing\nService identity-keycloak → 172.18.0.5:30080");
  pod("p_bff", 1, 1, "Pod: bff-xxx (ns app-bff, kind-internal)", "internal",
    ["bff · svc.py · :8080 API · :9100 metrik"],
    "ConfigMap svc-code (svc.py, tracing.py, metrics.py)\nENV: CORE_URL, SERVICE_NAME=bff, OTLP_ENDPOINT\nİç JWT doğrulama: iss, aud, exp, kanal");
  pod("p_core", 1, 2, "Pod: core-xxx (ns app-core, kind-internal)", "internal",
    ["core · svc.py · :8080 API · :9100 metrik"],
    "ConfigMap svc-code\nBellekte hesap ve işlem deposu (sub bazlı)\nIdempotency-Key kayıtları\nENV: SERVICE_NAME=core, OTLP_ENDPOINT");

  pod("p_kc", 2, 0, "Pod: keycloak-xxx (ns auth, kind-identity)", "identity",
    ["keycloak · dmz-lab/keycloak-dpop:26.6 · :8080"],
    "Secret keycloak-db, keycloak-admin (Vault türevi)\nSPI: dmz-dpop-mobile-exchange · x509cert-lookup: envoy\nENV: KC_HOSTNAME, tracing → 172.18.0.12:30318\nNodePort 30080");
  pod("p_pg", 2, 1, "Pod: postgres-xxx (ns auth, kind-identity)", "identity",
    ["postgres · 16 · :5432"],
    "emptyDir (lab; restart'ta veri gider)\nSecret keycloak-db (parola)\nAğ kısıtı: F8 host firewall (lab)");
  pod("p_vault", 2, 2, "Pod: vault-xxx (ns secrets, kind-mgmt)", "mgmt",
    ["vault · 1.18 · :8200"],
    "emptyDir (lab)\nSecret vault-bootstrap (unseal anahtarı, root token)\nKV v2 · secret/ · politika keycloak\nNodePort 30200 (F9 ile sınırlı)");

  // Pod'lar arası akış
  p.edge("p_gwweb", "p_ext", "ext-authz");
  p.edge("p_gwbr", "p_ext", "ext-authz");
  p.edge("p_ext", "p_gwi", "token exchange → iç JWT (mTLS)", "internal");
  p.edge("p_gwi", "p_bff", "iç JWT", "internal");
  p.edge("p_bff", "p_core", "iç token (forward)", "internal");
  p.edge("p_gwi", "p_kc", "/realms · JWKS · exchange", "response");
  p.edge("p_kc", "p_pg", "JDBC");
  p.edge("p_vault", "p_kc", "identity secret (bootstrap)", "response");

  return p.build(20);
}

// ---------------------------------------------------------------------------
// 9) Şube cluster içi (kind-branch): HAProxy yok, doğrudan gw-branch (F10)
// ---------------------------------------------------------------------------
function branchCluster() {
  const p = new Page("4b Şube cluster içi");
  p.text(20, 12, 1300, 34, "Şube cluster içi (kind-branch): WAN üzerinden doğrudan gw-branch, HAProxy yok",
    "text;html=1;fontStyle=1;fontSize=18;align=left;verticalAlign=middle;fontColor=#0F172A;");
  p.text(20, 40, 1300, 22, "Şube trafiği WAN üzerinden, F10 ile DMZ gw-branch'e (NodePort 30449) gider. Token exchange auth servisinde (ext-authz) yapılır.",
    "text;html=1;fontSize=11;align=left;verticalAlign=middle;fontColor=#64748B;");

  p.zone(20, 70, 700, 420, "Şube cluster (kind-branch) · şube ağı", "branch");
  p.fw("f10", 690, 100, "F10");

  p.ns(40, 120, 640, 330, "branch", "#0F766E");
  p.node("b_ui", 60, 160, 280, 120, "Şube UI pod (branch-ui)\nport 9100 · host 9100 (NodePort 30900)\nPKCE girişi (branch-app)\nhesap sorgusu · güvenlik kontrolleri", "branch", 10);
  p.resource("b_dev_r", 60, 300, 280, 130, "Secret branch-device-tls (cihaz sertifikası, internal-ca)\nSecret branch-app-secrets (identity\'den kopya)\nENV: BRANCH_GW_HOST = DMZ node IP, port 30449\nHAProxy\'den geçmez");
  p.resource("b_info", 370, 160, 290, 270,
    "Akış özeti:\n1. Şube UI, gw-branch'e cihaz sertifikasıyla mTLS bağlanır\n2. Login: /realms (PKCE, branch-app)\n3. /bff/* istekleri ext-authz'e gider\n4. ext-authz dış token'ı iç JWT'ye çevirir (exchange)\n5. Iç JWT yalnız iç ağda dolaşır");

  p.node("x_gwbr", 900, 160, 220, 80, "gw-branch (kind-dmz)\nmTLS cihaz doğrulama\n/bff/*, /realms/*", "dmz", 10);
  p.node("x_ext", 900, 280, 220, 70, "ext-authz (auth, kind-dmz)\nbranch profili · token exchange", "dmz", 10);
  p.node("x_kc", 900, 390, 220, 70, "Keycloak (kind-identity)\nbranch-app PKCE · dmz-exchange-branch", "identity", 10);

  p.edge("b_ui", "x_gwbr", "F10 · mTLS + /realms, /bff/*", "internal");
  p.edge("x_gwbr", "x_ext", "ext-authz (branch)");
  p.edge("x_ext", "x_kc", "token exchange (client-x509)", "response");
  p.edge("x_gwbr", "x_kc", "/realms (login, PKCE)", "response");

  p.text(40, 520, 680, 140,
    "<b>Notlar</b><br>" +
    "• Şube kanalında HAProxy yok. gw-branch cihaz sertifikasını (branch-ca) doğrular; /partner ve /public 404 döner.<br>" +
    "• Şube token'ı yalnız /bff için geçerli; iç RBAC x-channel == branch.<br>" +
    "• Lab: şube UI branch cluster pod'u; teller.lab.local HAProxy'den çıkarıldı. Bağlantı kind ağı üzerinden gw-branch:30449 (WAN benzeri, F10).",
    "text;html=1;fontSize=12;align=left;verticalAlign=top;fontColor=#1F2937;");

  return p.build(20);
}

module.exports = { dmzCluster, internalCluster, identityCluster, mgmtCluster, podDetail, branchCluster };
