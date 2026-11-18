// Sequence diagramları (draw.io sayfaları). Kaynak tanımlar: sequence-defs.js (ve diğer *-defs*.js).
// Oklar, her mesajın iki ucundaki görünmez bağlantı noktalarına (anchor) bağlanır: böylece her zaman çizilir.
//
// Mesaj listesinde ek öğeler (mevcut tanımlar bunları kullanmaz, geriye dönük uyumlu):
//   { frag: "opt" | "alt" | "loop", label }   çerçeve başlangıcı (yer kaplamaz)
//   { frag: "else", label }                    alt içinde ikinci dal (yer kaplamaz)
//   { frag: "end" }                            çerçeve bitişi (yer kaplamaz)
//   { note: "metin", over: "katılımcıId" }     katılımcı üstünde not (kendi satırını kaplar)
//   { gap: 30 }                                önceki mesajdan sonra dikey boşluk (ör. ||30||)
// Her sayfanın altında "Adım legend'ı": çerçeve, not ve boşluk hariç her adım numaralı, gönderen -> alıcı ile.
const { Page } = require("./builder.js");
const { SEQ } = require("./palette.js");
const defs = [...require("./sequence-defs.js"), ...require("./sequence-defs-branch.js")];

const X0 = 40;
const SPACING = 190;
const HEADER_Y = 40;
const HEADER_H = 64;
const FIRST_MSG_Y = 130;
const STEP = 46;
const NOTE_H = 44;
const NOTE_STEP = 56;

const INVISIBLE = "shape=ellipse;perimeter=ellipsePerimeter;fillColor=none;strokeColor=none;";
const LIFELINE = "endArrow=none;dashed=1;dashPattern=4 4;strokeColor=#94A3B8;strokeWidth=1.1;edgeStyle=none;";
const FRAME = "rounded=0;whiteSpace=wrap;html=1;fillColor=none;strokeColor=#64748B;strokeWidth=1.1;dashed=1;dashPattern=4 3;";
const FRAME_TAB = "rounded=0;whiteSpace=wrap;html=1;fontSize=10;fontStyle=1;fillColor=#E2E8F0;strokeColor=#64748B;align=left;spacingLeft=4;";
const MSG_NOTE = "shape=note;whiteSpace=wrap;html=1;size=8;fillColor=#FEF9C3;strokeColor=#CA8A04;fontSize=10;align=left;spacing=4;";
const LEGEND = "rounded=1;whiteSpace=wrap;html=1;align=left;verticalAlign=top;fillColor=#FFFFFF;strokeColor=#CBD5E1;fontSize=10;spacing=6;";

const isFrag = (m) => Boolean(m.frag);

