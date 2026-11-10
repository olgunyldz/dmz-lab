// Sequence diagram'larını draw.io (mxfile) formatında üretir.
// Çalıştırma: node docs/gen-sequence.js  ->  docs/sequences.drawio
// Her diyagram ayrı bir draw.io sayfasıdır (<diagram>). Kaynak tanımlar aşağıdadır.
const fs = require("fs");
const path = require("path");

const X0 = 40;
const SPACING = 190;
const HEADER_Y = 40;
const HEADER_H = 64;
const FIRST_MSG_Y = 130;
const STEP = 46;

const esc = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/\n/g, "&#xa;");

// Hücre kimlikleri dosya genelinde tekil olsun diye sayaç modül düzeyinde tutulur.
let nid = 2;
const id = () => `n${nid++}`;

function diagram(def) {
  const idx = Object.fromEntries(def.participants.map((p, i) => [p.id, i]));
  const cx = (id) => X0 + idx[id] * SPACING + 75; // lifeline x-merkezi
  let cells = [];

  // Başlık
  cells.push(
    `<mxCell id="${id()}" value="${esc(def.title)}" style="text;html=1;fontStyle=1;fontSize=16;align=left;verticalAlign=middle;" vertex="1" parent="1"><mxGeometry x="${X0}" y="6" width="1100" height="28" as="geometry"/></mxCell>`
  );

  // Mesaj y koordinatlarını hesapla
  let y = FIRST_MSG_Y;
  const msgY = def.messages.map((m) => {
    if (m.gap) y += m.gap;
    const my = y;
    y += STEP;
    return my;
  });
  const bottom = Math.max(...msgY, FIRST_MSG_Y) + 60;

  // Katılımcı başlıkları ve yaşam çizgileri
  for (const p of def.participants) {
    const x = cx(p.id);
    cells.push(
      `<mxCell id="${id()}" value="${p.label.split("\n").map(esc).join("&lt;br&gt;")}" style="rounded=1;whiteSpace=wrap;html=1;fillColor=${p.color || "#ffffff"};strokeColor=#333333;fontStyle=1;fontSize=11;" vertex="1" parent="1"><mxGeometry x="${x - 85}" y="${HEADER_Y}" width="170" height="${HEADER_H}" as="geometry"/></mxCell>`
    );
    cells.push(
      `<mxCell id="${id()}" value="" style="endArrow=none;dashed=1;strokeColor=#888888;" edge="1" parent="1"><mxGeometry relative="1" as="geometry"><mxPoint x="${x}" y="${HEADER_Y + HEADER_H}" as="sourcePoint"/><mxPoint x="${x}" y="${bottom}" as="targetPoint"/></mxGeometry></mxCell>`
    );
  }

  // Notlar (katılımcının üstünde, kutu olarak)
  for (const n of def.notes || []) {
    const x = cx(n.over) - 110;
    cells.push(
      `<mxCell id="${id()}" value="${esc(n.text)}" style="shape=note;whiteSpace=wrap;html=1;size=8;fillColor=#fff2cc;strokeColor=#d6b656;fontSize=11;align=left;" vertex="1" parent="1"><mxGeometry x="${x}" y="${n.y}" width="220" height="${n.h || 60}" as="geometry"/></mxCell>`
    );
  }

  // Mesajlar
  def.messages.forEach((m, i) => {
    const y = msgY[i];
    if (m.self) {
      // Kendi üzerine mesaj: kutu olarak
      const x = cx(m.from) + 6;
      cells.push(
        `<mxCell id="${id()}" value="${esc(m.label)}" style="rounded=0;whiteSpace=wrap;html=1;fontSize=10;fillColor=#dae8fc;strokeColor=#6c8ebf;align=left;" vertex="1" parent="1"><mxGeometry x="${x}" y="${y - 14}" width="180" height="30" as="geometry"/></mxCell>`
      );
      return;
    }
    const sx = cx(m.from);
    const tx = cx(m.to);
    const style = [
      "endArrow=classic",
      "html=1",
      m.ret ? "dashed=1" : "",
      m.ret ? "strokeColor=#888888" : "strokeColor=#333333",
      m.internalToken ? "strokeColor=#b85450;strokeWidth=2" : "",
      m.plannedToken ? "dashed=1" : "",
      "fontSize=10",
      "labelBackgroundColor=#ffffff",
    ]
      .filter(Boolean)
      .join(";");
    cells.push(
      `<mxCell id="${id()}" value="${esc(m.label)}" style="${style}" edge="1" parent="1"><mxGeometry relative="1" as="geometry"><mxPoint x="${sx}" y="${y}" as="sourcePoint"/><mxPoint x="${tx}" y="${y}" as="targetPoint"/></mxGeometry></mxCell>`
    );
  });

  // Alt kutu: kontroller ve lab/prod farkı
  let footerH = 0;
  if (def.footer) {
    const fw = def.participants.length * SPACING - 60;
    footerH = 16 + def.footer.length * 30;
    cells.push(
      `<mxCell id="${id()}" value="${def.footer.map(esc).join("&lt;br&gt;")}" style="rounded=1;whiteSpace=wrap;html=1;align=left;verticalAlign=top;fillColor=#f5f5f5;strokeColor=#999999;fontSize=11;spacing=8;" vertex="1" parent="1"><mxGeometry x="${X0}" y="${bottom + 10}" width="${fw}" height="${footerH}" as="geometry"/></mxCell>`
    );
  }

  const width = X0 + def.participants.length * SPACING + 60;
  const height = bottom + 60 + footerH + 20;
  return { name: def.name, width, height, body: cells.join("\n          ") };
}

