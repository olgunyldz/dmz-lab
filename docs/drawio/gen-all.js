// Lab mimarisinin draw.io sayfalarını TEK dosyada üretir: docs/dmz-lab.drawio (her sayfa bir tab).
// Çalıştırma (repo kökünden):  node docs/drawio/gen-all.js
// Ortak yardımcılar: builder.js (sayfa/kutu/ok), palette.js (renk ve stiller).
// Kaynak gerçeği: docs/ altındaki metinler ve kod (apps/, infra/, platform/, observability/).
const fs = require("fs");
const path = require("path");
const { Page, mxfile } = require("./builder.js");
const { SEQ } = require("./palette.js");
const L = require("./lab-pages.js");

// ---------------------------------------------------------------------------
// 1) Genel mimari: bölgeler, cluster'lar, host platformu ve ana akışlar
// ---------------------------------------------------------------------------
function overview() {
  const p = new Page("Demo (lab)");

  p.zone(20, 60, 180, 840, "İstemciler", "internet");
  p.node("web", 40, 150, 140, 70, "Web tarayıcı", "client");
  p.node("mob", 40, 300, 140, 80, "Mobil uygulama", "client");

  p.zone(220, 60, 220, 840, "edge (host, docker compose)", "edge");
  p.node("edge", 240, 150, 180, 150, "HAProxy 127.0.0.1:8443\nTLS sonlandırma: web, mobil\nSNI passthrough: seal", "edge");

  p.zone(460, 60, 300, 380, "codevo-dmz (kind)", "dmz");
  p.node("seal", 480, 120, 260, 90, "Seal Mobile\ncihaz mTLS, PIN, cihaz imzası\nseal.lab.local", "dmz");
  p.node("sint", 480, 250, 260, 100, "Seal Intranet\nB2B akış uçları\nseal-intranet.lab.local", "dmz");

  p.zone(460, 500, 300, 300, "bank-dmz-prod (kind)", "dmz");
  p.node("jweb", 480, 560, 260, 90, "Janus web\nweb.lab.local", "dmz");
  p.node("jmob", 480, 690, 260, 90, "Janus mobil\nmobile-api.lab.local", "dmz");

  p.zone(790, 60, 540, 840, "bank-prod (kind)", "internal");
  p.ns(810, 110, 500, 120, "ns: auth", "#7C3AED");
  p.node("auth", 830, 150, 460, 60, "auth-server (kimlik sağlayıcı)\nid.bank.lab.local, PKCE, token, introspection", "identity");
  p.ns(810, 250, 500, 300, "ns: channel", "#2563EB");
  p.node("cgw", 830, 290, 230, 40, "FortunaUsersCGW", "internal", 10);
  p.node("api", 830, 340, 230, 40, "FortunaUserAPI", "internal", 10);
  p.node("acl", 830, 390, 230, 40, "FortunaUserACL", "internal", 10);
  p.node("sms", 830, 440, 230, 40, "SmsOtpCGW (mock)", "internal", 10);
  p.node("cg", 1080, 290, 210, 190, "channel-gateway\nserver token doğrulama\nBALANCE", "internal");
  p.ns(810, 570, 500, 110, "ns: secrets", "#15803D");
  p.node("vault", 830, 610, 460, 50, "Vault: KV v2 (secret/)", "mgmt", 10);

  p.zone(1350, 60, 340, 840, "platform (host, docker compose)", "host");
  p.node("fm", 1370, 120, 300, 110, "Fortuna monolit\nservices/legacy-monolith\n/fortuna/*, /seal-pm/*", "internal");
  p.node("ldb", 1370, 260, 300, 70, "LegacyDB (MSSQL as-is; lab: PostgreSQL 16)\ncustomers, accounts, fortuna_users", "mgmt");
  p.node("br", 1370, 360, 300, 130, "Köprüler (bridge-*)\nbridge-auth → 30543\nbridge-si → 30456\nbridge-fortuna → 30890\nbridge-legacydb → 30432", "host");
  p.node("obs", 1370, 520, 300, 140, "Gözlemlenebilirlik\nPrometheus, Loki, Jaeger, Grafana", "mgmt");

  // Dış erişim
  p.edge("web", "edge", "HTTPS :8443", "request");
  p.edge("mob", "edge", "HTTPS :8443", "request");
  p.edge("edge", "jweb", "web.lab.local → ingress :30802", "request");
  p.edge("edge", "jmob", "mobile-api.lab.local → ingress :30802", "request");
  p.edge("edge", "seal", "seal.lab.local → ingress :30456 (passthrough)", "request");

  // Kimlik
  p.edge("seal", "auth", "introspection (id.bank.lab.local)", "request");
  p.edge("sint", "auth", "JWKS (id.bank.lab.local)", "request");

  // Kanal çağrıları (Janus → bank-prod, NodePort)
  p.edge("jweb", "cgw", "müşteri doğrulama :30880", "request");
  p.edge("jweb", "sms", "OTP :30881", "request");
  p.edge("jweb", "cg", "server token :30990 (mTLS)", "internal");
  p.edge("jmob", "cg", "server token :30990 (mTLS)", "internal");
  p.edge("cgw", "api", "", "request");
  p.edge("api", "acl", "", "request");
  p.edge("acl", "ldb", "parola ve durum (bridge-legacydb)", "request");

  // Monolit ve Seal Intranet
  p.edge("cg", "fm", "BALANCE → /fortuna/accounts (bridge-fortuna)", "request");
  p.edge("seal", "fm", "PIN doğrulama (/seal-pm/*)", "request");
  p.edge("fm", "auth", "token exchange (bridge-auth)", "request");
  p.edge("fm", "sint", "B2B çağrı (bridge-si)", "request");

  // Telemetri
  p.edge("auth", "obs", "metrik, iz (OTLP)", "telemetry");
  p.edge("cg", "obs", "log, metrik, iz", "telemetry");

  p.text(20, 920, 1700, 40,
    "Demo: tek site ve tek örnek. DR ve aktif-aktif as-is mimaride vardır, bu demoda gösterilmez (bkz. As-is sayfası). " +
    "Her cluster'da Alloy (log) ve Prometheus agent (metrik) çalışır; uygulamalar OTLP ile Jaeger'a iz gönderir. Kimlik ve sırlar Vault'tadır; repoda sır yoktur.",
    "text;html=1;fontSize=11;align=left;fontColor=#1F2937;whiteSpace=wrap;");
  return p.build();
}

