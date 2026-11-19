# DMZ Lab

Bankacılık DMZ laboratuvarı. Edge, iki DMZ cluster'ı, bank-prod cluster'ı ve host üzerinde çalışan bir platform yığınından oluşur. Amaç, kurumsal bir ortamın akışını (ayrı cluster'lar, nginx ingress, Vault, Jenkins ile dağıtım) tek makinede simüle etmek.

Ayrıntılı dokümantasyon: [docs/README.md](docs/README.md)

## Dizin
| Klasör | İçerik |
|---|---|
| `apps/<ad>/` | Uygulama: katalog (`app.env`), hook (`hook.sh`), manifest'ler |
| `services/<ad>/` | Uygulama kaynağı ve Dockerfile |
| `images/` | Taban imajlar (python, java) ve sürüm sabitleri |
| `infra/` | Cluster tanımları ve Vault |
| `platform/` | Host üzerindeki docker compose yığını |
| `edge/` | HAProxy ve sertifika betikleri |
| `observability/` | Log ve metrik ajanları |
| `scripts/` | Kurulum, dağıtım, temizlik ve ortak fonksiyonlar |
| `tools/`, `console/`, `shared/` | Operatör araçları, konsol, ortak Python modülleri |
| `docs/` | Dokümantasyon |

## Hızlı başlangıç
Önkoşullar: Docker, kind, kubectl, helm, openssl, python3.

```bash
bash scripts/install-all.sh          # sıfırdan kurulum
bash scripts/deploy-app.sh janus     # tek uygulamayı yeniden dağıt
bash scripts/purge.sh                # temizlik (argümansız: etkileşimli menü)
```

## Güvenlik
Repoda sır yoktur. Sırlar Vault'ta ve Kubernetes secret'larında tutulur; `platform/.env` ilk kurulumda üretilir ve `.gitignore`'dadır. Ayrıntı: [docs/mimari.md](docs/mimari.md).
