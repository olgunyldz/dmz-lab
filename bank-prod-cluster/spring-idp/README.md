# Spring kimlik sağlayıcı (prototip)

Spring Boot 4.1 + Spring Authorization Server 7.1.2 tabanlı kimlik sağlayıcı. Identity cluster'da (`idp` namespace) çalışır; tüm tüketiciler (ext-authz, BFF, core, konsol, şube) bunu kullanır. Keycloak kaldırıldı.

## Veritabanı

PostgreSQL (`postgres:16.15-alpine`). Şema Flyway ile `src/main/resources/db/migration` altından kurulur:
- `V1`: Spring Authorization Server tabloları (`oauth2_registered_client`, `oauth2_authorization`, `oauth2_authorization_consent`), PostgreSQL uyarlamasıyla (`timestamptz`, `text`).
- `V2`: kullanıcı tabloları (`users`, `authorities`).

İstemci ve kullanıcılar açılışta `Seeder` ile eklenir; var olanlar değiştirilmez (sır rotasyonu ayrı adım). Bağlantı: `IDP_DB_URL`, `IDP_DB_USER`, `IDP_DB_PASSWORD`.

Doğrulama: yeniden başlatma sonrası 13/13 duman testi geçti, istemci/kullanıcı sayıları değişmedi (tekrar tohumlama yok).

## Veritabanı

PostgreSQL (`postgres:16.15-alpine`). Şema Flyway ile `src/main/resources/db/migration` altından kurulur:
- `V1`: Spring Authorization Server tabloları (`oauth2_registered_client`, `oauth2_authorization`, `oauth2_authorization_consent`), PostgreSQL uyarlamasıyla (`timestamptz`, `text`).
- `V2`: kullanıcı tabloları (`users`, `authorities`).

İstemci ve kullanıcılar açılışta `Seeder` ile eklenir; var olanlar değiştirilmez (sır rotasyonu ayrı adım). Bağlantı: `IDP_DB_URL`, `IDP_DB_USER`, `IDP_DB_PASSWORD`.

Doğrulama: yeniden başlatma sonrası 13/13 duman testi geçti; istemci (10) ve kullanıcı (1) sayıları değişmedi.

## Kapsam (çalışıyor)

| Özellik | Uç nokta / davranış | Test |
|---|---|---|
| Discovery | `/.well-known/openid-configuration` (kök), uç noktalar `/realms/bank/...` | `tests/smoke.sh` |
| JWKS | `/realms/bank/protocol/openid-connect/certs` | `tests/smoke.sh` |
| Authorization Code + PKCE | `/realms/bank/protocol/openid-connect/auth`; PKCE zorunlu (`requireProofKey`) | elle: PKCE'li → `/login`, PKCE'siz → `code_challenge` hatası |
| client_credentials | `/realms/bank/protocol/openid-connect/token` | `tests/smoke.sh` |
| Token exchange (RFC 8693) | aynı token uç noktası; istemci kimliği **mTLS** (`tls_client_auth`, `CN=dmz-exchange-<kanal>`); `aud` = istenen audience, `azp` = exchange istemcisi | `tests/smoke.sh` |
| mTLS | sunucu TLS 1.2, istemci sertifikası isteğe bağlı (`client-auth: want`); exchange istemcileri sertifika zinciri (yaprak + lab CA) sunmalı | `tests/smoke.sh` |
| Kanal claim'leri | `channel`, `auth_method`, `partner_id`, `aud` (`channel-*`) — IdP mapper'larının karşılığı (`ChannelClaims`) | `tests/smoke.sh` |
| Olumsuz senaryolar | sertifikasız exchange → 401; yetkisiz istemci → `unauthorized_client`; sahte subject token → `invalid_grant` | `tests/smoke.sh` |

Sonuç (yerel konteyner, rastgele sırlarla, TLS + PostgreSQL): `tests/smoke.sh` 17/17. PKCE akışı yalnız elle doğrulandı (tarayıcı girişi testte yok).

### Ext-authz ve istemci gereksinimleri

- **Sertifika zinciri:** Spring, istemci sertifikası zinciri tek elemanlıysa (yalnız yaprak) sertifikayı *self-signed* sayar ve `SELF_SIGNED_TLS_CLIENT_AUTH` bekler. Bu yüzden exchange istemcisi **yaprak + lab CA** zincirini göndermeli. Ext-authz'un TLS istemcisi bu şekilde yapılandırılmalı.
- **Windows curl:** schannel PEM istemci sertifikası yükleyemez ve zinciri göndermez; mTLS testi `openssl s_client` ile yapılır.

### İç yol (gateway modeli)

- Dağıtımda IdP iki port açar: **8443** (HTTPS, TLS 1.2, isteğe bağlı istemci sertifikası) ve **8080** (düz HTTP, yalnız iç gateway ve iç düğümler; F8 host firewall).
- İç gateway istemci sertifikasını **XFCC** başlığında iletir. `XfccCertificateFilter` bunu **yalnız 8080'de** okur; yaprağın lab CA tarafından imzalandığını ve geçerlilik süresini **kendisi doğrular**, zinciri `[yaprak, CA]` olarak kurar. HTTPS portunda başlık yok sayılır (istemci sahte XFCC gönderemez).
- Yönlendirme: internal kümede `gw-internal/auth-server` Endpoints'i, IdP yerine IdP'nin iç NodePort'u (30081) olabilir. Şu an **IdP'ta (30080)**; geçiş için aşağıdaki test/konsol bağımlılıkları önce taşınmalı.
- Smoke testi iç yolu da kapsar: `IDP_INTERNAL=http://127.0.0.1:<port>` ile XFCC üzerinden exchange.

