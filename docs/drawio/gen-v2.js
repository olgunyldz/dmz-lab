// V2 draw.io dosyası: docs/dmz-lab-v2.drawio (mevcut dmz-lab.drawio'ya dokunmaz).
// Sekmeler: (1) V2 genel mimari, (2) V2 namespace yerleşimi, (3) Mobil akışlar, (4) Web akışlar.
// Mobil ve Web sekmeleri, lab'da gerçekleştirilmiş akışları dikey olarak üst üste içerir; her akışın altında legend var.
// Çalıştırma (repo kökünden):  node docs/drawio/gen-v2.js
const fs = require("fs");
const path = require("path");
const { mxfile } = require("./builder.js");
const v2 = require("./pages-v2.js");
const v2ns = require("./pages-v2-ns.js");
const { sequencePage } = require("./gen-sequence.js");
const v2Sequences = require("./sequence-defs-v2.js");

// Bir sayfanın gövdesindeki dikey geometriyi dy kadar kaydırır (dikey yığın için).
function shiftY(body, dy) {
  if (!dy) return body;
  return body.replace(/<mxGeometry x="([\d.\-]+)" y="([\d.\-]+)" width=/g,
    (m, x, y) => `<mxGeometry x="${x}" y="${Number(y) + dy}" width=`);
}

// Birden çok akış sayfasını tek sekmede dikey olarak birleştirir.
function stackPage(name, defs) {
  let dy = 0;
  let width = 0;
  const bodies = [];
  for (const def of defs) {
    const pg = sequencePage(def);
    bodies.push(shiftY(pg.body, dy));
    dy += pg.height + 40;
    width = Math.max(width, pg.width);
  }
  return { name, width, height: dy, body: bodies.join("\n        ") };
}

// Sıra ve aşama: aktivasyon, ilk login, login, işlem. Akış adı (name) -> aşama başlığı.
const MOBILE_ORDER = [
  ["V2 M5", "1. Aktivasyon"],
  ["V2 M2", "2. İlk login (cihaz kaydı)"],
  ["V2 M1", "3. Login (IdP: PKCE)"],
  ["V2 M3", "3. Login (PIN + cihaz imzası)"],
  ["V2 M4", "4. İşlem"],
  ["V2 O", "5. Ek: tek aktif giriş"],
];
const WEB_ORDER = [
  ["V2 W1", "1. Login (IdP: PKCE)"],
  ["V2 W2", "2. İşlem"],
];

// Akışları verilen sıra ve aşama başlığıyla seçer (akış başlığının başına aşamayı ekler).
function ordered(order) {
  return order.map(([prefix, phase]) => {
    const def = v2Sequences.find((d) => d.name.startsWith(prefix));
    if (!def) throw new Error(`akış bulunamadı: ${prefix}`);
    return { ...def, title: `${phase} · ${def.title}` };
  });
}

const pages = [
  v2ns.v2NorthSouth(),
  v2.v2Architecture(),
  v2.v2Namespaces(),
  stackPage("Mobil akışlar", ordered(MOBILE_ORDER)),
  stackPage("Web akışlar", ordered(WEB_ORDER)),
];

const out = path.join(__dirname, "..", "dmz-lab-v2.drawio");
fs.writeFileSync(out, mxfile(pages, "dmz-lab gen-v2.js"), "utf8");
console.log(`yazıldı: ${out} (${pages.length} sekme)`);
pages.forEach((pg, i) => console.log(`  ${i + 1}. ${pg.name}`));
