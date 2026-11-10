# DMZ Edge — Lab

Tasarımdaki (design.md, bölüm 4.1) DMZ Edge katmanının lab gerçeklemesi.

| Katman | Lab bileşeni | Görev |
|---|---|---|
| Yük dengeleyici | HAProxy 3.0 | SNI yönlendirme, TLS sonlandırma, re-encrypt, sağlık kontrolü, host yönlendirme |
| WAF | Coraza (coraza-spoa v0.9.1) + OWASP CRS | Uygulama katmanı saldırıları (SQLi, XSS, path traversal) |
| DDoS (L4) | HAProxy stick-table | IP başına bağlantı hızı ve eşzamanlı bağlantı sınırı |
| DDoS (L7) | HAProxy stick-table | IP başına istek hızı sınırı (429) |
| Slowloris koruması | HAProxy `timeout http-request` | Yarım kalan istekleri kesme (408) |
| Gateway'ler (DMZ) | nginx stub'ları | kgateway'in yerine geçer: gw-web (x2), gw-mobile, gw-partner |

Kapsam dışı: hacimsel DDoS (ISP / bulut temizleme katmanı, lab'da simüle edilemez), gerçek kgateway (DMZ cluster kurulunca), HA çifti (keepalived/VRRP, Docker Desktop'ta test edilemez).

## Gereksinimler

- Docker Desktop (Compose v2)
- Git Bash veya WSL (`bash`, `openssl`, `curl`, `xargs`, `git`)

## Kurulum

```bash
# 1) WAF imajı: coraza-spoa v0.9.1 kaynaktan derlenir (bir kez)
bash edge/scripts/build-waf.sh

# 2) Sertifikalar (bir kez)
bash edge/scripts/gen-certs.sh

# 3) Ortam
cd edge
docker compose up -d
```

## Testler

```bash
bash edge/tests/run-all.sh          # hepsi
bash edge/tests/smoke.sh            # TLS, yönlendirme, LB, L7 rate limit, partner mTLS
bash edge/tests/lb.sh               # gw-web-2 düşünce failover ve geri dönüş
bash edge/tests/waf.sh              # WAF: normal 200, saldırılar 403
bash edge/tests/ddos.sh             # L4 bağlantı hızı, slowloris
```

Testler `curl --resolve` ile çalışır, `hosts` dosyasına dokunmaz. Lab portu `8443`'tür.

HAProxy istatistikleri: http://127.0.0.1:8404/stats

## Mimari (lab)

```
Client :8443
  └─ fe_public (L4) ── IP başına bağlantı sınırı
       ├─ SNI partner-api.lab.local ──passthrough──> gw-partner-1:443 (mTLS gw-partner'da)
       └─ diğer ──> fe_https (TLS, PROXY protocol)
                      ├─ IP başına istek sınırı (429)
                      ├─ Coraza WAF (SPOE) ──> coraza-spoa:9000 (403)
                      ├─ web.lab.local     ──re-encrypt──> be_gw_web   (gw-web-1, gw-web-2)
                      └─ mobile-api.lab.local ──re-encrypt──> be_gw_mobile (gw-mobile-1)
```

- `edge` ağı: haproxy, coraza-spoa.
- `dmz` ağı: haproxy ve gateway'ler. Gateway'lere host'tan port açılmaz.
- Lab'da gerçek firewall yoktur. Ayrımı docker ağları sağlar.

## Sertifikalar

| Dosya | İmzalayan | Kullanım |
|---|---|---|
| `public-ca.crt` | kendisi | Client'lar edge'e güvenir |
| `edge.crt` / `edge.pem` | public-ca | Edge TLS (web, mobile-api). `edge.pem` HAProxy için birleşik dosya |
| `internal-ca.crt` | kendisi | HAProxy, gw-* sertifikalarını bununla doğrular |
| `gw-*.crt` | internal-ca | Gateway TLS sertifikaları |
| `partner-ca.crt` | kendisi | gw-partner istemci sertifikası doğrular |
| `partner-client.*` | partner-ca | Test partner'ı |

Sertifikalar lab amaçlıdır, üretimde kullanılmamalıdır.

## Notlar

- Partner trafiği L4 passthrough olduğu için L7 WAF ve L7 rate limit partner trafiğine uygulanmaz. Partner kotası ve partner API'sinin korunması tasarımda gw-partner'a aittir.
- Windows'ta curl (schannel) lab CA'sının CRL'ini bulamadığı için testler `--ssl-no-revoke` kullanır. Partner mTLS testi OpenSSL ile yapılır, çünkü schannel PEM istemci sertifikasını içe aktaramaz.
