# Bankacılık Kubernetes Platformu — Tasarım Dokümanı (lab)

| Alan | Değer |
|---|---|
| Doküman | design.md |
| Versiyon | 1.0 (lab durumuna göre yeniden yazıldı) |
| Durum | Lab'da uygulandı ve kısmen doğrulandı. Prod kararları açık |

Bu doküman lab'ın **güncel** mimarisini anlatır. Ayrıntılı servis listesi ve durum etiketleri için `docs/servisler.md` esas alınır.

---

## 1. Amaç ve Kapsam

Dış kanalları (web, mobil) iç çekirdek bankacılık servislerinden izole eden, kimlik ve cihaz doğrulaması yapan bir Kubernetes ortamını lab'da kanıtlamak.

**Kapsam içinde:** edge, DMZ kanal servisleri (Janus), cihaz doğrulama (Seal), kimlik sağlayıcı (IdP), Fortuna çekirdek zinciri, kanal gateway'i (channel-gateway), yönetim cluster'ı (sırlar, veritabanı, izleme).

**Kapsam dışı:** iş kuralları, prod veri katmanı, DR, uygulama API sözleşmeleri.

---

## 2. Tasarım İlkeleri

1. **Her kanal kendi giriş noktasına sahiptir.** Web ve mobil ayrı Janus örnekleridir; ortak bir "tek kapı" yoktur.
2. **Kimlik kaynağı tek yerdedir.** Müşteri parolası ve müşteri durumu Fortuna'dadır (LegacyDB). Cihaz PIN'i ve cihaz kaydı Seal'dedir. Bir bilgi iki yerde yetkili kaynak olamaz.
3. **Token'lar kanal sınırında değişir.** Dışarı giden token (client token) Janus tarafından üretilir; içeri giderken Janus onu doğrular ve kısa ömürlü bir server token üretir. İç servis yalnızca server token'ı kabul eder.
4. **Dışarıdan içeriye doğrudan erişim yok.** Kanal servisleri iç servislere yalnızca tanımlı NodePort/hedef üzerinden ulaşır.
5. **Sıfır güven.** Her çağrıda kimlik doğrulanır: splash token, client token, server token, cihaz sertifikası.
6. **En az yetki.** Seal Intranet yalnızca akış uçlarını sunar; channel-gateway yalnızca tanımlı işlemleri (`BALANCE`) yürütür.
7. **Lab sınırları açıkça işaretlenir.** Mock servisler (SMS, Seal Intranet vendor davranışı, channel-gateway anahtarı) prod'da aynen kullanılmaz.

---

## 3. Cluster ve Katman Yapısı

| Ortam | Rol | Ana bileşenler |
|---|---|---|
| **edge** (docker compose, HAProxy) | Dış giriş | SNI passthrough `seal.lab.local` → codevo; TLS sonlandırma `web.lab.local`, `mobile-api.lab.local` → Janus. Host port 8443 |
| **codevo-dmz** | Cihaz doğrulama | Seal Mobile (cihaz mTLS, PIN, cihaz imzası); Seal Intranet (yalnız akış uçları) |
| **bank-dmz-prod** | Kanal girişi | Janus web, Janus mobil (splash, OTP, giriş, client token, server token üretimi) |
| **platform** (host, docker compose, ağ: lab-platform) | LegacyDB, merkezi Prometheus/Loki/Tempo/Grafana, Fortuna monolit, köprüler (IdP, Seal Intranet, monolit girişi) | `platform/` |
| **bank-prod** | Kimlik ve çekirdek zincir | auth-server (IdP, `mobile-app` istemcisi); Fortuna zinciri (CGW, API, ACL, SMS mock); channel-gateway; Vault |

Cluster'lar arası çağrılar NodePort ve `hostAliases` ile yapılır. Node IP'leri Docker `kind` ağından okunur.

---

## 4. Bileşenler

### 4.1 Janus (kanal girişi)

Web ve mobil için ayrı örnekler. Python stdlib, HS256 imza. Akış uçları `X-Splash-Token` ister.

| Uç nokta | İşlev |
|---|---|
| `/janus/splash` | Splash token (15 dk, cihaz ve kanal bağlı) |
| `/janus/otp/request` | OTP isteği (lab: kod yanıtta gösterilir) |
| `/janus/login-user` | Müşteri no + parola + captcha (Fortuna) + OTP. Başarılıysa client token (web) |
| `/janus/secure-login` | Seal yetkisini Fortuna üzerinden doğrular (mobil) |
| `/janus/mobile-login` | Cihaz ACTIVE ise client token (mobil) |
| `/janus/activation/token`, `/janus/activation/complete` | Yeni cihaz aktivasyonu (PENDING → ACTIVE) |
| `/janus/transaction` | Client token'ı doğrular, server token üretir, channel-gateway'e iletir |