// ---------------------------------------------------------------------------
// 1b) As-is mimari: iki aktif site (A, B) + DR sitesi (C). Demoda gösterilmez; kurumsal mimarinin parçasıdır.
// ---------------------------------------------------------------------------
function targetArch() {
  const p = new Page("As-is mimari (DR, aktif-aktif: demoda yok)");

  p.node("gslb", 560, 40, 780, 60, "Global yük dengeleme (GSLB / DNS)\nweb, mobil, seal, id: sağlık kontrolü ile A ve B arasında dağıtım", "ops", 11);

  // Site A
  p.zone(20, 130, 880, 580, "Site A (aktif)", "internal");
  p.node("eA", 40, 180, 300, 80, "Edge HAProxy (HA çifti, VIP)", "edge", 11);
  p.ns(40, 290, 420, 200, "DMZ (codevo-dmz, bank-dmz-prod)", "#EA580C");
  p.node("jwA", 60, 330, 380, 50, "Janus web / mobil (ingress, çoklu örnek)", "dmz", 10);
  p.node("smA", 60, 390, 180, 50, "Seal Mobile (çoklu örnek)", "dmz", 10);
  p.node("siA", 260, 390, 180, 50, "Seal Intranet (çoklu örnek)", "dmz", 10);
  p.ns(480, 290, 420, 200, "bank-prod", "#2563EB");
  p.node("auA", 500, 330, 380, 50, "auth-server (çoklu örnek, durumsuz)", "identity", 10);
  p.node("fcA", 500, 390, 380, 50, "Fortuna zinciri + channel-gateway (çoklu örnek)", "internal", 10);
  p.ns(40, 510, 860, 170, "Veri ve sırlar", "#15803D");
  p.node("dbA", 60, 550, 260, 90, "LegacyDB PRIMARY\n(bölüm bazlı yazma)", "mgmt", 10);
  p.node("vtA", 340, 550, 260, 90, "Vault üyesi (raft)", "mgmt", 10);
  p.node("obA", 620, 550, 260, 90, "Gözlemlenebilirlik ajanları (log, metrik)", "mgmt", 10);

  // Site B (aynı yapı, sağa kaydırılmış)
  p.zone(1000, 130, 880, 580, "Site B (aktif)", "internal");
  p.node("eB", 1020, 180, 300, 80, "Edge HAProxy (HA çifti, VIP)", "edge", 11);
  p.ns(1020, 290, 420, 200, "DMZ (codevo-dmz, bank-dmz-prod)", "#EA580C");
  p.node("jwB", 1040, 330, 380, 50, "Janus web / mobil (ingress, çoklu örnek)", "dmz", 10);
  p.node("smB", 1040, 390, 180, 50, "Seal Mobile (çoklu örnek)", "dmz", 10);
  p.node("siB", 1240, 390, 180, 50, "Seal Intranet (çoklu örnek)", "dmz", 10);
  p.ns(1460, 290, 420, 200, "bank-prod", "#2563EB");
  p.node("auB", 1480, 330, 380, 50, "auth-server (çoklu örnek, durumsuz)", "identity", 10);
  p.node("fcB", 1480, 390, 380, 50, "Fortuna zinciri + channel-gateway (çoklu örnek)", "internal", 10);
  p.ns(1020, 510, 860, 170, "Veri ve sırlar", "#15803D");
  p.node("dbB", 1040, 550, 260, 90, "LegacyDB REPLİKA\n(yazmalar A'ya yönlenir)", "mgmt", 10);
  p.node("vtB", 1320, 550, 260, 90, "Vault üyesi (raft)", "mgmt", 10);
  p.node("obB", 1600, 550, 260, 90, "Gözlemlenebilirlik ajanları (log, metrik)", "mgmt", 10);

  // Site C (DR)
  p.zone(20, 740, 1860, 230, "Site C (DR: ılık yedek, bölgesel felaket kurtarma)", "ops");
  p.node("dr1", 60, 790, 300, 150, "LegacyDB yedek (asenkron replika, PITR)", "planned", 10);
  p.node("dr2", 400, 790, 300, 150, "Vault DR (replika)", "planned", 10);
  p.node("dr3", 740, 790, 300, 150, "Kubernetes cluster'ları (ılık: manifest + imaj hazır)", "planned", 10);
  p.node("dr4", 1080, 790, 300, 150, "Registry replikası (imaj yedeği)", "planned", 10);
  p.node("dr5", 1420, 790, 440, 150, "Merkezi gözlemlenebilirlik ve log arşivi", "planned", 10);

  // Trafik
  p.edge("gslb", "eA", "A'ya yönlendirme", "request");
  p.edge("gslb", "eB", "B'ye yönlendirme", "request");
  p.edge("eA", "jwA", "ingress", "request");
  p.edge("eB", "jwB", "ingress", "request");
  p.edge("jwA", "auA", "PKCE, token", "request");
  p.edge("jwB", "auB", "PKCE, token", "request");
  p.edge("auA", "dbA", "yazma/okuma", "request");
  p.edge("auB", "dbB", "okuma; yazma A'ya", "request");

  // Veri ve sır replikasyonu
  p.edge("dbA", "dbB", "senkron replika (A → B)", "internal");
  p.edge("vtA", "vtB", "raft (çoğunluk)", "request");
  p.edge("dbA", "dr1", "asenkron replika", "planned");
  p.edge("vtA", "dr2", "DR replika", "planned");
  p.edge("obA", "dr5", "log / metrik arşivi", "planned");
  p.edge("obB", "dr5", "log / metrik arşivi", "planned");

  p.text(20, 990, 1860, 90,
    "Demo kapsamı: tek site, tek örnek; DR ve aktif-aktif bu demoda çalıştırılmaz. Yazma modeli (LegacyDB, bölüm bazlı sahiplik), " +
    "durum yönetimi (oturum ve tek aktif giriş auth-server veritabanında, durumsuz örnekler) ve RTO/RPO ayrıntıları as-is mimari dokümanlarında tanımlıdır.",
    "text;html=1;fontSize=11;align=left;verticalAlign=top;whiteSpace=wrap;fontColor=#1F2937;");
  return p.build();
}

