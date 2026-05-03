#!/usr/bin/env bash
set -euo pipefail

OS="$(uname -s)"
CONFIG="${TUN2SOCKS_CONFIG:-/usr/local/etc/tun2socks.conf}"

if [[ ! -f "$CONFIG" ]]; then
  echo "Config not found: $CONFIG" >&2
  echo "Copy config/tun2socks.conf.example (or config/tun2socks.conf.linux.example on Linux) to /usr/local/etc/tun2socks.conf and edit it." >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG"

: "${REAL_IF:?}"
: "${SSH_USER:?}"
: "${SSH_HOST:?}"
: "${SSH_IP:?}"
: "${SSH_PORT:=22}"
: "${SSH_IDENTITY_FILE:=}"
: "${SSH_IDENTITIES_ONLY:=yes}"
: "${SSH_TUNNELS_COUNT:=10}"
: "${SOCKS_HOST:=127.0.0.1}"
: "${SOCKS_BASE_PORT:=1080}"
: "${SOCKS_BALANCER_PORT:=1090}"
: "${GOST_STRATEGY:=round}"
: "${GOST_MAX_FAILS:=1}"
: "${GOST_FAIL_TIMEOUT:=10s}"
case "$OS" in
  Linux)
    : "${TUN_IF:=tun0}"
    ;;
  *)
    : "${TUN_IF:=utun123}"
    ;;
esac
: "${TUN_GW:=198.18.0.1}"
: "${TUN_MTU:=1400}"
: "${ROUTE_MODE:=default}"
case "$OS" in
  Linux)
    : "${RUNTIME_DIR:=/var/run/tun2socks}"
    ;;
  *)
    : "${RUNTIME_DIR:=/var/run/tun2socks-macos}"
    ;;
esac

SSH_PID_DIR="$RUNTIME_DIR/ssh"
GOST_PID_FILE="$RUNTIME_DIR/gost.pid"
TUN2SOCKS_PID_FILE="$RUNTIME_DIR/tun2socks.pid"
STATE_FILE="$RUNTIME_DIR/state.env"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: command not found: $1" >&2
    exit 1
  fi
}

if [[ "${EUID}" -ne 0 ]]; then
  echo "Re-running as root via sudo..."
  exec sudo TUN2SOCKS_CONFIG="$CONFIG" "$0" "$@"
fi

if [[ "$OS" == "Darwin" ]]; then
  require_cmd ssh
  require_cmd route
  require_cmd ifconfig
  require_cmd ipconfig
  require_cmd tun2socks
  require_cmd gost
  require_cmd networksetup
elif [[ "$OS" == "Linux" ]]; then
  require_cmd ssh
  require_cmd ip
  require_cmd tun2socks
  require_cmd gost
else
  echo "Unsupported OS: $OS (expected Darwin or Linux)" >&2
  exit 1
fi

mkdir -p "$RUNTIME_DIR" "$SSH_PID_DIR"
if [[ "$OS" == "Darwin" ]]; then
  chown root:wheel "$RUNTIME_DIR" "$SSH_PID_DIR"
else
  chown root:root "$RUNTIME_DIR" "$SSH_PID_DIR"
fi
chmod 755 "$RUNTIME_DIR" "$SSH_PID_DIR"

if [[ -n "$SSH_IDENTITY_FILE" && ! -f "$SSH_IDENTITY_FILE" ]]; then
  echo "ERROR: SSH identity file not found: $SSH_IDENTITY_FILE" >&2
  exit 1
fi

detect_real_gateway_darwin() {
  REAL_GW="$(ipconfig getoption "$REAL_IF" router 2>/dev/null | head -n 1 || true)"
  if [[ -z "$REAL_GW" ]]; then
    REAL_GW="$(route -n get default | awk '/gateway:/ {print $2; exit}')"
  fi
}

detect_real_gateway_linux() {
  REAL_GW="$(ip -4 route show dev "$REAL_IF" 2>/dev/null | awk '/default/ {print $3; exit}')"
  if [[ -z "$REAL_GW" ]]; then
    REAL_GW="$(ip -4 route show default 2>/dev/null | awk '/default/ {print $3; exit}')"
  fi
}

if [[ "$OS" == "Darwin" ]]; then
  detect_real_gateway_darwin
elif [[ "$OS" == "Linux" ]]; then
  detect_real_gateway_linux
fi

if [[ -z "$REAL_GW" ]]; then
  echo "ERROR: cannot detect real gateway for $REAL_IF" >&2
  exit 1
fi

