"use client";
import { useState } from "react";
import { TraceFlow } from "./Trace.jsx";


// Parola alanı: göster/gizle simgesi ile
export function PasswordInput({ value, onChange, ...rest }) {
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

// ------------------------------------------------------------ ortak kabuk (header + footer)
// Tüm sayfalar (web, mobil, müşteri ekle, ...) bu kabuğun içinde çalışır.
// Header: gezinme, "Müşteri ekle", "Hata ayıklama" (açar/kapatır). Footer: istek akışı paneli (iz linkleri).
export function Shell({ title, children, compact }) {
  const [debug, setDebug] = useState(false);
  return (
    <div className={"console " + (compact ? "compact" : "")}>
      <header className="console-head">
        {title && <h1>{title}</h1>}
        <nav className="console-nav">
          <a href="/">Giriş</a><a href="/web">Web</a><a href="/mobil">Mobil</a><a href="/islemler">Hesap işlemleri</a>
          <a href="/musteri-ekle">Müşteri ekle</a><a href="/sms" target="_blank" rel="noopener">SMS kutusu ↗</a>
          <button type="button" className="link-btn" aria-expanded={debug} onClick={() => setDebug(!debug)}>
            {debug ? "Hata ayıklamayı kapat" : "Hata ayıkla"}
          </button>
        </nav>
      </header>
      <main>{children}</main>
      <footer className="console-foot">
        {debug && <div className="flow-wrap"><TraceFlow /></div>}
        <p className="muted small">DMZ Lab Konsolu · yalnız lab · <a href="/musteri-ekle">Müşteri ekle</a> · <button type="button" className="link-btn" onClick={() => setDebug(!debug)}>Hata ayıklama</button></p>
      </footer>
    </div>
  );
}


