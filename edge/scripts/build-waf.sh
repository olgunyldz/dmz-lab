#!/usr/bin/env bash
# coraza-spoa (OWASP Coraza WAF, HAProxy SPOA) imajını sabit bir sürümden derler.
# Docker Hub'da resmi imaj olmadığı için upstream kaynaktan derlenir.
set -euo pipefail

VERSION="v0.9.1"
IMAGE="dmz-lab/coraza-spoa:${VERSION#v}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

git clone --depth 1 --branch "$VERSION" https://github.com/corazawaf/coraza-spoa.git "$WORK/src"
docker build -f "$WORK/src/example/Dockerfile" -t "$IMAGE" "$WORK/src"

echo "Imaj hazır: $IMAGE"
