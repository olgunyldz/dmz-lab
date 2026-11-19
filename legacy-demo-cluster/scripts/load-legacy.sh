#!/usr/bin/env bash
# Fortuna monolit ve LegacyDB artık host'ta docker compose ile çalışır (legacy-demo ve mgmt cluster'ları kaldırıldı).
# Kurulum ve güncelleme: platform/scripts/up.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
exec bash "$ROOT/platform/scripts/up.sh"
