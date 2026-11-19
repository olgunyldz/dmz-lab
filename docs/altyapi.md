# Altyapı

## Cluster'lar
Tanımlar `infra/clusters/<ad>/kind-config.yaml` içindedir. Üç kind cluster'ı:

| Cluster | Rol | Host'a açık port |
|---|---|---|
| `bank-prod` | auth-server, Fortuna zinciri, channel-gateway, Vault | yok (köprülerle erişilir) |
| `bank-dmz-prod` | Janus web ve mobil | 127.0.0.1:30802 (ingress HTTP) |
| `codevo-dmz` | Seal Mobile, Seal Intranet | 127.0.0.1:30456 (ingress HTTPS, SNI passthrough) |

## nginx ingress
`scripts/lib/cluster.sh` içindeki `install_ingress` her cluster'a controller'ı helm ile kurar. NodePort'lar:

| Cluster | HTTP | HTTPS | SSL passthrough |
|---|---|---|---|
| bank-dmz-prod | 30802 | 30443 | hayır (Janus düz HTTP ve host tabanlı) |
| codevo-dmz | 30080 | 30456 | evet |
| bank-prod | 30081 | 30543 | evet (auth-server) |

Ingress manifest'leri uygulamalarla birlikte gelir (`apps/<ad>/manifests/ingress.yaml`).

## Vault
`infra/vault/` altında. Vault `bank-prod` cluster'ında `secrets` namespace'indedir. `load-vault.sh` ilk başlatmayı ve açmayı (unseal) yapar. Port-forward: `tools/tools-forward.sh` ile `127.0.0.1:18200`.

## Platform (docker compose)
`platform/docker-compose.yml`, ağ `lab-platform`. Kind tarafına `kind` ağı üzerinden köprülerle açılır.

| Servis | Host portu | Kind tarafındaki köprü | Not |
|---|---|---|---|
| legacydb (PostgreSQL 16) | 127.0.0.1:30432 | platform-legacydb → 30432 | Fortuna verileri |
| fortuna-mock (monolit) | — | platform-fortuna-bridge → 30890 | `services/legacy-monolith`, kendi mTLS'i |
| prometheus | 127.0.0.1:30090 | platform-prometheus → 30090 | cluster agent'larının remote_write hedefi |
| loki | 127.0.0.1:30100 | platform-loki → 30100 | log alımı (Alloy) |
| jaeger | 127.0.0.1:30318 (OTLP), 16686 (UI) | platform-tempo → 30318 | iz alımı |
| grafana | 127.0.0.1:3000 | — | dashboard'lar `platform/config/grafana/` |
| auth bridge | — | platform-auth-bridge → `id.bank.lab.local` (bank-prod 30543) | monolit → auth-server |
| si bridge | — | platform-si-bridge → `seal-intranet.lab.local` (codevo 30456) | monolit → Seal Intranet |

Parolalar `platform/.env` içindedir. `up.sh` eksikse üretir; sırlar her çalıştırmada cluster'lardan okunur.

## Edge (HAProxy)
`edge/docker-compose.yml` ve `edge/haproxy/haproxy.cfg.tpl` (`edge/scripts/render-haproxy.sh` ile üretilir).

| Ad | Giriş | Davranış | Hedef |
|---|---|---|---|
| web.lab.local | 127.0.0.1:8443 | TLS edge'de sonlanır | 30802 (Janus web) |
| mobile-api.lab.local | 127.0.0.1:8443 | TLS edge'de sonlanır | 30802 (Janus mobil) |
| seal.lab.local | 127.0.0.1:8443 | SNI passthrough | 30456 (Seal Mobile) |
| stats | 127.0.0.1:8404 | HAProxy istatistikleri | — |

## Konsol ve araçlar
- Konsol: `console/app.py`, `127.0.0.1:9000`. Auth-server'a port-forward ile (127.0.0.1:18443) bağlanır.
- Araçlar: `tools/tools-forward.sh` (start/stop/status), `tools/tool-credentials.sh` (adresler ve parolalar; çıktıda parola vardır).

## Ağ ve adlandırma
- Kind düğüm IP'leri dinamiktir; statik IP verilmez. Köprü ve düğüm IP'leri `docker_ip` ile okunur.
- Windows ayrılmış port aralığı (8185-8284) nedeniyle Vault 18200'de yayınlanır.
