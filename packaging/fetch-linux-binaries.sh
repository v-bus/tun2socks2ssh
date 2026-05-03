#!/usr/bin/env bash
set -euo pipefail

# Downloads tun2socks and gost release binaries into BUILD_DIR (no sudo).

TUN2SOCKS_VERSION="${TUN2SOCKS_VERSION:-v2.6.0}"
GOST_VERSION="${GOST_VERSION:-v3.2.6}"
BUILD_DIR="${BUILD_DIR:-$(cd "$(dirname "$0")/.." && pwd)/build/binaries}"

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "This fetch script is intended to run on Linux (same arch as target)." >&2
  exit 1
fi

mkdir -p "$BUILD_DIR"

arch="$(uname -m)"
case "$arch" in
  x86_64) tun_asset="tun2socks-linux-amd64.zip" ; gost_asset="gost_${GOST_VERSION#v}_linux_amd64.tar.gz" ;;
  aarch64 | arm64) tun_asset="tun2socks-linux-arm64.zip" ; gost_asset="gost_${GOST_VERSION#v}_linux_arm64.tar.gz" ;;
  *) echo "Unsupported architecture: $arch" >&2; exit 1 ;;
esac

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

tun_url="https://github.com/xjasonlyu/tun2socks/releases/download/${TUN2SOCKS_VERSION}/${tun_asset}"
curl -L --fail -o "$tmpdir/tun2socks.zip" "$tun_url"
unzip -q "$tmpdir/tun2socks.zip" -d "$tmpdir/tun-extract"

tun_bin="$(find "$tmpdir/tun-extract" -type f \( -name 'tun2socks' -o -name 'tun2socks-*' \) | head -n 1 || true)"
if [[ -z "$tun_bin" ]]; then
  echo "tun2socks binary not found in zip" >&2
  exit 1
fi

gost_url="https://github.com/go-gost/gost/releases/download/${GOST_VERSION}/${gost_asset}"
curl -L --fail -o "$tmpdir/gost.tgz" "$gost_url"
tar -xzf "$tmpdir/gost.tgz" -C "$tmpdir"

gost_bin="$(find "$tmpdir" -type f -name 'gost' | head -n 1 || true)"
if [[ -z "$gost_bin" ]]; then
  echo "gost binary not found in tarball" >&2
  exit 1
fi

install -m 0755 "$tun_bin" "$BUILD_DIR/tun2socks"
install -m 0755 "$gost_bin" "$BUILD_DIR/gost"

echo "Wrote $BUILD_DIR/tun2socks and $BUILD_DIR/gost"
