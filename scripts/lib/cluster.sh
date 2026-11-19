#!/usr/bin/env bash
# Ortak cluster yardımcıları. Her cluster'ın kendi script'inde tekrar yazılmaz; şu şekilde kaynak alınır:
#   source "$(cd "$(dirname "$0")/.." && pwd)/scripts/lib/cluster.sh"     (scripts/ ve alt klasörlerden)
# Bu dosya doğrudan çalıştırılmaz.

LIB_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Bir kind container'ının kind ağındaki IP'si (düğüm IP'si, köprü IP'si). Örn: docker_ip platform-tempo
docker_ip() {
    docker inspect -f '{{ index .NetworkSettings.Networks "kind" "IPAddress" }}' "$1"
}

# Platform OTLP kabulü (Jaeger, kind ağındaki platform-tempo köprüsü, port 30318). Çıktı: http://IP:30318
otlp_url() {
    echo "http://$(docker_ip platform-tempo):30318"
}

# Cluster yoksa oluşturur. <cluster>
ensure_cluster() {
    local c="$1"
    if ! kind get clusters 2>/dev/null | grep -qx "$c"; then
        kind create cluster --name "$c" --config "$LIB_REPO/infra/clusters/$c/kind-config.yaml" --wait 120s
    fi
}

# nginx ingress controller'ı bir cluster'a kurar (helm upgrade --install).
# install_ingress <cluster> <http-nodeport> <https-nodeport> <ssl-passthrough true|false>
install_ingress() {
    local cluster="$1" http_np="$2" https_np="$3" passthrough="$4"
    helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx --kube-context "kind-$cluster" \
        --namespace ingress-nginx --create-namespace \
        --set controller.ingressClassResource.name=nginx \
        --set controller.ingressClassResource.default=true \
        --set controller.service.type=NodePort \
        --set controller.service.nodePorts.http="$http_np" \
        --set controller.service.nodePorts.https="$https_np" \
        --set controller.extraArgs.enable-ssl-passthrough="$passthrough" \
        --set controller.admissionWebhooks.enabled=false \
        --set controller.resources.requests.cpu=100m \
        --set controller.resources.requests.memory=128Mi \
        --wait --timeout 540s >/dev/null
    echo "ingress controller hazır: $cluster (http $http_np, https $https_np, passthrough $passthrough)"
}

# ---- Namespace standardı -------------------------------------------------------------------
# ensure_ns <cluster> <ns>: namespace yoksa oluşturur (idempotent) ve ortak etiketleri koyar.
ensure_ns() { # <cluster> <ns>
    kubectl --context "kind-$1" create namespace "$2" --dry-run=client -o yaml \
        | kubectl --context "kind-$1" apply -f - >/dev/null
    kubectl --context "kind-$1" label namespace "$2" \
        app.kubernetes.io/part-of=dmz-lab lab.dmz/cluster="$1" --overwrite >/dev/null
}

# ---- Uygulama kurulum standardı ------------------------------------------------------------
# Görüntü: <build_dir> içinden derlenir ve kind düğümüne yüklenir. <cluster> <image> <build_dir>
kind_load_image() {
    docker build -q -t "$2" "$3" >/dev/null
    kind load docker-image "$2" --name "$1" >/dev/null
}

# Manifest: placeholder'lar (__OTLP_URL__ dahil) doldurulup uygulanır. <cluster> <file> [sed-ifadesi...]
# __OTLP_URL__ her zaman otlp_url ile doldurulur; diğer ifadeler verilen sırayla uygulanır.
apply_manifest() {
    local cluster="$1" file="$2"; shift 2
    local otlp; otlp="$(otlp_url)"
    local -a exprs=(-e "s|__OTLP_URL__|$otlp|")
    local e
    for e in "$@"; do exprs+=(-e "$e"); done
    sed "${exprs[@]}" "$file" | kubectl --context "kind-$cluster" apply -f - >/dev/null
}

# Deployment'ı yeniden başlatır ve hazır olmasını bekler. <cluster> <ns> <deploy> [zaman aşımı]
rollout_wait() {
    local cluster="$1" ns="$2" deploy="$3" timeout="${4:-240s}"
    kubectl --context "kind-$cluster" -n "$ns" rollout restart "deploy/$deploy" >/dev/null
    kubectl --context "kind-$cluster" -n "$ns" rollout status "deploy/$deploy" --timeout="$timeout"
}

