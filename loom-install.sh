#!/usr/bin/env bash
set -euo pipefail

REPO="weave-hq/loom-core"
RELEASE_NAME="loom"
NAMESPACE="loom"
VERSION=""
COMMAND="${1:-}"

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
  --purge-data             Delete PVCs/secrets/namespace during wipe
EOF
}

shift || true

GITHUB_TOKEN="${GITHUB_TOKEN:-}"
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

  echo "Waiting for Kubernetes node"
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

download_asset() {
  local url="$1"
  local output="$2"

  if [[ -n "$GITHUB_TOKEN" ]]; then
    curl -fL \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -o "$output" \
      "$url"
  else
    curl -fL \
      -o "$output" \
      "$url"
  fi
}

generate_secret_value() {
  openssl rand -base64 32 | tr -d '\n'
}

create_platform_secrets() {
  echo "Creating namespace and secrets"

  kubectl create namespace "$NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -

  # Generate passwords once so they're consistent across all secrets
  local pg_password redis_password
  pg_password="$(generate_secret_value)"
  redis_password="$(generate_secret_value)"

  # Create or skip postgres secret
  if kubectl -n "$NAMESPACE" get secret loom-postgres-secret >/dev/null 2>&1; then
    echo "loom-postgres-secret already exists"
  else
    echo "Creating loom-postgres-secret"
    kubectl -n "$NAMESPACE" create secret generic loom-postgres-secret \
      --from-literal=postgres-password="$pg_password" \
      --from-literal=password="$pg_password"
  fi

  # Create or skip redis secret
  if kubectl -n "$NAMESPACE" get secret loom-redis-secret >/dev/null 2>&1; then
    echo "loom-redis-secret already exists"
  else
    echo "Creating loom-redis-secret"
    kubectl -n "$NAMESPACE" create secret generic loom-redis-secret \
      --from-literal=redis-password="$redis_password"
  fi

  # Create or skip platform secret
  # This secret contains all credentials needed by services: SESSION_SECRET,
  # CONTROL_PLANE_INTERNAL_KEY, DATABASE_URL (with coordinated pg_password),
  # REDIS_URL and LOOM_SESSION_REDIS_URL (with coordinated redis_password).
  if kubectl -n "$NAMESPACE" get secret loom-platform-secrets >/dev/null 2>&1; then
    echo "loom-platform-secrets already exists"
  else
    echo "Creating loom-platform-secrets"
    kubectl -n "$NAMESPACE" create secret generic loom-platform-secrets \
      --from-literal=SESSION_SECRET="$(generate_secret_value)" \
      --from-literal=CONTROL_PLANE_INTERNAL_KEY="$(generate_secret_value)" \
      --from-literal=DATABASE_URL="postgresql://loomai:${pg_password}@postgres:5432/loomai" \
      --from-literal=REDIS_URL="redis://:${redis_password}@redis-master:6379" \
      --from-literal=LOOM_SESSION_REDIS_URL="redis://:${redis_password}@redis-master:6379/0"
  fi
}

install_or_upgrade_loom() {
  if [[ -z "$VERSION" ]]; then
    echo "--version is required"
    exit 1
  fi

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT

  local base_url="https://github.com/${REPO}/releases/download/v${VERSION}"
  local chart_file="${tmp_dir}/loom-${VERSION}.tgz"
  local values_file="${tmp_dir}/values-v${VERSION}.yaml"

  echo "Downloading Loom release v${VERSION}"

  download_asset "${base_url}/loom-${VERSION}.tgz" "$chart_file"
  download_asset "${base_url}/values-v${VERSION}.yaml" "$values_file"

  echo "Installing/upgrading Loom v${VERSION}"

  helm upgrade --install "$RELEASE_NAME" "$chart_file" \
    --namespace "$NAMESPACE" \
    --create-namespace \
    -f "$values_file" \
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
    create_platform_secrets
    install_or_upgrade_loom
    status_loom
    ;;

  upgrade)
    configure_kubeconfig
    install_helm
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
