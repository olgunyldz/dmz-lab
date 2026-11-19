#!/usr/bin/env bash
# Gözlemlenebilirlik ajanlarını her cluster'a kurar (platform compose'a bağlı; önkoşul: platform/scripts/up.sh):
#   - Alloy: pod logları -> platform Loki (install_alloy)
#   - Prometheus agent: scrape hedefleri apps/*/app.env içindeki METRICS alanından; remote_write -> platform Prometheus
# METRICS biçimi (boşlukla ayrılmış öğeler): job|scheme(http|https)|host:port|path
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/lib/cluster.sh"

LOKI="http://$(docker_ip platform-loki):30100/loki/api/v1/push"
REMOTE_WRITE="http://$(docker_ip platform-prometheus):30090/api/v1/write"
JOBS_DIR="$(mktemp -d)"
trap 'rm -rf "$JOBS_DIR"' EXIT

for c in bank-prod bank-dmz-prod codevo-dmz; do
    install_alloy "$c" "$LOKI"

    jobs="$JOBS_DIR/$c.jobs"
    : > "$jobs"
    for env in "$ROOT"/apps/*/app.env; do
        ( source "$env"; if [[ "$CLUSTER" == "$c" ]]; then for item in ${METRICS:-}; do echo "$item"; done; fi ) |
        while IFS='|' read -r job scheme target path; do
            [[ -n "$job" ]] || continue
            {
                echo "  - job_name: $job"
                echo "    metrics_path: $path"
                if [[ "$scheme" == https ]]; then
                    echo "    scheme: https"
                    echo "    tls_config: { insecure_skip_verify: true }"
                fi
                echo "    static_configs: [{ targets: [\"$target\"] }]"
            } >> "$jobs"
        done
    done
    install_prom_agent "$c" "$jobs" "$REMOTE_WRITE"
done
echo "Gözlemlenebilirlik hazır: loglar -> $LOKI, metrikler -> $REMOTE_WRITE"
