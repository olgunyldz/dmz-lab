# Servisler, cluster'lar ve durum

Bu dosya mevcut lab düzenini anlatır. Düzen: edge (docker compose) + 5 kind cluster (`codevo-dmz`, `bank-dmz-prod`, `bank-prod`, `mgmt`, `legacy-demo`).

Durum etiketleri: **Test edildi** (bu düzende uçtan uca çalıştırıldı), **Kuruldu** (manifest uygulandı, çalışıyor, uçtan uca test edilmedi), **Planlandı** (henüz yok).

## 1. Cluster ve edge özeti

| Ortam | Ne çalışır | Dizin | Durum |
|---|---|---|---|
| **edge** (docker compose) | HAProxy: `seal.lab.local` TLS passthrough (SNI), `web.lab.local` ve `mobile-api.lab.local` TLS sonlandırma → Janus. Host portu `127.0.0.1:8443`, stats `8404` | `edge/` | Test edildi |
| **platform** (host, docker compose, ağ `lab-platform`) | LegacyDB (PostgreSQL 16, 30432 köprüsü), Fortuna monolit (mTLS), merkezi Prometheus (remote_write alıcısı), Loki, Tempo, Grafana (127.0.0.1:3000). Köprüler: IdP, Seal Intranet, monolit girişi (kind ağına yayın) | `platform/` (`scripts/up.sh`, `docker-compose.yml`) | Test edildi |
| **codevo-dmz** | Seal Mobile (cihaz mTLS, NodePort 30456), Seal Intranet (yalnız akış uçları, NodePort 30643) | `codevo-dmz-cluster/` | Test edildi |
| **bank-dmz-prod** | Janus web (NodePort 30802) ve Janus mobil (NodePort 30801). Janus kimlik üretir: splash, client token, server token | `bank-dmz-prod-cluster/` | Test edildi |
| **bank-prod** | auth-server (Spring Authorization Server, ns `auth`, NodePort 30543 HTTPS, 30582 iç), Fortuna zinciri (`channel`: FortunaUsersCGW, FortunaUserAPI, FortunaUserACL, SmsOtpCGW mock), channel-gateway (NodePort 30990), Vault (ns `secrets`) | `bank-prod-cluster/` | Test edildi (auth, Fortuna, channel-gateway); Vault kuruldu |

Node IP'leri `docker inspect` ile okunur (`kind` ağı). Cluster'lar arası çağrılar NodePort + `hostAliases` ile yapılır; yer tutucular (`__BANKPROD_NODE_IP__` vb.) loader betiklerinde `sed` ile doldurulur.

## 2. Akış servisleri

### 2.1 Janus (bank-dmz-prod, ns `janus`)

Kanal başına iki deployment: `janus-web` (`CHANNEL=web`) ve `janus-mobile` (`CHANNEL=mobile`). Python stdlib, HS256 imza, anahtarlar `janus-keys` secret'ında (loader üretir, repoda yok).

| Uç nokta | Ne yapar | Durum |
|---|---|---|
| `/janus/health` | Sağlık | Test edildi |
| `/janus/splash` | Splash token (typ `splash`, 15 dk) ve splashCode | Test edildi |
| `/janus/secure-login` | Seal yetkisini Fortuna üzerinden doğrular (mobil) | Test edildi |
| `/janus/otp/request` | SMS OTP isteği (SmsOtpCGW mock, lab: kod yanıtta) | Test edildi |
| `/janus/login-user` | Müşteri no + parola + captcha (Fortuna) + OTP. Başarılıysa **client token** (typ `client`) | Test edildi |
| `/janus/mobile-login` | Cihaz ACTIVE ise client token üretir | Test edildi |
| `/janus/activation/token`, `/janus/activation/complete` | Yeni cihaz aktivasyonu (PENDING → ACTIVE) | Test edildi (konsol yeni cihaz akışı) |
| `/janus/transaction` | Client token'ı doğrular, **server token** (typ `server`, `aud=channel-gateway`, 60 sn) üretip channel-gateway'e iletir | Test edildi |

Akış tokenları: dışarı giden token **client token**; içeri giden **server token**. Splash token'ı tüm akış uçlarında `X-Splash-Token` ile gönderilir.

Bilinen sınırlar: Janus ve channel-gateway'den gelen tüm çağrılar mTLS (kanal başına istemci sertifikası; sunucular CN kontrolü yapar). Fortuna iç zinciri (CGW → API → ACL) da mTLS. Bekleyen OTP durumu bellekte (tek replika).

### 2.2 channel-gateway (bank-prod, ns `channel`)

Janus server token'ını doğrular (imza, `typ=server`, `aud=channel-gateway`, süre). Lab'da Janus HS256 anahtarlarını bir secret'tan alır; prod'da Janus açık anahtarı (JWKS) kullanılmalı. İşlem: `BALANCE` → Fortuna monolith `/fortuna/accounts`. Diğer işlemler `400` döner.

