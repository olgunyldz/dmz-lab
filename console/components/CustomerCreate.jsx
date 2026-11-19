"use client";
// Müşteri ekleme: rastgele müşteri no üretilir, parola yalnız IdP'ye iletilir. Mobil giriş için bu adım önce yapılır.
import { useState } from "react";
import { api } from "./api.js";
import { Shell, PasswordInput } from "./Ui.jsx";
import { fmtTL } from "./format.js";
import { TraceLinks } from "./Trace.jsx";

export function CustomerCreatePage() {
  const [pass, setPass] = useState("");
  const [pass2, setPass2] = useState("");
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState({ text: "", ok: true });
  const [created, setCreated] = useState(null); // {customerId, fullName, accounts}
  const [tid, setTid] = useState("");

  async function create(e) {
    e.preventDefault();
    if (pass.length < 8) return setMsg({ text: "Parola en az 8 karakter olmalı", ok: false });
    if (pass !== pass2) return setMsg({ text: "Parolalar eşleşmiyor", ok: false });
    setBusy(true);
    const r = await api("/api/customer/create", { password: pass });
    setBusy(false);
    setTid(r.tid);
    setPass(""); setPass2("");
    if (r.ok) { setCreated(r.data); setMsg({ text: "Müşteri oluşturuldu.", ok: true }); }
    else setMsg({ text: r.data.error || "Müşteri oluşturulamadı", ok: false });
  }

  return (
    <Shell title="Müşteri ekle">
      {created ? (
        <div className="card-form">
          <div className="success">✔ Müşteri oluşturuldu</div>
          <dl className="summary">
            <dt>Müşteri no</dt><dd><code>{created.customerId}</code></dd>
            <dt>Ad soyad</dt><dd>{created.fullName}</dd>
          </dl>
          <div className="table-wrap">
            <table>
              <thead><tr><th>Hesap</th><th>Tür</th><th className="num">Bakiye</th></tr></thead>
              <tbody>
                {(created.accounts || []).map((a) => <tr key={a.id}><td>{a.id}</td><td>{a.type}</td><td className="num">{fmtTL(a.balance)}</td></tr>)}
              </tbody>
            </table>
          </div>
          <p className="hint">Mobil girişte bu müşteri no ve belirlediğiniz parola kullanılır. Parola yalnız kimlik sağlayıcıda tutulur.</p>
          <div className="actions">
            <a className="btn primary" href="/mobil">Mobil girişe git</a>
            <button onClick={() => { setCreated(null); setMsg({ text: "", ok: true }); }}>Yeni müşteri</button>
          </div>
        </div>
      ) : (
        <form className="card-form" onSubmit={create}>
          <p className="info">Müşteri no otomatik üretilir. Parolayı belirleyin; kimlik sağlayıcıya (IdP) yalnız bu adımda iletilir ve konsolda saklanmaz.</p>
          <label className="field"><span>Parola</span><PasswordInput value={pass} onChange={setPass} autoComplete="new-password" /></label>
          <label className="field"><span>Parola (tekrar)</span><PasswordInput value={pass2} onChange={setPass2} autoComplete="new-password" /></label>
          <small className="hint">En az 8 karakter; parola müşteri numarasını içeremez.</small>
          <button className="primary big" type="submit" disabled={busy}>{busy ? "Oluşturuluyor…" : "Müşteri oluştur"}</button>
        </form>
      )}
      {msg.text && <p className={"status " + (msg.ok ? "ok" : "bad")}>{msg.text}</p>}
      <TraceLinks tid={tid} label="İzleme" />
    </Shell>
  );
}
