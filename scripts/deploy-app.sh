#!/usr/bin/env bash
# Tek uygulamayı kurar. Kaynak: apps/<ad>/ (app.env, hook.sh, manifests/). Jenkins'te ve lab'da aynı akış:
#   1) namespace (cluster + ns etiketleri)
#   2) hook.sh (varsa): sırlar, sertifikalar; SUBST_EXPRS ve gerekirse BUILD_CONTEXT üretir
#   3) imaj: REGISTRY_MODE=kind (lab: kind load) veya registry (docker build + push)
#   4) kod ConfigMap'i (CODE_CM / CODE_FILES)
#   5) manifest'ler uygulanır (MANIFEST; placeholder'lar SUBST_EXPRS + __OTLP_URL__)
#   6) ROLLOUT listesindeki deployment'lar yeniden başlatılır ve hazır olana kadar beklenir
# Kullanım: bash scripts/deploy-app.sh <ad>        Örn: bash scripts/deploy-app.sh janus
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/lib/cluster.sh"

APP="${1:?kullanım: deploy-app.sh <ad>}"
APP_DIR="$ROOT/apps/$APP"
CAT="$APP_DIR/app.env"
[[ -f "$CAT" ]] || { echo "HATA: katalog yok: apps/$APP/app.env" >&2; exit 2; }
source "$CAT"

for v in CLUSTER NAMESPACE MANIFEST ROLLOUT; do
    [[ -n "${!v:-}" ]] || { echo "HATA: apps/$APP/app.env içinde $v boş" >&2; exit 2; }
done
# İmaj (IMAGE + BUILD_CONTEXT) ve/veya kod ConfigMap'i (CODE_CM + CODE_FILES) olabilir.
if [[ -n "${IMAGE:-}" ]]; then
    [[ -n "${BUILD_CONTEXT:-}" ]] || { echo "HATA: apps/$APP/app.env: IMAGE için BUILD_CONTEXT gerekli" >&2; exit 2; }
fi
REGISTRY_MODE="${REGISTRY_MODE:-kind}"
# BUILD_CONTEXT ve CODE_FILES repo köküne göredir; hook mutlak yol üretebilir (örn. .build/<ad>)
ctx_path() { case "$1" in /*|[A-Za-z]:*) echo "$1" ;; *) echo "$ROOT/$1" ;; esac; }
SUBST_EXPRS=()

echo "== $APP -> cluster=$CLUSTER ns=$NAMESPACE"
ensure_ns "$CLUSTER" "$NAMESPACE"

if [[ -n "${PRE_HOOK:-}" ]]; then
    echo "-- hook: $PRE_HOOK"
    source "$APP_DIR/$PRE_HOOK"
fi

if [[ -n "${IMAGE:-}" ]]; then
    echo "-- imaj ($REGISTRY_MODE)"
    case "$REGISTRY_MODE" in
        kind)     kind_load_image "$CLUSTER" "$IMAGE" "$(ctx_path "$BUILD_CONTEXT")" ;;
        registry) docker build -q -t "$IMAGE" "$(ctx_path "$BUILD_CONTEXT")" >/dev/null && docker push "$IMAGE" >/dev/null ;;
        *) echo "HATA: REGISTRY_MODE bilinmiyor: $REGISTRY_MODE" >&2; exit 2 ;;
    esac
fi

if [[ -n "${CODE_CM:-}" ]]; then
    echo "-- kod ConfigMap: $CODE_CM"
    files=()
    for pair in $CODE_FILES; do files+=("${pair%%=*}=$ROOT/${pair#*=}"); done
    apply_configmap "$CLUSTER" "$NAMESPACE" "$CODE_CM" "${files[@]}"
fi

echo "-- manifest"
for m in $MANIFEST; do apply_manifest "$CLUSTER" "$APP_DIR/$m" "${SUBST_EXPRS[@]}"; done

echo "-- rollout"
for d in $ROLLOUT; do rollout_wait "$CLUSTER" "$NAMESPACE" "$d"; done
echo "tamam: $APP"