# ---- Observability standardı (her cluster'a sabit) ------------------------------------------
# Log toplayıcı (Alloy) bir cluster'a kurulur. Loki adresi platform compose'undan gelir.
# install_alloy <cluster> <loki_push_url>
install_alloy() {
    local cluster="$1" loki="$2"
    ensure_ns "$cluster" observability
    sed -e "s|__CLUSTER__|$cluster|" -e "s|__LOKI_URL__|$loki|" "$LIB_REPO/observability/agents/alloy.yaml" \
        | kubectl --context "kind-$cluster" apply -f - >/dev/null
    rollout_wait "$cluster" observability alloy
    echo "alloy hazır: $cluster -> $loki"
}

# ---- Secret standardı -----------------------------------------------------------------------
# Secret'ı idempotent uygular. <cluster> <ns> <name> [kubectl create secret generic argümanları...]
apply_secret() {
    local cluster="$1" ns="$2" name="$3"; shift 3
    kubectl --context "kind-$cluster" -n "$ns" create secret generic "$name" "$@" \
        --dry-run=client -o yaml | kubectl --context "kind-$cluster" apply -f - >/dev/null
}

# ---- Vault standardı (bank-prod, ns secrets; VAULT_CTX ile değiştirilebilir) ------------------
_vault_ctx() { echo "${VAULT_CTX:-kind-bank-prod}"; }

# Vault kök token'ı (vault-bootstrap secret'ı). Yalnızca önbelleğe alınır, dosyaya yazılmaz.
vault_root_token() {
    kubectl --context "$(_vault_ctx)" -n secrets get secret vault-bootstrap -o jsonpath='{.data.root_token}' | base64 -d
}

vault_bootstrapped() { kubectl --context "$(_vault_ctx)" -n secrets get secret vault-bootstrap >/dev/null 2>&1; }

# Vault CLI'ı vault pod'unda çalıştırır. Örn: vault_exec vault kv get -format=json secret/x
vault_exec() {
    if [[ -z "${_VAULT_TOKEN:-}" ]]; then _VAULT_TOKEN="$(vault_root_token)"; fi
    kubectl --context "$(_vault_ctx)" -n secrets exec deploy/vault -- env VAULT_TOKEN="$_VAULT_TOKEN" "$@"
}

# Tek alan okur. vault_get <path> <field>
vault_get() { vault_exec vault kv get -field="$2" "$1"; }

# Alanları yazar: varsa patch, yoksa put. vault_kv_set <path> KEY=VAL...
vault_kv_set() {
    local path="$1"; shift
    if vault_exec vault kv get "$path" >/dev/null 2>&1; then
        vault_exec vault kv patch "$path" "$@" >/dev/null
    else
        vault_exec vault kv put "$path" "$@" >/dev/null
    fi
}

# ---- Uygulama standardı (görüntü ve rollout) ---------------------------------------------------
# kind_load_image, rollout_wait, apply_manifest yukarıda tanımlı.

# ---- Hook standardı (apps/<ad>/hook.sh) -----------------------------------------------------------
# Hook girdileri: ROOT, CLUSTER, NAMESPACE. Çıktıları: SUBST_EXPRS (dizi), gerekirse BUILD_CONTEXT.
# Yardımcılar aşağıdadır; hook'lar ham kubectl/openssl/docker yazmaz.

# Secret var mı? secret_exists <cluster> <ns> <name>
secret_exists() {
    kubectl --context "kind-$1" -n "$2" get secret "$3" >/dev/null 2>&1
}

# Secret yoksa oluşturur, varsa dokunmaz (tek seferlik üretilen sırlar). secret_once <cluster> <ns> <name> [args...]
secret_once() {
    local cluster="$1" ns="$2" name="$3"; shift 3
    if secret_exists "$cluster" "$ns" "$name"; then return 0; fi
    apply_secret "$cluster" "$ns" "$name" "$@"
    echo "secret üretildi: $ns/$name"
}

# mTLS sertifikalarını (edge/certs/mtls) üretir; idempotent.
ensure_mtls_certs() { bash "$LIB_REPO/scripts/gen-mtls-certs.sh" >/dev/null; }
mtls_dir() { echo "$LIB_REPO/edge/certs/mtls"; }