// ---------------------------------------------------------------------------
// 1c) Topoloji: siteler, ağ bölgeleri (segment), güvenlik duvarları ve WAN bağlantıları
// ---------------------------------------------------------------------------
function topology() {
  const p = new Page("Topoloji");

  p.zone(20, 40, 1860, 110, "İnternet ve dış katman", "internet");
  p.node("inet", 60, 80, 300, 50, "Kullanıcılar, mobil cihazlar, partnerler", "client", 10);
  p.node("wafA", 480, 80, 340, 50, "Dış güvenlik duvarı / WAF (sağlayıcı, GSLB arkası)", "edge", 10);
  p.node("wafB", 1000, 80, 340, 50, "Dış güvenlik duvarı / WAF (sağlayıcı, GSLB arkası)", "edge", 10);

  const siteBox = (x, label, key) => {
    p.zone(x, 180, 600, 560, label, key === "C" ? "ops" : "internal");
    p.node(`fw${key}`, x + 20, 220, 560, 40, "DMZ güvenlik duvarı  ·  iç güvenlik duvarı  ·  yönetim güvenlik duvarı", "ops", 10);
    p.ns(x + 20, 280, 270, 200, "DMZ segmenti", "#EA580C");
    p.node(`dmz${key}`, x + 35, 320, 240, 140, key === "C"
      ? "Ilık: DMZ cluster'ları için manifest ve imaj hazır"
      : "codevo-dmz, bank-dmz-prod\nEdge, Janus, Seal Mobile, Seal Intranet", "dmz", 10);
    p.ns(x + 310, 280, 270, 200, "Bank segmenti", "#2563EB");
    p.node(`bank${key}`, x + 325, 320, 240, 140, key === "C"
      ? "Ilık: bank-prod cluster'ı (auth, Fortuna zinciri)"
      : "bank-prod\nauth-server, Fortuna zinciri, channel-gateway", "internal", 10);
    p.ns(x + 20, 500, 270, 200, "Veri segmenti", "#15803D");
    p.node(`data${key}`, x + 35, 540, 240, 140, key === "C"
      ? "LegacyDB yedek replikası, Vault DR"
      : "LegacyDB (A: primary, B: replika), Vault üyesi", "mgmt", 10);
    p.ns(x + 310, 500, 270, 200, "Yönetim segmenti", "#475569");
    p.node(`mgmt${key}`, x + 325, 540, 240, 140, key === "C"
      ? "Merkezi gözlemlenebilirlik, log arşivi"
      : "Gözlemlenebilirlik ajanları, operatör erişimi (jump host)", "host", 10);
  };
  siteBox(20, "Site A", "A");
  siteBox(660, "Site B", "B");
  siteBox(1300, "Site C (DR)", "C");

  // WAN bağlantıları
  p.node("wanAB", 560, 780, 160, 50, "WAN: A ↔ B (özel hat)", "planned", 10);

  p.edge("inet", "wafA", "HTTPS / TLS", "request");
  p.edge("inet", "wafB", "HTTPS / TLS", "request");
  p.edge("wafA", "fwA", "izinli portlar", "request");
  p.edge("wafB", "fwB", "izinli portlar", "request");
  p.edge("fwA", "dmzA", "DMZ → bank: sınırlı API", "request");
  p.edge("dmzA", "bankA", "bank çağrıları (mTLS)", "internal");
  p.edge("bankA", "dataA", "DB ve sır erişimi", "internal");
  p.edge("bankA", "mgmtA", "telemetri", "telemetry");
  p.edge("fwB", "dmzB", "izinli portlar", "request");
  p.edge("dmzB", "bankB", "bank çağrıları (mTLS)", "internal");
  p.edge("bankB", "dataB", "DB okuma / yazma A'ya", "internal");
  p.edge("dataA", "dataB", "senkron replika", "internal");
  p.edge("dataA", "dataC", "asenkron replika", "planned");
  p.edge("bankA", "wanAB", "A ↔ B", "planned");
  p.edge("wanAB", "bankB", "A ↔ B", "planned");

  p.text(20, 910, 1860, 60,
    "Ağ segmentleri ve güvenlik duvarı kuralları (VLAN, CIDR, izin listeleri) ayrıca belirlenmeli; bu diyagram yalnızca rol ve akış sınırlarını gösterir. " +
    "Lab'da tüm segmentler tek makinede (kind ağları ve docker compose) simüle edilir.",
    "text;html=1;fontSize=11;align=left;verticalAlign=top;whiteSpace=wrap;fontColor=#1F2937;");
  return p.build();
}

