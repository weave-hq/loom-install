#!/usr/bin/env bash
set -euo pipefail

REPO="weave-hq/loom-install"
BIN_NAME="loom"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
VERSION="${VERSION:-latest}"
LIB_DIR="${LIB_DIR:-/usr/local/lib/${BIN_NAME}}"

detect_os() {
  case "$(uname -s)" in
    Linux*) echo "linux" ;;
    Darwin*) echo "darwin" ;;
    *) echo "Unsupported OS: $(uname -s)" >&2; exit 1 ;;
  esac
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    arm64|aarch64) echo "arm64" ;;
    *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
  esac
}

OS="$(detect_os)"
ARCH="$(detect_arch)"

download_url_exists() {
  local url="$1"
  local code
  code="$(curl -s -o /dev/null -w "%{http_code}" -L "$url")"
  [ "$code" = "200" ]
}

resolve_release_tag() {
  if [ "$VERSION" = "latest" ]; then
    local latest_url
    latest_url="$(curl -fsSL -o /dev/null -w "%{url_effective}" "https://github.com/${REPO}/releases/latest")"
    if [ -z "$latest_url" ]; then
      echo "Failed to resolve latest release for ${REPO}" >&2
      exit 1
    fi
    echo "${latest_url##*/}"
    return
  fi

  if [[ "$VERSION" =~ ^cli-v[0-9] ]]; then
    echo "$VERSION"
    return
  fi

  if [[ "$VERSION" =~ ^v[0-9] ]]; then
    echo "$VERSION"
    return
  fi

  echo "cli-v${VERSION}"
}

resolve_semver_from_tag() {
  local tag="$1"
  case "$tag" in
    cli-v*) echo "${tag#cli-v}" ;;
    v*) echo "${tag#v}" ;;
    *) echo "$tag" ;;
  esac
}

install_file() {
  local source="$1"
  local destination="$2"
  if [ -w "$(dirname "$destination")" ]; then
    mv "$source" "$destination"
  else
    sudo mv "$source" "$destination"
  fi
}

ensure_dir() {
  local dir="$1"
  if [ -d "$dir" ] && [ -w "$dir" ]; then
    return
  fi
  if [ -w "$(dirname "$dir")" ]; then
    mkdir -p "$dir"
  else
    sudo mkdir -p "$dir"
  fi
}

RELEASE_TAG="$(resolve_release_tag)"
SEMVER="$(resolve_semver_from_tag "$RELEASE_TAG")"

BINARY_URL="https://github.com/${REPO}/releases/download/${RELEASE_TAG}/${BIN_NAME}-${OS}-${ARCH}"
TARBALL_URL="https://github.com/${REPO}/releases/download/${RELEASE_TAG}/loom-cli-${SEMVER}.tar.gz"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Installing ${BIN_NAME} for ${OS}/${ARCH} (release: ${RELEASE_TAG})..."

ensure_dir "$INSTALL_DIR"

if download_url_exists "$BINARY_URL"; then
  curl -fsSL "$BINARY_URL" -o "$TMP/$BIN_NAME"
  chmod +x "$TMP/$BIN_NAME"
  install_file "$TMP/$BIN_NAME" "$INSTALL_DIR/$BIN_NAME"
  echo "Installed binary from ${BINARY_URL}"
  echo "Installed:"
  "$INSTALL_DIR/$BIN_NAME" --version || true
  exit 0
fi

if ! download_url_exists "$TARBALL_URL"; then
  echo "No supported release asset found for ${RELEASE_TAG}." >&2
  echo "Checked: ${BINARY_URL}" >&2
  echo "Checked: ${TARBALL_URL}" >&2
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  echo "node is required to install CLI tarball releases" >&2
  exit 1
fi

curl -fsSL "$TARBALL_URL" -o "$TMP/loom-cli.tar.gz"
tar -xzf "$TMP/loom-cli.tar.gz" -C "$TMP"

PKG_DIR="$(find "$TMP" -mindepth 1 -maxdepth 1 -type d -name "loom-cli-*" | head -n 1)"
if [ -z "$PKG_DIR" ] || [ ! -f "$PKG_DIR/dist/main.js" ]; then
  echo "Invalid CLI tarball format from ${TARBALL_URL}" >&2
  exit 1
fi

TARGET_DIR="${LIB_DIR}/${SEMVER}"
ensure_dir "$(dirname "$TARGET_DIR")"
if [ -w "$(dirname "$TARGET_DIR")" ]; then
  rm -rf "$TARGET_DIR"
  cp -R "$PKG_DIR" "$TARGET_DIR"
else
  sudo rm -rf "$TARGET_DIR"
  sudo cp -R "$PKG_DIR" "$TARGET_DIR"
fi

cat > "$TMP/$BIN_NAME" <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec node "${TARGET_DIR}/dist/main.js" "\$@"
EOF
chmod +x "$TMP/$BIN_NAME"
install_file "$TMP/$BIN_NAME" "$INSTALL_DIR/$BIN_NAME"

echo "Installed tarball from ${TARBALL_URL}"
echo "Installed launcher: ${INSTALL_DIR}/${BIN_NAME}"
echo "Package location: ${TARGET_DIR}"
echo "Installed package version: ${SEMVER}"

if ! "${INSTALL_DIR}/${BIN_NAME}" --version >/dev/null 2>&1; then
  echo "Warning: installed tarball is not currently self-contained and may require additional runtime dependencies in the release artifact." >&2
fi
