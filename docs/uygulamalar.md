# Uygulamalar

Her uygulama `apps/<ad>/` altında bir klasördür. Kurulum (`scripts/deploy-app.sh`), Jenkins pipeline'ı ve gözlemlenebilirlik kurulumu aynı katalogu kullanır.

## Klasör
```
apps/<ad>/
  app.env        katalog (zorunlu)
  hook.sh        sır, sertifika, placeholder hazırlığı (varsa)
  manifests/     Kubernetes manifest'leri; ingress.yaml de burada
services/<ad>/   kaynak kod, Dockerfile, testler (imajın bağlamı)
```

## Katalog anahtarları (`app.env`)
| Anahtar | Zorunlu | Anlamı |
|---|---|---|
| `CLUSTER` | evet | Hedef cluster (`kind-<CLUSTER>` context'i) |
| `NAMESPACE` | evet | Hedef namespace; yoksa oluşturulur (etiketlerle) |
| `MANIFEST` | evet | Boşlukla ayrılmış manifest yolları; **`apps/<ad>/` altına göredir** (örn. `manifests/janus.yaml manifests/ingress.yaml`) |
| `ROLLOUT` | evet | Yeniden başlatılıp beklenecek deployment adları |
| `IMAGE`, `BUILD_CONTEXT` | hayır | İmaj adı ve build bağlamı; **repo köküne göre** (örn. `services/janus`) |
| `CODE_CM`, `CODE_FILES` | hayır | Kod ConfigMap'i ve kaynakları (`hedef=kaynak`, repo köküne göre) |
| `PRE_HOOK` | hayır | Hook dosyası; **`apps/<ad>/` altına göre** (genelde `hook.sh`) |
| `METRICS` | hayır | Prometheus scrape hedefleri: `job\|scheme\|host:port\|path` (boşlukla ayrılmış) |

## Hook sözleşmesi (`hook.sh`)
- **Girdi:** `ROOT`, `CLUSTER`, `NAMESPACE`. Hook, deploy script'i tarafından `source` edilir.
- **Çıktı:** `SUBST_EXPRS` dizisi (sed ifadeleri; `subst_ip`, `subst_expr` ile üretilir). İsteğe bağlı `BUILD_CONTEXT` (ör. `stage_build_context` ile `.build/<ad>` hazırlanır).
- **Yasak:** ham `kubectl`, `openssl`, `docker` çağrısı yerine `scripts/lib/cluster.sh` helper'ları kullanılır.

Kullanılabilir helper'lar:
| Helper | Ne yapar |
|---|---|
| `secret_once`, `apply_secret` | Secret'ı yoksa üretir / idempotent uygular |
| `secret_value`, `secret_exists` | Secret okuma ve varlık kontrolü (cross-cluster okumalar dahil) |
| `mtls_secret`, `ensure_mtls_certs` | mTLS secret'ı (server.* / client.* anahtarları) |
| `subst_ip`, `subst_expr` | Placeholder doldurma |
| `stage_build_context` | Build klasörü hazırlama |
| `ensure_seal_certs`, `load_seal_keys` | Seal sertifikaları ve paylaşılan anahtarlar |
| `vault_get`, `vault_kv_set`, `vault_exec`, `vault_bootstrapped` | Vault erişimi |
| `env_get` | `platform/.env` okuma |

## Deploy akışı (`scripts/deploy-app.sh <ad>`)
1. Namespace oluşturulur (etiketlerle).
2. `PRE_HOOK` çalışır.
3. İmaj: `REGISTRY_MODE=kind` (lab, `kind load`) ya da `registry` (build + push).
4. Kod ConfigMap'i uygulanır.
5. Manifest'ler uygulanır (`__OTLP_URL__` her zaman doldurulur).
6. `ROLLOUT` deployment'ları yeniden başlatılır ve beklenir.

## Bağımlılık sırası
`auth-server` → `janus` → `fortuna` → `channel-gateway` → `seal-intranet` → `seal-mobile`

- channel-gateway, `janus-keys` secret'ına (janus) bağlıdır.
- fortuna, `auth-secrets` içindeki `ALICE_PASSWORD`'a ve `platform/.env` içindeki `LEGACYDB_PASSWORD`'a bağlıdır.
- seal-mobile, auth-server'ın sırlarına ve Seal anahtarlarına bağlıdır.

## Mevcut uygulamalar
| Ad | Cluster / ns | İmaj | Not |
|---|---|---|---|
| auth-server | bank-prod / auth | evet | Spring Boot, Postgres aynı manifest'te, ingress: id.bank.lab.local |
| fortuna | bank-prod / channel | hayır (ConfigMap) | CGW, API, ACL, SMS mock; NodePort 30880/30881 |
| janus | bank-dmz-prod / janus | hayır (ConfigMap) | web ve mobil; ingress: web.lab.local, mobile-api.lab.local |
| channel-gateway | bank-prod / channel | hayır (ConfigMap) | janus-keys'e bağlı |
| seal-intranet | codevo-dmz / seal-intranet | evet | ingress: seal-intranet.lab.local (passthrough) |
| seal-mobile | codevo-dmz / seal-mobile | evet | ingress: seal.lab.local (passthrough) |

## Yeni uygulama eklemek
1. `apps/<ad>/app.env` yaz (yukarıdaki anahtarlar).
2. Gerekiyorsa `apps/<ad>/hook.sh` yaz.
3. `apps/<ad>/manifests/` altına manifest'leri koy.
4. `services/<ad>/` altına kaynağı ve Dockerfile'ı koy (imaj gerekiyorsa).
5. `Jenkinsfile` içindeki seçenek listesine ve gerekiyorsa `all` sırasına ekle.
6. `bash scripts/deploy-app.sh <ad>` ile dene.