# mTLS secret'ı: <basename>.crt/.key ve ca.crt'den. role=server|client (secret anahtarları server.* / client.*).
# mtls_secret <cluster> <ns> <secret-adı> <dosya-kökü> <server|client>
mtls_secret() {
    local cluster="$1" ns="$2" name="$3" base="$4" role="$5"
    local d; d="$(mtls_dir)"
    apply_secret "$cluster" "$ns" "$name" \
        --from-file="$role.crt=$d/$base.crt" --from-file="$role.key=$d/$base.key" --from-file=ca.crt="$d/ca.crt"
}

# Placeholder ifadesi: subst_expr <__PLACEHOLDER__> <değer>  ->  sed ifadesi
subst_expr() { printf 's|%s|%s|' "$1" "$2"; }

# Kind düğümü (docker container) IP'si ile placeholder: subst_ip <__PLACEHOLDER__> <container>
subst_ip() { subst_expr "$1" "$(docker_ip "$2")"; }

# Build bağlamı hazırla: <app> <kaynak-klasör> [ek dosya kaynakları...] -> .build/<app>; çıktı yolu
# Ek dosyalar "hedef=kaynak" biçiminde ya da yalnızca kaynak (taban adıyla kopyalanır).
stage_build_context() {
    local app="$1" src="$2"; shift 2
    local dst="$LIB_REPO/.build/$app"
    rm -rf "$dst" && mkdir -p "$dst"
    cp -r "$src/." "$dst/"
    local pair
    for pair in "$@"; do
        if [[ "$pair" == *=* ]]; then cp "${pair#*=}" "$dst/${pair%%=*}"; else cp "$pair" "$dst/"; fi
    done
    echo "$dst"
}

# Seal sertifikaları (edge/certs/seal, edge/certs/device) yoksa üretilir.
ensure_seal_certs() { [[ -f "$LIB_REPO/edge/certs/seal/seal-mobile.crt" ]] || bash "$LIB_REPO/edge/scripts/gen-seal-certs.sh"; }

# Seal paylaşılan anahtarları (SEAL_PM_KEY, SEAL_MOCK_KEY) Vault'tan yükler/üretir.
load_seal_keys() { source "$LIB_REPO/scripts/seal-keys.sh"; }

# Secret'tan tek anahtar okur (cross-cluster okumalar dahil). secret_value <cluster> <ns> <ad> <anahtar>
secret_value() {
    kubectl --context "kind-$1" -n "$2" get secret "$3" -o jsonpath="{.data.$4}" | base64 -d
}

# Repo .env dosyasından değer okur (yoksa boş). env_get <KEY> [dosya]
env_get() {
    local file="${2:-$LIB_REPO/platform/.env}"
    [[ -f "$file" ]] || { echo ""; return 0; }
    grep -E "^$1=" "$file" | head -1 | cut -d= -f2- || true
}

# ConfigMap'i dosyalardan uygular. apply_configmap <cluster> <ns> <ad> "hedef=kaynak" ...
apply_configmap() {
    local cluster="$1" ns="$2" name="$3"; shift 3
    local -a args=()
    local pair
    for pair in "$@"; do args+=(--from-file="$pair"); done
    kubectl --context "kind-$cluster" -n "$ns" create configmap "$name" "${args[@]}" \
        --dry-run=client -o yaml | kubectl --context "kind-$cluster" apply -f - >/dev/null
}

# Prometheus agent bir cluster'a kurulur. Scrape işleri <jobs_file>'dan, remote_write <rw_url>'ye.
# install_prom_agent <cluster> <jobs_file> <remote_write_url>
install_prom_agent() {
    local cluster="$1" jobs="$2" rw="$3" tmp
    tmp="$(mktemp)"
    {
        printf 'global:\n  scrape_interval: 30s\n  external_labels:\n    cluster: %s\nscrape_configs:\n' "$cluster"
        cat "$jobs"
        printf 'remote_write:\n  - url: %s\n' "$rw"
    } > "$tmp"
    ensure_ns "$cluster" observability
    apply_configmap "$cluster" observability prometheus-agent-config "prometheus.yml=$tmp"
    kubectl --context "kind-$cluster" apply -f "$LIB_REPO/observability/agents/prometheus-agent.yaml" >/dev/null
    rollout_wait "$cluster" observability prometheus-agent
    rm -f "$tmp"
    echo "prometheus agent hazır: $cluster -> $rw"
}
