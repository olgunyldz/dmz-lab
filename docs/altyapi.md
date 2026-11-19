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
| legacydb (PostgreSQL 16, lab karşılığı) | 127.0.0.1:30432 | bridge-legacydb → 30432 | Fortuna verileri. As-is veritabanı MSSQL'dir |
| fortuna-mock (monolit) | — | bridge-fortuna → 30890 | as-is: Windows IIS (on-prem). Lab: imaj `dmz-lab/legacy-monolith` (Python mock), kendi mTLS'i |
| prometheus | 127.0.0.1:30090 | bridge-prometheus → 30090 | cluster agent'larının remote_write hedefi |
| loki | 127.0.0.1:30100 | bridge-loki → 30100 | log alımı (Alloy) |
| jaeger | 127.0.0.1:30318 (OTLP), 16686 (UI) | bridge-jaeger → 30318 | iz alımı |
| grafana | 127.0.0.1:3000 | — | dashboard'lar `platform/config/grafana/` |
| auth bridge | — | bridge-auth → `id.bank.lab.local` (bank-prod 30543) | monolit → auth-server |
| si bridge | — | bridge-si → `seal-intranet.lab.local` (codevo 30456) | monolit → Seal Intranet |

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

## Cluster, namespace ve pod yapısı (lab)
Replika ve port değerleri manifest'lerden alınmıştır. Lab'da her cluster tek node'lu kind cluster'ıdır.

| Cluster | Namespace | Pod (Deployment ×replika · port) |
|---|---|---|
| bank-prod | ingress-nginx | ingress-nginx-controller ×1 (NodePort 30081 / 30543) |
| bank-prod | auth | auth-server ×1 (:8443, :8080, :9100) · postgres-auth ×1 (:5432, PVC) |
| bank-prod | channel | channel-gateway ×1 (:8443, NodePort 30990) · fortuna-users-cgw ×1 (:8443, 30880) · fortuna-user-api ×1 · fortuna-user-acl ×1 · sms-otp-cgw ×1 (:8443, 30881) |
| bank-prod | secrets | vault ×1 (:8200, KV v2) |
| bank-prod | observability | alloy ×1 (:12345) · prometheus-agent ×1 (:9090) |
| bank-dmz-prod | ingress-nginx | ingress-nginx-controller ×1 (NodePort 30802 / 30443) |
| bank-dmz-prod | janus | janus-web ×1 (:8080, web.lab.local) · janus-mobile ×1 (:8080, mobile-api.lab.local) |
| bank-dmz-prod | observability | alloy ×1 · prometheus-agent ×1 |
| codevo-dmz | ingress-nginx | ingress-nginx-controller ×1 (NodePort 30456 passthrough / 30080) |
| codevo-dmz | seal-intranet | seal-intranet ×1 (:8443, metrik :9100; ingress seal-intranet.lab.local) |
| codevo-dmz | seal-mobile | seal-mobile ×1 (:8443, metrik :9100; ingress seal.lab.local) |
| codevo-dmz | observability | alloy ×1 · prometheus-agent ×1 |
| platform (host, compose) | — | legacydb ×1 (:5432) · fortuna-mock ×1 (:8443) · prometheus ×1 (:9090) · loki ×1 (:3100) · jaeger ×1 (OTLP :4318, UI :16686) · grafana ×1 (:3000) · köprüler (bridge-*) |

Diyagram sayfaları: "Lab · Cluster ve namespace yapısı", "Lab · Ingress ve giriş kuralları", "Lab · Kanal: web", "Lab · Kanal: mobil", "Lab · Sırlar ve veri".
