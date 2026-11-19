"use client";
import { useState, useEffect } from "react";
import { api } from "./api.js";
import { Shell, PasswordInput } from "./Ui.jsx";
import { Ops } from "./Ops.jsx";
import { TraceLinks } from "./Trace.jsx";


// ------------------------------------------------------------ Web girişi
export function WebPage() {
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
        {smsSent && <a className="sms-link" href="/sms" target="_blank" rel="noopener">SMS kutusunu aç ↗ (lab kodu orada)</a>}
        <label className="field"><span>SMS kodu</span><input value={sms} onChange={(e) => setSms(e.target.value)} inputMode="numeric" maxLength={6} autoComplete="one-time-code" placeholder="6 haneli kod" /></label>
        <button className="primary" type="submit">Giriş yap</button>
        <p className={"status " + (status.ok ? "ok" : "bad")}>{status.msg}</p>
        <details className="debug"><summary>Hata ayıklama</summary><TraceLinks tid={tid} label="Son istek" /></details>
        <p className="hint center"><a href="/musteri-ekle">Yeni müşteri oluştur</a></p>
      </form>
    </Shell>
  );
}