### 4.2 Seal (cihaz doğrulama, codevo-dmz)

- **Seal Mobile:** Cihaz istemci sertifikasıyla mTLS (CERT_REQUIRED, cihaz CA). PIN doğrulaması Fortuna monolitindeki PIN doğrulayıcı uçları üzerinden (`/seal-pm/*`). Cihaz imzası: nonce üzerinde PKCS1v15 SHA-256. Mobil IdP token'ını introspection ile doğrular.
- **Seal Intranet:** Yalnızca akış uçları: login-status, timestamp, activation token/status, update-device (lab mock). Çağıran B2B bearer token taşır (RS256, IdP JWKS).
- Web girişinde Seal yoktur.

### 4.3 Kimlik sağlayıcı (auth-server, bank-prod)

Ayrı bir identity cluster'ı yoktur. IdP kodu `bank-prod-cluster/spring-idp/` altındadır ve bank-prod'da `auth` namespace'inde `auth-server` olarak çalışır.

Spring Authorization Server (Java 21, Spring Boot 4.1.2, Spring Security 7). Mobil istemci `mobile-app` public ve PKCE zorunlu. Seal Mobile'ın kullandığı access token'ı üretir. Janus kendi token'larını üretir; IdP'nin müşteri token'ı Janus akışında kullanılmaz.

Kaldırılanlar: DPoP (D-12), ApprovalGate, restricted-claim (ölü kod), iç onay uçları.

### 4.4 Fortuna zinciri (bank-prod `channel` ve legacy-demo)

- **FortunaUsersCGW:** Captcha (lab değeri `lab-captcha`) kontrolü, API'ye iletir.
- **FortunaUserAPI:** Parola doğrulama zinciri.
- **FortunaUserACL:** Parola (`fortuna_users`) ve müşteri durumu (`customers`). Pasif müşteri reddedilir.
- **SmsOtpCGW (mock):** OTP üretir ve doğrular. SMS gönderilmez.
- **Fortuna monolit mock (legacy-demo):** Hesaplar, cihaz durumu, secure-login ve mobile-login uçları.

### 4.5 channel-gateway (bank-prod)

Janus server token'ını doğrular: imza (anahtar Janus kanalına göre), `typ=server`, `aud=channel-gateway`, süre. İşlemler: `BALANCE` → Fortuna `/fortuna/accounts`. Diğer işlemler reddedilir.

Lab notu: Janus anahtarları secret ile verilir. Prod'da Janus açık anahtarı (JWKS) kullanılmalı.

### 4.6 Veri (LegacyDB, mgmt)

PostgreSQL 16 (`ibdb_fortuna`). Tablolar: `customers`, `accounts`, `fortuna_users`, `pin_verifiers` (PIN doğrulayıcıları), `device_events` (denetim). `customer_devices` artık karar vermek için kullanılmıyor (Seal tek kaynak); tablo kaldırılabilir. Müşteri numarası giriş kimliğidir (`customerId`).

### 4.7 Yönetim ve gözlemlenebilirlik (mgmt, observability)

- **Loglar:** Alloy her cluster'da Kubernetes API'den pod loglarını okur, Loki'ye gönderir (etiketler: cluster, namespace, pod, container, app).
- **Metrikler:** Prometheus; Janus, channel-gateway ve Fortuna servisleri `/metrics` (`http_requests_total`), Seal Mobile ve Seal Intranet ile auth-server ayrı düz HTTP metrik portlarında sunar.
- **İzler:** Tempo (OTLP 30318). Konsol izleri kaldırıldı; servislerde iz üretimi henüz yok.
- **Grafana:** Prometheus, Tempo ve Loki veri kaynakları.

### 4.8 Konsol (lab)

`console/app.py` (127.0.0.1:9000). Web ve mobil akışlarını tarayıcıdan çalıştırır. Kimlik bilgileri tarayıcıya gitmez.

---

## 5. Akışlar

### 5.1 Web girişi

1. Splash (cihaz `web-…`).
2. OTP isteği (lab: kod yanıtta).
3. Login-user: müşteri no, parola, captcha, OTP. Fortuna doğrular, Janus client token üretir.
4. İşlem: `BALANCE` → Janus → server token → channel-gateway → Fortuna.

