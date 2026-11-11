// Sequence diyagramları (draw.io sayfaları). Kaynak tanımlar: sequence-defs.js.
// Oklar, her mesajın iki ucundaki görünmez bağlantı noktalarına (anchor) bağlanır: böylece her zaman çizilir.
const { Page } = require("./builder.js");
const { SEQ } = require("./palette.js");
const defs = [...require("./sequence-defs.js"), ...require("./sequence-defs-branch.js")];

const X0 = 40;
const SPACING = 190;
const HEADER_Y = 40;
const HEADER_H = 64;
const FIRST_MSG_Y = 130;
const STEP = 46;

const INVISIBLE = "shape=ellipse;perimeter=ellipsePerimeter;fillColor=none;strokeColor=none;";
const LIFELINE = "endArrow=none;dashed=1;dashPattern=4 4;strokeColor=#94A3B8;strokeWidth=1.1;edgeStyle=none;";

function sequencePage(def) {
  const p = new Page(def.name);
  const idx = Object.fromEntries(def.participants.map((q, i) => [q.id, i]));
  const cx = (id) => X0 + idx[id] * SPACING + 75; // yaşam çizgisi x merkezi

  p.text(X0, 6, 1100, 28, def.title,
    "text;html=1;fontStyle=1;fontSize=16;align=left;verticalAlign=middle;fontColor=#1F2937;");

  // Mesaj y koordinatları
  let y = FIRST_MSG_Y;
  const msgY = def.messages.map((m) => {
    if (m.gap) y += m.gap;
    const my = y;
    y += STEP;
    return my;
  });
  const bottom = Math.max(...msgY, FIRST_MSG_Y) + 60;

  // Katılımcı başlıkları ve yaşam çizgileri
  const head = {};
  const foot = {};
  for (const q of def.participants) {
    const x = cx(q.id);
    head[q.id] = p.box(`h_${q.id}`, x - 85, HEADER_Y, 170, HEADER_H, q.label,
      `rounded=1;whiteSpace=wrap;html=1;fillColor=${q.color || "#FFFFFF"};strokeColor=#334155;strokeWidth=1.3;` +
      "fontStyle=1;fontSize=11;fontColor=#1F2937;");
    foot[q.id] = p.box(null, x - 1, bottom, 2, 2, "", INVISIBLE);
    p.link(head[q.id], foot[q.id], "", LIFELINE);
  }

  // Notlar (katılımcının üstünde)
  for (const n of def.notes || []) {
    p.box(null, cx(n.over) - 110, n.y, 220, n.h || 60, n.text,
      "shape=note;whiteSpace=wrap;html=1;size=8;fillColor=#FEF9C3;strokeColor=#CA8A04;fontSize=11;align=left;");
  }

  // Mesajlar
  def.messages.forEach((m, i) => {
    const my = msgY[i];
    if (m.self) {
      p.box(null, cx(m.from) + 6, my - 14, 180, 30, m.label,
        "rounded=0;whiteSpace=wrap;html=1;fontSize=10;fillColor=#DBEAFE;strokeColor=#1D4ED8;align=left;");
      return;
    }
    const a = p.box(null, cx(m.from) - 1, my - 1, 2, 2, "", INVISIBLE);
    const b = p.box(null, cx(m.to) - 1, my - 1, 2, 2, "", INVISIBLE);
    let style = SEQ.normal;
    if (m.internalToken) style = SEQ.internal;
    else if (m.plannedToken) style = SEQ.planned;
    else if (m.ret) style = SEQ.ret;
    p.link(a, b, m.label, style);
  });

  // Alt kutu: kontroller ve lab/prod farkı
  let footerH = 0;
  if (def.footer) {
    const fw = def.participants.length * SPACING - 60;
    footerH = 16 + def.footer.length * 30;
    p.box(null, X0, bottom + 10, fw, footerH, def.footer.join("\n"),
      "rounded=1;whiteSpace=wrap;html=1;align=left;verticalAlign=top;fillColor=#F8FAFC;strokeColor=#CBD5E1;fontSize=11;spacing=8;");
  }

  // Ok lejantı
  const ly = bottom + 10 + footerH + 16;
  p.text(X0, ly, 1000, 22,
    "<span style='color:#334155'>━━ istek</span>&nbsp;&nbsp;&nbsp;" +
    "<span style='color:#94A3B8'>╍╍ yanıt</span>&nbsp;&nbsp;&nbsp;" +
    "<span style='color:#B91C1C'><b>━━ iç JWT (yalnız iç ağda)</b></span>&nbsp;&nbsp;&nbsp;" +
    "<span style='color:#9CA3AF'>╍╍ planlı / prod</span>",
    "text;html=1;fontSize=11;align=left;verticalAlign=middle;");

  return p.build(40);
}

function sequencePages() {
  return defs.map(sequencePage);
}

module.exports = { sequencePages };
