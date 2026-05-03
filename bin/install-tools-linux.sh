#!/usr/bin/env bash
set -euo pipefail

# Installs tun2socks and gost on Linux from GitHub releases.

TUN2SOCKS_VERSION="${TUN2SOCKS_VERSION:-v2.6.0}"
GOST_VERSION="${GOST_VERSION:-v3.2.6}"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "This installer is for Linux only." >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required" >&2
  exit 1
fi

arch="$(uname -m)"
case "$arch" in
  x86_64) tun_asset="tun2socks-linux-amd64.zip" ; gost_asset="gost_${GOST_VERSION#v}_linux_amd64.tar.gz" ;;
  aarch64 | arm64) tun_asset="tun2socks-linux-arm64.zip" ; gost_asset="gost_${GOST_VERSION#v}_linux_arm64.tar.gz" ;;
  *) echo "Unsupported Linux architecture: $arch" >&2; exit 1 ;;
esac

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

tun_url="https://github.com/xjasonlyu/tun2socks/releases/download/${TUN2SOCKS_VERSION}/${tun_asset}"
echo "Downloading tun2socks from $tun_url"
curl -L --fail -o "$tmpdir/tun2socks.zip" "$tun_url"
unzip -q "$tmpdir/tun2socks.zip" -d "$tmpdir/tun2socks-extract"

tun_bin="$(find "$tmpdir/tun2socks-extract" -type f \( -name 'tun2socks' -o -name 'tun2socks-*' \) | head -n 1 || true)"
if [[ -z "$tun_bin" ]]; then
  echo "Cannot find tun2socks binary in downloaded archive" >&2
  exit 1
fi

gost_url="https://github.com/go-gost/gost/releases/download/${GOST_VERSION}/${gost_asset}"
echo "Downloading gost from $gost_url"
curl -L --fail -o "$tmpdir/gost.tgz" "$gost_url"
tar -xzf "$tmpdir/gost.tgz" -C "$tmpdir"

gost_bin="$(find "$tmpdir" -type f -name 'gost' | head -n 1 || true)"
if [[ -z "$gost_bin" ]]; then
  echo "Cannot find gost binary in downloaded archive" >&2
  exit 1
fi

sudo install -m 0755 "$tun_bin" "$INSTALL_DIR/tun2socks"
sudo install -m 0755 "$gost_bin" "$INSTALL_DIR/gost"

echo "Installed:"
command -v gost && gost -V || true
command -v tun2socks && tun2socks --version || true
