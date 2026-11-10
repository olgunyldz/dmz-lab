# Kullanılan Servisler, İçerikleri ve Yapılanlar

Bu doküman lab'da kurulan her servisi, ne işe yaradığını, hangi cluster'da çalıştığını, içeriğini ve durumunu özetler.
Mimari hedef için `design.md`, görsel için `docs/architecture.drawio`, akışlar için `docs/sequences.drawio` bakılmalıdır.

Son güncelleme: 2026-11-10. Durum sütunu lab'daki son doğrulamayı gösterir.

---

## 1. DMZ Edge (docker compose, `edge/`)

| Servis | Ne yapar | İçerik / yapılandırma | Durum |
|---|---|---|---|
| **HAProxy 3.0** | Dış giriş (public 443). SNI'ye göre partner passthrough, TLS sonlandırma, host yönlendirme (`web.lab.local`, `mobile-api.lab.local`), re-encrypt, L4 bağlantı ve L7 istek hızı sınırı (IP başına), WAF'a SPOE ile yönlendirme | `haproxy/haproxy.cfg`: `fe_public` (L4, `req.ssl_sni`), `fe_https` (L7, `stick-table`, `http-request`), `be_gw_web` / `be_gw_mobile` / `be_partner_pt` (DMZ NodePort 30446–30448, `check-ssl`) | Yapılandırıldı, `haproxy -c` geçerli. Uçtan uca test WAF imajı bekliyor |
| **Coraza WAF (coraza-spoa v0.9.1)** | Uygulama katmanı saldırıları (SQLi, XSS, path traversal), OWASP CRS ile | `waf/coraza-spoa.yaml`, `haproxy/coraza.cfg`. İmaj `scripts/build-waf.sh` ile derlenir | Çalışıyor: imaj yerel derlendi, SQLi/XSS/traversal 403 |
| Edge test suite | HAProxy, WAF, DDoS, LB, slowloris | `tests/smoke.sh`, `lb.sh`, `waf.sh`, `ddos.sh`, `run-all.sh` | 25/25 (smoke 12, lb 6 dahil failover, waf 5, ddos 2) |

**Edge ↔ DMZ firewall (F1):** Henüz uygulanmadı. Önerilen: DMZ node'larında host iptables ile yalnız HAProxy kaynağından 30446–30448 portlarına izin. Bkz. `design.md` 6.2 F1.

---

## 2. DMZ Cluster (kind-dmz, `dmz-cluster/`)

### 2.1 Platform
| Servis | Ne yapar | İçerik | Durum |
|---|---|---|---|
| **Gateway API v1.7.0** | Gateway/HTTPRoute CRD'leri | Standart kurulum | Kuruldu |
| **kgateway v2.5.0** | Gateway API uygulayıcısı (Envoy) | Helm: `kgateway-crds`, `kgateway` | Kuruldu |

### 2.2 Kanal gateway'leri
| Kaynak | Ne yapar | İçerik | Durum |
|---|---|---|---|
| `Gateway gw-web` / `gw-mobile` / `gw-partner` | Kanal başına TLS sonlandırma. Partner gateway'de istemci sertifikası doğrulaması (ConfigMap `partner-ca`) | `manifests/channels.yaml`, secret'lar `gw-*-tls` | Çalışıyor |
| `HTTPRoute web`, `mobile`, `partner` | `/bff/*` ve `/partner/*` iç gateway'e (`internal-gw`), diğer yollar yok (default deny) | `manifests/channels.yaml`, `manifests/internal-backend.yaml` | Çalışıyor |
| `HTTPRoute *-public`, `*-login` | `/public/*` ve `/realms/*` route'ları (ext-authz yok) | `manifests/route-classes.yaml` | Stub backend'li (gerçek servis değil) |
| `Service/Endpoints internal-gw` + `BackendTLSPolicy` | İç gateway'e mTLS ile bağlantı, sunucu doğrulaması `gw-internal` adıyla | `manifests/internal-backend.yaml` | Çalışıyor |
| `Gateway spec.tls.backend.clientCertificateRef` | DMZ kimliğini (`dmz-gateway-client-tls`) iç gateway'e sunar | `scripts/load-internal-backend.sh` | Çalışıyor |
| `gw-*-nodeport` | Edge'den erişim için NodePort (30446, 30447, 30448) | `manifests/gateway-nodeports.yaml` | Çalışıyor |