**Geçişi engelleyen bağımlılıklar (IdP'ye özgü):** `internal-cluster/tests/service-verify.sh`, `dmz-cluster/tests/extauth.sh`, `api.sh`, `authz.sh`, `internal-path.sh`, `branch.sh` IdP secret'larını (`idp-secrets`) ve `svc/IdP` port-forward'ını kullanıyor; PKCE yardımcısı IdP login formunu bekliyor (Spring login formu CSRF ister); konsol IdP'ye doğrudan bağlı.

## Kapsam dışı (henüz yok)

- **Audience yetki listesi**: exchange'de istenen `audience`'ın istemci için izinli olup olmadığı kontrol edilmiyor.
- **Kullanıcılar**: yalnız `alice`. önceki IdP'deki `teller` ve diğer kullanıcılar yok.
- **Refresh token, logout, userinfo, admin**: yapılandırılmadı (refresh ve logout için yalnız istemci tanımında grant var).

## Bilinen sınırlamalar

- Discovery belgesi Spring'in varsayılanıyla issuer yolunu uç noktalara iki kez ekliyordu; `SecurityConfig` içinde auth, token ve JWKS adresleri gerçek yollara sabitlendi. Diğer meta veri alanları (ör. `userinfo_endpoint`, `end_session_endpoint`) hâlâ çift yol içerebilir; kullanılmadıkları için şimdilik bırakıldı.
- Discovery'nin `/realms/bank/.well-known/openid-configuration` yolunda sunulmadığı; yalnız kökte olduğu.
- **Tomcat güven deposu:** Boot 4 `server.ssl.trust-store` değerini Tomcat'e geçirmiyor (log: `trust store [null]`); `IdpConfig.mtlsTruststore` bunu doğrudan `SSLHostConfig` üzerinden ayarlıyor.
- **TLS 1.2 sınırı:** TLS 1.3'te isteğe bağlı istemci sertifikası (post-handshake auth) Tomcat'te çalışmadığı için sunucu yalnız TLS 1.2 konuşuyor.
- **Sır rotasyonu:** `Seeder` sistem istemcilerini her açılışta günceller (env sırları kaynak); kullanıcı parolası değiştirilmez.
- **Sır kaynağı (lab sapması):** Sırlar Vault `secret/auth/auth-server` yolunda tutulur; `load-auth-server.sh` bunları Kubernetes secret'ı `idp-secrets` olarak türetir. Prod: External Secrets Operator.
- **Kalıcılık:** İmzalama anahtarı PKCS12 (`idp-signing` secret'ı, alias `idp-sign`) olarak kalıcıdır; yeniden başlatmada token'lar geçerli kalır. PostgreSQL `postgres-idp-data` PVC'de tutulur (lab: local-path, tek replika). Prod: HA PostgreSQL ve anahtar yönetimi (HSM/KMS).
- **İzleme:** OpenTelemetry (OTLP HTTP → Tempo, mgmt NodePort 30318), servis adı `spring-idp`, örnekleme %100. Yanıtta `X-Trace-Id` döner; gelen `traceparent` korunur. Konsolun IdP çağrıları henüz `traceparent` göndermiyor (ayrı iş).

## Çalıştırma (yerel)

Gerekli: PostgreSQL, PKCS12 sunucu anahtarı (`IDP_TLS_KEYSTORE`) ve lab CA güven deposu (`IDP_TLS_TRUSTSTORE`).

```bash
cd bank-prod-cluster/spring-idp
docker build -t dmz-lab/spring-idp:0.1.0 .
docker run -d --name spring-idp-test -p 127.0.0.1:18443:8443 -v <tls-dizini>:/tls:ro \
  -e IDP_ISSUER=https://127.0.0.1:18443/realms/bank \
  -e IDP_DB_URL=jdbc:postgresql://<db>:5432/idp -e IDP_DB_USER=idp -e IDP_DB_PASSWORD=... \
  -e IDP_TLS_KEYSTORE=/tls/server.p12 -e IDP_TLS_KEYSTORE_PASSWORD=... \
  -e IDP_TLS_TRUSTSTORE=/tls/trust.p12 -e IDP_TLS_TRUSTSTORE_PASSWORD=... \
  -e ALICE_PASSWORD=... -e WEB_APP_SECRET=... -e PARTNER_ACME_SECRET=... \
  -e BFF_SECRET=... -e CORE_SVC_SECRET=... \
  dmz-lab/spring-idp:0.1.0
IDP_URL=https://127.0.0.1:18443 IDP_CA=<sunucu.crt> \
  EXCHANGE_CERT=<dmz-exchange-web.crt> EXCHANGE_KEY=<dmz-exchange-web.key> EXCHANGE_CA=<internal-ca.crt> \
  BFF_SECRET=... PARTNER_ACME_SECRET=... bash tests/smoke.sh
```

Not: `18080` lab'da IdP port-forward'ı için kullanılıyor (`tools-forward`); bu yüzden test 18443'te yapıldı. TLS test materyali (sunucu anahtarı) repo dışında üretilir, repo'ya girmez.
