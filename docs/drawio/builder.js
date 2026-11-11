// draw.io sayfa üretici: kutu, zone, namespace, pod, ok ve metin yardımcıları.
// Tüm koordinatlar mutlak (parent="1"). Önce çizilen hücre arkada kalır: kapsayıcıları önce ekleyin.
const P = require("./palette.js");

const esc = (s) => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
const br = (s) => esc(s).replace(/\n/g, "&lt;br&gt;");

let PAGE_SEQ = 0; // her sayfaya benzersiz kimlik öneki (dosya genelinde çakışma olmasın)

class Page {
  constructor(name) {
    this.name = name;
    this.cells = [];
    this.n = 2;
    this.prefix = `p${++PAGE_SEQ}_`;
    this.ids = {};
    this.maxX = 0;
    this.maxY = 0;
  }

  _id() { return `${this.prefix}c${this.n++}`; }

  _track(x, y, w, h) {
    this.maxX = Math.max(this.maxX, x + w);
    this.maxY = Math.max(this.maxY, y + h);
  }

  _vertex(key, x, y, w, h, label, style) {
    const cid = this._id();
    if (key) {
      if (this.ids[key]) throw new Error(`[${this.name}] tekrar eden anahtar: ${key}`);
      this.ids[key] = cid;
    }
    this._track(x, y, w, h);
    this.cells.push(
      `<mxCell id="${cid}" value="${br(label || "")}" style="${style}" vertex="1" parent="1">` +
      `<mxGeometry x="${x}" y="${y}" width="${w}" height="${h}" as="geometry"/></mxCell>`
    );
    return cid;
  }

  // Zone: cluster/bölge arka planı
  zone(x, y, w, h, title, zoneKey) {
    return this._vertex(null, x, y, w, h, title, P.zoneStyle(P.Z[zoneKey]));
  }

  // Namespace: kesikli çerçeve
  ns(x, y, w, h, title, color) {
    return this._vertex(null, x, y, w, h, title, P.nsStyle(color));
  }

  // Pod / bileşen kutusu (renk türüne göre)
  node(key, x, y, w, h, label, kind, size) {
    return this._vertex(key, x, y, w, h, label, P.nodeStyle(kind, size));
  }

  // Pod içi container
  container(key, x, y, w, h, label) {
    return this._vertex(key, x, y, w, h, label, P.containerStyle());
  }

  // Pod'a bağlı kaynak (ConfigMap / Secret / PVC)
  resource(key, x, y, w, h, label) {
    return this._vertex(key, x, y, w, h, label, P.resourceStyle());
  }

  // I/O sütun kutusu
  io(key, x, y, w, h, label, kind) {
    return this._vertex(key, x, y, w, h, label, P.ioStyle(kind));
  }

  fw(key, x, y, label) {
    return this._vertex(key, x, y, 58, 30, label, P.firewallStyle());
  }

  text(x, y, w, h, html, style) {
    return this._vertex(null, x, y, w, h, html, style || "text;html=1;fontSize=11;align=left;verticalAlign=middle;fontColor=#1F2937;");
  }

  // Bağlı ok (kutular arasında). kind: request | internal | response | telemetry | planned
  edge(src, tgt, label, kind = "request") {
    if (!this.ids[src]) throw new Error(`[${this.name}] ok kaynağı yok: ${src}`);
    if (!this.ids[tgt]) throw new Error(`[${this.name}] ok hedefi yok: ${tgt}`);
    this.cells.push(
      `<mxCell id="${this._id()}" value="${br(label || "")}" style="${P.edgeStyle(kind)}" edge="1" parent="1" ` +
      `source="${this.ids[src]}" target="${this.ids[tgt]}"><mxGeometry relative="1" as="geometry"/></mxCell>`
    );
  }

  // Kimlikle verilen iki hücre arasında ham stil ile ok (sequence okları için)
  link(srcId, tgtId, label, style) {
    this.cells.push(
      `<mxCell id="${this._id()}" value="${br(label || "")}" style="${style}" edge="1" parent="1" ` +
      `source="${srcId}" target="${tgtId}"><mxGeometry relative="1" as="geometry"/></mxCell>`
    );
  }

  // Kutu: anahtar ve ham stil ile (sequence katılımcıları gibi özel görünümler)
  box(key, x, y, w, h, label, style) {
    return this._vertex(key, x, y, w, h, label, style);
  }

  build(padding = 40) {
    return {
      name: this.name,
      width: Math.max(this.maxX + padding, 600),
      height: Math.max(this.maxY + padding, 400),
      body: this.cells.join("\n        "),
    };
  }
}

// Tüm sayfaları tek bir .drawio dosyasında (her sayfa bir tab) birleştirir.
function mxfile(pages, agent) {
  const diagrams = pages.map((d, i) => `  <diagram id="p${i + 1}" name="${esc(d.name)}">
    <mxGraphModel dx="1400" dy="900" grid="1" gridSize="10" guides="1" tooltips="1" connect="1" arrows="1" fold="1" page="0" pageScale="1" pageWidth="${d.width}" pageHeight="${d.height}" math="0" shadow="0">
      <root>
        <mxCell id="0"/>
        <mxCell id="1" parent="0"/>
        ${d.body}
      </root>
    </mxGraphModel>
  </diagram>`);
  return `<?xml version="1.0" encoding="UTF-8"?>
<mxfile host="app.diagrams.net" agent="${esc(agent)}" version="24.0.0" type="device">
${diagrams.join("\n")}
</mxfile>
`;
}

module.exports = { Page, mxfile, esc };