// ---------------------------------------------------------------------------
// 1c) As-is batıdan doğuya (soldan sağa) mimari. Referans: inter-labs.drawio üretim sayfaları.
// Sıra: İnternet (web, mobil, partner) | Kurum WAN · şube (şube, ATM, POS) | Kurum VPN (çağrı merkezi)
//       | edge | DMZ | bank (Kubernetes) | çekirdek (on-prem). Altta mesajlaşma ve gözlemlenebilirlik.
// Aktif akışlar: web ve mobil. Diğerleri planlı. Kafka, RabbitMQ, Redis rolleri varsayım.
// ---------------------------------------------------------------------------
function channelsPage() {
  const p = new Page("As-is: batıdan doğuya");
  const TITLE = "text;html=1;whiteSpace=nowrap;align=left;verticalAlign=middle;spacing=0;fontSize=25;fontColor=#1f1f1f;fontStyle=1;fontFamily=Segoe UI;";
  const SUB = "text;html=1;whiteSpace=nowrap;align=left;verticalAlign=middle;spacing=0;fontSize=16;fontColor=#5f5f5a;fontStyle=0;fontFamily=Segoe UI;";
  const NOTE = "text;html=1;whiteSpace=wrap;align=left;verticalAlign=top;spacing=0;fontSize=12.5;fontColor=#1f1f1f;fontFamily=Segoe UI;";

  p.text(40, 14, 1800, 36, "As-is mimari: kanallardan çekirdeğe (batı → doğu)", TITLE);
  p.text(40, 52, 1800, 24, "Aktif akışlar: web ve mobil. Diğer kanallar planlı. Kafka, RabbitMQ ve Redis rolleri varsayımdır, doğrulanacak.", SUB);

  // Sütun 1 (batı): İnternet
  p.zone(20, 90, 260, 560, "İNTERNET · GÜVENİLMEYEN AĞ", "internet");
  p.node("web", 40, 140, 220, 90, "Web (AKTİF)\nweb · www.banka", "client", 11);
  p.node("mob", 40, 250, 220, 90, "Mobil (AKTİF)\niOS · Android · mobile-api", "client", 11);
  p.node("par", 40, 360, 220, 90, "Partner API (planlı)\naçık bankacılık · mTLS", "planned", 11);

  // Sütun 2: Kurum WAN · şube ağı
  p.zone(300, 90, 260, 560, "KURUM WAN · ŞUBE AĞI · ÖZEL HAT", "branch");
  p.node("sub", 320, 140, 220, 80, "Şube (planlı)\ngişe · operasyon", "planned", 11);
  p.node("atm", 320, 240, 220, 80, "ATM (planlı)\nISO 8583", "planned", 11);
  p.node("pos", 320, 340, 220, 80, "POS (planlı)\nüye işyeri · acquirer", "planned", 11);

  // Sütun 3: Kurum ağı · VPN
  p.zone(580, 90, 240, 560, "KURUM AĞI · VPN", "ops");
  p.node("cc", 600, 140, 200, 80, "Çağrı merkezi (planlı)\ntemsilci işlemleri", "planned", 11);

  // Sütun 4: edge
  p.zone(840, 90, 240, 560, "EDGE · HAProxy / GSLB", "edge");
  p.node("edge", 860, 140, 200, 130, "HAProxy / GSLB\nTLS sonlandırma (web, mobil)\nSNI passthrough (seal)", "edge", 11);

  // Sütun 5: DMZ
  p.zone(1100, 90, 260, 560, "DMZ · kuzey-güney geçiş", "dmz");
  p.node("jweb", 1120, 140, 220, 90, "Janus web\nweb.lab.local ingress\nsplash, OTP, login", "dmz", 11);
  p.node("jmob", 1120, 250, 220, 90, "Janus mobil\nmobile-api.lab.local\nsecure-login, mobile-login", "dmz", 11);
  p.node("seal", 1120, 360, 220, 90, "Seal Mobile\nseal.lab.local (passthrough)\ncihaz mTLS, PIN", "dmz", 11);
  p.node("sint", 1120, 470, 220, 90, "Seal Intranet\nseal-intranet.lab.local\nB2B akış uçları", "dmz", 11);

  // Sütun 6: bank (Kubernetes)
  p.zone(1380, 90, 260, 560, "BANK · Kubernetes", "internal");
  p.node("auth", 1400, 140, 220, 90, "auth-server\nid.bank.lab.local\nPKCE, token, introspection", "identity", 11);
  p.node("cg", 1400, 250, 220, 90, "channel-gateway\nserver token, yönlendirme", "internal", 11);
  p.node("cgw", 1400, 360, 220, 90, "Fortuna zinciri\nCGW · API · ACL · SMS mock", "internal", 11);

  // Sütun 7 (doğu): çekirdek on-prem
  p.zone(1660, 90, 260, 560, "ÇEKİRDEK · on-prem", "host");
  p.node("iis", 1680, 140, 220, 130, "Fortuna monolit\n(Windows IIS)\nhesap, hareket, havale, PIN", "host", 11);
  p.node("ldb", 1680, 300, 220, 110, "LegacyDB\nMSSQL (as-is)\nlab: PostgreSQL 16", "mgmt", 11);

  // Alt bant: mesajlaşma ve önbellek (varsayım)
  p.zone(20, 680, 1900, 110, "MESAJLAŞMA VE ÖNBELLEK · kurumsal, rol varsayım", "ops");
  p.node("kafka", 60, 720, 560, 56, "Kafka · olay akışı", "planned", 11);
  p.node("rabbit", 680, 720, 560, 56, "RabbitMQ · asenkron kuyruk", "planned", 11);
  p.node("redis", 1300, 720, 560, 56, "Redis · önbellek / oturum", "planned", 11);

  // Alt bant: gözlemlenebilirlik (kurumsal)
  p.zone(20, 810, 1900, 110, "GÖZLEMLENEBİLİRLİK · kurumsal", "mgmt");
  p.node("dyn", 60, 850, 420, 56, "Dynatrace · APM, uçtan uca iz", "mgmt", 11);
  p.node("prom", 520, 850, 380, 56, "Prometheus · metrik", "mgmt", 11);
  p.node("graf", 940, 850, 340, 56, "Grafana · panolar", "mgmt", 11);
  p.node("elk", 1320, 850, 540, 56, "ELK · Elasticsearch, Logstash, Kibana (log)", "mgmt", 11);

  // Batı -> doğu: aktif akışlar düz, planlılar kesikli
  p.edge("web", "edge", "HTTPS :8443", "request");
  p.edge("mob", "edge", "HTTPS :8443", "request");
  p.edge("par", "edge", "planlı", "planned");
  p.edge("sub", "edge", "planlı", "planned");
  p.edge("atm", "edge", "planlı", "planned");
  p.edge("pos", "edge", "planlı", "planned");
  p.edge("cc", "edge", "planlı", "planned");

  p.edge("edge", "jweb", "web.lab.local → ingress :30802", "request");
  p.edge("edge", "jmob", "mobile-api → ingress :30802", "request");
  p.edge("edge", "seal", "seal.lab.local → ingress :30456", "request");

  p.edge("jweb", "auth", "web girişi, PKCE", "request");
  p.edge("jmob", "auth", "PKCE, token", "request");
  p.edge("jweb", "cg", "server token (60 sn)", "internal");
  p.edge("jmob", "cg", "server token (60 sn)", "internal");
  p.edge("seal", "auth", "introspection", "request");
  p.edge("sint", "auth", "JWKS", "request");

  p.edge("cg", "cgw", "müşteri çağrıları", "request");
  p.edge("cg", "iis", "BALANCE, HISTORY, TRANSFER", "request");
  p.edge("seal", "iis", "PIN doğrulama (/seal-pm/*)", "request");
  p.edge("auth", "iis", "token exchange", "request");
  p.edge("cgw", "ldb", "müşteri ve parola (ACL)", "request");
  p.edge("iis", "ldb", "hesap, defter", "request");

  p.edge("iis", "kafka", "olay yayını (varsayım)", "planned");
  p.edge("cg", "rabbit", "kuyruk (varsayım)", "planned");
  p.edge("cgw", "redis", "önbellek (varsayım)", "planned");

  p.edge("cg", "dyn", "APM", "telemetry");
  p.edge("iis", "dyn", "APM", "telemetry");
  p.edge("cg", "prom", "metrik", "telemetry");
  p.edge("iis", "elk", "log", "telemetry");

  p.text(40, 955, 1860, 40,
    "Okuma yönü: soldan sağa (batı → doğu). Lab karşılıkları: Dynatrace → Jaeger, ELK → Loki; Kafka, RabbitMQ ve Redis lab'da yok; Fortuna monolit lab'da Python mock'tur.",
    NOTE);
  return p.build();
}

