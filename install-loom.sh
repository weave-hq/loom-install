#!/usr/bin/env bash
set -euo pipefail

REPO="weave-hq/loom-core"
RELEASE_NAME="loom"
NAMESPACE="loom"
VERSION=""
COMMAND="${1:-}"
GHCR_PULL_SECRET="loom-ghcr-pull"
INGRESS_CLASS=""
KAFKA_REPLICAS=""
KAFKA_ANTI_AFFINITY=""

usage() {
  cat <<EOF
Usage:
  $0 install --version <version>
  $0 upgrade --version <version>
  $0 wipe [--purge-data]
  $0 status

Options:
  --version <version>      Loom version, e.g. 0.1.0
  --namespace <namespace>  Kubernetes namespace, default: loom
  --github-token <token>   Token for private release assets
  --ghcr-token <token>     Token for GHCR image pulls (defaults to --github-token)
  --ghcr-username <user>   GitHub username for GHCR login (auto-detected if omitted)
  --ghcr-pull-secret <name> Image pull secret name, default: loom-ghcr-pull
  --ingress-class <name>   IngressClass to use (auto-detected if omitted)
  --kafka-replicas <n>     Redpanda broker replicas (auto-detected if omitted)
  --kafka-anti-affinity <type> Redpanda anti-affinity: hard|soft|custom (auto-detected if omitted)
  --purge-data             Delete PVCs/secrets/namespace during wipe
EOF
}

shift || true

GITHUB_TOKEN="${GITHUB_TOKEN:-}"
GHCR_TOKEN="${GHCR_TOKEN:-}"
GHCR_USERNAME="${GHCR_USERNAME:-}"
PURGE_DATA="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="$2"
      shift 2
      ;;
    --namespace)
      NAMESPACE="$2"
      shift 2
      ;;
    --github-token)
      GITHUB_TOKEN="$2"
      shift 2
      ;;
    --ghcr-token)
      GHCR_TOKEN="$2"
      shift 2
      ;;
    --ghcr-username)
      GHCR_USERNAME="$2"
      shift 2
      ;;
    --ghcr-pull-secret)
      GHCR_PULL_SECRET="$2"
      shift 2
      ;;
    --ingress-class)
      INGRESS_CLASS="$2"
      shift 2
      ;;
    --kafka-replicas)
      KAFKA_REPLICAS="$2"
      shift 2
      ;;
    --kafka-anti-affinity)
      KAFKA_ANTI_AFFINITY="$2"
      shift 2
      ;;
    --purge-data)
      PURGE_DATA="true"
      shift
      ;;
    *)
      echo "Unknown argument: $1"
      usage
      exit 1
      ;;
  esac
done

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Please run as root or with sudo"
    exit 1
  fi
}

require_github_token() {
  if [[ -z "$GITHUB_TOKEN" ]]; then
    echo "--github-token (or GITHUB_TOKEN env var) is required for private releases and GHCR pulls"
    exit 1
  fi
}

install_k3s() {
  if command -v k3s >/dev/null 2>&1; then
    echo "k3s already installed"
    return
  fi

  echo "Installing k3s"
  curl -sfL https://get.k3s.io | sh -
}

configure_kubeconfig() {
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

  # Wait for k3s API server to be responsive
  echo "Waiting for k3s API server to be ready"
  local max_attempts=30
  local attempt=0
  while ! kubectl cluster-info >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    if [[ $attempt -ge $max_attempts ]]; then
      echo "k3s API server failed to become ready after ${max_attempts} attempts"
      exit 1
    fi
    echo "  Attempt $attempt/$max_attempts..."
    sleep 2
  done

  echo "Waiting for Kubernetes node to be ready"
  kubectl wait --for=condition=Ready node --all --timeout=180s
}

install_helm() {
  if command -v helm >/dev/null 2>&1; then
    echo "Helm already installed"
    return
  fi

  echo "Installing Helm"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
}

