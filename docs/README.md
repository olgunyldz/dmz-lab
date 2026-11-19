# DMZ Lab

Bankacılık DMZ laboratuvarı: edge, iki DMZ cluster'ı, bir bank-prod cluster'ı ve host üzerinde çalışan bir platform yığını.
Amaç, kurumsal bir ortamın (Jenkins ile dağıtım, ayrı cluster'lar, ayrı kimlik sağlayıcı) akışını tek makinede simüle etmek.

## Dokümanlar
| Dosya | İçerik |
|---|---|
| [mimari.md](mimari.md) | Bölgeler, trafik akışları, güven ve TLS modeli, sır yönetimi |
| [altyapi.md](altyapi.md) | Cluster'lar, ingress, Vault, platform compose, edge, portlar |
| [uygulamalar.md](uygulamalar.md) | Uygulama kataloğu, hook ve deploy sözleşmesi, bağımlılık sırası |
| [operasyon.md](operasyon.md) | Kurulum, tek uygulama dağıtımı, Jenkins, purge, araçlar |
| [gozlemlenebilirlik.md](gozlemlenebilirlik.md) | Log, metrik ve iz akışı |
| [seal-vendor-sorular.md](seal-vendor-sorular.md) | Seal ürünü tedarikçisine sorulacak sorular |
| `dmz-lab.drawio` | Diyagramlar (14 sayfa: demo, lab cluster/namespace/pod yapısı, ingress kuralları, web ve mobil uçtan uca, sırlar ve veri, as-is batıdan doğuya, as-is DR, topoloji, ağ/portlar, dağıtım, üç sıra diyagramı). Kaynak: `node docs/drawio/gen-all.js` |

## Dizin yapısı
```
apps/<ad>/            uygulama: app.env (katalog), hook.sh (sır/sertifika), manifests/ (K8s)
services/<ad>/        uygulama kaynağı, Dockerfile (taban imajdan), testler
images/               taban imajlar (python, java), sürüm sabitleri, build-base.sh
infra/clusters/<c>/   cluster tanımı (kind-config.yaml)
infra/vault/          Vault manifest'i ve ilk başlatma betiği
platform/             host üzerindeki docker compose yığını (LegacyDB, monolit, Prometheus, Loki, Jaeger, Grafana, köprüler)
edge/                 HAProxy (compose) ve iç/dış sertifika betikleri
observability/        Alloy ve Prometheus agent manifest'leri, install.sh
scripts/              install-all.sh, deploy-app.sh, purge.sh, lib/cluster.sh, sır ve sertifika betikleri
tools/                operatör yardımcıları (port-forward, erişim bilgileri)
console/              operatör konsolu (python, 127.0.0.1:9000)
shared/               ortak Python modülleri (tracing, metrics)
Jenkinsfile           uygulama dağıtım pipeline'ı
```

## Hızlı başlangıç
```bash
bash scripts/install-all.sh              # sıfırdan kurulum (cluster'lar dahil)
bash scripts/deploy-app.sh janus         # tek uygulamayı yeniden dağıt
bash scripts/purge.sh                    # temizlik (argümansız: etkileşimli menü)
```
Ayrıntılar için [operasyon.md](operasyon.md).