cat > "$STATE_FILE" <<EOFSTATE
CONFIG="$CONFIG"
REAL_IF="$REAL_IF"
REAL_GW="$REAL_GW"
SSH_IP="$SSH_IP"
TUN_IF="$TUN_IF"
TUN_GW="$TUN_GW"
TUN_MTU="$TUN_MTU"
ROUTE_MODE="$ROUTE_MODE"
SOCKS_HOST="$SOCKS_HOST"
SOCKS_BALANCER_PORT="$SOCKS_BALANCER_PORT"
SSH_TUNNELS_COUNT="$SSH_TUNNELS_COUNT"
SOCKS_BASE_PORT="$SOCKS_BASE_PORT"
DNS_MANAGE="$DNS_MANAGE"
DNS_SERVICE_NAME="$DNS_SERVICE_NAME"
DNS_BACKUP_FILE="$DNS_BACKUP_FILE"
EOFSTATE

backup_dns() {
  if [[ "${DNS_MANAGE:-no}" != "yes" ]]; then
    return 0
  fi

  if [[ "$OS" == "Darwin" ]]; then
    echo "Backing up DNS for service: $DNS_SERVICE_NAME"
    networksetup -getdnsservers "$DNS_SERVICE_NAME" > "$DNS_BACKUP_FILE" 2>/dev/null || {
      echo "ERROR: cannot read DNS servers for service: $DNS_SERVICE_NAME" >&2
      exit 1
    }
  elif [[ "$OS" == "Linux" ]]; then
    if ! command -v resolvectl >/dev/null 2>&1; then
      echo "WARN: DNS_MANAGE=yes but resolvectl not found; skipping DNS changes" >&2
      return 0
    fi
    echo "Backing up DNS for link: $REAL_IF (resolvectl)"
    resolvectl dns "$REAL_IF" > "$DNS_BACKUP_FILE" 2>/dev/null || {
      echo "ERROR: cannot read DNS for interface: $REAL_IF" >&2
      exit 1
    }
  fi
}

set_cloudflare_dns() {
  if [[ "${DNS_MANAGE:-no}" != "yes" ]]; then
    return 0
  fi

  if [[ "$OS" == "Darwin" ]]; then
    echo "Setting Cloudflare DNS for service: $DNS_SERVICE_NAME -> ${DNS_SERVERS[*]}"
    networksetup -setdnsservers "$DNS_SERVICE_NAME" "${DNS_SERVERS[@]}"
  elif [[ "$OS" == "Linux" ]]; then
    if ! command -v resolvectl >/dev/null 2>&1; then
      return 0
    fi
    echo "Setting DNS for link $REAL_IF -> ${DNS_SERVERS[*]} (resolvectl)"
    resolvectl dns "$REAL_IF" "${DNS_SERVERS[@]}"
  fi
}

restore_dns_on_error() {
  if [[ "${DNS_MANAGE:-no}" != "yes" ]]; then
    return 0
  fi

  if [[ ! -f "$DNS_BACKUP_FILE" ]]; then
    return 0
  fi

  if [[ "$OS" == "Darwin" ]]; then
    if grep -q "There aren't any DNS Servers set" "$DNS_BACKUP_FILE"; then
      networksetup -setdnsservers "$DNS_SERVICE_NAME" Empty >/dev/null 2>&1 || true
    else
      mapfile -t old_dns < "$DNS_BACKUP_FILE"
      if [[ "${#old_dns[@]}" -gt 0 ]]; then
        networksetup -setdnsservers "$DNS_SERVICE_NAME" "${old_dns[@]}" >/dev/null 2>&1 || true
      fi
    fi
  elif [[ "$OS" == "Linux" ]]; then
    command -v resolvectl >/dev/null 2>&1 || return 0
    # Backup format is one line from resolvectl dns LINK
    if [[ ! -s "$DNS_BACKUP_FILE" ]]; then
      resolvectl revert "$REAL_IF" >/dev/null 2>&1 || true
      return 0
    fi
    # Try revert first (restores manager defaults)
    resolvectl revert "$REAL_IF" >/dev/null 2>&1 || true
  fi
}

add_ssh_route() {
  echo "Protecting SSH route: $SSH_IP -> $REAL_GW via $REAL_IF"
  if [[ "$OS" == "Darwin" ]]; then
    route delete -host "$SSH_IP" >/dev/null 2>&1 || true
    route add -host "$SSH_IP" "$REAL_GW"
  else
    ip route del "$SSH_IP/32" >/dev/null 2>&1 || true
    ip route replace "$SSH_IP/32" via "$REAL_GW" dev "$REAL_IF"
  fi
}

