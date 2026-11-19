# Gözlemlenebilirlik

Üç sinyal, üç bileşen:

| Sinyal | Toplama | Depolama | Görüntüleme |
|---|---|---|---|
| Log | Alloy (her cluster'da, Kubernetes API'den pod logları) | Loki (platform) | Grafana > Explore > Loki |
| Metrik | Prometheus agent (her cluster'da, kendi servislerini kazır) | Prometheus (platform, remote_write alıcısı) | Grafana |
| İz | Uygulamalar OTLP/HTTP ile gönderir | Jaeger (platform, bellek içi depolama) | Jaeger UI, 127.0.0.1:16686 |

## Kurumsal ve lab karşılığı
| Sinyal | Kurumsal (as-is) | Lab (demo) |
|---|---|---|
| İz (APM) | Dynatrace | Jaeger |
| Log | ELK (Elasticsearch, Logstash, Kibana) | Loki (Grafana'dan okunur) |
| Metrik | Prometheus | Prometheus |
| Pano | Grafana | Grafana |

Kafka, RabbitMQ ve Redis'in izlenmesi kurumsal tarafta tanımlanacak; lab'da bu bileşenler yoktur.

## Nerede
- **Platform:** `platform/docker-compose.yml`, konfigürasyonlar `platform/config/` (`prometheus.yml`, `loki.yml`, `grafana/`). Platform bileşenlerinin kendi metrikleri (loki, grafana, jaeger) merkezi Prometheus'a dahildir.
- **Cluster ajanları:** `observability/agents/` (`alloy.yaml`, `prometheus-agent.yaml`).
- **Kurulum:** `observability/install.sh`. Her cluster için Alloy ve Prometheus agent kurar; install-all'ın son adımıdır.

## Scrape hedefleri
Her cluster'ın agent'ı yalnızca kendi servislerini kazır. Hedefler **uygulama kataloğundan** üretilir (`apps/<ad>/app.env` içindeki `METRICS`). Yeni bir servis metrik sunuyorsa ilgili uygulamaya `METRICS` satırı eklenmesi yeterlidir; agent yapılandırması elle düzenlenmez.

| Uygulama | Hedef | Şema | Yol |
|---|---|---|---|
| auth-server | auth-server.auth.svc:9100 | http | /actuator/prometheus |
| janus | janus-web / janus-mobile :8080 | http | /metrics |
| fortuna | 4 servis :8443 | https | /metrics |
| channel-gateway | channel-gateway :8443 | https | /metrics |
| seal-intranet | seal-intranet-metrics :9100 | http | /metrics |
| seal-mobile | seal-mobile-metrics :9100 | http | /metrics |

Platform bileşenleri (`platform/config/prometheus.yml`): Prometheus kendisi, Loki, Grafana, Jaeger ve Fortuna monolit (`fortuna-mock:8443`, https).

## Etiketler
- Agent'lar `cluster` dış etiketini ekler; platform job'ları `cluster: platform` kullanır.
- Log etiketleri (Alloy): cluster, namespace, pod, container, app.

## İz (trace) akışı
- Her servis `shared/tracing.py` (yalnızca standart kütüphane) ile W3C `traceparent` üretir ve taşır.
- Gönderim adresi `otlp_url` helper'ından gelir: platform Jaeger'ın OTLP portu (127.0.0.1:30318 → kind ağında bridge-jaeger köprüsü).
- Auth-server kendi OpenTelemetry bağımlılığıyla aynı başlığı işler; yanıt `X-Trace-Id` döner.
- Konsol, iz kimliğiyle Jaeger ve Loki bağlantıları üretir. İz görüntüleyici konsolun içinde değildir (istek üzerine kaldırıldı).

## Bilinen sınırlar
- Jaeger bellek içi depolama kullanır; platform yeniden başlatılınca izler gider.
- Tempo tamamen kaldırılmıştır; trace backend Jaeger'dır.
- Seal Intranet ve Seal Mobile metrik NodePort'ları (30644, 30457) kullanılmıyor; kaldırılabilir.