function sequencePage(def) {
  const p = new Page(def.name);
  const idx = Object.fromEntries(def.participants.map((q, i) => [q.id, i]));
  const cx = (id) => X0 + idx[id] * SPACING + 75; // yaşam çizgisi x merkezi

  p.text(X0, 6, 1100, 28, def.title,
    "text;html=1;fontStyle=1;fontSize=16;align=left;verticalAlign=middle;fontColor=#1F2937;");

  // Mesaj y koordinatları (çerçeve ve notlar yer kaplar; çerçeve işaretleri kaplamaz)
  let y = FIRST_MSG_Y;
  const msgY = def.messages.map((m) => {
    if (m.gap) y += m.gap;
    const my = y;
    if (!isFrag(m)) y += m.note ? NOTE_STEP : STEP;
    return my;
  });
  const bottom = Math.max(...msgY, FIRST_MSG_Y) + 60;

  // Katılımcı başlıkları ve yaşam çizgileri
  for (const q of def.participants) {
    const x = cx(q.id);
    const head = p.box(`h_${q.id}`, x - 85, HEADER_Y, 170, HEADER_H, q.label,
      `rounded=1;whiteSpace=wrap;html=1;fillColor=${q.color || "#FFFFFF"};strokeColor=#334155;strokeWidth=1.3;` +
      "fontStyle=1;fontSize=11;fontColor=#1F2937;");
    const foot = p.box(null, x - 1, bottom, 2, 2, "", INVISIBLE);
    p.link(head, foot, "", LIFELINE);
  }

  // Notlar (katılımcının üstünde; eski tanımlar için)
  for (const n of def.notes || []) {
    p.box(null, cx(n.over) - 110, n.y, 220, n.h || 60, n.text,
      "shape=note;whiteSpace=wrap;html=1;size=8;fillColor=#FEF9C3;strokeColor=#CA8A04;fontSize=11;align=left;");
  }

  // Çerçeveler (opt / alt / loop): önce hesaplanır, sonra çizilir (oklar üstte kalsın)
  const frames = [];
  const stack = [];
  def.messages.forEach((m, i) => {
    if (m.frag === "opt" || m.frag === "alt" || m.frag === "loop") {
      stack.push({ type: m.frag, label: m.label, y0: msgY[i], elses: [] });
    } else if (m.frag === "else") {
      const top = stack[stack.length - 1];
      if (!top) throw new Error(`[${def.name}] else çerçevesiz`);
      top.elses.push({ y: msgY[i], label: m.label });
    } else if (m.frag === "end") {
      const top = stack.pop();
      if (!top) throw new Error(`[${def.name}] end çerçevesiz`);
      frames.push({ ...top, y1: msgY[i] });
    }
  });
  if (stack.length) throw new Error(`[${def.name}] kapanmamış çerçeve: ${stack[0].type}`);
  const first = def.participants[0].id;
  const last = def.participants[def.participants.length - 1].id;
  for (const f of frames) {
    const x0 = cx(first) - 95;
    const x1 = cx(last) + 95;
    const top = f.y0 - 16;
    const bot = f.y1 + 4;
    p.box(null, x0, top, x1 - x0, bot - top, "", FRAME);
    p.box(null, x0, top, 220, 18, `${f.type}: ${f.label || ""}`, FRAME_TAB);
    for (const e of f.elses) {
      p.box(null, x0, e.y - 9, x1 - x0, 18, `else: ${e.label || ""}`,
        "rounded=0;whiteSpace=wrap;html=1;fillColor=none;strokeColor=none;fontSize=10;fontStyle=2;align=left;spacingLeft=6;");
      p.box(null, x0, e.y, x1 - x0, 0, "", "shape=line;strokeColor=#64748B;dashed=1;dashPattern=4 3;");
    }
  }

  // Mesajlar ve notlar
  def.messages.forEach((m, i) => {
    if (isFrag(m)) return;
    const my = msgY[i];
    if (m.note) {
      p.box(null, cx(m.over) - 130, my - 6, 260, NOTE_H, m.note, MSG_NOTE);
      return;
    }
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
    p.box(null, X0, bottom + 10, fw, footerH, def.footer.join("\n"), LEGEND);
  }

  // Adım legend'ı: çerçeve, not ve boşluk hariç her adım numaralı, gönderen -> alıcı ile
  const nameOf = (id) => {
    const q = def.participants.find((x) => x.id === id);
    return (q ? q.label : id).split("\n")[0];
  };
  const steps = def.messages.filter((m) => !isFrag(m) && !m.note && !m.gap);
  const legendLines = steps.map((m, k) => (m.self
    ? `${k + 1}. [${nameOf(m.from)}] kendi içinde: ${m.label}`
    : `${k + 1}. [${nameOf(m.from)}] -> [${nameOf(m.to)}]: ${m.label}`));
  const legendY = bottom + 10 + footerH + 16;
  const legendH = 26 + legendLines.length * 16;
  p.box(null, X0, legendY, Math.max(1000, def.participants.length * SPACING - 60), legendH,
    ["Adım legend'ı", ...legendLines].join("\n"), LEGEND);

  // Ok lejantı
  const ly = legendY + legendH + 14;
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

module.exports = { sequencePages, sequencePage };
