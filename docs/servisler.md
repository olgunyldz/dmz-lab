# Servisler, İçerikler ve Durum

Bu doküman lab'daki her bileşenin **ne yaptığını, nerede çalıştığını, nasıl yapılandırıldığını ve son doğrulama durumunu** özetler.
Hedef mimari için `design.md`; tüm görseller tek dosyada: `docs/dmz-lab.drawio` (tab'lar: genel mimari, I/O ve araçlar, cluster ve pod görünümleri, şube cluster'ı, sequence diyagramları).

Son güncelleme: 2026-11-11.

"Durum" sütunu iki değerden birini taşır:
- **Doğrulandı**: ilgili test son çalıştırmada geçti (test adı ve sayısı verildi).
- **Doğrulama bekliyor**: kod ve yapılandırma yazıldı ya da değişti, henüz uçtan uca test edilmedi.

---

## 0. Kurulum ve kaldırma

| Betik | Görev |
|---|---|
| `bash up.sh --check` | Yalnız ön kontroller: araçlar, Docker, repo dosyaları, kind ağı (172.18.0.0/16), portlar, internet, sertifikalar. FAIL varsa kurulum yapılmaz |
| `bash up.sh` | Ön kontroller, sonra sırayla: sertifikalar ve imajlar → mgmt (Vault) → edge → identity (Keycloak, realm) → internal → DMZ (gateway'ler, F1, iç backend, ext-authz) → **şube cluster'ı** (F10) |
| `bash down.sh` | Ters sırada kaldırır: port-forward'lar → kind cluster'ları (branch, dmz, internal, identity, mgmt) → edge. `--purge` ile sertifika ve imajlar da silinir. Onay ister, `--yes` ile atlanır |

Ortam durumu: son kontrolde kind cluster'ları ve edge container'ları yoktu (sertifikalar ve repo yerinde). Sıfırdan `up.sh` çalıştırıldı. **Durum: identity adımında durdu (EXIT 2).** Hata: `load-vault.sh` içinde Vault unseal, `'key' must be a valid hex or base64 string` ile reddedildi. Vault başlatılmış (`Initialized: true`) ve mühürlü. Olası neden: `vault-bootstrap` secret'ındaki unseal anahtarının init çıktısından yanlış ayrıştırılması. Doğrulanmadı. Mgmt cluster ve `vault-bootstrap` yeniden oluşturulmadan düzeltilemez. Kalan adımlar (identity, internal, DMZ, şube) çalıştırılmadı.

---

## 1. Edge (docker compose, `edge/`)

| Bileşen | Görev | Yapılandırma | Durum |
|---|---|---|---|
| **HAProxy 3.0** | Tek dış giriş (443). SNI'ye göre **TCP passthrough**: yalnız `partner-api.lab.local`. Diğer host'lar TLS sonlandırır, WAF'a SPOE ile gider, DMZ gateway'lerine re-encrypt eder. L4 ve L7 IP başına hız sınırı. Aktif sağlık kontrolü: `GET /public/branches` (200). **Şube (`teller.lab.local`) HAProxy'den geçmez** | `edge/haproxy/haproxy.cfg`, `coraza.cfg` (SPOE processing 2 s) | Doğrulandı: edge 25/25 (önceki çalıştırma). Şube kuralının kaldırılması: doğrulama bekliyor |
| **Coraza WAF** (coraza-spoa v0.9.1) | OWASP CRS: SQLi, XSS, path traversal → 403 (`waf-block`) | İmaj `dmz-lab/coraza-spoa:0.9.1` (`edge/scripts/build-waf.sh`) | Doğrulandı (edge testleri) |

Edge testleri (`edge/tests/run-all.sh`): smoke, lb (failover dahil), waf, ddos → **25 kontrol**.

**Not:** HAProxy OpenTelemetry desteği olmadan derlenmiş (`-OT`); edge span üretmez. Edge, `x-request-id` ile korele edilir.

---

## 2. DMZ Cluster (kind-dmz, `dmz-cluster/`)

### 2.1 Kanal gateway'leri (kgateway v2.5.0 / Envoy)

| Gateway | Kanal | Giriş | Özel kurallar |
|---|---|---|---|
| `gw-web` | Web | `web.lab.local` (HAProxy → NodePort 30446) | PKCE token → ext-authz (Bearer) |
| `gw-mobile` | Mobil | `mobile-api.lab.local` (HAProxy → 30447) | PKCE + DPoP → ext-authz (DPoP doğrulama) |
| `gw-partner` | Partner | `partner-api.lab.local` (HAProxy passthrough → 30448) | Frontend mTLS (`partner-ca`) |
| `gw-branch` | Şube | **Şube cluster'ından doğrudan**, WAN benzeri bağlantı (NodePort 30449, HAProxy yok) | Frontend mTLS (`branch-ca`, cihaz sertifikası), F10 ile sınırlı |

Her gateway'de: `/bff/*` ve `/partner/*` ext-authz'den geçer; `/public/*` (yalnız GET) ve `/realms/*` ext-authz'siz **iç gateway'e** gider (`internal-gw`, mTLS). Tanımsız yollar 404 (default deny). Şube gateway'inde yalnız `/bff/*` ve `/realms/*` vardır.

Tracing: her gateway `ListenerPolicy` ile OTLP/gRPC span gönderir (Tempo, 30317). `traceparent` ve `x-request-id` ext-authz'e iletilir.

### 2.2 Güvenlik duvarları (host iptables, DMZ node'ları)

| Kural | Kapsam | Durum |
|---|---|---|
| **F1** | NodePort 30446–30448: yalnız edge HAProxy IP'si ve DMZ node IP'leri. Diğerleri DROP | Doğrulandı: `dmz-cluster/tests/firewall.sh` 4/4 (önceki çalıştırma) |
| **F10** | NodePort 30449 (gw-branch): yalnız şube cluster'ının node IP'leri. Diğerleri DROP. Zincir `F10-BRANCH` | Doğrulama bekliyor (şube cluster'ı kurulduktan sonra) |

`host-firewall.sh` her çalıştırmada zincirleri sıfırdan kurar. Şube cluster'ı yoksa F10 kapalı kalır ve uyarı verir.

### 2.3 Kimlik doğrulama: ext-authz (ns `auth`)

| Bileşen | Görev | Durum |
|---|---|---|
| **ext-authz** (Python, stdlib) | Dış token: RS256 (Keycloak JWKS), iss, aud, kanal, exp. Mobil ve DPoP bağlı token'da **RS256 ve ES256 (P-256)** DPoP proof doğrulaması. Ardından kanal sertifikasıyla **token exchange** (mTLS, `dmz-exchange-<kanal>`) → iç JWT. Kanal profilleri: web, mobile, partner, branch | Doğrulandı: `extauth.sh` 29/29 (önceki çalıştırma). Branch profili: doğrulama bekliyor |
| Hata gövdesi | 4xx/5xx JSON: `error`, `error_description`, `layer: dmz-ext-authz`, `status`; 401'de `WWW-Authenticate` | Doğrulandı |
| Tracing | Karar ve token exchange span'leri (Tempo) | Doğrulandı |
| Metrikler | `authz_decisions_total{channel,decision,status}`, `authz_exchange_total`, `authz_decision_duration_seconds` (port 9100, NodePort 30903) | Doğrulandı |
| Replika | 1 (DPoP replay cache süreç içi; prod'da paylaşılan store) | Lab sınırı |

### 2.4 Route sınıfları ve iç backend
Login ve public route'ları gerçek servislere gider (stub yok). `partner-login` yolu `/realms/`.

**DMZ test suite'leri (önceki çalıştırma):** `smoke.sh` 4/4, `route-classes.sh` 10/10, `extauth.sh` 29/29, `internal-path.sh` 8/8, `firewall.sh` (F1) 4/4. `branch.sh` (şube, uçtan uca) **yeniden yazıldı, doğrulama bekliyor**.

---

## 3. İç Cluster (kind-internal, `internal-cluster/`)

| Bileşen | Görev | Yapılandırma | Durum |
|---|---|---|---|
| **kgateway gw-internal** | DMZ kimliğini mTLS ile doğrular (`dmz-client-ca`), iç JWT doğrular, kanal RBAC, default deny | `manifests/gateway.yaml`, `internal-authz.yaml`, `listener-client-cert.yaml`; tracing `ListenerPolicy`; `scripts/up.sh` kurar | Doğrulandı: `authz.sh` 16/16 (önceki çalıştırma) |
| **Kanala özel iç endpoint'ler** | `/bff/web/*`, `/bff/mobile/*`, `/bff/branch/*`: her biri yalnız kendi kanalının `x-channel` değerini kabul eder | `internal-authz.yaml` | Doğrulandı |
| **BFF** (`app-bff`) | Kanalı token'dan doğrular; yanıtı kanala göre şekillendirir (mobil sadeleşir, şube `view: teller`); core'a iç token ile iletir | `services/svc.py` (ConfigMap `svc-code`), `manifests/services.yaml` | Doğrulandı |
| **Core** (`app-core`) | Dummy iş API'si: `/api/v1/accounts`, `/api/v1/accounts/{id}`, `/api/v1/accounts/{id}/transactions`, `POST /api/v1/transfers`. `/partner/*` ve `/public/*` | Hesap ve işlemler `sub` değerine göre deterministik, bellekte (restart'ta sıfır) | Doğrulandı: `api.sh` 16/16 |
| Transfer kuralları | `Idempotency-Key` zorunlu; kanal başına işlem limiti (`CHANNEL_LIMITS`, kuruş); bakiye kontrolü; partner salt okunur | `svc.py` | Doğrulandı: `api.sh` |
| Servis doğrulaması | Her servis iç JWT'yi kendisi doğrular (iss, aud, exp, kanal); hata gövdesi JSON (`layer: internal-service:<ad>`) | `svc.py` | Doğrulandı: `service-verify.sh` 9/9 |
| Metrikler | `svc_requests_total`, `svc_request_duration_seconds` (BFF ve core, NodePort 30901/30902); `core_transfers_total`, `core_transfer_amount_cents_total` | `shared/metrics.py` | Prometheus'a scrape ediliyor |
| **kube-state-metrics** | Cluster durum metrikleri. Secret okumaz, sınırlı RBAC | `manifests/metrics.yaml` (NodePort 30904) | Doğrulandı |

Tracing: BFF ve core span üretir (`bff → core` alt span'i dahil).

---

## 4. Şube Cluster'ı (kind-branch, `branch-cluster/`) ve Şube Zone

Şube trafiği HAProxy'den **geçmez**. Şube iş istasyonu WAN üzerinden, cihaz sertifikasıyla gw-branch'e (DMZ NodePort 30449) doğrudan bağlanır. Token exchange auth servisinde (ext-authz) yapılır. Lab'da WAN, kind ağı ile simüle edilir.

| Bileşen | Görev | Yapılandırma | Durum |
|---|---|---|---|
| **kind-branch cluster** | Şube UI pod'unun çalıştığı cluster. Tek node. Host'ta `127.0.0.1:9100` | `branch-cluster/kind-config.yaml` (extraPortMappings 30900 → 9100) | Doğrulama bekliyor (`up.sh` adım 6) |
| **Şube UI pod'u** (`branch-ui`, ns `branch`) | Veznedar arayüzü: PKCE girişi (`branch-app`), hesap sorgusu, güvenlik kontrolleri, çıkış. Python stdlib, `python:3.12-alpine` | `branch-cluster/manifests/branch-ui.yaml`, kod `branch/server.py` + `branch/index.html` (ConfigMap `branch-code`) | Doğrulama bekliyor |
| **Şube sondası** (`branch/probe.py`) | Test için: şube pod'undan gw-branch'e tek HTTPS isteği. Cihaz sertifikasız denemeyi de yapar | ConfigMap `branch-code` içinde | Doğrulama bekliyor (`branch.sh`) |
| **Şube cihaz sertifikası** | `branch-device` (CN=branch-ws-01), `branch-ca` ile imzalı. Secret `branch-device-tls` | `edge/scripts/gen-branch-certs.sh` | Üretildi |
| **Şube secret'ları** | `branch-app` client secret ve `teller` parolası: identity'den kopyalanır, repo'da yok | Secret `branch-app-secrets` (`up.sh` kopyalar) | Doğrulama bekliyor |
| **gw-branch** | Cihaz mTLS, `/bff/*` (ext-authz), `/realms/*` (login) | `dmz-cluster/manifests/branch.yaml`, `scripts/load-branch.sh` | Doğrulandı (önceki çalıştırma: 9/9) |
| **F10** | gw-branch NodePort'una yalnız şube node IP'lerinden erişim | `dmz-cluster/scripts/host-firewall.sh` | Doğrulama bekliyor |

**Şube UI ortam değişkenleri:** `BRANCH_GW_HOST` (DMZ node IP, `up.sh` ayarlar), `BRANCH_GW_PORT` (30449), `BRANCH_CERT_DIR`, `BRANCH_LISTEN` (pod'da 0.0.0.0), `BRANCH_APP_SECRET` ve `TELLER_PASSWORD` (pod'da secret'tan).

**Şube testi:** `dmz-cluster/tests/branch.sh`, 9 kontrol: cihaz sertifikasız TLS reddi, cihaz sertifikasıyla `/realms` 200, token yok 401, branch token 200 (`channel=branch`, `auth_method=branch_cert`), web token 403 (audience), `/partner` 404, `/public` 404. Test istekleri şube pod'undan `kubectl exec` ile gider.

**Önceki sürüm:** Şube UI host'ta çalışıyor ve `teller.lab.local` üzerinden HAProxy passthrough kullanıyordu. Bu sürüm kaldırıldı.

**Lab sınırları:** cihaz sertifikası tek iş istasyonu için (`branch-ws-01`); çalışan kimliği yerel `teller` kullanıcısı; şube CA özel anahtarı `edge/certs/` içinde (git'e girmez).

---

## 5. Identity Cluster (kind-identity, `identity-cluster/`)

| Bileşen | Görev | Yapılandırma | Durum |
|---|---|---|---|
| **Keycloak 26.6** | Login, token üretimi, token exchange (standart V2 + SPI), realm `bank` | `manifests/keycloak.yaml`: `--spi-x509cert-lookup--provider=envoy`, `KC_HOSTNAME=https://id.bank.lab.local` (issuer), `--hostname-admin=http://127.0.0.1:18080`, OpenTelemetry tracing (Tempo) | Doğrulandı (önceki çalıştırma) |
| **SPI `dmz-dpop-mobile-exchange`** | Mobil DPoP bağlı subject token'ı yeniden imzalayıp standart exchange'e sokar | `keycloak-spi/` (Java), imaj `dmz-lab/keycloak-dpop:26.6` | Doğrulandı |
| **PostgreSQL 16** | Keycloak veritabanı | emptyDir (lab) | Doğrulandı |
| **F8 host firewall** | Keycloak'a yalnız iç node'lardan ve pod ağından erişim | `identity-cluster/scripts/host-firewall.sh` | Doğrulandı: 3/3 |

**Realm `bank` client'ları:**

| Client | Akış | Not |
|---|---|---|
| `web-app` | PKCE, confidential | DPoP yok (Bearer), exchange kabul eder |
| `mobile-app` | PKCE, public | DPoP zorunlu; `directAccessGrants` kapalı |
| `branch-app` | PKCE, confidential | Şube çalışanı girişi (`teller`); redirect `https://teller.lab.local/*` |
| `partner-acme` | Client credentials | mTLS ile birlikte |
| `dmz-exchange-{web,mobile,partner,branch}` | client-x509 | Token exchange istemcileri (kanal başına) |
| `bff`, `core-svc`, `kgateway-internal` | Servis | Hedef audience |

Kullanıcılar (lab): `alice` (web/mobil test), `teller` (şube). Test token'ları PKCE ile alınır (`identity-cluster/tests/lib/pkce.sh`).

Admin konsolu: `http://127.0.0.1:18080/admin/` (port-forward gerekir). Admin parolası cluster secret'ında, repo'da yok. Admin konsolunda "3rd party check iframe" zaman aşımı uyarısı açık konudur (bölüm 10).

Cilium denemesi (WSL2 kernel'de `xt_socket` eksik) başarısız oldu ve kaldırıldı; F8 host iptables ile çözüldü.

---

## 6. Management / Gözlemlenebilirlik (kind-mgmt, `mgmt-cluster/`)

| Bileşen | Görev | Yapılandırma | Durum |
|---|---|---|---|
| **Vault 1.18** (ns `secrets`) | KV v2 (`secret/`), identity secret'ları, Keycloak parolaları | `manifests/vault.yaml`, NodePort 30200, `identity-cluster/scripts/load-vault.sh` (init, unseal, secret türetme). F9 host firewall: yalnız identity ve internal node'lar | Doğrulandı (önceki çalıştırma) |
| **Grafana 11.3** (ns `observability`) | Dashboard ve iz sorgusu. Veri kaynakları: Prometheus (uid `prometheus`), Tempo (uid `tempo`) | `manifests/grafana.yaml`, NodePort 30300, admin parolası `grafana-admin` secret'ında | Çalışıyor |
| Dashboard: **DMZ Lab – Genel Bakış** | İstek hızı, gecikme, yetkilendirme kararları, transfer sonuçları | `lab-overview.json` | Çalışıyor |
| Dashboard: **DMZ Lab – Dağıtık İzleme** | Servis bazlı son izler, hata izleri (TraceQL), iz kimliğiyle arama | `lab-tracing.json` | Çalışıyor |
| **Grafana Tempo 2.6.1** | Trace depolama ve sorgu. OTLP HTTP NodePort 30318, gRPC 30317 (Jaeger'ın yerini aldı) | `manifests/tempo.yaml`; emptyDir, `block_retention` 48 saat | Çalışıyor |
| **Prometheus 2.55** | Metrik toplama: bff, core, ext-authz, kube-state-metrics. Her hedefe `cluster` ve `namespace` etiketi | `manifests/prometheus.yaml`, NodePort 30090 | Beş scrape hedefi tanımlı |

Trace ve metrik kalıcılığı lab'da emptyDir'dir; yeniden başlatmada veri gider.

---

## 7. Operasyon Konsolu (`console/`)

| Bileşen | Görev | Durum |
|---|---|---|
| **`console/app.py`** (port 9000) | Organizer ve kanal sayfaları (`organizer.html`, `channel.html`). Giriş ve çıkış her zaman görünür. Her çağrı kök bir console span'i ve Tempo izi üretir | Doğrulandı (önceki çalıştırma) |
| **Şube kanalı** | `app.py` hâlâ şube kanalını `teller.lab.local` üzerinden edge'e gönderiyor. Bu yol artık çalışmaz (bölüm 10) | **Güncellenmedi, açık** |
| **Operasyon tablosu** (`console/ops.js`) | Kanal bazında işlem matrisi: yapılabilen (✓) ve yapılamayan (✗) işlemler | Tek kaynak tablo |
| Port-forward'lar | Identity Keycloak `18081`, Tempo OTLP `14318`, Grafana `3000` | `app.py` içinde `kubectl port-forward` |

Ayrıntılı kullanım: `console/README.md`.

---

## 8. Ortak Araçlar ve Diyagramlar

| Dosya | Kullanım |
|---|---|
| `shared/tracing.py` | Stdlib W3C traceparent ve OTLP/HTTP JSON span üretimi; servisler ConfigMap ile `/app/tracing.py` olarak alır |
| `shared/metrics.py` | Stdlib Prometheus metin formatı (counter, histogram); ayrı port 9100 |
| `docs/drawio/palette.js` | Diyagramlar için ortak renk paleti ve stiller |
| `docs/drawio/builder.js` | Sayfa üretici: kutu, zone, namespace, pod, bağlı ok |
| `docs/drawio/pages-overview.js` | 1 Genel mimari, 2 I/O ve araçlar, 3 Tüm cluster'lar ve namespace'ler |
| `docs/drawio/pages-clusters.js` | 4 DMZ, 4b Şube, 5 İç, 6 Identity, 7 Mgmt cluster içi; 8 Pod içi detay |
| `docs/drawio/gen-sequence.js` + `sequence-defs.js` + `sequence-defs-branch.js` | Sequence sayfaları (7 adet) |
| `docs/drawio/gen-all.js` | Hepsini `docs/dmz-lab.drawio` dosyasında tab olarak üretir: `node docs/drawio/gen-all.js` |

---

## 9. Test Özeti

Tam koşu: `bash run-all.sh` (kök dizin), 11 süit. Son tam koşu Tempo ve Keycloak izleme değişikliklerinden önce yapıldı. Şube cluster'ı ve F10 eklendiğinden beri tam koşu yapılmadı.

| Süit | Kontrol | Durum |
|---|---|---|
| `identity-cluster/tests/firewall.sh` (F8) | 3 | Önceki çalıştırma geçti |
| `dmz-cluster/tests/smoke.sh` | 4 | Önceki çalıştırma geçti |
| `dmz-cluster/tests/route-classes.sh` | 10 | Önceki çalıştırma geçti |
| `dmz-cluster/tests/extauth.sh` | 29 | Önceki çalıştırma geçti |
| `dmz-cluster/tests/internal-path.sh` | 8 | Önceki çalıştırma geçti |
| `dmz-cluster/tests/firewall.sh` (F1) | 4 | Önceki çalıştırma geçti. F10 eklendi, yeniden çalıştırılmalı |
| `dmz-cluster/tests/branch.sh` | 9 | **9/9 geçti** (token alımı web gateway'in `/realms` route'u üzerinden https ile) |
| `internal-cluster/tests/authz.sh` | 16 | Önceki çalıştırma geçti |
| `internal-cluster/tests/service-verify.sh` | 9 | Önceki çalıştırma geçti |
| `internal-cluster/tests/api.sh` | 16 | Önceki çalıştırma geçti |
| `edge/tests/run-all.sh` | 25 | Önceki çalıştırma geçti. Şube kuralı kaldırıldı, yeniden çalıştırılmalı |

---

## 10. Açık Konular

- **Sabit node IP'leri:** Çözüldü. IP'ler kurulumda okunuyor (`scripts/lab-ips.sh`, `render`); HAProxy yapılandırması `edge/scripts/render-haproxy.sh` ile üretiliyor. Gateway NodePort'ları ve public/login route'ları artık kurulumda uygulanıyor.

- **Konsol şube kanalı:** `console/app.py` şube kanalını `teller.lab.local` (HAProxy) üzerinden çağırıyor. Şube artık HAProxy'den geçmediği için bu kanal çalışmaz. Düzeltme: şube kanalını şube cluster'ındaki pod üzerinden (`kubectl exec` ya da port-forward) çağırmak.
- **Şube kurulumunun doğrulanması:** `up.sh` adım 6, `branch.sh` 9 kontrol ve F10 henüz uçtan uca çalıştırılmadı.
- **Şube UI tarayıcı testi:** `branch/` arayüzü tarayıcıda ayrıca doğrulanmalı.
- **HAProxy span'leri:** OTel'li HAProxy imajı gerekiyor (onay bekliyor).
- **Kalıcılık:** Trace, metrik, PostgreSQL ve dummy veriler lab'da emptyDir/bellek.
- **Vault PKI ve ESO:** Exchange, DMZ, partner ve şube sertifikaları henüz Vault'tan değil; identity secret'ları bootstrap betiğiyle.
- **Argo CD ve Kyverno:** kurulmadı (planlı).
- **D-12 (realm imzalama anahtarları):** Keycloak DB, HSM/KMS veya Vault Transit kararı bekleniyor.
- **Partner CRL/OCSP:** kgateway v2.5 desteklemiyor; kısa ömürlü sertifika ile sınırlanacak.
- **ext-authz replika > 1:** Paylaşılan replay store gerekiyor.
- **Lab kullanıcıları:** `alice` ve `teller` test kullanıcıları; prod öncesi kaldırılacak.
- **Admin konsolu iframe uyarısı:** Keycloak admin konsolunda "3rd party check iframe" zaman aşımı; hosts dosyası ve HTTPS çözümü onay bekliyor.