### 2.3 Kimlik doğrulama (ext-authz, namespace `auth`)
| Kaynak | Ne yapar | İçerik | Durum |
|---|---|---|---|
| **ext-authz** (Python, stdlib) | Her isteği doğrular: dış token RS256 (Keycloak JWKS), iss, aud, channel, exp. Mobilde DPoP proof (RFC 9449). Ardından token exchange (mTLS) ile iç JWT | `extauth/ext_authz.py`, Deployment `ext-authz` (1 replika, replay cache tutarlılığı için) | Çalışıyor |
| `GatewayExtension extauth-*` + `TrafficPolicy extauth-*` | Gateway'den ext-authz'e çağrıyı bağlar. `headersToForward: authorization, dpop, host`, `headersToBackend: authorization` | `manifests/extauth.yaml` | Çalışıyor |
| `ReferenceGrant allow-gw-*-extauth` | Gateway namespace'lerinin `ext-authz` servisine erişimi | `manifests/extauth.yaml` | Çalışıyor |
| Secret `dmz-gateway-client-tls` | ext-authz'in iç gateway'e (JWKS, exchange) sunduğu DMZ kimliği | `scripts/load-extauth.sh` | Çalışıyor |
| Secret `dmz-exchange-client-tls` | Kanal başına exchange sertifikaları (`web`, `mobile`, `partner`) | `scripts/load-extauth.sh` | Çalışıyor |
| ConfigMap `internal-ca` | İç CA (sunucu doğrulaması) | `scripts/load-extauth.sh` | Çalışıyor |

### 2.4 Lab stub'ları (gerçek servis değil)
| Servis | Ne yapar | Durum |
|---|---|---|
| `web-stub`, `mobile-stub`, `partner-stub` | Yalnız login ve public route'ların hedefi (nginx, sabit yanıt). İç token içermez | Lab için; prod'da gerçek servis |

**DMZ test suite'leri:** `tests/smoke.sh` (TLS, route, default deny), `tests/route-classes.sh` (public/login/api sınıfları), `tests/extauth.sh` (dış token, DPoP, exchange, sızıntı), `tests/internal-path.sh` (DMZ → iç uçtan uca).

---

## 3. İç Cluster (kind-internal, `internal-cluster/`)

| Servis | Ne yapar | İçerik | Durum |
|---|---|---|---|
| **kgateway internal** (`Gateway gw-internal`) | Tek giriş noktası. DMZ kimliğini mTLS ile doğrular, iç JWT doğrular, kanal RBAC, default deny | `manifests/gateway.yaml` (TLS, `tls.frontend` ile `dmz-client-ca`), `manifests/listener-client-cert.yaml` (XFCC `SanitizeSet`), `manifests/internal-authz.yaml` | Çalışıyor |
| `GatewayExtension internal-jwt` | JWT provider: issuer `https://id.bank.lab.local/realms/bank`, audience `kgateway-internal`, JWKS (Keycloak), `forwardToken: true`, `claimsToHeaders` (channel, sub, auth_method) | `manifests/internal-authz.yaml` | Çalışıyor |
| `TrafficPolicy bff-authz`, `partner-authz` | Route bazlı JWT zorunluluğu ve RBAC (`x-channel`) | `manifests/internal-authz.yaml` | Çalışıyor |
| `HTTPRoute identity-realms` | `/realms/*`, `/.well-known/*` → identity Keycloak (Service + Endpoints, NodePort 30080) | `manifests/gateway.yaml` | Çalışıyor |
| `HTTPRoute bff-api`, `partner-api`, `public-api` | `/bff/*` → BFF, `/partner/*` → core, `/public/*` (GET) → core | `manifests/internal-authz.yaml` | Çalışıyor |
| **BFF** (`app-bff`) | Web/mobil için iç servis. İç JWT'yi kendisi doğrular (JWKS), kanal: web, mobile | `services/svc.py` (Python, stdlib), `manifests/services.yaml` | Çalışıyor |
| **Core servis** (`app-core`) | Partner ve public yollar. İç JWT doğrular, `PUBLIC_PATHS=1` ile `/public/*` token'sız | `services/svc.py`, `manifests/services.yaml` | Çalışıyor (gerçek iş mantığı yok) |
| `Service/Endpoints identity-keycloak` (app-bff, app-core) | BFF ve core'un JWKS'i Keycloak'tan alması | `manifests/services.yaml` | Çalışıyor |
| `ReferenceGrant` | gw-internal'dan app-bff / app-core servislerine route | `manifests/internal-authz.yaml` | Çalışıyor |

**Servis doğrulama kuralları (`svc.py`):** `iss` eşleşmeli, `aud` içinde `kgateway-internal`, `exp` geçerli, `channel` servisin izinli listesinde (BFF: web, mobile; core: partner). Kanal ve kullanıcı yalnızca token claim'lerinden okunur, gateway başlıklarından değil.

