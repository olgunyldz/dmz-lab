// V2 draw.io dosyası: docs/dmz-lab-v2.drawio (mevcut dmz-lab.drawio'ya dokunmaz).
// Çalıştırma (repo kökünden):  node docs/drawio/gen-v2.js
const fs = require("fs");
const path = require("path");
const { mxfile } = require("./builder.js");
const v2 = require("./pages-v2.js");
const { sequencePage } = require("./gen-sequence.js");
const v2Sequences = require("./sequence-defs-v2.js");
const vendorSequences = require("./sequence-defs-vendor.js");

const pages = [
  v2.v2Architecture(),
  v2.v2Namespaces(),
  ...v2Sequences.map(sequencePage),
  ...vendorSequences.map(sequencePage),
];
const out = path.join(__dirname, "..", "dmz-lab-v2.drawio");
fs.writeFileSync(out, mxfile(pages, "dmz-lab gen-v2.js"), "utf8");
console.log(`yazıldı: ${out} (${pages.length} sayfa)`);
pages.forEach((pg, i) => console.log(`  ${i + 1}. ${pg.name}`));
