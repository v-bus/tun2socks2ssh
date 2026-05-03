PREFIX ?= /usr/local
SBINDIR = $(PREFIX)/sbin
BINDIR = $(PREFIX)/bin
ETCDIR = $(PREFIX)/etc
TUN2SOCKS_SRC ?= $(abspath ../tun2socks)
TUN2SOCKS_VERSION ?= v2.6.0
GOST_VERSION ?= v3.2.6
DEB_VERSION ?= 0.1.0
DEB_ARCH ?= $(shell dpkg-architecture -qDEB_HOST_ARCH 2>/dev/null || uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
BIN_SRC ?= $(CURDIR)/build/binaries

.PHONY: install-linux install-systemd fetch-linux-binaries build-tun2socks deb check clean

install-linux:
	install -d $(DESTDIR)$(SBINDIR) $(DESTDIR)$(BINDIR) $(DESTDIR)$(ETCDIR)
	install -m 0755 bin/start-tun2socks.sh $(DESTDIR)$(SBINDIR)/start-tun2socks.sh
	install -m 0755 bin/stop-tun2socks.sh $(DESTDIR)$(SBINDIR)/stop-tun2socks.sh
	install -m 0755 bin/tun2socks-routeguard.sh $(DESTDIR)$(SBINDIR)/tun2socks-routeguard.sh
	install -m 0755 bin/install-tools-linux.sh $(DESTDIR)$(SBINDIR)/install-tools-linux.sh
	install -m 0644 config/tun2socks.conf.linux.example $(DESTDIR)$(ETCDIR)/tun2socks.conf.example

install-systemd:
	install -d $(DESTDIR)/etc/systemd/system
	install -m 0644 systemd/tun2socks-routeguard.service $(DESTDIR)/etc/systemd/system/tun2socks-routeguard.service

fetch-linux-binaries:
	TUN2SOCKS_VERSION=$(TUN2SOCKS_VERSION) GOST_VERSION=$(GOST_VERSION) \
	  BUILD_DIR=$(BIN_SRC) ./packaging/fetch-linux-binaries.sh

build-tun2socks:
	test -d "$(TUN2SOCKS_SRC)" || (echo "Clone tun2socks into $(TUN2SOCKS_SRC) or set TUN2SOCKS_SRC=" >&2; exit 1)
	mkdir -p build "$(BIN_SRC)"
	cd "$(TUN2SOCKS_SRC)" && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o "$(CURDIR)/build/tun2socks" .
	install -m 0755 build/tun2socks "$(BIN_SRC)/tun2socks"
	@echo "Built $(CURDIR)/build/tun2socks and copied to $(BIN_SRC)/tun2socks"

deb: fetch-linux-binaries
	DEB_VERSION=$(DEB_VERSION) DEB_ARCH=$(DEB_ARCH) BIN_SRC=$(BIN_SRC) ./packaging/build-deb.sh

deb-only:
	DEB_VERSION=$(DEB_VERSION) DEB_ARCH=$(DEB_ARCH) BIN_SRC=$(BIN_SRC) ./packaging/build-deb.sh

check:
	@set -e; for f in bin/*.sh packaging/*.sh; do echo "bash -n $$f"; bash -n "$$f"; done
	@echo OK

clean:
	rm -rf build/binaries build/deb-stage