**İç test suite'leri:** `tests/authz.sh` (16 test: JWT, RBAC, mTLS, default deny, sızıntı), `tests/service-verify.sh` (9 test: gateway atlanınca servislerin kendi doğrulaması).

---

## 4. Identity Cluster (kind-identity, `identity-cluster/`)

| Servis | Ne yapar | İçerik | Durum |
|---|---|---|---|
| **Keycloak 26.6** (`dmz-lab/keycloak-dpop:26.6`) | Token üretimi, token exchange (standart V2 + SPI), login, realm `bank` | `manifests/keycloak.yaml`: `--spi-x509cert-lookup--provider=envoy` (XFCC ile istemci sertifikası), `KC_HOSTNAME=https://id.bank.lab.local` (sabit issuer), tek replika | Çalışıyor, realm kurulumu son adımda yeniden çalıştırıldı |
| **SPI `dmz-dpop-mobile-exchange`** | Mobil exchange: DPoP'a bağlı subject token'ı Keycloak anahtarıyla bağlamasız yeniden imzalar, sonra standart exchange | `keycloak-spi/` (Java, Maven), `order()=100` (önce çalışır), `supports()` yalnız `dmz-exchange-mobile` | Çalışıyor (mobil akış doğrulandı) |
| **PostgreSQL 16** | Keycloak veritabanı | `manifests/keycloak.yaml`, parola `keycloak-db` secret'ından (Vault kaynaklı), emptyDir | Çalışıyor. Lab: kalıcı değil |
| Keycloak NodePort 30080 | İç gateway'in Keycloak'a erişimi | `manifests/keycloak-nodeport.yaml` | Çalışıyor |
| **F8 host firewall** | Keycloak'a yalnız iç node IP'lerinden ve pod ağından erişim (kube-proxy SNAT dahil) | `scripts/host-firewall.sh` (iptables `F8-KEYCLOAK`, FORWARD, dport 8080) | Çalışıyor, `tests/firewall.sh` 3/3 |
| Realm `bank` ve client'lar | `web-app` (PKCE, DPoP), `mobile-app` (PKCE, DPoP), `partner-acme` (client credentials), `bff`, `core-svc`, `kgateway-internal` (hedef audience), `dmz-exchange-*` (client-x509), `lab-cli` (test) | `scripts/setup-realm.sh` | Yeniden kurulumda `setup-realm.sh` tamamlandı (token exchange yetkileri, secret'lar) |
| Test kullanıcısı `alice` | Test için | `setup-realm.sh` | Lab'a özgü |

**Cilium denemesi (kaldırıldı):** NetworkPolicy için Cilium kuruldu, ancak bu WSL2 çekirdeğinde `xt_socket` modülü eksik olduğu için iptables kuralları yüklenemedi ve pod'lar dış ağa erişemedi. Cilium kaldırıldı, F8 erişim kısıtı host iptables ile sağlandı.

---

## 5. Management / Secrets Cluster (kind-mgmt, `mgmt-cluster/`)

| Servis | Ne yapar | İçerik | Durum |
|---|---|---|---|
| **Vault 1.18** (ns `secrets`) | Secret kaynağı: Keycloak parolaları, KV v2 (`secret/`), politika `keycloak` | `manifests/vault.yaml` (file storage, emptyDir, TLS kapalı, `command` ile doğrudan `vault server`), `manifests/vault-nodeport.yaml` (NodePort 30200) | Çalışıyor. Init ve unseal yapıldı |
| `vault-bootstrap` secret | Unseal anahtarı ve root token (lab) | Oluşturma `identity-cluster/scripts/load-vault.sh` | Lab sapması, prod'da kaldırılır |
| **F9 host firewall** | Vault'a yalnız identity ve internal node IP'lerinden erişim | `scripts/host-firewall.sh` (iptables `F9-VAULT`) | Uygulandı |
| `load-vault.sh` | Init, unseal, KV, politika ve identity secret'larının türetilmesi | `identity-cluster/scripts/load-vault.sh` | Çalışıyor |
| Argo CD, Kyverno | Yönetim araçları (planlı) | — | Kurulmadı |

---

## 6. Ortak Kullanılan Araçlar ve Dosyalar

| Araç | Kullanım |
|---|---|
| kind | Lab cluster'ları (dmz, internal, identity, mgmt) |
| Helm | Gateway API ve kgateway kurulumu |
| kubectl | Tüm cluster işlemleri |
| openssl | Sertifika üretimi (`edge/scripts/gen-certs.sh`), DPoP ve JWT test yardımcıları |
| docker | Kind node'ları, HAProxy, test container'ları, host firewall için `docker exec` |
| Maven + Docker | SPI derlemesi (`identity-cluster/keycloak-spi/Dockerfile`) |
| Node.js | Sequence diagram üretimi (`docs/gen-sequence.js`, `docs/sequence-defs.js`) |
| draw.io | `docs/architecture.drawio` (katmanlar), `docs/sequences.drawio` (1 mimari genel bakış + 6 sequence diagram) |