// Mimari genel bakış: zonlar, bileşenler, firewall'lar ve iç token sınırı.
function overview() {
  const cells = [];
  const ids = {};
  const add = (xml) => cells.push(xml);
  const box = (key, x, y, w, h, label, style) => {
    const cid = id();
    ids[key] = cid;
    add(`<mxCell id="${cid}" value="${label.split("\n").map(esc).join("&lt;br&gt;")}" style="${style}" vertex="1" parent="1"><mxGeometry x="${x}" y="${y}" width="${w}" height="${h}" as="geometry"/></mxCell>`);
  };
  const zone = (x, y, w, h, label, fill) =>
    add(`<mxCell id="${id()}" value="${esc(label)}" style="rounded=0;whiteSpace=wrap;html=1;fillColor=${fill};strokeColor=#666666;dashed=1;verticalAlign=top;align=left;spacingLeft=8;spacingTop=6;fontStyle=1;fontSize=13;" vertex="1" parent="1"><mxGeometry x="${x}" y="${y}" width="${w}" height="${h}" as="geometry"/></mxCell>`);
  const comp = (key, x, y, w, h, label, fill, prod) =>
    box(key, x, y, w, h, label, `rounded=1;whiteSpace=wrap;html=1;fillColor=${fill};strokeColor=#333333;fontSize=11;${prod ? "dashed=1;" : ""}`);
  const fw = (key, x, y, w, label) =>
    box(key, x, y, w, 26, label, "rounded=0;whiteSpace=wrap;html=1;fillColor=#f8cecc;strokeColor=#b85450;fontStyle=1;fontSize=10;");
  const link = (src, tgt, label, kind = "std") => {
    const styles = {
      std: "strokeColor=#333333",
      internal: "strokeColor=#b85450;strokeWidth=2",
      dashed: "strokeColor=#888888;dashed=1",
    };
    add(`<mxCell id="${id()}" value="${esc(label)}" style="endArrow=classic;html=1;fontSize=10;labelBackgroundColor=#ffffff;${styles[kind]};" edge="1" parent="1" source="${ids[src]}" target="${ids[tgt]}"><mxGeometry relative="1" as="geometry"/></mxCell>`);
  };

  box("title", X0, 6, 1200, 28, "Mimari genel bakış: dört cluster, kimlik katmanı ve token sınırları", "text;html=1;fontStyle=1;fontSize=16;align=left;verticalAlign=middle;");

  // Zonlar (arka plan)
  zone(20, 60, 170, 780, "Internet", "#f5f5f5");
  zone(220, 60, 200, 780, "DMZ Edge", "#fff2cc");
  zone(460, 60, 330, 380, "DMZ Cluster (kind-dmz)", "#ffe6cc");
  zone(830, 60, 330, 380, "Internal Cluster (kind-internal)  iç JWT yalnız burada", "#dae8fc");
  zone(460, 500, 330, 340, "Identity Cluster (kind-identity)", "#e1d5e7");
  zone(830, 500, 330, 340, "Mgmt / Secrets (kind-mgmt)", "#d5e8d4");
  zone(1200, 60, 200, 780, "Ops (planlı)", "#f5f5f5");

  // Bileşenler
  comp("browser", 35, 120, 140, 60, "Web tarayıcı", "#ffffff");
  comp("mobil", 35, 230, 140, 60, "Mobil uygulama", "#ffffff");
  comp("partner", 35, 340, 140, 60, "Partner (mTLS)", "#ffffff");
  comp("anon", 35, 450, 140, 60, "Anonim kullanıcı", "#ffffff");

  comp("haproxy", 235, 120, 170, 90, "HAProxy 3.0\nL4 SNI · TLS · L7 limit · SPOE", "#fff2cc");
  comp("waf", 235, 250, 170, 60, "Coraza WAF\nOWASP CRS (SPOE)", "#fff2cc");
  comp("ddos", 235, 350, 170, 60, "DDoS / dış katman\n(prod: F5 veya CDN)", "#ffffff", true);
  comp("ha", 235, 450, 170, 60, "HA (prod: 2+ LB, VRRP)", "#ffffff", true);

  comp("gwweb", 475, 130, 140, 60, "kgateway gw-web", "#ffe6cc");
  comp("gwmob", 635, 130, 140, 60, "kgateway gw-mobile", "#ffe6cc");
  comp("gwpar", 475, 230, 140, 60, "kgateway gw-partner", "#ffe6cc");
  comp("ea", 635, 230, 140, 70, "ext-authz\nJWKS · exchange · DPoP", "#ffe6cc");

  comp("gi", 845, 130, 300, 70, "kgateway gw-internal\niç JWT · RBAC · mTLS (DMZ kimliği)", "#dae8fc");
  comp("bff", 845, 240, 140, 60, "BFF app-bff", "#dae8fc");
  comp("core", 995, 240, 150, 60, "Core app-core", "#dae8fc");

  comp("kc", 475, 540, 300, 70, "Keycloak 26.6\nrealm bank · token exchange · SPI", "#e1d5e7");
  comp("pg", 475, 650, 140, 60, "PostgreSQL 16", "#e1d5e7");

  comp("vault", 845, 540, 300, 70, "Vault 1.18\nKV v2 · secret/ · politika keycloak", "#d5e8d4");
  comp("hsm", 845, 650, 140, 60, "HSM / KMS (prod, D-12)", "#ffffff", true);

  comp("git", 1215, 130, 170, 60, "Git (GitOps)", "#ffffff", true);
  comp("argo", 1215, 220, 170, 60, "Argo CD", "#ffffff", true);
  comp("kyv", 1215, 310, 170, 60, "Kyverno", "#ffffff", true);
  comp("siem", 1215, 400, 170, 60, "SIEM", "#ffffff", true);

  // Firewall'lar
  fw("f1", 420, 245, 36, "F1");
  fw("f2", 792, 245, 36, "F2");
  fw("f8", 700, 470, 80, "F8 identity");
  fw("f9", 930, 470, 80, "F9 Vault");

  // Bağlantılar
  link("browser", "haproxy", "HTTPS 443 (dış token)");
  link("mobil", "haproxy", "HTTPS 443 (DPoP)");
  link("partner", "haproxy", "mTLS passthrough");
  link("anon", "haproxy", "HTTPS 443 (public)");
  link("haproxy", "waf", "SPOE");
  link("haproxy", "gwweb", "TLS re-encrypt");
  link("haproxy", "gwmob", "TLS re-encrypt");
  link("haproxy", "gwpar", "TCP passthrough");
  link("gwweb", "ea", "ext-authz");
  link("gwmob", "ea", "ext-authz");
  link("gwpar", "ea", "ext-authz");
  link("ea", "gi", "token exchange (mTLS) → iç JWT", "internal");
  link("gwweb", "gi", "iç JWT (mTLS)", "internal");
  link("gwpar", "gi", "/partner + iç JWT (mTLS)", "internal");
  link("gi", "bff", "iç JWT", "internal");
  link("gi", "core", "iç JWT", "internal");
  link("gi", "kc", "exchange, /realms, JWKS");
  link("bff", "kc", "JWKS", "dashed");
  link("kc", "pg", "JDBC");
  link("vault", "kc", "identity secret (lab: bootstrap, prod: ESO)", "dashed");
  link("hsm", "kc", "imzalama anahtarı (prod)", "dashed");
  link("git", "argo", "GitOps", "dashed");

  box("legend", 20, 860, 1380, 40,
    "Kırmızı kalın ok: iç JWT (yalnız iç ağda).   Kesikli ok veya kesikli kutu: planlı ya da prod'a özgü.   Kırmızı kutu: firewall (F1 edge→DMZ, F2 DMZ→iç mTLS, F8 identity ingress, F9 Vault ingress).",
    "rounded=0;whiteSpace=wrap;html=1;align=left;verticalAlign=middle;fillColor=#ffffff;strokeColor=#999999;fontSize=11;spacing=8;");

  return { name: "0 Mimari genel bakış", width: 1440, height: 920, body: cells.join("\n          ") };
}

const diagrams = require("./sequence-defs.js").map(diagram);
const all = [overview(), ...diagrams];

const pages = all
  .map(
    (d, i) => `  <diagram id="seq${i + 1}" name="${esc(d.name)}">
    <mxGraphModel dx="1400" dy="900" grid="1" gridSize="10" guides="1" tooltips="1" connect="1" arrows="1" fold="1" page="0" pageScale="1" pageWidth="${d.width}" pageHeight="${d.height}" math="0" shadow="0">
      <root>
        <mxCell id="0"/>
        <mxCell id="1" parent="0"/>
          ${d.body}
      </root>
    </mxGraphModel>
  </diagram>`
  )
  .join("\n");

const xml = `<?xml version="1.0" encoding="UTF-8"?>
<mxfile host="app.diagrams.net" agent="dmz-lab gen-sequence.js" version="24.0.0" type="device">
${pages}
</mxfile>
`;

const out = path.join(__dirname, "sequences.drawio");
fs.writeFileSync(out, xml, "utf8");
console.log(`yazıldı: ${out} (${all.length} sayfa: 1 mimari genel bakış + ${diagrams.length} sequence)`);
