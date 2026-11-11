#!/usr/bin/env bash
# İç servislerin (BFF, core) kodunu ConfigMap olarak yükler ve manifest'leri uygular.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/../scripts/lab-ips.sh"
K="kubectl --context kind-internal"

for ns in app-bff app-core; do
    $K create namespace "$ns" --dry-run=client -o yaml | $K apply -f - >/dev/null
    $K -n "$ns" create configmap svc-code --from-file=svc.py="$ROOT/services/svc.py" \
        --from-file=tracing.py="$ROOT/../shared/tracing.py" \
        --from-file=metrics.py="$ROOT/../shared/metrics.py" \
        --dry-run=client -o yaml | $K apply -f -
done

render "$ROOT/manifests/services.yaml" | $K apply -f -
$K -n app-bff rollout restart deploy/bff >/dev/null
$K -n app-core rollout restart deploy/core >/dev/null
$K -n app-bff rollout status deploy/bff --timeout=180s
$K -n app-core rollout status deploy/core --timeout=180s
echo "İç servisler (BFF, core) iç JWT doğrulamasıyla çalışıyor."
