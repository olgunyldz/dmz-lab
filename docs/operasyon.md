# Operasyon

## Sıfırdan kurulum
```bash
bash scripts/install-all.sh
```
Sıra: cluster'lar → edge CA → nginx ingress controller'ları → Vault → auth-server → platform (compose) → Fortuna → Janus → channel-gateway → Seal Intranet → Seal Mobile → HAProxy → gözlemlenebilirlik.

Betik tekrar çalıştırılabilir (idempotent). Hata durumunda hangi adımda kaldığı günlükte görünür; düzeltilip yeniden çalıştırılabilir.

Önkoşullar: Docker, kind, kubectl, helm, openssl, python3, maven (auth-server derlemesi Docker içinde yapılır).

## Tek uygulama dağıtımı
```bash
bash scripts/deploy-app.sh janus
REGISTRY_MODE=registry bash scripts/deploy-app.sh seal-mobile   # şirket: build + push
```

## Jenkins
`Jenkinsfile` iki parametre alır:
- `APP`: `all` veya tek bir uygulama. `all`, bağımlılık sırasıyla çalışır.
- `REGISTRY_MODE`: `kind` (lab) veya `registry` (build + push).

Pipeline her zaman `scripts/deploy-app.sh` çağırır; uygulama mantığı pipeline'da değildir. **Durum:** `registry` yolu henüz test edilmedi; registry adresi, kimlik bilgileri ve agent kubeconfig'leri belirlenmelidir.

## Temizlik (`scripts/purge.sh`)
Argümansız çalıştırılırsa etkileşimli menü açılır. İlk soru "Hepsi silinsin mi?"dir: evet denirse dosyalar, imajlar ve Docker temizliği tek seferde seçilir; hayır denirse her biri ayrı sorulur. Son onay her durumda `evet` yazmaktır. Bayraklar:

| Bayrak | Silinen |
|---|---|
| `--dry-run` | Hiçbir şey; yalnızca listeler |
| `--yes` | Bayraklarla gerçek silmeyi onaylar (zorunlu) |
| `--files` | `platform/.env`, `edge/certs`, `haproxy.cfg`, `.tools-forward`, `.build` |
| `--images` | `dmz-lab/*` imajları |
| `--base-images` | Üçüncü taraf imajlar (kindest/node, grafana, prometheus, loki, jaeger, haproxy, python, ...) |
| `--docker-all` | Kullanılmayan container, volume, network ve build cache (imajlar korunur) |

Her zaman silinenler: süreçler (console, kubectl port-forward), kind cluster'ları, platform ve edge compose yığınları, lab container/volume/network'leri.

Bilinen sınır: betik `spring-idp-m2` gibi Maven önbellek volume'larını ve etiketsiz `kindest/node` kalıntılarını kapsamaz; bunlar elle kaldırılır.

## Araçlar
```bash
bash tools/tools-forward.sh start     # Vault, auth-server port-forward'ları (arka plan)
bash tools/tools-forward.sh status
bash tools/tool-credentials.sh        # adresler ve parolalar (ekran kaydı almayın)
python3 console/app.py                # operatör konsolu, http://127.0.0.1:9000
```

## Doğrulama
- Auth-server duman testi: `services/auth-server/tests/smoke.sh` (`AUTH_URL`, `AUTH_CA` ortam değişkenleri).
- Seal Intranet testleri: `services/seal-intranet/tests/`.
- Katalog tutarlılığı: `MANIFEST`, `PRE_HOOK`, `CODE_FILES`, `BUILD_CONTEXT` yollarının varlığı (bkz. uygulamalar.md).

## Sık görülen sorunlar
| Belirti | Neden | Çözüm |
|---|---|---|
| `platform/.env yok` | Platform henüz kurulmamış | `bash platform/scripts/up.sh` |
| `iç CA yok` | Edge sertifikaları eksik | `bash edge/scripts/gen-certs.sh && bash edge/scripts/gen-internal-certs.sh` |
| `janus-keys` yok (channel-gateway) | Janus önce kurulmamış | `deploy-app.sh janus` |
| Seal sertifikasında yeni ad yok | SAN güncellendi, eski sertifika kullanılıyor | Sertifikaları sil, `gen-seal-certs.sh` çalıştır, ilgili uygulamayı yeniden dağıt |
| Namespace bulunamadı (Ingress) | Ingress, namespace'den önce uygulandı | Bu yapıda ingress uygulamayla birlikte gelir; `deploy-app.sh` namespace'i önce oluşturur |
| Windows'ta port 8200 yok | Ayrılmış port aralığı 8185-8284 | Vault 18200'de yayınlanır |

## Açık konular
- Yeniden kurulum sonrası uçtan uca doğrulama (ingress yolları, Fortuna'nın başarılı yolu, beş/altı uygulamanın gerçek cluster'da çalışması).
- Jenkins registry ve kimlik bilgileri kararı.
- Seal Intranet ve Seal Mobile'ın metrik NodePort'ları (30644, 30457) artık kullanılmıyor; agent'lar küme içi servis adlarını kazıyor. Kaldırılabilir.
- kgateway ertelendi; Gateway API kurulmadı.
- Token yenileme, mevcut cihazla mobil giriş ve transfer izlerinin Jaeger'da doğrulanması test edilmedi.
- Java auth-server, `AUTH_*` yeniden adlandırmasından sonra çalışma zamanında test edilmedi (yalnızca `mvn package`).