start_ssh_tunnels() {
  echo "Starting $SSH_TUNNELS_COUNT parallel ssh -D tunnels..."

  local i
  local port
  local pid
  local ssh_opts=()
  local listen_ok
  local attempt
  if [[ -n "${SSH_KNOWN_HOSTS_FILE:-}" ]]; then
    ssh_opts+=(
      -o "UserKnownHostsFile=$SSH_KNOWN_HOSTS_FILE"
    )
  fi

  if [[ -n "${SSH_STRICT_HOST_KEY_CHECKING:-}" ]]; then
    ssh_opts+=(
      -o "StrictHostKeyChecking=$SSH_STRICT_HOST_KEY_CHECKING"
    )
  fi

  if [[ -n "$SSH_IDENTITY_FILE" ]]; then
    ssh_opts+=(
      -i "$SSH_IDENTITY_FILE"
    )

    if [[ "$SSH_IDENTITIES_ONLY" == "yes" || "$SSH_IDENTITIES_ONLY" == "true" || "$SSH_IDENTITIES_ONLY" == "1" ]]; then
      ssh_opts+=(
        -o IdentitiesOnly=yes
      )
    fi
  fi

  rm -f "$SSH_PID_DIR"/ssh-*.pid >/dev/null 2>&1 || true

  for ((i = 0; i < SSH_TUNNELS_COUNT; i++)); do
    port=$((SOCKS_BASE_PORT + i))

    echo "  starting SOCKS $SOCKS_HOST:$port..."

    ssh \
      -f \
      -N \
      -D "$SOCKS_HOST:$port" \
      -p "$SSH_PORT" \
      "${ssh_opts[@]}" \
      -o ExitOnForwardFailure=yes \
      -o ServerAliveInterval=30 \
      -o ServerAliveCountMax=3 \
      -o BatchMode=yes \
      -l "$SSH_USER" \
      "$SSH_HOST"

    pid="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null | head -n 1 || true)"

    listen_ok="no"

    for attempt in {1..20}; do
      pid="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null | head -n 1 || true)"

      if [[ -n "$pid" ]] && ps -p "$pid" -o comm= 2>/dev/null | grep -q "ssh"; then
        listen_ok="yes"
        break
      fi

      sleep 0.25
    done

    if [[ "$listen_ok" != "yes" ]]; then
      echo "ERROR: ssh tunnel on port $port did not start or is not listening" >&2
      echo "Debug:" >&2
      echo "  lsof -nP -iTCP:$port -sTCP:LISTEN" >&2
      echo "  ssh -vvv -N -D $SOCKS_HOST:$port -p $SSH_PORT -i $SSH_IDENTITY_FILE -l $SSH_USER $SSH_HOST" >&2
      exit 1
    fi

    echo "$pid" > "$SSH_PID_DIR/ssh-$port.pid"
    echo "  SOCKS $SOCKS_HOST:$port PID=$pid"
  done

  echo "Checking all SSH SOCKS listeners..."

  for ((i = 0; i < SSH_TUNNELS_COUNT; i++)); do
    port=$((SOCKS_BASE_PORT + i))

    pid="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null | head -n 1 || true)"

    if [[ -z "$pid" ]]; then
      echo "ERROR: no listener on $SOCKS_HOST:$port" >&2
      exit 1
    fi

    if ! ps -p "$pid" -o comm= 2>/dev/null | grep -q "ssh"; then
      echo "ERROR: listener on $SOCKS_HOST:$port is not ssh, PID=$pid" >&2
      exit 1
    fi
  done

  echo "All SSH SOCKS tunnels are listening."
}

start_gost_balancer() {
  local forwarders=""
  local port
  local i
  local gost_pid

  echo "Starting GOST SOCKS balancer: $SOCKS_HOST:$SOCKS_BALANCER_PORT"

  for ((i = 0; i < SSH_TUNNELS_COUNT; i++)); do
    port=$((SOCKS_BASE_PORT + i))

    if [[ -n "$forwarders" ]]; then
      forwarders+=","
    fi

    forwarders+="socks5://$SOCKS_HOST:$port"

    echo "  upstream: socks5://$SOCKS_HOST:$port"
  done

  forwarders+="?strategy=$GOST_STRATEGY&maxFails=$GOST_MAX_FAILS&failTimeout=$GOST_FAIL_TIMEOUT"

  echo "GOST forwarders: $forwarders"

  gost \
    -L "socks5://$SOCKS_HOST:$SOCKS_BALANCER_PORT" \
    -F "$forwarders" &

  gost_pid=$!
  echo "$gost_pid" > "$GOST_PID_FILE"

  sleep 1

  if ! kill -0 "$gost_pid" >/dev/null 2>&1; then
    echo "ERROR: gost balancer failed" >&2
    exit 1
  fi
}

configure_tun_address_darwin() {
  ifconfig "$TUN_IF" "$TUN_GW" "$TUN_GW" up

  if [[ -n "$TUN_MTU" ]]; then
    ifconfig "$TUN_IF" mtu "$TUN_MTU" >/dev/null 2>&1 || true
  fi
}

