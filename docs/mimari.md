# Mimari

## Bölgeler
| Bölge | Yer | Ne çalışır |
|---|---|---|
| Edge | `edge/` (docker compose, host) | HAProxy: TLS sonlandırma (web, mobil API) ve SNI passthrough (Seal Mobile) |
| DMZ | `bank-dmz-prod` cluster'ı | Janus web ve mobil (kanal girişleri, ingress arkasında) |
| DMZ | `codevo-dmz` cluster'ı | Seal Mobile (cihaz tarafı), Seal Intranet (iç API) |
| Bank | `bank-prod` cluster'ı | auth-server (kimlik sağlayıcı, Spring Authorization Server), Fortuna zinciri, channel-gateway, Vault |
| Platform | `platform/` (docker compose, host) | LegacyDB, Fortuna monolit (eski çekirdek), Prometheus, Loki, Jaeger, Grafana, köprüler |

Kimlik sağlayıcı (auth-server) ayrı bir kimlik cluster'ında değildir; bank-prod'da `auth` namespace'indedir.

## Trafik akışları (özet)
- **Web / mobil girişi:** tarayıcı veya mobil uygulama → edge (HAProxy, TLS sonlandırma) → bank-dmz-prod nginx ingress (host tabanlı) → Janus → channel-gateway → Fortuna zinciri (CGW → API → ACL) → LegacyDB. Kimlik doğrulama ve token'lar auth-server'dan alınır.
- **Mobil cihaz:** cihaz → edge (`seal.lab.local`, SNI passthrough) → codevo-dmz ingress → Seal Mobile. Seal, parolayı görmez; yalnızca cihaz ve PIN doğrular. Oturum durumu auth-server'da tutulur (tek aktif giriş).
- **Seal Intranet:** auth-server ve platform monolit, `seal-intranet.lab.local` üzerinden (codevo ingress, SNI passthrough) çağırır.
- **Seal Mobile → monolit (PIN uçları):** küme dışı, platform köprüsü üzerinden.
- **İzleme:** servisler OTLP ile Jaeger'a (platform) iz gönderir.

## Güven ve TLS
- **Lab CA:** `edge/scripts/gen-certs.sh` kök CA'yı, `gen-internal-certs.sh` iç CA'yı üretir. Servis sertifikaları iç CA ile imzalanır (`gen-seal-certs.sh`, `scripts/gen-mtls-certs.sh`).
- **SNI passthrough:** auth-server (`id.bank.lab.local`), Seal Mobile (`seal.lab.local`) ve Seal Intranet (`seal-intranet.lab.local`) TLS'i uçtan uca kendileri sonlandırır; ingress yalnızca SNI'a göre yönlendirir.
- **mTLS:** kanal servisleri arasındaki çağrılarda istemci sertifikaları (`mtls_secret` helper'ı ile secret'a yazılır). CN allowlist'leri servislerde uygulanır.
- **Sertifika SAN'ı:** bir servisin adı değişirse sertifikası yeniden üretilmelidir; `ensure_seal_certs` yalnızca eksik dosyayı üretir.

## Kimlik ve sırlar
- Kullanıcı adı ve parola yalnızca auth-server'da doğrulanır. Seal yalnızca cihaz ve PIN'i tutar.
- Sırlar Vault'ta (`secret/auth/auth-server`, `secret/seal/v3`) tutulur. Kubernetes secret'ları bu sırlardan veya hook'lardan üretilir; **repoda sır yoktur**.
- `platform/.env` ilk kurulumda `platform/scripts/up.sh` tarafından üretilir ve `.gitignore`'dadır.
- Lab sapması: Vault'un kök token'ı ve unseal anahtarı `vault-bootstrap` secret'ındadır. Üretimde bu olmamalıdır.

## Servis adları
Servis adları küme içi DNS'te ve sertifikalarda kullanılır. Kimlik sağlayıcı `auth-server` adıyla geçer; Java paketi `dev.dmzlab.auth`'tır; yapılandırma öneki `auth.*`, ortam değişkenleri `AUTH_*`'tır.