resolve_kafka_topology_overrides() {
  if [[ -n "$KAFKA_REPLICAS" ]]; then
    if ! [[ "$KAFKA_REPLICAS" =~ ^[0-9]+$ ]] || [[ "$KAFKA_REPLICAS" -lt 1 ]]; then
      echo "--kafka-replicas must be a positive integer" >&2
      exit 1
    fi
  else
    local ready_nodes
    ready_nodes="$(kubectl get nodes --no-headers 2>/dev/null | awk '$2 ~ /Ready/ {count++} END {print count+0}')"

    if ! [[ "$ready_nodes" =~ ^[0-9]+$ ]] || [[ "$ready_nodes" -lt 1 ]]; then
      ready_nodes=1
    fi

    if [[ "$ready_nodes" -ge 3 ]]; then
      KAFKA_REPLICAS=3
    else
      KAFKA_REPLICAS="$ready_nodes"
    fi
  fi

  if [[ -n "$KAFKA_ANTI_AFFINITY" ]]; then
    case "$KAFKA_ANTI_AFFINITY" in
      hard|soft|custom)
        ;;
      *)
        echo "--kafka-anti-affinity must be one of: hard, soft, custom" >&2
        exit 1
        ;;
    esac
  else
    if [[ "$KAFKA_REPLICAS" -lt 3 ]]; then
      KAFKA_ANTI_AFFINITY="soft"
    else
      KAFKA_ANTI_AFFINITY="hard"
    fi
  fi

  echo "Using Redpanda topology: replicas=${KAFKA_REPLICAS}, anti-affinity=${KAFKA_ANTI_AFFINITY}"
}

resolve_ingress_class() {
  if [[ -n "$INGRESS_CLASS" ]]; then
    echo "Using ingress class override: ${INGRESS_CLASS}"
    return
  fi

  if kubectl -n ingress-nginx get deployment ingress-nginx-controller >/dev/null 2>&1; then
    INGRESS_CLASS="nginx"
    echo "Detected ingress-nginx controller; using ingress class: ${INGRESS_CLASS}"
    return
  fi

  if kubectl -n kube-system get deployment traefik >/dev/null 2>&1 \
    || kubectl -n kube-system get deployment traefik-v2 >/dev/null 2>&1; then
    INGRESS_CLASS="traefik"
    echo "Detected Traefik controller; using ingress class: ${INGRESS_CLASS}"
    return
  fi

  if kubectl get ingressclass nginx >/dev/null 2>&1; then
    INGRESS_CLASS="nginx"
    echo "Detected ingress class nginx; using ingress class: ${INGRESS_CLASS}"
    return
  fi

  if kubectl get ingressclass traefik >/dev/null 2>&1; then
    INGRESS_CLASS="traefik"
    echo "Detected ingress class traefik; using ingress class: ${INGRESS_CLASS}"
    return
  fi

  INGRESS_CLASS="nginx"
  echo "No known ingress controller detected; defaulting ingress class to ${INGRESS_CLASS}" >&2
}

ensure_cert_manager() {
  if kubectl get crd certificates.cert-manager.io >/dev/null 2>&1 \
    && kubectl get crd issuers.cert-manager.io >/dev/null 2>&1; then
    echo "cert-manager CRDs already installed"
    return
  fi

  echo "Installing cert-manager CRDs and controller"
  helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
  helm repo update >/dev/null

  helm upgrade --install cert-manager jetstack/cert-manager \
    --namespace cert-manager \
    --create-namespace \
    --set crds.enabled=true \
    --wait \
    --timeout 5m
}

download_asset() {
  local url="$1"
  local output="$2"

  # For private repos, direct /releases/download/ URLs return 404 even with a token.
  # Resolve the asset via the GitHub API which redirects to a presigned download URL.
  if [[ -n "$GITHUB_TOKEN" ]]; then
    local tag filename api_url release_json asset_id
    tag="$(echo "$url" | sed 's|.*/download/\([^/]*\)/.*|\1|')"
    filename="$(basename "$url")"
    api_url="https://api.github.com/repos/${REPO}/releases/tags/${tag}"

    release_json="$(curl -fsSL \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      "$api_url")"

    if command -v jq >/dev/null 2>&1; then
      asset_id="$(echo "$release_json" | jq -r --arg name "$filename" '.assets[] | select(.name == $name) | .id' | head -1)"
    elif command -v python3 >/dev/null 2>&1; then
      asset_id="$(echo "$release_json" | python3 -c 'import json,sys; data=json.load(sys.stdin); name=sys.argv[1]; ids=[str(a.get("id")) for a in data.get("assets",[]) if a.get("name")==name]; print(ids[0] if ids else "")' "$filename")"
    else
      echo "Neither jq nor python3 is available to parse release assets" >&2
      return 1
    fi

    if [[ -z "$asset_id" || "$asset_id" == "null" ]]; then
      echo "Asset not found: ${filename} in release ${tag}" >&2
      return 1
    fi

    curl -fL \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H "Accept: application/octet-stream" \
      -o "$output" \
      "https://api.github.com/repos/${REPO}/releases/assets/${asset_id}"
  else
    curl -fL \
      -o "$output" \
      "$url"
  fi
}