configure_tun_address_linux() {
  ip link set "$TUN_IF" up 2>/dev/null || true
  ip addr flush dev "$TUN_IF" 2>/dev/null || true
  ip addr add "${TUN_GW}/32" dev "$TUN_IF"
  if [[ -n "$TUN_MTU" ]]; then
    ip link set dev "$TUN_IF" mtu "$TUN_MTU" 2>/dev/null || true
  fi
}

start_tun2socks() {
  echo "Starting tun2socks on $TUN_IF via GOST balancer $SOCKS_HOST:$SOCKS_BALANCER_PORT"

  tun2socks \
    -device "$TUN_IF" \
    -proxy "socks5://$SOCKS_HOST:$SOCKS_BALANCER_PORT" \
    -interface "$REAL_IF" &

  echo $! > "$TUN2SOCKS_PID_FILE"

  sleep 1

  if ! kill -0 "$(cat "$TUN2SOCKS_PID_FILE")" >/dev/null 2>&1; then
    echo "ERROR: tun2socks failed" >&2
    exit 1
  fi

  if [[ "$OS" == "Darwin" ]]; then
    configure_tun_address_darwin
  else
    configure_tun_address_linux
  fi
}

apply_routes_darwin() {
  add_ssh_route

  if [[ "$ROUTE_MODE" == "default" ]]; then
    echo "Changing default route to $TUN_GW"

    route change default "$TUN_GW" >/dev/null 2>&1 || {
      route delete default >/dev/null 2>&1 || true
      route add default "$TUN_GW"
    }
  else
    echo "Adding split-default routes through $TUN_GW"

    local routes=(
      "1.0.0.0/8"
      "2.0.0.0/7"
      "4.0.0.0/6"
      "8.0.0.0/5"
      "16.0.0.0/4"
      "32.0.0.0/3"
      "64.0.0.0/2"
      "128.0.0.0/1"
      "198.18.0.0/15"
    )

    local net

    for net in "${routes[@]}"; do
      route delete -net "$net" >/dev/null 2>&1 || true
      route add -net "$net" "$TUN_GW" >/dev/null 2>&1 || true
    done
  fi
}

apply_routes_linux() {
  add_ssh_route

  if [[ "$ROUTE_MODE" == "default" ]]; then
    echo "Changing default route to tunnel $TUN_IF"
    ip route replace default dev "$TUN_IF"
  else
    echo "Adding split-default routes through $TUN_IF"

    local routes=(
      "1.0.0.0/8"
      "2.0.0.0/7"
      "4.0.0.0/6"
      "8.0.0.0/5"
      "16.0.0.0/4"
      "32.0.0.0/3"
      "64.0.0.0/2"
      "128.0.0.0/1"
      "198.18.0.0/15"
    )

    local net

    for net in "${routes[@]}"; do
      ip route replace "$net" dev "$TUN_IF" >/dev/null 2>&1 || ip route add "$net" dev "$TUN_IF" >/dev/null 2>&1 || true
    done
  fi
}

apply_routes() {
  if [[ "$OS" == "Darwin" ]]; then
    apply_routes_darwin
  else
    apply_routes_linux
  fi
}

start_routeguard_if_loaded() {
  if [[ "$OS" == "Darwin" ]]; then
    if launchctl print system/local.tun2socks.routeguard >/dev/null 2>&1; then
      echo "Routeguard LaunchDaemon is loaded. It will monitor and restore routes."
    else
      echo "Routeguard is not loaded. To enable: sudo launchctl bootstrap system /Library/LaunchDaemons/local.tun2socks.routeguard.plist"
    fi
  elif [[ "$OS" == "Linux" ]]; then
    if systemctl is-active tun2socks-routeguard.service >/dev/null 2>&1; then
      echo "tun2socks-routeguard.service is active. It will monitor and restore routes."
    else
      echo "Routeguard service is not active. To enable: sudo systemctl enable --now tun2socks-routeguard.service"
    fi
  fi
}

trap restore_dns_on_error ERR
backup_dns
start_ssh_tunnels
start_gost_balancer
start_tun2socks
apply_routes
set_cloudflare_dns
start_routeguard_if_loaded

echo
echo "Started. Checks:"
if [[ "$OS" == "Darwin" ]]; then
  echo "  route -n get $SSH_IP | egrep 'gateway|interface'"
  echo "  route -n get default | egrep 'gateway|interface'"
else
  echo "  ip route get $SSH_IP"
  echo "  ip route show default"
fi
echo "  curl --socks5-hostname $SOCKS_HOST:$SOCKS_BALANCER_PORT https://ifconfig.me"
echo "  curl https://ifconfig.me"