---

## 7. Yapılanlar (özet kronoloji)

1. **Edge:** nginx'ten HAProxy'ye geçiş (SNI, TLS, L4/L7 DDoS, LB, sağlık). Coraza WAF yapılandırması hazır.
2. **DMZ cluster:** kgateway, kanal gateway'leri, route sınıfları (public, login, api), default deny.
3. **Ext-authz:** RS256 doğrulama, token exchange (önce stub STS, sonra gerçek Keycloak), mTLS, DPoP proof doğrulaması, replay ve iat kontrolü.
4. **Identity:** Keycloak 26.6, realm `bank`, token exchange V2, client-x509 ile exchange istemcileri, DPoP SPI.
5. **İç cluster:** kgateway internal, iç JWT doğrulaması, kanal RBAC, mTLS (DMZ kimliği), BFF ve core'da servis düzeyi doğrulama, `forwardToken`.
6. **DMZ ↔ iç:** `/bff/*` ve `/partner/*` iç gateway'e mTLS ile iletiliyor, uçtan uca test edildi.
7. **Güvenlik düzeltmeleri:** Dış token'ın iç audience'a sızması (Full Scope kapatıldı), iç token'ın istemciye sızması (stub echo kaldırıldı), default deny, public route'un servis düzeyinde de kısıtlanması.
8. **Cilium denemesi:** Başarısız (kernel), kaldırıldı. F8 host iptables ile çözüldü. kube-proxy SNAT sorunu düzeltildi.
9. **Vault:** Identity'den mgmt cluster'a taşındı. Init, unseal, KV ve identity secret türetimi.
10. **Dokümanlar:** `design.md` (4.5 identity, 4.6 mgmt, 6.2 F8/F9, 15 lab durumu ve prod farkları), `architecture.drawio`, `sequences.drawio`, bu doküman.

---

## 8. Test özeti (son bilinen sonuçlar)

| Suite | Kapsam | Son sonuç (2026-11-10, identity yeniden kurulumu ve realm kurulumu sonrası) |
|---|---|---|
| `dmz-cluster/tests/smoke.sh` | TLS, route, default deny | 4/4 |
| `dmz-cluster/tests/route-classes.sh` | public, login, api | 10/10 |
| `dmz-cluster/tests/extauth.sh` | Dış token, DPoP, exchange, sızıntı | 25/25 |
| `dmz-cluster/tests/internal-path.sh` | DMZ → iç uçtan uca | 8/8 |
| `internal-cluster/tests/authz.sh` | İç JWT, RBAC, mTLS | 16/16 |
| `internal-cluster/tests/service-verify.sh` | Servis düzeyi doğrulama | 9/9 |
| `identity-cluster/tests/firewall.sh` | F8 erişim kısıtı | 3/3 |
| `dmz-cluster/tests/firewall.sh` | F1: NodePort'lara yalnız edge HAProxy erişimi | 4/4 |
| Edge (`edge/tests/*`) | WAF, DDoS, LB | Çalıştırılmadı (WAF imajı bekliyor, edge testleri DMZ'li topolojiye göre güncellenmeli) |

**Not:** Yukarıdaki sonuçlar tek bir çalıştırmadan alınmıştır. `firewall.sh` ilk çalıştırmada 2/3 verdi: iç cluster'dan Keycloak NodePort kontrolü, `kubectl run -i` attach'inin çıktıyı kaybetmesi nedeniyle boş döndü. Güvenlik kuralı değil, test yöntemi hatasıydı. Test log tabanlı yapıldı ve 3/3 geçti. Doğrudan kontrol: iç pod'dan `http://172.18.0.5:30080` → HTTP 200.

---

## 9. Açık konular

- Edge ↔ DMZ firewall (F1): uygulanmadı.
- WAF imajı: kullanıcı tarafında derlenmeli.
- Argo CD ve Kyverno: mgmt cluster'da kurulmadı.
- Vault PKI: exchange, DMZ ve partner sertifikaları henüz Vault'tan değil.
- Realm imzalama anahtarları (D-12): HSM/KMS veya Vault Transit kararı bekleniyor.
- Mobil ES256 DPoP proof desteği ve paylaşılan replay store (prod).
- Lab test client'larının (`lab-cli`, `mobile-app` directAccessGrants) kaldırılması (prod).