### 5.2 Mobil giriş (mevcut cihaz)

1. Splash (cihaz ACTIVE olmalı).
2. IdP: `mobile-app` PKCE ile access token.
3. Seal: login/begin, login/pin (PIN_OK), login/authorize (cihaz imzası).
4. Janus secure-login (SEAL_AUTHORIZED), mobile-login (client token).
5. İşlem: Web ile aynı.

### 5.3 Mobil yeni cihaz

1. Splash (yeni cihaz kimliği).
2. Seal: login/pin (NEW_DEVICE), authorize (PIN_AUTHORIZED).
3. Janus secure-login, OTP, login-user (parola + OTP).
4. Activation token → complete (ACTIVATED). Cihaz ACTIVE olur.
5. Seal PIN kaydı (device/enroll). Ardından 5.2 akışı.

### 5.4 Token modeli

| Token | Üretici | Tür | Ömür | Kullanım |
|---|---|---|---|---|
| Splash | Janus | HS256, `typ=splash` | 15 dk | Akış uçlarında `X-Splash-Token` |
| Client | Janus | HS256, `typ=client` | 15 dk | Kanal istemcisinin tuttuğu token |
| Server | Janus | HS256, `typ=server`, `aud=channel-gateway` | 60 sn | Janus'tan channel-gateway'e |
| Yenileme (Janus) | Janus | Opak, bellekte | 8 saat, tek kullanımlık (döner) | `/janus/token/refresh` ile yeni client token ve yeni yenileme token'ı |
| IdP access (mobil) | auth-server | RS256 | IdP politikası | Seal Mobile (introspection) |
| B2B | auth-server | RS256 | IdP politikası | Seal Intranet |

Client token dışarıda kalır. Server token yalnızca Janus'un içeri çağrısında üretilir; dış çağrılar server token kabul etmez (test edildi).

---

## 6. Ağ ve Güvenlik Kontrolleri

- Dış giriş yalnızca edge üzerinden: SNI passthrough (Seal) ve TLS sonlandırma (Janus).
- Janus → channel-gateway: mTLS. Janus kanal başına istemci sertifikası sunar (janus-web, janus-mobile); channel-gateway yalnızca bu CN'leri kabul eder. Sertifikalar iç CA ile imzalanır (`scripts/gen-mtls-certs.sh`).
- Janus → Fortuna CGW, SMS mock ve Fortuna monolit: mTLS. Bu sunucular yalnızca `janus-web`, `janus-mobile` (monolit ayrıca `channel-gateway`) CN'lerini kabul eder. Sağlık uçları sertifikasız açıktır.
- Fortuna iç zinciri (CGW → API → ACL): mTLS. Her servis yalnızca bir önceki halkanın CN'ini kabul eder (`fortuna-users-cgw`, `fortuna-user-api`).
- Cihaz kimliği: device CA ile imzalı istemci sertifikası; CN, Seal'de cihaz kimliğidir ve splash `deviceId` ile eşleşmelidir.
- Sırlar: repoda sır yoktur. Loader betikleri secret'ları üretir veya kopyalar (Vault bank-prod'da).
- DPoP kaldırıldı (D-12). Token'lar Bearer.

---

## 7. Kararlar

| # | Konu | Karar | Durum |
|---|---|---|---|
| D-1 | Token modeli | Kanal token'ı Janus'ta; içeri giderken server token (60 sn). IdP token'ı yalnız Seal için | Lab'da uygulandı, test edildi |
| D-2 | Credential otoritesi | Parola ve müşteri durumu Fortuna'da; PIN ve cihaz Seal'de | Lab'da uygulandı |
| D-3 | Edge | HAProxy (TLS, SNI passthrough, L7 hız sınırı). WAF lab'da mock | Prod WAF kararı güvenlik ekibinde |
| D-4 | IdP | Lab: Spring Authorization Server. Prod ürün kararı açık | Açık |
| D-5 | Kubernetes dağıtımı | Lab: kind. Prod: RKE2 veya OpenShift önerilir | Açık |
| D-6 | CNI | Prod: Cilium önerilir | Açık |
| D-7 | Cihaz doğrulaması | Cihaz mTLS + PIN + cihaz imzası. Vendor (Seal) davranışı lab mock'u ile temsil edilir | Vendor doğrulaması bekliyor |
| D-8 | DR | Ayrı doküman. Aktif-pasif önerilir | Açık |
| D-9 | MFA | OTP (lab: SMS mock). Prod: OTP + push veya FIDO2 | Lab'da OTP |
| D-10 | Sender constraint | DPoP kaldırıldı (D-12); token Bearer, kısa ömür | Kabul edildi |
| D-11 | Mobil cihaz bağlaması | Cihaz sertifikası + PIN + imza ile çağrı cihaza bağlanır | Lab'da uygulandı |
| D-12 | DPoP | Kaldırıldı (IdP, Seal, konsol, testler) | Uygulandı |
| D-13 | Cihaz kaydı kaynağı | **Seal cihaz kaydının ve durumunun tek kaynağıdır** (`update-device` yazar, `get-device` okur). Fortuna monolit cihaz durumunu Seal'den okur/yazar; LegacyDB'de cihaz durumu tutulmaz, yalnız denetim kaydı (`device_events`). PIN doğrulaması Fortuna'dadır. | Karar verildi (vendor yanıtına göre yeniden değerlendirilir) |

