# Mimari

## Bölgeler
| Bölge | Yer | Ne çalışır |
|---|---|---|
| Edge | `edge/` (docker compose, host) | HAProxy: TLS sonlandırma (web, mobil API) ve SNI passthrough (Seal Mobile) |
| DMZ | `bank-dmz-prod` cluster'ı | Janus web ve mobil (kanal girişleri, ingress arkasında) |
| DMZ | `codevo-dmz` cluster'ı | Seal Mobile (cihaz tarafı), Seal Intranet (iç API) |
| Bank | `bank-prod` cluster'ı | auth-server (kimlik sağlayıcı, Spring Authorization Server), Fortuna zinciri, channel-gateway, Vault |
| Platform | `platform/` (docker compose, host) | LegacyDB (lab: PostgreSQL; as-is: MSSQL), Fortuna monolit, Prometheus, Loki, Jaeger, Grafana, köprüler |

Kimlik sağlayıcı (auth-server) ayrı bir kimlik cluster'ında değildir; bank-prod'da `auth` namespace'indedir.

## Kanallar (as-is)
| Kanal | Durum | Giriş |
|---|---|---|
| Mobil | aktif | Janus mobil (mobile-api.lab.local), Seal Mobile |
| Web | planlı | Janus web (web.lab.local) |
| Şube | planlı | — |
| Çağrı merkezi | planlı | — |
| POS | planlı | — |
| ATM | planlı | — |
| Partner | planlı | B2B entegrasyon |

Aktif akışlar web ve mobildir; diğer kanallar planlıdır ve demoda yoktur. Konsolda diğer kanallar "Yakında" olarak gösterilir.

## Fortuna monolit
As-is mimaride Fortuna monolit **Windows IIS** üzerinde, on-prem bir Windows Server'da çalışır (hesap, hareket, havale, PIN doğrulayıcı, mobil cihaz kaydı). Kubernetes içindeki Fortuna zinciri (CGW, API, ACL, SMS) bu monolitle ve LegacyDB ile konuşur.
Lab'da monolit bir Python mock'udur ve platform compose içinde çalışır (`services/legacy-monolith`); uç noktaları ve sözleşmesi as-is ile aynıdır.

## Veritabanı (as-is)
LegacyDB as-is mimaride **MSSQL**'dir (on-prem). Lab'da aynı şemanın karşılığı PostgreSQL 16'dır (platform compose); sorgu ve şema farkları lab'a özgüdür.

## Kurumsal servisler (as-is)
| Bileşen | As-is rolü | Durum |
|---|---|---|
| Kafka | olay akışı | varsayım, doğrulanacak |
| RabbitMQ | asenkron kuyruk | varsayım, doğrulanacak |
| Redis | önbellek / oturum | varsayım, doğrulanacak |
| Dynatrace | APM, uçtan uca iz | kurumsal |
| Prometheus, Grafana | metrik ve panolar | kurumsal ve lab'da var |
| ELK (Elasticsearch, Logstash, Kibana) | log | kurumsal |

Lab karşılıkları: Dynatrace → Jaeger, ELK → Loki. Kafka, RabbitMQ ve Redis lab'da yoktur.

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

## As-is mimari: aktif-aktif ve DR (kurumsal mimari; bu demoda gösterilmez)
- **Siteler:** Site A ve Site B aktif çalışır; Site C bölgesel felaket kurtarma (DR) sitesidir (ılık yedek: veri replikası, Vault DR, manifest ve imaj hazır).
- **Yük dengeleme:** GSLB/DNS, sağlık kontrolüyle A ve B arasında dağıtır; her sitede edge HAProxy HA çifti (VIP).
- **Durumsuz katman:** auth-server, Fortuna zinciri, channel-gateway, Janus ve Seal çoklu örnekle çalışır.
- **Veri:** LegacyDB'nin bugünkü tek yazıcılı modeli korunur; B'deki yazmalar A'ya yönlenir, A → B senkron replika, A → C asenkron replika.
- **Sırlar:** Vault raft kümesi A ve B'de üye, DR'de replika.

### Demoda gösterilmeyen konular (as-is'te tanımlı)
1. LegacyDB yazma modeli: bölüm (müşteri) bazlı sahiplik veya çok yazıcılı çözüm.
2. Seal Intranet cihaz kaydı bellek içinde; çoklu örnek için kalıcı depo.
3. Oturum ve tek aktif giriş durumu auth-server veritabanında (durumsuz örnekler).
4. Jaeger bellek içi depolama; merkezi arka uç.
5. RTO/RPO hedefleri ve DNS TTL'si.

Diyagramlar: `docs/dmz-lab.drawio` (Demo, As-is mimari, Topoloji sayfaları). Demo yalnızca tek site ve tek örneği çalıştırır.