generate_secret_value() {
  openssl rand -base64 32 | tr -d '\n'
}

generate_url_safe_secret_value() {
  # Hex keeps credentials URL-safe without requiring percent-encoding.
  openssl rand -hex 24 | tr -d '\n'
}

get_secret_key_value() {
  local secret_name="$1"
  local key_name="$2"
  local encoded

  encoded="$(kubectl -n "$NAMESPACE" get secret "$secret_name" -o "jsonpath={.data.${key_name}}" 2>/dev/null || true)"
  if [[ -z "$encoded" ]]; then
    return 1
  fi

  printf '%s' "$encoded" | base64 --decode
}

url_encode_component() {
  local value="$1"

  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$value"
    return 0
  fi

  if command -v jq >/dev/null 2>&1; then
    jq -rn --arg v "$value" '$v|@uri'
    return 0
  fi

  # Fallback when neither python3 nor jq is present.
  printf '%s' "$value"
}

create_ghcr_pull_secret() {
  local github_user="$GHCR_USERNAME"
  local ghcr_token_effective="$GHCR_TOKEN"
  local user_api="https://api.github.com/user"

  if [[ -z "$ghcr_token_effective" ]]; then
    ghcr_token_effective="$GITHUB_TOKEN"
  fi

  if [[ -z "$ghcr_token_effective" ]]; then
    echo "GHCR token is required for private image pulls (--ghcr-token or --github-token)" >&2
    return 1
  fi

  if [[ -z "$github_user" ]]; then
    if command -v jq >/dev/null 2>&1; then
      github_user="$(curl -fsSL \
        -H "Authorization: Bearer ${ghcr_token_effective}" \
        -H "Accept: application/vnd.github+json" \
        "$user_api" | jq -r '.login')"
    elif command -v python3 >/dev/null 2>&1; then
      github_user="$(curl -fsSL \
        -H "Authorization: Bearer ${ghcr_token_effective}" \
        -H "Accept: application/vnd.github+json" \
        "$user_api" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("login", ""))')"
    else
      echo "Neither jq nor python3 is available to resolve GitHub username" >&2
      return 1
    fi
  fi

  if [[ -z "$github_user" || "$github_user" == "null" ]]; then
    echo "Failed to resolve GitHub username from token; pass --ghcr-username explicitly" >&2
    return 1
  fi

  GHCR_USERNAME="$github_user"
  GHCR_TOKEN="$ghcr_token_effective"

  echo "Creating/updating GHCR image pull secret: ${GHCR_PULL_SECRET}"
  kubectl -n "$NAMESPACE" create secret docker-registry "$GHCR_PULL_SECRET" \
    --docker-server=ghcr.io \
    --docker-username="$github_user" \
    --docker-password="$ghcr_token_effective" \
    --docker-email="none@example.com" \
    --dry-run=client -o yaml | kubectl apply -f -
}

