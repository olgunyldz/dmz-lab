// Ortak palet ve stil fonksiyonları: tüm draw.io sayfaları bu dosyayı kullanır.
// Renk anlamı: bölge = cluster/zone; düğüm = bileşen türü; ok = trafik türü.

const C = {
  ink: "#1F2937", muted: "#64748B", line: "#334155", red: "#B91C1C", blue: "#2563EB", planned: "#9CA3AF",
};

// Bölge (zone) renkleri
const Z = {
  internet: { fill: "#F8FAFC", stroke: "#94A3B8", title: "#334155" },
  edge:     { fill: "#FFF8E6", stroke: "#D97706", title: "#92400E" },
  dmz:      { fill: "#FDF0E6", stroke: "#EA580C", title: "#9A3412" },
  internal: { fill: "#EAF2FB", stroke: "#2563EB", title: "#1E40AF" },
  identity: { fill: "#F3EEFA", stroke: "#7C3AED", title: "#5B21B6" },
  mgmt:     { fill: "#EDF8F0", stroke: "#15803D", title: "#166534" },
  ops:      { fill: "#F5F5F5", stroke: "#9CA3AF", title: "#4B5563" },
  host:     { fill: "#F1F5F9", stroke: "#475569", title: "#1E293B" },
  branch:   { fill: "#F0FDFA", stroke: "#0F766E", title: "#115E59" },
};

// Düğüm türleri (bileşen / pod)
const N = {
  client:   { fill: "#FFFFFF", stroke: "#64748B" },
  edge:     { fill: "#FEF3C7", stroke: "#B45309" },
  dmz:      { fill: "#FFEDD5", stroke: "#C2410C" },
  internal: { fill: "#DBEAFE", stroke: "#1D4ED8" },
  identity: { fill: "#EDE9FE", stroke: "#6D28D9" },
  mgmt:     { fill: "#DCFCE7", stroke: "#15803D" },
  host:     { fill: "#F1F5F9", stroke: "#475569" },
  branch:   { fill: "#CCFBF1", stroke: "#0F766E" },
  note:     { fill: "#F8FAFC", stroke: "#CBD5E1", dashed: true },
  planned:  { fill: "#FFFFFF", stroke: "#9CA3AF", dashed: true },
};

// Ok türleri
const E = {
  request:  `endArrow=classic;html=1;rounded=1;strokeColor=${C.line};strokeWidth=1.3;fontSize=10;fontColor=${C.line};labelBackgroundColor=#FFFFFF;edgeStyle=orthogonalEdgeStyle;`,
  internal: `endArrow=classic;html=1;rounded=1;strokeColor=${C.red};strokeWidth=2.6;fontSize=10;fontStyle=1;fontColor=${C.red};labelBackgroundColor=#FFFFFF;edgeStyle=orthogonalEdgeStyle;`,
  response: `endArrow=open;html=1;rounded=1;strokeColor=${C.muted};strokeWidth=1.2;dashed=1;dashPattern=5 4;fontSize=10;fontColor=${C.muted};labelBackgroundColor=#FFFFFF;edgeStyle=orthogonalEdgeStyle;`,
  telemetry:`endArrow=classic;html=1;rounded=1;strokeColor=${C.blue};strokeWidth=1.4;dashed=1;dashPattern=2 3;fontSize=10;fontColor=#1D4ED8;labelBackgroundColor=#FFFFFF;edgeStyle=orthogonalEdgeStyle;`,
  planned:  `endArrow=classic;html=1;rounded=1;strokeColor=${C.planned};strokeWidth=1.2;dashed=1;dashPattern=6 4;fontSize=10;fontColor=${C.muted};labelBackgroundColor=#FFFFFF;edgeStyle=orthogonalEdgeStyle;`,
};