Test: geçerli server token → 200 ve bakiye; yanlış imza, yanlış `typ` → 401. Janus üzerinden (client → server → channel-gateway) 200.

### 2.3 Seal (codevo-dmz)

| Servis | Görev | Durum |
|---|---|---|
| **Seal Mobile** (`seal-mobile`, NodePort 30456, SNI `seal.lab.local`) | Cihaz mTLS (`CERT_REQUIRED`, device CA), PIN (Fortuna monolitindeki `/seal-pm/*` uçlarıyla), cihaz imzası (PKCS1v15 SHA-256, nonce). Mobil IdP token'ını introspection ile doğrular | Test edildi |
| **Seal Intranet** (`seal-intranet`, NodePort 30643) | Yalnız akış uçları: login-status, timestamp, activation token/status, update-device (lab mock). B2B bearer (RS256, IdP JWKS) | Test edildi |

Seal cihaz kaydı ve durumunun tek kaynağıdır (`update-device` yazar, `get-device` okur). PIN doğrulaması Fortuna monolitindedir. Vendor doğrulaması bekliyor (aşağıda açık konular).

### 2.4 Kimlik sağlayıcı (bank-prod, ns `auth`)

Kaynak: `bank-prod-cluster/spring-idp/` (imaj `dmz-lab/auth-server:0.1.0`, yükleyici `bank-prod-cluster/scripts/load-auth-server.sh`). Ayrı bir identity cluster'ı yoktur; `auth-server` bu kodun bank-prod'daki çalışan hâlidir.

Spring Authorization Server (Java 21, Spring Boot 4.1.2, Spring Security 7). Realm yolu `/realms/bank/...`. Mobil istemci `mobile-app`: public, PKCE zorunlu, `com.bank.app:/callback`. Web ve diğer istemciler bu dokümanın kapsamı dışında. Discovery ve JWKS 200 döner.

Kullanıcı girişi yalnız kimlik doğrulama için kullanılır; müşteri parolası Fortuna'da doğrulanır (`fortuna_users`). DPoP kaldırıldı; token exchange grant tipi kodda duruyor, bu akışta kullanılmıyor.

### 2.5 Fortuna (bank-prod `channel` ve legacy-demo)

| Servis | Görev |
|---|---|
| FortunaUsersCGW (`:30880`) | Captcha (lab değeri `lab-captcha`) kontrolü, API'ye iletir |
| FortunaUserAPI | Parola doğrulama zinciri |
| FortunaUserACL | `fortuna_users` tablosunda parola, `customers` tablosunda ad ve durum; pasif müşteri reddedilir |
| SmsOtpCGW (`:30881`, mock) | OTP üretir/doğrular; lab'da SMS gönderilmez |
| Fortuna monolith (legacy-demo, `fortuna-mock`) | Hesaplar (`/fortuna/accounts`), cihaz durumu, secure-login ve mobile-login uçları |

Müşteri verisi, cihaz kayıtları ve denetim kaydı LegacyDB'de (mgmt, PostgreSQL 16): `customers`, `accounts`, `fortuna_users`, `customer_devices` (PENDING / ACTIVE / LOCKED / REVOKED), `device_events`. Seed: `C000000001`, `Alice Demo`, hesap `TR000000000001`, bakiye 12500.00.

## 3. Konsol (`console/`)

`console/app.py`, `127.0.0.1:9000`. Web ve mobil kanal için tarayıcı arayüzü (`console/channel.html`). Kimlik bilgileri tarayıcıya gitmez; alice parolası bank-prod `auth-secrets`'tan bellekte okunur.

- **Web**: splash → OTP → login-user → client token → `BALANCE`. Test edildi.
- **Mobil**: splash → IdP (PKCE, `mobile-app`) → Seal (PIN, cihaz imzası) → secure-login → mobile-login → `BALANCE`. Test edildi.
- **Mobil yeni cihaz**: Seal (NEW_DEVICE, PIN_AUTHORIZED) → OTP + parola (login-user) → activation/token → activation/complete (ACTIVATED) → PIN kaydı → normal mobil giriş → `BALANCE`. Test edildi.

