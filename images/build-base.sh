#!/usr/bin/env bash
# Taban imajları derler: dmz-lab/base-python ve dmz-lab/base-java. Sürümler images/versions.env.
# BASE_PUSH=1 ve REGISTRY=<adres> ise imajları registry'ye de gönderir (Jenkins / şirket ortamı).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/images/versions.env"

push_if_asked() { # <imaj>
    if [[ "${BASE_PUSH:-0}" == 1 ]]; then
        local remote="${REGISTRY:?BASE_PUSH=1 için REGISTRY gerekli}/$1"
        docker tag "$1" "$remote" && docker push "$remote" >/dev/null
        echo "registry'ye gönderildi: $remote"
    fi
}

# Python: bağlam geçici klasörde (tracing.py kopyası dahil); repo ağacı Docker'a gönderilmez.
ctx="$(mktemp -d)"
trap 'rm -rf "$ctx"' EXIT
cp "$ROOT/images/base/python/Dockerfile" "$ctx/Dockerfile"
cp "$ROOT/shared/tracing.py" "$ctx/tracing.py"
docker build -q --build-arg PYTHON_TAG="$PYTHON_TAG" -t "$BASE_PYTHON_IMAGE" "$ctx" >/dev/null
echo "hazır: $BASE_PYTHON_IMAGE"
push_if_asked "$BASE_PYTHON_IMAGE"

docker build -q --build-arg JAVA_TAG="$JAVA_TAG" -t "$BASE_JAVA_IMAGE" "$ROOT/images/base/java" >/dev/null
echo "hazır: $BASE_JAVA_IMAGE"
push_if_asked "$BASE_JAVA_IMAGE"
