"use client";
import { useState, useEffect } from "react";
import { api } from "./api.js";
import { PasswordInput } from "./Ui.jsx";
import { Ops } from "./Ops.jsx";
import { TraceLinks } from "./Trace.jsx";


// ------------------------------------------------------------ Mobil uygulama (giriş sihirbazı + alt menü)
export function MobilePage() {
  const [user, setUser] = useState(null);
  const [step, setStep] = useState(1);
  const [cust, setCust] = useState("C000000001");
  const [pin, setPin] = useState("4321");
  const [newDevice, setNewDevice] = useState(false);
  const [otp, setOtp] = useState("");
  const [pw, setPw] = useState(""); // yalnız yeni cihaz aktivasyonunda; konsol saklamaz
  const [msg, setMsg] = useState({ text: "", ok: true });
  const [busy, setBusy] = useState(false);
  const [tid, setTid] = useState("");
  const [screen, setScreen] = useState("home");
  const [menuOpen, setMenuOpen] = useState(false);

  useEffect(() => { api("/api/state").then((r) => { if (r.ok && r.data.mobile && r.data.mobile.loggedIn) setUser(r.data.mobile); }); }, []);

  async function login(extra) {
    setBusy(true);
    const r = await api("/api/mobile/login", { customerId: cust.trim(), pin, newDevice, password: pw, ...(extra || {}) });
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
      <div className="phone">
        <header className="topbar"><span className="title">Mobil Bankacılık</span></header>
        <div className="phone-body">
        <div className="steps">
          {["Cihaz ve PIN", "Onay", "SMS kodu", "Tamam"].map((s, i) => (
            <span key={s} className={"step " + (step === i + 1 ? "active" : step > i + 1 ? "done" : "")}>{i + 1} · {s}</span>
          ))}
        </div>
        {step === 1 && (
          <form className="card-form" onSubmit={(e) => { e.preventDefault(); if (!cust.trim()) return setMsg({ text: "Müşteri no girin", ok: false }); if (!pin) return setMsg({ text: "PIN girin", ok: false }); if (newDevice && pw.length < 8) return setMsg({ text: "Yeni cihaz için müşteri parolasını girin (en az 8 karakter)", ok: false }); setStep(2); }}>
            <p className="info">Bu tarayıcıda daha önce giriş yaptıysanız <b>Mevcut cihaz</b>, ilk kez kullanıyorsanız <b>Yeni cihaz</b>'ı seçin.</p>
            <label className="field"><span>Müşteri numaranız</span><input value={cust} onChange={(e) => setCust(e.target.value)} inputMode="numeric" autoComplete="username" /></label>
            <div className="choices">
              <label className="choice"><input type="radio" checked={!newDevice} onChange={() => setNewDevice(false)} /><span><strong>📱 Mevcut cihaz</strong><small>Bu tarayıcıda zaten aktif</small></span></label>
              <label className="choice"><input type="radio" checked={newDevice} onChange={() => setNewDevice(true)} /><span><strong>✨ Yeni cihaz</strong><small>İlk kez giriş, SMS kodu gerekir</small></span></label>
            </div>
            {newDevice && (
              <label className="field"><span>Müşteri parolası</span><PasswordInput value={pw} onChange={setPw} autoComplete="current-password" /><small className="hint">Parola yalnız kimlik sağlayıcıya iletilir, cihazda saklanmaz.</small></label>
            )}
            <label className="field"><span>PIN</span><PasswordInput value={pin} onChange={setPin} inputMode="numeric" maxLength={6} autoComplete="off" /><small className="hint">PIN'inizi kimseyle paylaşmayın.</small></label>
            <button className="primary big" type="submit">Devam et</button>
            <p className="hint center"><a href="/musteri-ekle">Yeni müşteri oluştur</a></p>
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
            <a className="sms-link" href="/sms" target="_blank" rel="noopener">SMS kutusunu aç ↗</a>
            <label className="field"><span>SMS kodu</span><input value={otp} onChange={(e) => setOtp(e.target.value)} inputMode="numeric" maxLength={6} autoComplete="one-time-code" /></label>
            <div className="actions">
              <button onClick={() => { setStep(2); setOtp(""); }}>Geri</button>
              <button className="primary big" disabled={busy} onClick={() => login({ smsCode: otp.trim() })}>Doğrula ve giriş yap</button>
            </div>
          </div>
        )}
        {msg.text && <p className={"status " + (msg.ok ? "ok" : "bad")}>{msg.text}</p>}
        <details className="debug"><summary>Hata ayıklama</summary><TraceLinks tid={tid} label="Son istek" /></details>
        </div>
      </div>
    );
  }

  // giriş yapılmış: uygulama kabuğu
  const go = (s) => { setScreen(s); setMenuOpen(false); };
  return (
    <div className="phone">
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
    <details className="debug"><summary>Hata ayıklama</summary><TraceLinks tid={tid} label="Son istek" /></details>
    </div>
  );
}

