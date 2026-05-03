#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${DEB_VERSION:-0.1.0}"
ARCH="${DEB_ARCH:-amd64}"

case "$ARCH" in
  amd64) GHOST_ARCH=x86_64 ;;
  arm64) GHOST_ARCH=aarch64 ;;
  *) echo "Set DEB_ARCH to amd64 or arm64 (got $ARCH)" >&2; exit 1 ;;
esac

if [[ "$(uname -m)" != "$GHOST_ARCH" ]]; then
  echo "WARN: building on $(uname -m) for $ARCH - fetch-linux-binaries must match target arch." >&2
  echo "Run this script on the target architecture or set BUILD_DIR binaries manually." >&2
fi

BIN_SRC="${BIN_SRC:-$ROOT/build/binaries}"
if [[ ! -f "$BIN_SRC/tun2socks" || ! -f "$BIN_SRC/gost" ]]; then
  echo "Missing binaries in $BIN_SRC. Run: make fetch-linux-binaries" >&2
  exit 1
fi

STAGE="$ROOT/build/deb-stage"
PKG="tun2socks-ssh-stack_${VERSION}_${ARCH}"
OUT="$ROOT/build/${PKG}.deb"
rm -rf "$STAGE"
mkdir -p "$STAGE/DEBIAN" \
  "$STAGE/usr/local/bin" \
  "$STAGE/usr/local/sbin" \
  "$STAGE/usr/local/etc" \
  "$STAGE/usr/lib/systemd/system"

sed -e "s/DEB_VERSION_PLACEHOLDER/$VERSION/" \
  -e "s/ARCH_PLACEHOLDER/$ARCH/" \
  "$ROOT/packaging/debian/control" > "$STAGE/DEBIAN/control"

install -m 0755 "$BIN_SRC/tun2socks" "$STAGE/usr/local/bin/tun2socks"
install -m 0755 "$BIN_SRC/gost" "$STAGE/usr/local/bin/gost"

for s in start-tun2socks.sh stop-tun2socks.sh tun2socks-routeguard.sh install-tools-linux.sh; do
  install -m 0755 "$ROOT/bin/$s" "$STAGE/usr/local/sbin/$s"
done

install -m 0644 "$ROOT/systemd/tun2socks-routeguard.service" \
  "$STAGE/usr/lib/systemd/system/tun2socks-routeguard.service"

install -m 0644 "$ROOT/config/tun2socks.conf.linux.example" \
  "$STAGE/usr/local/etc/tun2socks.conf.example"

cat > "$STAGE/DEBIAN/postinst" <<'EOS'
#!/bin/sh
set -e
systemctl daemon-reload >/dev/null 2>&1 || true
exit 0
EOS
chmod 0755 "$STAGE/DEBIAN/postinst"

cat > "$STAGE/DEBIAN/prerm" <<'EOS'
#!/bin/sh
set -e
if [ "$1" = "remove" ] || [ "$1" = "deconfigure" ]; then
  systemctl stop tun2socks-routeguard.service >/dev/null 2>&1 || true
  systemctl disable tun2socks-routeguard.service >/dev/null 2>&1 || true
fi
exit 0
EOS
chmod 0755 "$STAGE/DEBIAN/prerm"

mkdir -p "$(dirname "$OUT")"
dpkg-deb --root-owner-group --build "$STAGE" "$OUT"
echo "Built $OUT"
ls -la "$OUT"
