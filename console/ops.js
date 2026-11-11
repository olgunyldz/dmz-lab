if (typeof apiFetch === 'undefined') {

// İşlem başına X-Trace-Id: çağıran traceId verirse onu kullanır, vermezse yenisini üretir (mevcut kimliği ezmez).
function newTraceId(){const a=new Uint8Array(16);crypto.getRandomValues(a);return Array.from(a,b=>b.toString(16).padStart(2,'0')).join('');}
function apiFetch(url, opts = {}) {
  const headers = Object.assign({}, opts.headers || {});
  // Tek trace kimliği: X-Trace-Id (uygulama) > traceparent (W3C) > opts.traceId > yeni. Varsa üzerine yazılmaz.
  const tp = (headers['traceparent'] || '').split('-');
  const tid = headers['X-Trace-Id'] || (tp.length === 4 ? tp[1] : '') || opts.traceId || newTraceId();
  headers['X-Trace-Id'] = tid;
  if (!headers['traceparent']) {
    const sp = new Uint8Array(8); crypto.getRandomValues(sp);
    headers['traceparent'] = '00-' + tid + '-' + Array.from(sp, b => b.toString(16).padStart(2, '0')).join('') + '-01';
  }
  const o = Object.assign({ credentials: 'same-origin' }, opts, { headers });
  delete o.traceId;
  return fetch(url, o).then((r) => { r.sentTraceId = tid; return r; });
}
}
// Operasyon matrisi: hangi kanal neyi yapabilir, neyi yapamaz ve neden.
// Tek kaynak: organizer matrisi ve kanal menüsü bu tabloyu kullanır. Kurallar sunucudaki gerçek kontrollerle eşleşir
// (bkz. internal-cluster/tests/api.sh, dmz-cluster/tests/branch.sh, console/channel.html CHECKS).

const CH_LABEL = { web: 'Web', mobile: 'Mobil', partner: 'Partner', branch: 'Şube', public: 'Public' };
const CHANNEL_KEYS = ['web', 'mobile', 'partner', 'branch', 'public'];

