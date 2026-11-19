// DMZ Lab konsolu (React). Tek uygulama; sayfa yoluna göre ekran seçilir:
//   /         kanal kartları (giriş)
//   /web      Web girişi, sonra hesap işlemleri (kanal: web)
//   /mobil    Mobil uygulama (giriş sihirbazı, sonra alt menülü uygulama; kanal: mobile)
//   /islemler Hesap işlemleri (giriş yapılmış kanal)
//   /sms      Lab SMS kutusu (2 sn'de bir yenilenir)
// Arka uç: console/app.py API'leri (/api/*). Her istek trace kimliği döner (X-Trace-Id).
import { useState, useEffect } from "react";
import Bank, { newTid } from "./bank-mock.js";

const JAEGER = "http://127.0.0.1:16686";
const GRAFANA = "http://127.0.0.1:3000";

async function api(path, body) {
  const B = Bank;
  const tid = newTid();
  const m = (p) => path === p;
  let data;
  if (m("/api/state")) data = await B.state();
  else if (m("/api/sms")) data = await B.sms();
  else if (m("/api/web/otp")) data = await B.requestOtp("web");
  else if (m("/api/web/login")) data = await B.webLogin(body);
  else if (m("/api/mobile/login")) data = await B.mobileLogin(body);
  else if (m("/api/transaction")) data = await B.tx(body.channel, body.code, body.params || {});
  else if (m("/api/logout")) data = await B.logout(body.channel);
  else data = { error: "bulunamadı" };
  const ok = !data.error;
  return { ok, status: ok ? 200 : 400, data, tid };
}

const fmtTL = (s) =>
  Number(s).toLocaleString("tr-TR", { minimumFractionDigits: 2, maximumFractionDigits: 2 }) + " TL";
const parseAmount = (v) => {
  let s = String(v).trim();
  if (s.includes(",")) s = s.replace(/\./g, "").replace(",", ".");
  if (!/^\d+(\.\d{1,2})?$/.test(s)) return null;
  return Number(s) > 0 ? s : null;
};

// İz bağlantısı: Grafana'da Loki günlüğü, Jaeger'da span ağacı
function TraceLinks({ tid, label }) {
  return null;
  return (
    <p className="trace small muted">
      {label ? label + ": " : ""}
      <a href={GRAFANA + "/d/dmz-lab-trace-lookup?orgId=1&from=now-1h&to=now&var-traceId=" + encodeURIComponent(tid)} target="_blank" rel="noopener">Log</a>
      {" · "}
      <a href={JAEGER + "/trace/" + encodeURIComponent(tid)} target="_blank" rel="noopener">Jaeger</a>
      {" "}<code title={tid}>{tid.slice(0, 12)}…</code>
    </p>
  );
}

// ------------------------------------------------------------ hesap işlemleri (kanala göre)
const TAB_OF = { home: "balance", history: "history", transfer: "transfer" };

