"use client";
import { useState, useEffect } from "react";
import { api } from "./api.js";
import { Shell } from "./Ui.jsx";
import { Ops } from "./Ops.jsx";


// ------------------------------------------------------------ İşlemler sayfası (giriş yapılmış kanal)
export function OpsPage() {
  const [channel, setChannel] = useState(null);
  const [loaded, setLoaded] = useState(false);
  useEffect(() => {
    api("/api/state").then((r) => {
      const s = r.data || {};
      const ch = s.web && s.web.loggedIn ? "web" : s.mobile && s.mobile.loggedIn ? "mobile" : null;
      setChannel(ch); setLoaded(true);
    });
  }, []);
  if (!loaded) return <Shell title="Hesap işlemleri"><p className="muted">Yükleniyor…</p></Shell>;
  if (!channel) return <Shell title="Hesap işlemleri"><p className="info">Önce bir kanaldan giriş yapın.</p><a href="/">Kanallara dön</a></Shell>;
  return <Shell title="Hesap işlemleri"><Ops channel={channel} /></Shell>;
}

// ------------------------------------------------------------ SMS kutusu
export function SmsPage() {
  const [box, setBox] = useState({ web: null, mobile: null });
  const [copied, setCopied] = useState("");
  useEffect(() => {
    let alive = true;
    const pull = () => api("/api/sms").then((r) => { if (alive && r.ok) setBox(r.data); });
    pull();
    const id = setInterval(pull, 2000);
    return () => { alive = false; clearInterval(id); };
  }, []);
  const rows = [["web", "Web"], ["mobile", "Mobil"]];
  return (
    <Shell title="SMS kutusu (lab)">
      <p className="info">Lab ortamında gönderilen kodlar burada görünür. Sayfa 2 saniyede bir yenilenir.</p>
      {rows.map(([k, label]) => (
        <div className="card-form sms-card" key={k}>
          <strong>{label}</strong>
          {box[k] ? (
            <>
              <div className="code">{box[k].demoOtp}</div>
              <small className="muted">{box[k].at}</small>
              <button onClick={() => { navigator.clipboard && navigator.clipboard.writeText(box[k].demoOtp); setCopied(k); setTimeout(() => setCopied(""), 1200); }}>{copied === k ? "Kopyalandı" : "Kopyala"}</button>
            </>
          ) : <span className="muted">Henüz kod yok</span>}
        </div>
      ))}
    </Shell>
  );
}

// ------------------------------------------------------------ Giriş (kanal kartları)
export function HomePage() {
  const channels = [
    { name: "Mobil", desc: "Cihaz ve PIN, SMS (yeni cihaz), hesap işlemleri", href: "/mobil", active: true },
    { name: "Web", desc: "Müşteri no, parola, SMS kodu", href: "/web", active: true },
    { name: "Şube", desc: "Şube terminali ve görevli girişi", href: null },
    { name: "Çağrı merkezi", desc: "Müşteri temsilcisi işlemleri", href: null },
    { name: "POS", desc: "Üye işyeri cihazı işlemleri", href: null },
    { name: "ATM", desc: "Nakit çekme ve bakiye sorgusu", href: null },
    { name: "Partner", desc: "Dış kurum (B2B) entegrasyonu", href: null },
  ];
  return (
    <Shell title="DMZ Lab Konsolu">
      <p className="info">Bir kanal seçin. Aktif kanal kartına tıklayınca o kanalın giriş ekranı açılır.</p>
      <div className="channels">
        {channels.map((c) => c.href ? (
          <a key={c.name} className="chan active" href={c.href}>
            <strong>{c.name}</strong><small>{c.desc}</small><span className="badge ok">Aktif</span>
          </a>
        ) : (
          <div key={c.name} className="chan disabled" aria-disabled="true">
            <strong>{c.name}</strong><small>{c.desc}</small><span className="badge">Yakında</span>
          </div>
        ))}
      </div>
      <p className="muted" style={{ marginTop: 14 }}>
        Hesap işlemleri için önce bir kanaldan giriş yapın: <a href="/islemler">Hesap işlemleri</a>. SMS kodları: <a href="/sms">SMS kutusu</a>.
      </p>
    </Shell>
  );
}