// ok: yapılabilir. path/method/auth/dpop/body: çağrı. needsAccount: önce hesap listesinden kimlik alınır.
// reason: yapılamıyorsa gerekçe (sunucudaki gerçek hata ile uyumlu).
const OPS = [
  { id: 'accounts', label: 'Hesap listesi', desc: 'Kullanıcının dummy hesapları',
    per: {
      web:     { ok: true, path: '/bff/web/accounts', auth: 'session', expect: '200' },
      mobile:  { ok: true, path: '/bff/mobile/accounts', auth: 'session', dpop: true, expect: '200' },
      branch:  { ok: true, path: '/bff/branch/accounts', auth: 'session', expect: '200' },
      partner: { ok: false, reason: 'Partner kanalında hesap API yok; partner yalnız ödeme rotasını kullanır (/partner/payments).' },
      public:  { ok: false, reason: 'Hesap bilgisi kişisel veri; token gerekir, public kanalda oturum yok.' } } },

  { id: 'transactions', label: 'İşlem geçmişi', desc: 'Bir hesabın işlemleri', needsAccount: true,
    per: {
      web:     { ok: true, path: '/bff/web/accounts/{id}/transactions', auth: 'session', expect: '200' },
      mobile:  { ok: true, path: '/bff/mobile/accounts/{id}/transactions', auth: 'session', dpop: true, expect: '200', note: 'Mobilde son 5 işlem' },
      branch:  { ok: true, path: '/bff/branch/accounts/{id}/transactions', auth: 'session', expect: '200' },
      partner: { ok: false, reason: 'Partner kanalında hesap/işlem API yok.' },
      public:  { ok: false, reason: 'İşlem geçmişi token gerektirir.' } } },

  { id: 'transfer', label: 'Para transferi (1,00 TRY)', desc: 'Idempotency-Key ile havale', needsAccount: true,
    per: {
      web:     { ok: true, path: '/bff/web/transfers', auth: 'session', method: 'POST', expect: '200', limit: '100.000,00 TRY' },
      mobile:  { ok: true, path: '/bff/mobile/transfers', auth: 'session', dpop: true, method: 'POST', expect: '200', limit: '10.000,00 TRY' },
      branch:  { ok: true, path: '/bff/branch/transfers', auth: 'session', method: 'POST', expect: '200', limit: '50.000,00 TRY' },
      partner: { ok: false, reason: 'Partner kanalı salt okunur; transfer yapamaz.' },
      public:  { ok: false, reason: 'Transfer için giriş gerekir; public kanalda oturum yok.' } } },

  { id: 'payments', label: 'Ödeme rotası (/partner/payments)', desc: 'Partner ödeme uç noktası',
    per: {
      web:     { ok: false, reason: 'Web token partner rotasında reddedilir (403, audience uyuşmazlığı).' },
      mobile:  { ok: false, reason: 'Mobil token partner rotasında reddedilir (403).' },
      branch:  { ok: false, reason: 'Şube ağında /partner rotası yok (404, default deny).' },
      partner: { ok: true, path: '/partner/payments', auth: 'session', expect: '200' },
      public:  { ok: false, reason: 'Partner rotası token ve partner sertifikası ister.' } } },

  { id: 'public', label: 'Public duyuru (GET /public/branches)', desc: 'Token gerektirmeyen şube listesi',
    per: {
      web:     { ok: true, path: '/public/branches', auth: 'none', expect: '200' },
      mobile:  { ok: true, path: '/public/branches', auth: 'none', expect: '200' },
      branch:  { ok: false, reason: 'Şube gateway\'inde public route yok (404).' },
      partner: { ok: false, reason: 'Partner gateway\'inde public route yok.' },
      public:  { ok: true, path: '/public/branches', auth: 'none', expect: '200' } } },

  { id: 'post-public', label: 'POST /public (yazma denemesi)', desc: 'Public yollar yalnız GET',
    per: {
      web:     { ok: false, reason: 'Public route yalnız GET kabul eder; POST 404 döner.' },
      mobile:  { ok: false, reason: 'Public route yalnız GET kabul eder; POST 404 döner.' },
      branch:  { ok: false, reason: 'Şubede public route yok.' },
      partner: { ok: false, reason: 'Partner\'da public route yok.' },
      public:  { ok: false, reason: 'Public kanalda yazma yok.' } } },

  { id: 'login', label: 'Giriş', desc: 'Kanala özel kimlik doğrulama (menüde bilgi)',
    per: {
      web:     { ok: true, note: 'PKCE (Bearer)' },
      mobile:  { ok: true, note: 'PKCE + ES256 DPoP' },
      branch:  { ok: true, note: 'Cihaz sertifikası + PKCE' },
      partner: { ok: true, note: 'Client credentials + mTLS' },
      public:  { ok: false, reason: 'Public kanalda giriş yok (token gerekmez).' } } },

  { id: 'logout', label: 'Çıkış', desc: 'Oturum kapatma (menüde bilgi)',
    per: {
      web:     { ok: true, note: 'Keycloak oturumu kapanır (204)' },
      mobile:  { ok: true, note: 'Refresh token iptali (revoke)' },
      branch:  { ok: true, note: 'Keycloak oturumu kapanır (204)' },
      partner: { ok: true, note: 'Yerel token silinir' },
      public:  { ok: false, reason: 'Public kanalda oturum yok.' } } },
];

// Menü için bir operasyonu çalıştırır (yalnız ok ve ağ çağrısı olanlar). Dönüş: {status, body, pass}
async function runOp(channel, op) {
  const cfg = op.per[channel];
  if (!cfg || !cfg.ok || !cfg.path) throw new Error('bu kanalda çalıştırılamaz');
  let path = cfg.path;
  if (op.needsAccount) {
    const acc = await callApi({ channel, method: 'GET', path: channelAccountsPath(channel), auth: 'session', dpop: !!cfg.dpop });
    const id = (acc.body || '').match(/TR[0-9A-F]{12}/);
    if (!id) throw new Error('hesap kimliği alınamadı (önce giriş yapın)');
    path = path.replace('{id}', id[0]);
  }
  const body = cfg.method === 'POST'
    ? { from: await firstAccount(channel), to: 'EXT-100001', amount: '1.00', currency: 'TRY', description: 'menü' }
    : undefined;
  const idem = cfg.method === 'POST' ? `MENU-${Date.now()}` : undefined;
  return callApi({ channel, method: cfg.method || 'GET', path, auth: cfg.auth, dpop: !!cfg.dpop,
                   body, idem, expect: cfg.expect });
}

