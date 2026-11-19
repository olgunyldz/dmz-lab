#!/usr/bin/env bash
# Her cluster'a bir Prometheus agent kurar: yalnızca kendi cluster'ının servislerini kazır ve
# merkezi Prometheus'a (mgmt, NodePort 30090, remote_write) gönderir. Cluster'lar arası kazıma yoktur.
# Önkoşul: mgmt merkezi Prometheus'u remote-write alıcısıyla çalışıyor (load-observability.sh).
set -euo pipefail

MGMT_IP=$(docker inspect -f '{{ index .NetworkSettings.Networks "kind" "IPAddress" }}' platform-prometheus)  # merkez Prometheus köprüsü (platform)
REMOTE_WRITE="http://$MGMT_IP:30090/api/v1/write"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"

# Cluster'a özgü scrape hedefleri (aynı cluster içinde servis DNS adı)
write_config() { # <cluster> <scrape_jobs_file>
    cat > "$TMP/$1.yml" <<EOF
global:
  scrape_interval: 30s
  external_labels:
    cluster: $1
scrape_configs:
EOF
    cat "$2" >> "$TMP/$1.yml"
    cat >> "$TMP/$1.yml" <<EOF
remote_write:
  - url: $REMOTE_WRITE
EOF
}

# bank-prod: channel-gateway, Fortuna CGW/API/ACL/SMS (HTTPS, sertifika lab CA; kazıma doğrulamasız), auth-server
cat > "$TMP/bank-prod.jobs" <<'EOF'
  - job_name: channel-gateway
    scheme: https
    tls_config: { insecure_skip_verify: true }
    static_configs: [{ targets: ["channel-gateway.channel.svc:8443"] }]
  - job_name: fortuna-users-cgw
    scheme: https
    tls_config: { insecure_skip_verify: true }
    static_configs: [{ targets: ["fortuna-users-cgw.channel.svc:8443"] }]
  - job_name: fortuna-user-api
    scheme: https
    tls_config: { insecure_skip_verify: true }
    static_configs: [{ targets: ["fortuna-user-api.channel.svc:8443"] }]
  - job_name: fortuna-user-acl
    scheme: https
    tls_config: { insecure_skip_verify: true }
    static_configs: [{ targets: ["fortuna-user-acl.channel.svc:8443"] }]
  - job_name: sms-otp-cgw
    scheme: https
    tls_config: { insecure_skip_verify: true }
    static_configs: [{ targets: ["sms-otp-cgw.channel.svc:8443"] }]
  - job_name: auth-server
    metrics_path: /actuator/prometheus
    static_configs: [{ targets: ["auth-server.auth.svc:9100"] }]
EOF

# bank-dmz-prod: Janus web ve mobil
cat > "$TMP/bank-dmz-prod.jobs" <<'EOF'
  - job_name: janus-web
    static_configs: [{ targets: ["janus-web.janus.svc:8080"] }]
  - job_name: janus-mobile
    static_configs: [{ targets: ["janus-mobile.janus.svc:8080"] }]
EOF

# codevo-dmz: Seal Mobile ve Seal Intranet (metrik servisleri, düz HTTP)
cat > "$TMP/codevo-dmz.jobs" <<'EOF'
  - job_name: seal-mobile
    static_configs: [{ targets: ["seal-mobile-metrics.seal-mobile.svc:9100"] }]
  - job_name: seal-intranet
    static_configs: [{ targets: ["seal-intranet-metrics.seal-intranet.svc:9100"] }]
EOF

# legacy-demo: Fortuna monolit (HTTPS)
cat > "$TMP/legacy-demo.jobs" <<'EOF'
  - job_name: fortuna-mock
    scheme: https
    tls_config: { insecure_skip_verify: true }
    static_configs: [{ targets: ["fortuna-mock.fortuna.svc:8443"] }]
EOF

for c in bank-prod bank-dmz-prod codevo-dmz; do
    write_config "$c" "$TMP/$c.jobs"
    K="kubectl --context kind-$c"
    $K create namespace observability --dry-run=client -o yaml | $K apply -f - >/dev/null
    $K -n observability create configmap prometheus-agent-config --from-file=prometheus.yml="$TMP/$c.yml" \
        --dry-run=client -o yaml | $K apply -f - >/dev/null
    $K apply -f "$ROOT/manifests/prometheus-agent.yaml" >/dev/null
    $K -n observability rollout restart deploy/prometheus-agent >/dev/null
    $K -n observability rollout status deploy/prometheus-agent --timeout=240s
    echo "agent hazır: $c -> $REMOTE_WRITE"
done
rm -rf "$TMP"