function Ops({ channel, onLogout, compact, tabOverride }) {
  const [tab, setTab] = useState(TAB_OF[tabOverride] || "balance");
  const [accounts, setAccounts] = useState([]);
  const [status, setStatus] = useState({ msg: "", ok: true });
  const [tid, setTid] = useState("");
  const [rows, setRows] = useState([]);
  const [hAcc, setHAcc] = useState("");
  const [t, setT] = useState({ to: "", amt: "", desc: "" });
  const [stage, setStage] = useState("form"); // form | confirm | receipt
  const [receipt, setReceipt] = useState(null);

  async function tx(code, params) {
    const r = await api("/api/transaction", { channel, code, params: params || {} });
    setTid(r.tid);
    return r;
  }
  async function loadBalance() {
    const r = await tx("BALANCE");
    if (!r.ok) return setStatus({ msg: r.data.error || "Bakiye alınamadı", ok: false });
    const list = r.data.accounts || [];
    setAccounts(list);
    if (!hAcc && list[0]) setHAcc(list[0].id);
    setStatus({ msg: "Bakiye güncellendi", ok: true });
  }
  async function loadHistory() {
    const acc = hAcc || (accounts[0] && accounts[0].id);
    if (!acc) return setStatus({ msg: "Hesap bulunamadı; önce bakiyeyi yükleyin", ok: false });
    const r = await tx("HISTORY", { account: acc, limit: 20 });
    if (!r.ok) return setStatus({ msg: r.data.error || "Hareketler alınamadı", ok: false });
    setRows(r.data.transactions || []);
    setStatus({ msg: (r.data.transactions || []).length + " hareket listelendi", ok: true });
  }
  function review(e) {
    e.preventDefault();
    const from = accounts[0] && accounts[0].id;
    const to = t.to.trim().toUpperCase();
    const amt = parseAmount(t.amt);
    if (!from) return setStatus({ msg: "Önce bakiyeyi yükleyin", ok: false });
    if (!to) return setStatus({ msg: "Alıcı hesap no girin", ok: false });
    if (to === from) return setStatus({ msg: "Gönderen ve alıcı aynı olamaz", ok: false });
    if (!amt) return setStatus({ msg: "Tutarı kontrol edin (örn. 150 veya 150,50)", ok: false });
    setStage("confirm");
    setStatus({ msg: "Bilgileri onaylayın", ok: true });
  }
  async function send() {
    const from = accounts[0].id;
    const r = await tx("TRANSFER", { fromAccount: from, toAccount: t.to.trim().toUpperCase(), amount: parseAmount(t.amt), description: t.desc.trim() || "Havale" });
    if (!r.ok) return setStatus({ msg: r.data.error || "Havale yapılamadı", ok: false });
    setReceipt(r.data);
    setStage("receipt");
    setStatus({ msg: "", ok: true });
    loadBalance();
  }
  function resetTransfer() {
    setStage("form");
    setT({ to: "", amt: "", desc: "" });
    setReceipt(null);
  }

  useEffect(() => { loadBalance(); }, []);

  const tabs = [["balance", "Bakiye", loadBalance], ["history", "Hareketler", () => { setTab("history"); loadHistory(); }], ["transfer", "Havale / EFT", () => { setTab("transfer"); resetTransfer(); }]];

  return (
    <section className={"ops " + (compact ? "compact" : "")}>
      {!compact && <h2>Hesap işlemleri</h2>}
      <nav className="ops-tabs">
        {tabs.map(([k, label, fn]) => (
          <button key={k} className={tab === k ? "primary" : ""} onClick={() => { if (k === "balance") setTab("balance"); fn(); }}>{label}</button>
        ))}
      </nav>

      {tab === "balance" && (
        <div className="table-wrap">
          <table>
            <thead><tr><th>Hesap</th><th>Tür</th><th className="num">Bakiye</th></tr></thead>
            <tbody>
              {accounts.length === 0 && <tr><td colSpan="3" className="muted">Bakiye yükleniyor…</td></tr>}
              {accounts.map((a) => <tr key={a.id}><td>{a.id}</td><td>{a.type}</td><td className="num">{fmtTL(a.balance)}</td></tr>)}
            </tbody>
          </table>
        </div>
      )}

      {tab === "history" && (
        <div>
          <label className="field"><span>Hesap</span>
            <select value={hAcc} onChange={(e) => setHAcc(e.target.value)}>
              {accounts.map((a) => <option key={a.id} value={a.id}>{a.id} · {fmtTL(a.balance)}</option>)}
            </select>
          </label>
          <button className="primary" onClick={loadHistory}>Hareketleri göster</button>
          <div className="table-wrap">
            <table>
              <thead><tr><th>Tarih</th><th>Açıklama</th><th>Karşı taraf</th><th className="num">Tutar</th><th className="num">Bakiye</th></tr></thead>
              <tbody>
                {rows.length === 0 && <tr><td colSpan="5" className="muted">Hareket yok</td></tr>}
                {rows.map((x, i) => {
                  const credit = x.direction === "CREDIT";
                  return (
                    <tr key={i}>
                      <td>{new Date(x.at).toLocaleString("tr-TR")}</td>
                      <td>{x.description}</td>
                      <td>{x.counterpart}</td>
                      <td className={"num " + (credit ? "ok" : "bad")}>{(credit ? "+" : "−") + fmtTL(x.amount)}</td>
                      <td className="num">{fmtTL(x.balanceAfter)}</td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        </div>
      )}

      {tab === "transfer" && stage === "form" && (
        <form onSubmit={review}>
          <label className="field"><span>Gönderen hesap</span>
            <select disabled><option>{accounts[0] ? accounts[0].id + " · " + fmtTL(accounts[0].balance) : "Yükleniyor…"}</option></select>
          </label>
          <label className="field"><span>Alıcı hesap no</span>
            <input value={t.to} onChange={(e) => setT({ ...t, to: e.target.value })} placeholder="örn. TR000000000002" autoComplete="off" />
          </label>
          <label className="field"><span>Tutar (TL)</span>
            <input value={t.amt} onChange={(e) => setT({ ...t, amt: e.target.value })} inputMode="decimal" placeholder="örn. 150 veya 150,50" autoComplete="off" />
          </label>
          <label className="field"><span>Açıklama (isteğe bağlı)</span>
            <input value={t.desc} onChange={(e) => setT({ ...t, desc: e.target.value })} maxLength={140} autoComplete="off" />
          </label>
          <button className="primary">Devam</button>
        </form>
      )}

      {tab === "transfer" && stage === "confirm" && (
        <div>
          <p className="info">Bilgileri kontrol edin. "Onayla ve gönder" ile havale yapılır.</p>
          <dl className="summary">
            <dt>Gönderen</dt><dd>{accounts[0] && accounts[0].id}</dd>
            <dt>Alıcı</dt><dd>{t.to.trim().toUpperCase()}</dd>
            <dt>Tutar</dt><dd>{fmtTL(parseAmount(t.amt))}</dd>
            <dt>Açıklama</dt><dd>{t.desc.trim() || "Havale"}</dd>
          </dl>
          <div className="actions">
            <button onClick={() => setStage("form")}>Düzenle</button>
            <button className="primary" onClick={send}>Onayla ve gönder</button>
          </div>
        </div>
      )}

      {tab === "transfer" && stage === "receipt" && receipt && (
        <div className="receipt">
          <div className="success">✔ Havale tamamlandı. Referans: {receipt.reference}</div>
          <dl className="summary">
            <dt>Tutar</dt><dd>{fmtTL(receipt.amount)}</dd>
            <dt>Alıcı</dt><dd>{receipt.toAccount}</dd>
            <dt>Kalan bakiye</dt><dd>{fmtTL(receipt.balanceAfter)}</dd>
            <dt>Alıcı bu bankada</dt><dd>{receipt.internal ? "Evet" : "Hayır (dış hesap)"}</dd>
          </dl>
          <button className="primary" onClick={resetTransfer}>Yeni havale</button>
        </div>
      )}

      <p className={"status " + (status.ok ? "ok" : "bad")}>{status.msg}</p>
      <TraceLinks tid={tid} label="İzleme" />
      {onLogout && <button className="ghost" onClick={onLogout}>Çıkış yap</button>}
    </section>
  );
}

// Parola alanı: göster/gizle simgesi ile
function PasswordInput({ value, onChange, ...rest }) {
  const [show, setShow] = useState(false);
  return (
    <span className="pw-wrap">
      <input {...rest} type={show ? "text" : "password"} value={value} onChange={(e) => onChange(e.target.value)} />
      <button type="button" className="pw-toggle" aria-label={show ? "Parolayı gizle" : "Parolayı göster"} title={show ? "Gizle" : "Göster"} onClick={() => setShow(!show)}>
        {show ? "🙈" : "👁"}
      </button>
    </span>
  );
}

// ------------------------------------------------------------ Web girişi
function WebPage() {
  const [user, setUser] = useState(null);
  const [cust, setCust] = useState("C000000001");
  const [pass, setPass] = useState("");
  const [sms, setSms] = useState("");
  const [smsSent, setSmsSent] = useState(false);
  const [status, setStatus] = useState({ msg: "", ok: true });
  const [tid, setTid] = useState("");

  useEffect(() => { api("/api/state").then((r) => { if (r.ok && r.data.web && r.data.web.loggedIn) setUser(r.data.web); }); }, []);

  async function requestOtp() {
    const r = await api("/api/web/otp", {});
    setTid(r.tid);
    if (r.ok) { setSmsSent(true); setStatus({ msg: "Kod gönderildi. Kodu SMS kutusundan alıp yazın.", ok: true }); }
    else setStatus({ msg: r.data.error || "Kod isteği başarısız", ok: false });
  }
  async function login(e) {
    e.preventDefault();
    const r = await api("/api/web/login", { customerId: cust.trim(), password: pass, smsCode: sms.trim() });
    setTid(r.tid);
    if (r.ok) { setPass(""); setSms(""); setUser({ customerId: r.data.customerId, fullName: r.data.fullName }); }
    else setStatus({ msg: r.data.error || "Giriş reddedildi", ok: false });
  }
  async function logout() {
    await api("/api/logout", { channel: "web" });
    setUser(null); setSmsSent(false);
  }

  if (user) {
    return (
      <Shell title={"Web · " + (user.fullName || user.customerId)}>
        <Ops channel="web" onLogout={logout} />
      </Shell>
    );
  }
  return (
    <Shell title="Web girişi">
      <form className="card-form" onSubmit={login}>
        <p className="info">1) Müşteri no ve parolanızı girin. 2) "Tek seferlik kod iste"ye basın; kodu SMS kutusundan alın. 3) Kodu girip "Giriş yap"a basın.</p>
        <label className="field"><span>Müşteri no</span><input value={cust} onChange={(e) => setCust(e.target.value)} inputMode="numeric" autoComplete="username" /></label>
        <label className="field"><span>Parola</span><PasswordInput value={pass} onChange={setPass} autoComplete="current-password" /></label>
        <label className="field"><span>Güvenlik doğrulaması</span><input value="lab-captcha" readOnly /></label>
        <button type="button" onClick={requestOtp}>Tek seferlik kod iste</button>
        {smsSent && <a className="sms-link" href="#/sms" target="_blank" rel="noopener">SMS kutusunu aç ↗ (lab kodu orada)</a>}
        <label className="field"><span>SMS kodu</span><input value={sms} onChange={(e) => setSms(e.target.value)} inputMode="numeric" maxLength={6} autoComplete="one-time-code" placeholder="6 haneli kod" /></label>
        <button className="primary" type="submit">Giriş yap</button>
        <p className={"status " + (status.ok ? "ok" : "bad")}>{status.msg}</p>
        <TraceLinks tid={tid} label="İzleme" />
      </form>
    </Shell>
  );
}

// ------------------------------------------------------------ Mobil uygulama (giriş sihirbazı + alt menü)
function MobilPage() {
  const [user, setUser] = useState(null);
  const [step, setStep] = useState(1);
  const [cust, setCust] = useState("C000000001");
  const [pin, setPin] = useState("4321");
  const [newDevice, setNewDevice] = useState(false);
  const [otp, setOtp] = useState("");
  const [msg, setMsg] = useState({ text: "", ok: true });
  const [busy, setBusy] = useState(false);
  const [tid, setTid] = useState("");
  const [screen, setScreen] = useState("home");
  const [menuOpen, setMenuOpen] = useState(false);

  useEffect(() => { api("/api/state").then((r) => { if (r.ok && r.data.mobile && r.data.mobile.loggedIn) setUser(r.data.mobile); }); }, []);

  async function login(extra) {
    setBusy(true);
    const r = await api("/api/mobile/login", { customerId: cust.trim(), pin, enroll: false, newDevice, ...(extra || {}) });
    setBusy(false);
    setTid(r.tid);
    if (r.ok && r.data.needOtp) { setStep(3); setMsg({ text: "SMS kodu gönderildi. Kodu SMS kutusundan alıp girin.", ok: true }); return; }
    if (r.ok) { setUser({ customerId: r.data.customerId, fullName: r.data.fullName }); setMsg({ text: "", ok: true }); return; }
    setMsg({ text: r.data.error || "Giriş başarısız", ok: false });
    if (extra) setStep(2);
  }
  async function logout() {
    await api("/api/logout", { channel: "mobile" });
    setUser(null); setStep(1); setMenuOpen(false); setScreen("home"); setOtp("");
  }

  if (!user) {
    return (
      <Shell title="Mobil giriş" compact>
        <div className="steps">
          {["Cihaz ve PIN", "Onay", "SMS kodu", "Tamam"].map((s, i) => (
            <span key={s} className={"step " + (step === i + 1 ? "active" : step > i + 1 ? "done" : "")}>{i + 1} · {s}</span>
          ))}
        </div>
        {step === 1 && (
          <form className="card-form" onSubmit={(e) => { e.preventDefault(); if (!cust.trim()) return setMsg({ text: "Müşteri no girin", ok: false }); if (!pin) return setMsg({ text: "PIN girin", ok: false }); setStep(2); }}>
            <p className="info">Bu tarayıcıda daha önce giriş yaptıysanız <b>Mevcut cihaz</b>, ilk kez kullanıyorsanız <b>Yeni cihaz</b>'ı seçin.</p>
            <label className="field"><span>Müşteri numaranız</span><input value={cust} onChange={(e) => setCust(e.target.value)} inputMode="numeric" autoComplete="username" /></label>
            <div className="choices">
              <label className="choice"><input type="radio" checked={!newDevice} onChange={() => setNewDevice(false)} /><span><strong>📱 Mevcut cihaz</strong><small>Bu tarayıcıda zaten aktif</small></span></label>
              <label className="choice"><input type="radio" checked={newDevice} onChange={() => setNewDevice(true)} /><span><strong>✨ Yeni cihaz</strong><small>İlk kez giriş, SMS kodu gerekir</small></span></label>
            </div>
            <label className="field"><span>PIN</span><PasswordInput value={pin} onChange={setPin} inputMode="numeric" maxLength={6} autoComplete="off" /><small className="hint">PIN'inizi kimseyle paylaşmayın.</small></label>
            <button className="primary big" type="submit">Devam et</button>
          </form>
        )}
        {step === 2 && (
          <div className="card-form">
            <h3>Bilgileri kontrol edin</h3>
            <dl className="summary"><dt>Müşteri no</dt><dd>{cust.trim()}</dd><dt>Cihaz</dt><dd>{newDevice ? "Yeni cihaz (aktivasyon)" : "Mevcut cihaz"}</dd></dl>
            <div className="actions">
              <button onClick={() => setStep(1)}>Geri</button>
              <button className="primary big" disabled={busy} onClick={() => login({})}>{busy ? "Bekleyin…" : newDevice ? "SMS kodu gönder" : "Giriş yap"}</button>
            </div>
          </div>
        )}
        {step === 3 && (
          <div className="card-form">
            <h3>SMS kodunu girin</h3>
            <p className="hint">Kod lab ortamında <b>SMS kutusunda</b> görünür.</p>
            <a className="sms-link" href="#/sms" target="_blank" rel="noopener">SMS kutusunu aç ↗</a>
            <label className="field"><span>SMS kodu</span><input value={otp} onChange={(e) => setOtp(e.target.value)} inputMode="numeric" maxLength={6} autoComplete="one-time-code" /></label>
            <div className="actions">
              <button onClick={() => { setStep(2); setOtp(""); }}>Geri</button>
              <button className="primary big" disabled={busy} onClick={() => login({ smsCode: otp.trim() })}>Doğrula ve giriş yap</button>
            </div>
          </div>
        )}
        {msg.text && <p className={"status " + (msg.ok ? "ok" : "bad")}>{msg.text}</p>}
        <TraceLinks tid={tid} label="İzleme" />
      </Shell>
    );
  }

  // giriş yapılmış: uygulama kabuğu
  const go = (s) => { setScreen(s); setMenuOpen(false); };
  return (
    <div className="app-shell">
      <header className="topbar">
        <button className="icon" aria-label="Menü" onClick={() => setMenuOpen(!menuOpen)}>☰</button>
        <span className="title">Merhaba, {user.fullName || user.customerId}</span>
      </header>
      {menuOpen && (
        <>
          <div className="scrim" onClick={() => setMenuOpen(false)} />
          <nav className="drawer">
            <div className="drawer-head"><strong>{user.fullName || user.customerId}</strong><small className="muted">{user.customerId}</small></div>
            <button onClick={() => go("home")}>🏦 Hesaplarım</button>
            <button onClick={() => go("history")}>🧾 Hesap hareketleri</button>
            <button onClick={() => go("transfer")}>💸 Havale / EFT</button>
            <hr />
            <button className="logout" onClick={logout}>⏻ Çıkış yap</button>
          </nav>
        </>
      )}
      <main>
        <Ops key={screen} channel="mobile" compact tabOverride={screen} />
      </main>
      <nav className="bottom">
        <button className={screen === "home" ? "active" : ""} onClick={() => go("home")}><span>🏠</span>Ana sayfa</button>
        <button className={screen === "history" ? "active" : ""} onClick={() => go("history")}><span>🧾</span>Hareketler</button>
        <button className={screen === "transfer" ? "active" : ""} onClick={() => go("transfer")}><span>💸</span>Havale</button>
        <button className={menuOpen ? "active" : ""} onClick={() => setMenuOpen(!menuOpen)}><span>☰</span>Menü</button>
      </nav>
    </div>
  );
}

// ------------------------------------------------------------ İşlemler sayfası (giriş yapılmış kanal)
function OpsPage() {
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
  if (!channel) return <Shell title="Hesap işlemleri"><p className="info">Önce bir kanaldan giriş yapın.</p><a href="#/">Kanallara dön</a></Shell>;
  return <Shell title="Hesap işlemleri"><Ops channel={channel} /></Shell>;
}

// ------------------------------------------------------------ SMS kutusu
function SmsPage() {
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
function HomePage() {
  const channels = [
    { name: "Mobil", desc: "Cihaz ve PIN, SMS (yeni cihaz), hesap işlemleri", href: "#/mobil", active: true },
    { name: "Web", desc: "Müşteri no, parola, SMS kodu", href: null },
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
        Hesap işlemleri için önce bir kanaldan giriş yapın: <a href="#/islemler">Hesap işlemleri</a>. SMS kodları: <a href="#/sms">SMS kutusu</a>.
      </p>
    </Shell>
  );
}

// ------------------------------------------------------------ ortak kabuk ve yönlendirme
function Shell({ title, children, compact }) {
  return (
    <div className={"console " + (compact ? "compact" : "")}>
      <header className="console-head">
        <h1>{title}</h1>
        {!compact && <nav className="console-nav"><a href="#/">Giriş</a><a href="#/web">Web</a><a href="#/mobil">Mobil</a><a href="#/islemler">Hesap işlemleri</a><a href="#/sms" target="_blank" rel="noopener">SMS kutusu ↗</a></nav>}
      </header>
      <main>{children}</main>
      <footer className="muted small">DMZ Lab Konsolu · yalnız lab</footer>
    </div>
  );
}

function RootView() {
  const [hash, setHash] = useState(window.location.hash);
  useEffect(() => {
    const onChange = () => setHash(window.location.hash);
    window.addEventListener("hashchange", onChange);
    return () => window.removeEventListener("hashchange", onChange);
  }, []);
  const path = (hash || "#/").replace(/^#/, "") || "/";
  if (path === "/web") return <WebPage />;
  if (path === "/mobil") return <MobilPage />;
  if (path === "/islemler") return <OpsPage />;
  if (path === "/sms") return <SmsPage />;
  return <HomePage />;
}

export default function Root() {
  return <RootView />;
}