// Sequence okları: düz (orthogonal değil), her zaman görünür
const SEQ = {
  normal:   `endArrow=classic;html=1;strokeColor=${C.line};strokeWidth=1.4;fontSize=10;fontColor=${C.ink};labelBackgroundColor=#FFFFFF;edgeStyle=none;`,
  ret:      `endArrow=open;html=1;dashed=1;dashPattern=5 4;strokeColor=${C.muted};strokeWidth=1.2;fontSize=10;fontColor=${C.muted};labelBackgroundColor=#FFFFFF;edgeStyle=none;`,
  internal: `endArrow=classic;html=1;strokeColor=${C.red};strokeWidth=2.6;fontSize=10;fontStyle=1;fontColor=${C.red};labelBackgroundColor=#FFFFFF;edgeStyle=none;`,
  planned:  `endArrow=classic;html=1;dashed=1;dashPattern=6 4;strokeColor=${C.planned};strokeWidth=1.3;fontSize=10;fontColor=${C.muted};labelBackgroundColor=#FFFFFF;edgeStyle=none;`,
};

function zoneStyle(z) {
  return `rounded=1;whiteSpace=wrap;html=1;arcSize=3;fillColor=${z.fill};strokeColor=${z.stroke};strokeWidth=1.6;` +
    `verticalAlign=top;align=left;spacingLeft=12;spacingTop=8;fontStyle=1;fontSize=13;fontColor=${z.title};`;
}

// Namespace: kesikli çerçeve, zone içinde
function nsStyle(color) {
  return `rounded=1;whiteSpace=wrap;html=1;arcSize=4;fillColor=#FFFFFF;strokeColor=${color};strokeWidth=1.2;` +
    `dashed=1;dashPattern=6 3;verticalAlign=top;align=left;spacingLeft=8;spacingTop=5;fontStyle=1;fontSize=11;fontColor=${color};`;
}

// Pod: düğüm türüne göre renkli
function nodeStyle(kind, size = 11) {
  const n = N[kind] || N.client;
  return `rounded=1;whiteSpace=wrap;html=1;arcSize=14;fillColor=${n.fill};strokeColor=${n.stroke};strokeWidth=1.3;` +
    `${n.dashed ? "dashed=1;dashPattern=4 3;" : ""}fontSize=${size};fontColor=${C.ink};spacing=6;`;
}

// Pod içindeki container: beyaz, ince çerçeve
function containerStyle() {
  return `rounded=1;whiteSpace=wrap;html=1;arcSize=10;fillColor=#FFFFFF;strokeColor=#94A3B8;strokeWidth=1;` +
    `fontSize=10;fontColor=${C.ink};align=left;spacingLeft=6;`;
}

// Pod'a bağlı kaynak (ConfigMap, Secret, PVC): kesikli, gri
function resourceStyle() {
  return `rounded=0;whiteSpace=wrap;html=1;fillColor=#FAFAF9;strokeColor=#A8A29E;dashed=1;dashPattern=2 2;` +
    `fontSize=9;fontColor=#57534E;align=left;spacingLeft=4;`;
}

// I/O sütunları
function ioStyle(kind) {
  const s = {
    input:  `rounded=1;whiteSpace=wrap;html=1;arcSize=8;fillColor=#F1F5F9;strokeColor=#64748B;fontSize=10;fontColor=${C.ink};align=left;spacingLeft=8;`,
    output: `rounded=1;whiteSpace=wrap;html=1;arcSize=8;fillColor=#ECFDF5;strokeColor=#15803D;fontSize=10;fontColor=${C.ink};align=left;spacingLeft=8;`,
    tool:   `rounded=1;whiteSpace=wrap;html=1;arcSize=8;fillColor=#FFFBEB;strokeColor=#B45309;dashed=1;fontSize=10;fontColor=${C.ink};align=left;spacingLeft=8;`,
  };
  return s[kind];
}

function firewallStyle() {
  return `shape=hexagon;perimeter=hexagonPerimeter2;whiteSpace=wrap;html=1;fillColor=#FEE2E2;strokeColor=${C.red};` +
    `strokeWidth=1.5;fontStyle=1;fontSize=10;fontColor=${C.red};`;
}

function edgeStyle(kind) {
  return E[kind] || E.request;
}

module.exports = { C, Z, N, E, SEQ, zoneStyle, nsStyle, nodeStyle, containerStyle, resourceStyle, ioStyle, firewallStyle, edgeStyle };
