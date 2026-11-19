"use client";
import { useState, useEffect } from "react";
import { api } from "./api.js";
import { fmtTL, parseAmount } from "./format.js";
import { TraceLinks } from "./Trace.jsx";


// ------------------------------------------------------------ hesap işlemleri (kanala göre)
const TAB_OF = { home: "balance", history: "history", transfer: "transfer" };

export function Ops({ channel, onLogout, compact, tabOverride }) {
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