// ---------------------------------------------------------------------------
// 2) Ağ ve port envanteri (tablo)
// ---------------------------------------------------------------------------
function network() {
  const p = new Page("Ağ ve portlar");
  const rows = [
    ["Kaynak", "Hedef", "Adres / port", "Mekanizma", "Not"],
    ["Tarayıcı, mobil", "edge (HAProxy)", "127.0.0.1:8443", "host port", "TLS sonlandırma (web, mobil)"],
    ["edge", "Janus (bank-dmz-prod)", "host.docker.internal:30802", "nginx ingress NodePort", "Host: web.lab.local, mobile-api.lab.local"],
    ["edge", "Seal Mobile (codevo-dmz)", "host.docker.internal:30456", "nginx ingress NodePort", "SNI passthrough: seal.lab.local"],
    ["Seal Mobile", "auth-server", "bank-prod düğüm:30543", "nginx ingress NodePort", "SNI passthrough: id.bank.lab.local"],
    ["Seal Intranet", "auth-server (JWKS)", "bank-prod düğüm:30543", "nginx ingress NodePort", "SNI passthrough: id.bank.lab.local"],
    ["Janus", "FortunaUsersCGW", "bank-prod düğüm:30880", "NodePort", "mTLS (istemci sertifikası)"],
    ["Janus", "SmsOtpCGW (mock)", "bank-prod düğüm:30881", "NodePort", "mTLS"],
    ["Janus", "channel-gateway", "bank-prod düğüm:30990", "NodePort", "mTLS; Janus server token"],
    ["channel-gateway", "Fortuna monolit", "bridge-fortuna:30890", "platform köprüsü (socat)", "BALANCE"],
    ["FortunaUserACL", "LegacyDB", "bridge-legacydb:30432", "platform köprüsü", "parola ve durum"],
    ["Fortuna monolit", "auth-server", "bridge-auth → 30543", "platform köprüsü", "token exchange"],
    ["Fortuna monolit", "Seal Intranet", "bridge-si → 30456", "platform köprüsü", "B2B"],
    ["Cluster ajanları", "Prometheus", "bridge-prometheus:30090", "remote_write", "metrik"],
    ["Cluster ajanları", "Loki", "bridge-loki:30100", "HTTP push", "log"],
    ["Uygulamalar", "Jaeger", "bridge-jaeger:30318", "OTLP/HTTP", "iz (W3C traceparent)"],
    ["Operatör", "Grafana / Jaeger UI", "127.0.0.1:3000 / 16686", "host port", "izleme"],
    ["Operatör", "Vault", "127.0.0.1:18200", "kubectl port-forward", "tools/tools-forward.sh"],
    ["Operatör", "Konsol", "127.0.0.1:9000", "python", "console/app.py"],
  ];
  const cell = (t, h) => h
    ? `<th style="border:1px solid #CBD5E1;padding:4px 8px;background:#F1F5F9;text-align:left">${t}</th>`
    : `<td style="border:1px solid #CBD5E1;padding:4px 8px">${t}</td>`;
  const html = `<table style="border-collapse:collapse;font-size:12px;font-family:Helvetica;color:#1F2937">` +
    rows.map((r, i) => `<tr>${r.map((c) => cell(c, i === 0)).join("")}</tr>`).join("") + `</table>`;
  p.text(30, 40, 1500, 560, html, "text;html=1;align=left;verticalAlign=top;whiteSpace=wrap;");
  p.text(30, 620, 1500, 60,
    "Kind düğüm IP'leri dinamiktir; köprü ve düğüm IP'leri kurulumda docker inspect ile okunur. " +
    "Windows ayrılmış port aralığı (8185-8284) nedeniyle Vault 18200'de yayınlanır.",
    "text;html=1;fontSize=11;align=left;fontColor=#1F2937;whiteSpace=wrap;");
  return p.build();
}

