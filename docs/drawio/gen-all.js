// Tüm draw.io sayfalarını TEK dosyada üretir: docs/dmz-lab.drawio (her sayfa bir tab).
// Çalıştırma (repo kökünden):  node docs/drawio/gen-all.js
const fs = require("fs");
const path = require("path");
const { mxfile } = require("./builder.js");
const overview = require("./pages-overview.js");
const clusters = require("./pages-clusters.js");
const { sequencePages } = require("./gen-sequence.js");

const pages = [
  overview.architecture(),
  overview.ioTools(),
  overview.allClusters(),
  clusters.dmzCluster(),
  clusters.branchCluster(),
  clusters.internalCluster(),
  clusters.identityCluster(),
  clusters.mgmtCluster(),
  clusters.podDetail(),
  ...sequencePages(),
];

const out = path.join(__dirname, "..", "dmz-lab.drawio");
fs.writeFileSync(out, mxfile(pages, "dmz-lab gen-all.js"), "utf8");
console.log(`yazıldı: ${out} (${pages.length} sayfa)`);
pages.forEach((pg, i) => console.log(`  ${i + 1}. ${pg.name}`));