validate_ghcr_access() {
  local image_repo="weave-hq/loom/api"
  local image="ghcr.io/${image_repo}:v${VERSION}"
  local token_url="https://ghcr.io/token?scope=repository:${image_repo}:pull&service=ghcr.io"
  local manifest_url="https://ghcr.io/v2/${image_repo}/manifests/v${VERSION}"
  local registry_token=""
  local status

  if command -v jq >/dev/null 2>&1; then
    registry_token="$(curl -fsSL \
      -u "${GHCR_USERNAME}:${GHCR_TOKEN}" \
      "$token_url" | jq -r '.token // empty')"
  elif command -v python3 >/dev/null 2>&1; then
    registry_token="$(curl -fsSL \
      -u "${GHCR_USERNAME}:${GHCR_TOKEN}" \
      "$token_url" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("token", ""))')"
  else
    echo "Neither jq nor python3 is available to parse GHCR token response" >&2
    return 1
  fi

  if [[ -z "$registry_token" || "$registry_token" == "null" ]]; then
    echo "GHCR auth challenge failed for ${image}" >&2
    echo "Use a token with read:packages (and repo access for private packages)." >&2
    echo "If your org enforces SSO, authorize the token for the org." >&2
    return 1
  fi

  status="$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer ${registry_token}" \
    -H "Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json" \
    "$manifest_url")"

  if [[ "$status" != "200" ]]; then
    echo "GHCR manifest check failed for ${image} (HTTP ${status})" >&2
    echo "If status is 404, confirm the image tag was pushed by the release workflow." >&2
    echo "If status is 401/403, verify token scopes and SSO authorization." >&2
    return 1
  fi
}

create_platform_secrets() {
  echo "Creating namespace and secrets"

  kubectl create namespace "$NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -

  # Generate passwords once so they're consistent across all secrets
  local pg_password redis_password
  pg_password=""
  redis_password=""

  # Create or skip postgres secret
  if kubectl -n "$NAMESPACE" get secret loom-postgres-secret >/dev/null 2>&1; then
    echo "loom-postgres-secret already exists"

    pg_password="$(get_secret_key_value loom-postgres-secret postgres-password || true)"
    if [[ -z "$pg_password" ]]; then
      pg_password="$(get_secret_key_value loom-postgres-secret password || true)"
    fi

    if [[ -z "$pg_password" ]]; then
      echo "Failed to read postgres password from loom-postgres-secret" >&2
      return 1
    fi
  else
    pg_password="$(generate_url_safe_secret_value)"
    echo "Creating loom-postgres-secret"
    kubectl -n "$NAMESPACE" create secret generic loom-postgres-secret \
      --from-literal=postgres-password="$pg_password" \
      --from-literal=password="$pg_password"
  fi

  # Create or skip redis secret
  if kubectl -n "$NAMESPACE" get secret loom-redis-secret >/dev/null 2>&1; then
    echo "loom-redis-secret already exists"

    redis_password="$(get_secret_key_value loom-redis-secret redis-password || true)"
    if [[ -z "$redis_password" ]]; then
      echo "Failed to read redis password from loom-redis-secret" >&2
      return 1
    fi
  else
    redis_password="$(generate_url_safe_secret_value)"
    echo "Creating loom-redis-secret"
    kubectl -n "$NAMESPACE" create secret generic loom-redis-secret \
      --from-literal=redis-password="$redis_password"
  fi

  # Reconcile platform URL values to keep DATABASE_URL/REDIS_URL valid even if
  # existing credentials include reserved URL characters.
  local pg_password_encoded redis_password_encoded database_url redis_url session_redis_url
  pg_password_encoded="$(url_encode_component "$pg_password")"
  redis_password_encoded="$(url_encode_component "$redis_password")"
  database_url="postgresql://loomai:${pg_password_encoded}@postgres:5432/loomai"
  redis_url="redis://:${redis_password_encoded}@redis-master:6379"
  session_redis_url="redis://:${redis_password_encoded}@redis-master:6379/0"

  if kubectl -n "$NAMESPACE" get secret loom-platform-secrets >/dev/null 2>&1; then
    echo "loom-platform-secrets already exists"

    kubectl -n "$NAMESPACE" patch secret loom-platform-secrets \
      --type merge \
      -p "{\"stringData\":{\"DATABASE_URL\":\"${database_url}\",\"REDIS_URL\":\"${redis_url}\",\"LOOM_SESSION_REDIS_URL\":\"${session_redis_url}\"}}" >/dev/null

    echo "Reconciled DATABASE_URL and REDIS_URL in loom-platform-secrets"
  else
    echo "Creating loom-platform-secrets"
    kubectl -n "$NAMESPACE" create secret generic loom-platform-secrets \
      --from-literal=SESSION_SECRET="$(generate_secret_value)" \
      --from-literal=CONTROL_PLANE_INTERNAL_KEY="$(generate_secret_value)" \
      --from-literal=DATABASE_URL="$database_url" \
      --from-literal=REDIS_URL="$redis_url" \
      --from-literal=LOOM_SESSION_REDIS_URL="$session_redis_url"
  fi

  create_ghcr_pull_secret
}

