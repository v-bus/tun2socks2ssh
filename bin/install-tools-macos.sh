#!/usr/bin/env bash
set -euo pipefail

# Installs tun2socks and gost on macOS.
# - gost: Homebrew formula
# - tun2socks: GitHub release binary, because Homebrew availability varies

TUN2SOCKS_VERSION="${TUN2SOCKS_VERSION:-v2.6.0}"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This installer is for macOS only." >&2
  exit 1
fi

if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew is required for gost. Install Homebrew first: https://brew.sh" >&2
  exit 1
fi

echo "Installing gost via Homebrew..."
brew install gost || brew upgrade gost || true

arch="$(uname -m)"
case "$arch" in
  arm64) asset="tun2socks-darwin-arm64.zip" ;;
  x86_64) asset="tun2socks-darwin-amd64.zip" ;;
  *) echo "Unsupported macOS architecture: $arch" >&2; exit 1 ;;
esac

url="https://github.com/xjasonlyu/tun2socks/releases/download/${TUN2SOCKS_VERSION}/${asset}"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

echo "Downloading tun2socks from $url"
curl -L --fail -o "$tmpdir/tun2socks.zip" "$url"
unzip -q "$tmpdir/tun2socks.zip" -d "$tmpdir"

bin="$(find "$tmpdir" -type f -name 'tun2socks*' -perm +111 | head -n 1 || true)"
if [[ -z "$bin" ]]; then
  bin="$(find "$tmpdir" -type f -name 'tun2socks*' | head -n 1 || true)"
fi
if [[ -z "$bin" ]]; then
  echo "Cannot find tun2socks binary in downloaded archive" >&2
  exit 1
fi

sudo install -m 0755 "$bin" "$INSTALL_DIR/tun2socks"

echo "Installed:"
command -v gost && gost -V || true
command -v tun2socks && tun2socks --version || true