function channelAccountsPath(ch) {
  return ch === 'mobile' ? '/bff/mobile/accounts' : ch === 'branch' ? '/bff/branch/accounts' : '/bff/web/accounts';
}

async function firstAccount(channel) {
  const acc = await callApi({ channel, method: 'GET', path: channelAccountsPath(channel), auth: 'session',
                              dpop: channel === 'mobile' });
  const id = (acc.body || '').match(/TR[0-9A-F]{12}/);
  return id ? id[0] : '';
}

async function callApi(body) {
  const r = await apiFetch('/api/call', { method: 'POST', credentials: 'same-origin',
    headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
  return r.json();
}

// Kanal sayfası menüsü: yapılabilenler (çalıştır) ve yapılamayanlar (gerekçeyle).
function renderMenu(container, channel, onResult) {
  container.innerHTML = '';
  const can = document.createElement('div');
  const cannot = document.createElement('div');
  const h1 = document.createElement('h3'); h1.textContent = 'Yapılabilen işlemler';
  const h2 = document.createElement('h3'); h2.textContent = 'Yapılamayan işlemler';
  can.append(h1); cannot.append(h2);
  for (const op of OPS) {
    const cfg = op.per[channel];
    if (!cfg) continue;
    if (cfg.ok) {
      const row = document.createElement('div'); row.className = 'row';
      const b = document.createElement('button'); b.textContent = op.label;
      b.title = [op.desc, cfg.note, cfg.limit ? `limit: ${cfg.limit}` : ''].filter(Boolean).join(' · ');
      b.addEventListener('click', async () => {
        b.disabled = true;
        try { onResult(op, cfg, await runOp(channel, op)); }
        catch (e) { onResult(op, cfg, { status: 'hata', body: String(e), pass: false }); }
        finally { b.disabled = false; }
      });
      row.append(b);
      if (cfg.note || cfg.limit) {
        const s = document.createElement('span'); s.className = 'hint';
        s.textContent = [cfg.note, cfg.limit ? `limit ${cfg.limit}` : ''].filter(Boolean).join(' · ');
        row.append(s);
      }
      can.append(row);
    } else {
      const row = document.createElement('div'); row.className = 'hint';
      row.textContent = `✗ ${op.label}: ${cfg.reason}`;
      cannot.append(row);
    }
  }
  container.append(can, cannot);
}

// Organizer matrisi: satır = operasyon, sütun = kanal. ✓ yapılabilir, ✗ yapılamaz (gerekçe başlıkta).
function renderMatrix(table) {
  const thead = table.querySelector('thead'); const tbody = table.querySelector('tbody');
  thead.innerHTML = ''; tbody.innerHTML = '';
  const tr0 = document.createElement('tr');
  const th0 = document.createElement('th'); th0.textContent = 'İşlem';
  tr0.append(th0);
  for (const ch of CHANNEL_KEYS) { const th = document.createElement('th'); th.textContent = CH_LABEL[ch]; tr0.append(th); }
  thead.append(tr0);
  for (const op of OPS) {
    const tr = document.createElement('tr');
    const td0 = document.createElement('td'); td0.textContent = op.label; tr.append(td0);
    for (const ch of CHANNEL_KEYS) {
      const cfg = op.per[ch] || { ok: false, reason: 'tanımlı değil' };
      const td = document.createElement('td');
      td.textContent = cfg.ok ? '✓' : '✗';
      td.className = cfg.ok ? 'pass' : 'fail';
      td.title = cfg.ok ? (cfg.note || cfg.limit || 'yapılabilir') : cfg.reason;
      tr.append(td);
    }
    tbody.append(tr);
  }
}
