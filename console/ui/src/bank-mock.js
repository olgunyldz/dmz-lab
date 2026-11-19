// Demo bankası: tarayıcıda çalışan sahte arka uç (yalnız demo). Gerçek servislere (Janus, Seal, auth) bağlanmaz.
// Durum localStorage'da tutulur; aynı tarayıcıdaki sekmeler SMS kutusunu paylaşır.

  const KEY = "demo-bank-v1";
  const delay = (v) => new Promise((res) => setTimeout(() => res(v), 250));
  const newTid = () => Math.random().toString(16).slice(2, 14) + Math.random().toString(16).slice(2, 10);

  const seed = () => ({
    customers: {
      C000000001: {
        name: "Alice Demo", pin: "4321", webPassword: "1234",
        accounts: [
          { id: "TR000000000001", type: "vadesiz", balance: 12500 },
          { id: "TR000000000002", type: "birikim", balance: 3400 },
        ],
        devices: [],
      },
    },
    sms: { web: null, mobile: null },
    sessions: { web: null, mobile: null },
    pending: { web: null, mobile: null },
    history: {},
  });

  function load() {
    try {
      const raw = localStorage.getItem(KEY);
      if (raw) return JSON.parse(raw);
    } catch (e) { /* bozuk kayıt: sıfırla */ }
    return seed();
  }
  let db = load();
  const save = () => { try { localStorage.setItem(KEY, JSON.stringify(db)); } catch (e) { /* yok say */ } };

  const code6 = () => String(Math.floor(100000 + Math.random() * 900000));
  const nowIso = () => new Date().toISOString();

  function sendSms(channel) {
    const c = code6();
    db.sms[channel] = { demoOtp: c, at: new Date().toLocaleTimeString("tr-TR") };
    save();
    return c;
  }
  function cust(id) { return db.customers[id] || null; }
  function historyFor(acc) {
    if (!db.history[acc]) {
      db.history[acc] = [
        { at: nowIso(), description: "Maaş", counterpart: "İşveren A.Ş.", direction: "CREDIT", amount: 9000, balanceAfter: 0 },
        { at: nowIso(), description: "Market", counterpart: "Market Zinciri", direction: "DEBIT", amount: 850, balanceAfter: 0 },
      ];
    }
    return db.history[acc];
  }
  function findAccount(id) {
    for (const c of Object.values(db.customers)) {
      const a = c.accounts.find((x) => x.id === id);
      if (a) return { owner: c, acc: a };
    }
    return null;
  }

  const Bank = {
    state() {
      return delay({ web: db.sessions.web || { loggedIn: false }, mobile: db.sessions.mobile || { loggedIn: false } });
    },
    sms() {
      return delay({ web: db.sms.web, mobile: db.sms.mobile });
    },
    requestOtp(channel) {
      sendSms(channel);
      return delay({ sent: true, channel });
    },
    webLogin({ customerId, password, smsCode }) {
      const c = cust(customerId);
      if (!c || c.webPassword !== password) return delay({ error: "Müşteri no veya parola hatalı" });
      if (!db.sms.web) return delay({ error: "Önce tek seferlik kod isteyin" });
      if (smsCode !== db.sms.web.demoOtp) return delay({ error: "SMS kodu hatalı" });
      db.sessions.web = { loggedIn: true, customerId, fullName: c.name };
      db.sms.web = null;
      save();
      return delay({ customerId, fullName: c.name });
    },
    mobileLogin({ customerId, pin, newDevice, smsCode }) {
      const c = cust(customerId);
      if (!c || c.pin !== pin) return delay({ error: "Müşteri no veya PIN hatalı" });
      if (newDevice) {
        if (!smsCode) {
          sendSms("mobile");
          db.pending.mobile = { customerId };
          save();
          return delay({ needOtp: true });
        }
        if (!db.sms.mobile || smsCode !== db.sms.mobile.demoOtp) return delay({ error: "SMS kodu hatalı" });
        db.sms.mobile = null;
        if (!c.devices.includes("demo-device")) c.devices.push("demo-device");
      } else if (!c.devices.includes("demo-device")) {
        return delay({ error: "Bu cihaz aktif değil; 'Yeni cihaz' ile aktive edin" });
      }
      db.sessions.mobile = { loggedIn: true, customerId, fullName: c.name };
      db.pending.mobile = null;
      save();
      return delay({ customerId, fullName: c.name });
    },
    logout(channel) {
      db.sessions[channel] = null;
      save();
      return delay({ ok: true });
    },
    tx(channel, code, params) {
      const s = db.sessions[channel];
      if (!s || !s.loggedIn) return delay({ error: "Oturum yok" });
      const c = cust(s.customerId);
      if (code === "BALANCE") return delay({ status: "OK", accounts: c.accounts.map((a) => ({ ...a })) });
      if (code === "HISTORY") {
        const acc = findAccount(params.account);
        if (!acc || acc.owner !== c) return delay({ error: "Hesap bulunamadı" });
        return delay({ transactions: historyFor(acc.acc.id).slice(0, params.limit || 20) });
      }
      if (code === "TRANSFER") {
        const from = findAccount(params.fromAccount);
        if (!from || from.owner !== c) return delay({ error: "Gönderen hesap size ait değil" });
        const amount = Number(params.amount);
        if (!(amount > 0)) return delay({ error: "Tutar geçersiz" });
        if (amount > 50000) return delay({ error: "Tek seferde en fazla 50.000 TL gönderilebilir" });
        if (from.acc.balance < amount) return delay({ error: "Yetersiz bakiye" });
        const to = findAccount(params.toAccount);
        from.acc.balance -= amount;
        if (to) to.acc.balance += amount;
        const ref = "HV" + Math.floor(100000 + Math.random() * 900000);
        const ts = nowIso();
        historyFor(from.acc.id).unshift({ at: ts, description: params.description || "Havale", counterpart: params.toAccount, direction: "DEBIT", amount, balanceAfter: from.acc.balance });
        if (to) historyFor(to.acc.id).unshift({ at: ts, description: params.description || "Havale", counterpart: params.fromAccount, direction: "CREDIT", amount, balanceAfter: to.acc.balance });
        save();
        return delay({ status: "OK", reference: ref, amount, fromAccount: params.fromAccount, toAccount: params.toAccount, balanceAfter: from.acc.balance, internal: !!to });
      }
      return delay({ error: "Bilinmeyen işlem" });
    },
    reset() { db = seed(); save(); return delay({ ok: true }); },
  };

export default Bank;
export { newTid };