install_or_upgrade_loom() {
  if [[ -z "$VERSION" ]]; then
    echo "--version is required"
    exit 1
  fi

  require_github_token
  validate_ghcr_access
  resolve_ingress_class
  resolve_kafka_topology_overrides

  local tmp_dir
  tmp_dir="$(mktemp -d)" || {
    echo "Failed to create temporary directory"
    exit 1
  }
  trap "rm -rf '$tmp_dir'" EXIT

  local base_url="https://github.com/${REPO}/releases/download/v${VERSION}"
  local chart_file="${tmp_dir}/loom-${VERSION}.tgz"
  local values_file="${tmp_dir}/values-v${VERSION}.yaml"

  echo "Downloading Loom release v${VERSION}"

  download_asset "${base_url}/loom-${VERSION}.tgz" "$chart_file" || {
    echo "Failed to download chart from: ${base_url}/loom-${VERSION}.tgz"
    echo "Ensure the release v${VERSION} has been published on GitHub"
    exit 1
  }

  download_asset "${base_url}/values-v${VERSION}.yaml" "$values_file" || {
    echo "Failed to download values from: ${base_url}/values-v${VERSION}.yaml"
    exit 1
  }

  echo "Installing/upgrading Loom v${VERSION}"

  helm upgrade --install "$RELEASE_NAME" "$chart_file" \
    --namespace "$NAMESPACE" \
    --create-namespace \
    -f "$values_file" \
    --set ingress.className="$INGRESS_CLASS" \
    --set redpanda.statefulset.replicas="$KAFKA_REPLICAS" \
    --set redpanda.statefulset.podAntiAffinity.type="$KAFKA_ANTI_AFFINITY" \
    --set imagePullSecrets[0].name="$GHCR_PULL_SECRET" \
    --set secrets.create=false \
    --set secrets.existingSecret=loom-platform-secrets \
    --set postgresql.auth.existingSecret=loom-postgres-secret \
    --set redis.auth.enabled=true \
    --set redis.auth.existingSecret=loom-redis-secret \
    --set redis.auth.existingSecretPasswordKey=redis-password \
    --wait \
    --timeout 10m
}

wipe_loom() {
  echo "Uninstalling Loom Helm release"

  helm uninstall "$RELEASE_NAME" \
    --namespace "$NAMESPACE" || true

  if [[ "$PURGE_DATA" == "true" ]]; then
    echo "Purging Loom data and secrets"

    kubectl -n "$NAMESPACE" delete pvc --all || true
    kubectl -n "$NAMESPACE" delete secret loom-platform-secrets || true
    kubectl -n "$NAMESPACE" delete secret loom-postgres-secret || true
    kubectl -n "$NAMESPACE" delete secret loom-redis-secret || true
    kubectl delete namespace "$NAMESPACE" || true
  else
    echo "Kept namespace, PVCs and secrets"
    echo "Use --purge-data to delete persistent data"
  fi
}

status_loom() {
  helm status "$RELEASE_NAME" --namespace "$NAMESPACE" || true
  kubectl -n "$NAMESPACE" get pods || true
}

case "$COMMAND" in
  install)
    require_root
    install_k3s
    configure_kubeconfig
    install_helm
    ensure_cert_manager
    create_platform_secrets
    install_or_upgrade_loom
    status_loom
    ;;

  upgrade)
    configure_kubeconfig
    install_helm
    ensure_cert_manager
    create_platform_secrets
    install_or_upgrade_loom
    status_loom
    ;;

  wipe)
    configure_kubeconfig
    wipe_loom
    ;;

  status)
    configure_kubeconfig
    status_loom
    ;;

  *)
    usage
    exit 1
    ;;
esac