Başlatma: `bash console/start.sh` (edge, bank-prod, bank-dmz-prod, codevo-dmz context'lerini kontrol eder). Ayrıntılı kullanım: `console/README.md`.

Bilinen sınırlar: mobil giriş için Seal'de ACTIVE cihaz gerekir (Seal yeniden başlarsa cihazlar yeniden aktive edilmeli). Lab cihaz kayıtları (`devtest-*`, `mob-*`) temizlendi; yeni cihaz akışı her çalıştırmada yeni bir cihaz kimliği aktive eder ve kayıt LegacyDB'de kalır (lab). Eski `devtest-d` ile yapılan testler artık çalışmaz.

## 4. Yüklemeler

| Betik | Ne kurar |
|---|---|
| `edge/scripts/render-haproxy.sh` | `haproxy.cfg` (node IP'leri ile) |
| `edge/scripts/gen-certs.sh`, `gen-internal-certs.sh`, `gen-device-certs.sh`, `gen-seal-certs.sh` | Sertifikalar (`edge/certs`, gitignored) |
| `codevo-dmz-cluster/scripts/load-seal-mobile.sh`, `load-seal-intranet.sh` | Seal servisleri |
| `bank-dmz-prod-cluster/scripts/load-janus.sh` | Janus (web, mobil) |
| `bank-prod-cluster/scripts/load-auth-server.sh`, `load-fortuna.sh`, `load-channel-gateway.sh` | auth-server, Fortuna zinciri, channel-gateway |
| `legacy-demo-cluster/scripts/load-legacy.sh` | Fortuna monolith mock; LegacyDB şeması ve demo verisi (`legacy-demo-cluster/db/schema.sql`, `seed.sql`, idempotent) |

Repoda sır yoktur; sırlar loader betikleri tarafından üretilir veya kopyalanır.

## 5. Açık konular

- **Seal vendor doğrulaması:** Cihaz kaydı Seal'de (D-13). Lab'da Seal Intranet `update-device` (durum yazar) ve `get-device` (durum okur) uçlarını mock olarak sunuyor; bellekte, yeniden başlatmada kayıtlar silinir. Vendor'ın bu uçları ve kalıcılığı teyit etmesi gerekir.
- **Channel-gateway anahtarı:** Lab'da secret; prod'da JWKS.
- **Janus ↔ alt servis mTLS:** Janus → channel-gateway, Janus → Fortuna CGW/SMS/monolit ve channel-gateway → monolit uygulandı ve test edildi. Fortuna iç zinciri (CGW → API → ACL) da mTLS ile korunuyor. Kalan: sertifika yenileme (prod).
- **web-ui-gateway:** Planlandı, henüz yok.
- **İzleme ve loglama (sonraki adımlar):** Yığın kuruldu (Tempo, Prometheus, Loki, Grafana). Loglar Alloy ile beş cluster'dan Loki'ye gidiyor. Metrikler: Janus, channel-gateway, Fortuna (CGW, SMS, legacy) `/metrics` sunuyor (`http_requests_total`, yol ve koda göre). Ayrıca auth-server (Spring Actuator, `/actuator/prometheus`, NodePort 30583), Seal Mobile (NodePort 30457) ve Seal Intranet (NodePort 30644) metrik sunuyor; bu üçü düz HTTP ayrı bir metrik portunda. ACL/API iç servisleri kazınmıyor (NodePort yok). Alloy'lar `loki.write` için açık yeniden deneme ayarı aldı (`max_backoff_period = "30s"`). Loki yeniden başlatıldığında beş cluster'ın akışı bir buçuk dakika içinde döndü (ölçüldü). Ölçüm (Loki yeniden başlatıldı, ~42 sn kesinti, 1 sn/satır test pod'u): 240/240 satır Loki'ye ulaştı, kayıp yok. Ölçülmemiş uzun kesintiler için yeniden deneme üst sınırı (100 deneme, en fazla 30 sn aralık) geçerli; bu süre aşılırsa kayıp olur.
- **Redis:** Mgmt'te çalışıyor, hiçbir servis kullanmıyor. Kaldırılsın mı, yoksa bir kullanım mı planlanıyor?
- **Kullanılmayan kod:** IdP'deki restricted-claim kodu ve `AuthStateRepository` kaldırıldı (hiçbir yerden çağrılmıyordu; `markPending` hiç çalışmadığı için dal ölüydü).
- **Eski dosyalar:** Beş-cluster kalıntıları (`internal-cluster`, `dmz-cluster`, `branch`, `branch-cluster`, `identity-cluster`, `edge/tests`, `up.sh`, `down.sh`, `run-all.sh`) silindi. Kaynaklar yeni yerlerine taşındı: Seal Mobile `codevo-dmz-cluster/seal-mobile`, Seal Intranet `codevo-dmz-cluster/seal-intranet`, Password Manager `mgmt-cluster/password-manager`, IdP `bank-prod-cluster/spring-idp`, Vault yükleyicisi ve manifesti `bank-prod-cluster/scripts/load-vault.sh` ve `bank-prod-cluster/manifests/vault.yaml`.
- **Taşınan yükleyicilerin yeniden deploy testi:** Yol kontrolü ve sözdizimi geçti, gerçek yeniden deploy yapılmadı. Çalışan sistem sağlıklı (Vault açık, IdP discovery 200, uçtan uca mobil test geçti).
- **Eski dokümanlar:** `design.md` ve `docs/*.drawio` eski akışı anlatıyor; silinmedi, güncellenmedi. Karar bekliyor (silinsin mi, yeniden yazılsın mı).