---

## 8. Bilinen Sınırlar (Lab)

- Janus ve channel-gateway'den gelen tüm çağrılar ve Fortuna iç zinciri mTLS. Düz HTTP kalan iç çağrı yok (lab).
- Janus'ta bekleyen OTP durumu bellekte; tek replika.
- channel-gateway Janus anahtarını secret'tan alıyor (prod'da JWKS).
- SMS mock; OTP yanıtta dönüyor.
- Captcha sabit değer (`lab-captcha`).
- Seal Intranet ve vendor davranışı mock.
- Yeni cihaz akışı her çalıştırmada LegacyDB'ye yeni cihaz kaydı ekler.
- Yenileme token'ları Janus belleğinde; tek replika. Mobil yenilemede cihaz durumu kontrol edilir; müşteri durumu yenilemede kontrol edilmez (prod'da gerekli).
- Loki: 10 GB PVC, tek replika. 42 sn'lik Loki kesintisinde log kaybı ölçülmedi (240/240). Uzun kesintilerde Alloy'un yeniden deneme üst sınırı aşılırsa kayıp olabilir.
- Metrik kapsamı: Janus, channel-gateway, Fortuna CGW/SMS/monolit, Seal Mobile, Seal Intranet ve auth-server kazınıyor. ACL ve API `/metrics` sunuyor ama NodePort'ları olmadığı için kazınmıyor.
- Trace: servislerde iz üretimi yok.
- web-ui-gateway planlandı, yok.

---

## 9. Prod'a Geçişte Değişecekler

| Lab | Prod |
|---|---|
| HS256 paylaşılan anahtar (Janus ↔ channel-gateway) | Janus açık anahtarı (JWKS), anahtar rotasyonu |
| Mock SMS | Gerçek SMS sağlayıcısı, OTP güvenliği ve hız sınırı |
| Mock Seal Intranet | Vendor ürünü ve sözleşme |
| Düz HTTP iç trafik (channel-gateway dışında) | mTLS (servis bazlı) |
| Tek replika, bellek içi OTP | Dağıtık OTP durumu, HA |
| EmptyDir / tek PVC | Yedekli depolama (Loki, LegacyDB) |
| kind | Kurumsal Kubernetes (RKE2 / OpenShift) |
| Lab kullanıcıları ve sabit captcha | Gerçek müşteri doğrulama ve captcha servisi |

---

## 10. Açık Sorular

1. Seal vendor doğrulaması: cihaz kaydı Seal'de olacak şekilde (D-13) ürün davranışı teyit edilecek; `get-device` ucu lab'da eklendi, vendor sözleşmesine dahil edilmeli.
2. Prod IdP ürünü ve barındırma.
3. Sertifika yönetimi: lab'da iç CA ile üretilen dosyalar; prod'da otomatik yenileme (cert-manager/Vault PKI) ve kısa ömür.
4. Mobil cihaz aktivasyonunun prod'da müşteri tarafı akışı (parola yerine, hangi kanal).
5. İzleme yığınının prod'daki yeri (mgmt cluster'ında kalıp kalmayacağı).
6. web-ui-gateway kapsamı ve şube kanalı (yeniden eklenecek mi).

---

## 11. Diyagramlar

`docs/dmz-lab.drawio` güncel düzeni çizer (4 sayfa: genel mimari, web girişi ve işlem, mevcut cihazla mobil giriş, yeni cihaz aktivasyonu). Üretici: `node docs/drawio/gen-all.js` (ortak yardımcılar `builder.js` ve `palette.js`). Diyagramları değiştirmek için önce `gen-all.js` düzenlenir, sonra yeniden üretilir.
