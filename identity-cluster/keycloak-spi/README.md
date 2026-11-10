# DMZ mobil DPoP token exchange SPI (Keycloak 26.6.4)

Tasarım referansı: `design.md` 5.0b ve D-11.

## Sorun

Keycloak standart token exchange, DPoP'a bağlı (`cnf`) subject token'ı reddediyor:
`Sender-constrained tokens (RFC 7800) cannot be used as subject_token in Token Exchange`.
Keycloak'un DPoP dokümanındaki çözüm (aynı client + cihaz anahtarıyla yeni proof) tasarımımızla uyuşmuyor, çünkü
exchange DMZ tarafından yapılır ve DMZ cihaz anahtarına sahip değildir.

## Çözüm

`DpopMobileTokenExchangeProvider`, `dmz-exchange-mobile` client'ından gelen mobil exchange isteklerinde:

1. Subject token'ı Keycloak'un realm anahtarıyla doğrular.
2. `azp = mobile-app` ve `channel = mobile` kontrolü yapar.
3. `cnf` (DPoP bağlaması) alanını kaldırıp token'ı Keycloak anahtarıyla yeniden imzalar.
4. İşi standart `StandardTokenExchangeProvider`'a devreder.

Güven sınırı: DMZ ext-authz DPoP proof'unu doğrular (`htm`, `htu`, `iat`, `jti`, `ath`, `cnf.jkt`) ve isteği
mTLS ile kimliği doğrulanmış `dmz-exchange-mobile` sertifikasıyla gönderir. SPI bu iki kontrole güvenir.

Diğer exchange'ler (web, partner) etkilenmez. `supports()` yalnızca `dmz-exchange-mobile` için `true` döner.

## Keycloak'un sağlayıcı seçimi

Keycloak `TokenExchangeProviderFactory` örneklerini `order()` değerine göre (büyük olan önce) dener ve
`supports()` `true` dönen ilkini kullanır. Standart provider `order() = 0` olduğu için bizimki `100` ile önce denenir.
`order() = -100` ile SPI'ye ulaşılmadığı doğrulandı.

## Derleme ve dağıtım

```bash
# 1) İmajı derle (Maven Central'dan keycloak-* 26.6.4 provided bağımlılıklar çekilir)
docker build -t dmz-lab/keycloak-dpop:26.6 identity-cluster/keycloak-spi

# 2) Lab: imajı kind cluster'a yükle
kind load docker-image dmz-lab/keycloak-dpop:26.6 --name identity

# 3) Deployment identity-cluster/manifests/keycloak.yaml içinde bu imajı kullanır
kubectl --context kind-identity -n auth rollout restart deploy/keycloak
```

## Doğrulama

- `dmz-cluster/tests/extauth.sh`: mobil DPoP akışı `200`, iç servise `channel=mobile` ve `auth_method=dpop_device`.
- `internal-cluster/tests/authz.sh`: mobil iç token `/bff` üzerinden kabul edilir.

## Sınırlar ve bakım

- Keycloak yükseltmelerinde SPI yeniden test edilmelidir. Standart exchange'in iç API'leri (`TokenExchangeProvider`,
  `AbstractTokenExchangeProvider`) sürümler arasında değişebilir. Keycloak bu SPI'yi "internal" olarak uyarır
  (`KC-SERVICES0047`).
- `kc.sh build` imaj derleme sırasında çalışır. Çalışma zamanı yapılandırması (`--spi-x509cert-lookup--*`) ayrıdır.
- Mobil token exchange'in güven modeli, DMZ'nin DPoP doğrulamasına dayanır. DMZ'deki DPoP doğrulaması RS256 ile
  sınırlıdır (lab). Üretimde ES256 desteği için kriptografi kütüphanesi gerekir.
- Lab'da bu SPI ile birlikte Keycloak, iç gateway'den gelen XFCC başlığına güvenir (bkz. `design.md` 4.4, lab notu).
