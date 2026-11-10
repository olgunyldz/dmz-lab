# DMZ Cluster — Lab

Tasarımdaki (design.md, bölüm 4.2) DMZ cluster'ının lab gerçeklemesi. kind ile tek makinede çalışır.

## İçerik

| Bileşen | Sürüm | Namespace | Görev |
|---|---|---|---|
| kind cluster | node: k8s v1.37 | — | 1 control-plane + 2 worker |
| Gateway API CRD | v1.7.0 | — | Gateway ve HTTPRoute tanımları |
| kgateway | v2.5.0 | kgateway-system | Gateway API uygulayıcısı (Envoy tabanlı) |
| gw-web | Gateway `gw-web` | gw-web | Web kanalı, TLS sonlandırma |
| gw-mobile | Gateway `gw-mobile` | gw-mobile | Mobil kanalı, TLS sonlandırma |
| gw-partner | Gateway `gw-partner` | gw-partner | Partner kanalı, **istemci sertifikası (mTLS) gateway'de doğrulanır** |

Her Gateway kendi Envoy deployment'ını ve Service'ini alır. Kanal izolasyonu bu şekilde sağlanır.

## Kurulum

```bash
# Önce edge/certs hazır olmalı: bash edge/scripts/gen-certs.sh
bash dmz-cluster/scripts/up.sh
bash dmz-cluster/tests/smoke.sh
```

`up.sh` idempotent. Tekrar çalıştırılabilir.

## Geçici durumlar (lab)

- **Backend'ler nginx stub'ları** (`web-stub`, `mobile-stub`, `partner-stub`). Tasarım gereği DMZ gateway'leri iç kgateway'e (F2) yönlenecek. İç cluster kurulunca `backendRefs` değiştirilecek.
- **Sertifikalar** `edge/certs/` içindeki lab CA'sından geliyor. Üretimde cert-manager + Vault kullanılır.
- **LoadBalancer IP yok:** kind'da `<pending>` görünür. Testler `port-forward` kullanır. Edge'den erişim için MetalLB veya kind'ın Docker ağı üzerinden bir VIP gerekir (sonraki adım).
- **Partner mTLS:** İstemci CA'sı ConfigMap `partner-ca` içinde. Gateway, istemci sertifikası olmayan bağlantıyı TLS seviyesinde reddediyor.

## Gözlem notları

- HTTP/1.0 istekleri kgateway/Envoy tarafından `426 Upgrade Required` ile reddediliyor. Partner istemcilerinin HTTP/1.1 veya HTTP/2 kullanması gerekir.
- Gateway yanıtlarında `server: envoy` başlığı var. Edge bunu zaten siliyor. Gateway seviyesinde gizlenmesi için bir politika sonra eklenebilir.

## Temizlik

```bash
kind delete cluster --name dmz
```

## Kimlik doğrulama katmanı (ext-authz)

Her kanal gateway'i, isteği `auth` namespace'indeki `ext-authz` servisine yönlendirir (kgateway `GatewayExtension` + `TrafficPolicy`). Servis:

1. `X-Dmz-Channel` başlığına göre kanal profilini seçer (`web`, `mobile`, `partner`).
2. Dış token'ı doğrular: imza, `iss`, `aud`, `channel`, `exp`.
3. `sts-internal` namespace'indeki iç STS'ten (RFC 8693 benzeri) iç JWT ister. İstemci kimliği kanala göre `dmz-exchange-<channel>`.
4. Dönen iç JWT'yi `Authorization` başlığıyla upstream'e ekler. Dış token iç ağa gitmez.

Kurulum: `bash dmz-cluster/scripts/load-extauth.sh`
Test: `bash dmz-cluster/tests/extauth.sh` (16 test: token yok, yanlış kanal, yanlış imza, süresi dolmuş, geçerli akışlar, iç JWT içeriği)

### Lab sınırları (üretimde değişecek)

- **İmza doğrulaması HS256 ile yapılıyor** (lab anahtarı `ext-issuer-key`). Üretimde Keycloak JWKS'inden RS256/ES256 doğrulaması ve `kid` desteği olacak.
- **Dış token'lar** test betiğinde üretiliyor (Keycloak yok). Gerçek akışta Keycloak `customer`/`partner` realm'lerinden çıkar.
- **İç STS bir stub** (`sts-internal/sts`). Gerçekte iç Keycloak'un token-exchange endpoint'i olacak.
- **DPoP ve cihaz attestation doğrulanmıyor.** Mobil ve web için DPoP proof kontrolü sonraki adım.
- **Partner `cnf` bağlaması** ext-authz'de kontrol edilmiyor, gateway'in mTLS doğrulaması ile sağlanıyor.
- **Backend stub'ları `Authorization` başlığını yanıtta geri yazıyor** (`auth=...`). Bu yalnızca test içindir, üretimde hiçbir yanıtta token dönmez.
- **ConfigMap `subPath` ile bağlı** stub'larda yapılandırma değişince `rollout restart` gerekir.