// ---------------------------------------------------------------------------
// 3) Dağıtım görünümü: pipeline, deploy-app ve hedef cluster/namespace
// ---------------------------------------------------------------------------
function deployment() {
  const p = new Page("Dağıtım görünümü");
  p.node("jk", 40, 60, 260, 70, "Jenkins (Jenkinsfile)\nAPP, REGISTRY_MODE", "ops", 11);
  p.node("da", 40, 170, 260, 70, "scripts/deploy-app.sh <ad>\napps/<ad>/app.env + hook.sh + manifests/", "ops", 11);
  p.node("ins", 40, 280, 260, 70, "scripts/install-all.sh\nsıfırdan kurulum", "ops", 11);
  p.edge("jk", "da", "her uygulama", "request");
  p.edge("ins", "da", "uygulamalar", "request");

  p.zone(360, 40, 420, 230, "bank-prod", "internal");
  p.node("d-auth", 380, 90, 380, 60, "ns auth: auth-server (image, ingress id.bank.lab.local)", "identity", 10);
  p.node("d-ch", 380, 165, 380, 85, "ns channel: fortuna, channel-gateway (ConfigMap kodu, imaj yok)", "internal", 10);

  p.zone(360, 300, 420, 150, "bank-dmz-prod", "dmz");
  p.node("d-jan", 380, 340, 380, 80, "ns janus: janus (ConfigMap kodu, ingress web/mobile)", "dmz", 10);

  p.zone(360, 480, 420, 230, "codevo-dmz", "dmz");
  p.node("d-si", 380, 520, 380, 70, "ns seal-intranet: image, ingress seal-intranet.lab.local", "dmz", 10);
  p.node("d-sm", 380, 610, 380, 70, "ns seal-mobile: image, ingress seal.lab.local", "dmz", 10);

  p.zone(820, 40, 360, 230, "platform (host)", "host");
  p.node("d-pl", 840, 90, 320, 90, "platform/scripts/up.sh\ndocker compose: LegacyDB, monolit, Prometheus, Loki, Jaeger, Grafana, köprüler", "host", 10);

  p.zone(820, 300, 360, 150, "observability", "mgmt");
  p.node("d-ob", 840, 340, 320, 90, "observability/install.sh\nAlloy + Prometheus agent (her cluster)", "mgmt", 10);

  p.zone(820, 480, 360, 230, "altyapı", "ops");
  p.node("d-vt", 840, 520, 320, 60, "infra/vault/load-vault.sh\nVault (bank-prod, ns secrets)", "mgmt", 10);
  p.node("d-ing", 840, 600, 320, 80, "scripts/lib: install_ingress\nnginx ingress (her cluster, helm)", "ops", 10);

  p.edge("da", "d-auth", "apply + rollout", "request");
  p.edge("da", "d-ch", "apply + rollout", "request");
  p.edge("da", "d-jan", "apply + rollout", "request");
  p.edge("da", "d-si", "apply + rollout", "request");
  p.edge("da", "d-sm", "apply + rollout", "request");
  p.edge("ins", "d-pl", "compose up", "request");
  p.edge("ins", "d-vt", "ilk başlatma", "request");
  p.edge("ins", "d-ob", "son adım", "request");

  p.text(40, 560, 260, 150,
    "Sıra (bağımlılık): Vault → platform → auth-server → Fortuna → Janus → channel-gateway → Seal Intranet → Seal Mobile → HAProxy → gözlemlenebilirlik. " +
    "Her uygulama kendi ingress'ini manifest ile getirir.",
    "text;html=1;fontSize=11;align=left;verticalAlign=top;whiteSpace=wrap;fontColor=#1F2937;");
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
    { key: "auth", label: "auth-server", kind: "identity" },
    { key: "seal", label: "Seal Mobile", kind: "dmz" },
    { key: "j", label: "Janus mobil", kind: "dmz" },
    { key: "fm", label: "Fortuna monolit", kind: "internal" },
  ],
  [
    { from: "m", to: "j", label: "POST /janus/splash (cihaz ACTIVE)" },
    { from: "j", to: "m", label: "splash token", type: "ret" },
    { from: "m", to: "auth", label: "PKCE: /auth, /token (mobile-app)" },
    { from: "auth", to: "m", label: "access token (aud channel-mobile)", type: "ret" },
    { from: "m", to: "seal", label: "login/begin (mTLS + Bearer)" },
    { from: "seal", to: "m", label: "flowId", type: "ret" },
    { from: "m", to: "seal", label: "login/pin" },
    { from: "seal", to: "fm", label: "pin/verify (/seal-pm/*)" },
    { from: "fm", to: "seal", label: "ok", type: "ret" },
    { from: "seal", to: "m", label: "PIN_OK, nonce", type: "ret" },
    { from: "m", to: "seal", label: "login/authorize (cihaz imzası)" },
    { from: "seal", to: "auth", label: "introspection (oturum aktif mi)" },
    { from: "auth", to: "seal", label: "active", type: "ret" },
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

const pages = [
  overview(),
  L.clusterStructure(Page), L.ingressRules(Page), L.channelWeb(Page), L.channelMobile(Page), L.secretsAndData(Page),
  channelsPage(), targetArch(), topology(), network(), deployment(), web, mobile, newDevice,
];

const out = path.join(__dirname, "..", "dmz-lab.drawio");
fs.writeFileSync(out, mxfile(pages, "dmz-lab gen-all.js"), "utf8");
console.log(`yazıldı: ${out} (${pages.length} sayfa)`);
pages.forEach((pg, i) => console.log(`  ${i + 1}. ${pg.name}`));
