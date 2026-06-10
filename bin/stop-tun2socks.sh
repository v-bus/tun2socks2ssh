#!/usr/bin/env bash
set -euo pipefail

OS="$(uname -s)"
CONFIG="${TUN2SOCKS_CONFIG:-/usr/local/etc/tun2socks.conf}"
if [[ -f "$CONFIG" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG"
fi

case "$OS" in
  Linux)
    : "${RUNTIME_DIR:=/var/run/tun2socks}"
    : "${TUN_IF:=tun0}"
    ;;
  *)
    : "${RUNTIME_DIR:=/var/run/tun2socks-macos}"
    : "${TUN_IF:=utun123}"
    ;;
esac
: "${TUN_GW:=198.18.0.1}"
: "${SSH_IP:=}"
: "${REAL_IF:=en0}"
: "${ROUTE_MODE:=default}"

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

if [[ -f "$STATE_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$STATE_FILE"
fi

if [[ "$OS" == "Darwin" ]]; then
  require_cmd networksetup
fi

if [[ "$OS" == "Linux" ]]; then
  require_cmd ip
fi

if [[ "$OS" == "Darwin" ]]; then
  REAL_GW="$(ipconfig getoption "$REAL_IF" router 2>/dev/null | head -n 1 || true)"
fi

restore_default_to_real_darwin() {
  if [[ -n "$REAL_GW" ]]; then
    echo "Restoring default route to real gateway $REAL_GW"
    route change default "$REAL_GW" >/dev/null 2>&1 || {
      route delete default >/dev/null 2>&1 || true
      route add default "$REAL_GW" >/dev/null 2>&1 || true
    }
  else
    echo "WARN: cannot detect real gateway; default route not restored automatically" >&2
  fi
}

restore_default_to_real_linux() {
  if [[ -n "$REAL_GW" ]]; then
    echo "Restoring default route via $REAL_GW dev $REAL_IF"
    ip route replace default via "$REAL_GW" dev "$REAL_IF" >/dev/null 2>&1 || {
      ip route del default >/dev/null 2>&1 || true
      ip route add default via "$REAL_GW" dev "$REAL_IF" >/dev/null 2>&1 || true
    }
  else
    echo "WARN: cannot restore default route (no REAL_GW in state); check manually" >&2
  fi
}

remove_routes() {
  if [[ "$ROUTE_MODE" == "default" ]]; then
    if [[ "$OS" == "Darwin" ]]; then
      restore_default_to_real_darwin
    else
      restore_default_to_real_linux
    fi
  else
    if [[ "$OS" == "Darwin" ]]; then
      local routes=(
        "1.0.0.0/8" "2.0.0.0/7" "4.0.0.0/6" "8.0.0.0/5"
        "16.0.0.0/4" "32.0.0.0/3" "64.0.0.0/2" "128.0.0.0/1"
        "198.18.0.0/15"
      )
      for net in "${routes[@]}"; do
        route delete -net "$net" >/dev/null 2>&1 || true
      done
    else
      local routes=(
        "1.0.0.0/8" "2.0.0.0/7" "4.0.0.0/6" "8.0.0.0/5"
        "16.0.0.0/4" "32.0.0.0/3" "64.0.0.0/2" "128.0.0.0/1"
        "198.18.0.0/15"
      )
      for net in "${routes[@]}"; do
        ip route del "$net" dev "$TUN_IF" >/dev/null 2>&1 || true
      done
    fi
  fi
  if [[ -n "${SSH_IP:-}" ]]; then
    if [[ "$OS" == "Darwin" ]]; then
      route delete -host "$SSH_IP" >/dev/null 2>&1 || true
    else
      ip route del "$SSH_IP/32" >/dev/null 2>&1 || true
    fi
  fi
}

kill_pid_file() {
  local file="$1" label="$2"
  if [[ -f "$file" ]]; then
    local pid
    pid="$(cat "$file")"
    if [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1; then
      echo "Stopping $label PID=$pid"
      kill "$pid" >/dev/null 2>&1 || true
      sleep 0.3
      kill -9 "$pid" >/dev/null 2>&1 || true
    fi
    rm -f "$file"
  fi
}

restore_dns() {
  if [[ "${DNS_MANAGE:-no}" != "yes" ]]; then
    return 0
  fi

  if [[ "$OS" == "Darwin" ]]; then
    if [[ -z "${DNS_SERVICE_NAME:-}" ]]; then
      echo "DNS_SERVICE_NAME is empty, skipping DNS restore"
      return 0
    fi

    if [[ -z "${DNS_BACKUP_FILE:-}" || ! -f "$DNS_BACKUP_FILE" ]]; then
      echo "DNS backup file not found, setting DNS to Empty"
      networksetup -setdnsservers "$DNS_SERVICE_NAME" Empty >/dev/null 2>&1 || true
      return 0
    fi

    echo "Restoring DNS for service: $DNS_SERVICE_NAME"

    if grep -q "There aren't any DNS Servers set" "$DNS_BACKUP_FILE"; then
      networksetup -setdnsservers "$DNS_SERVICE_NAME" Empty
    else
      mapfile -t old_dns < "$DNS_BACKUP_FILE"
      if [[ "${#old_dns[@]}" -gt 0 ]]; then
        networksetup -setdnsservers "$DNS_SERVICE_NAME" "${old_dns[@]}"
      else
        networksetup -setdnsservers "$DNS_SERVICE_NAME" Empty
      fi
    fi
  elif [[ "$OS" == "Linux" ]]; then
    command -v resolvectl >/dev/null 2>&1 || return 0
    echo "Reverting DNS for link $REAL_IF (resolvectl)"
    resolvectl revert "$REAL_IF" >/dev/null 2>&1 || true
  fi
}

if [[ "$OS" == "Darwin" ]]; then
  bring_tun_down() {
    ifconfig "$TUN_IF" down >/dev/null 2>&1 || true
  }
else
  bring_tun_down() {
    ip link set "$TUN_IF" down >/dev/null 2>&1 || true
  }
fi

remove_routes
kill_pid_file "$TUN2SOCKS_PID_FILE" "tun2socks"
kill_pid_file "$GOST_PID_FILE" "gost"

if [[ -d "$SSH_PID_DIR" ]]; then
  for pidfile in "$SSH_PID_DIR"/*.pid; do
    [[ -e "$pidfile" ]] || continue
    kill_pid_file "$pidfile" "ssh tunnel"
  done
fi

bring_tun_down
restore_dns
rm -rf "$RUNTIME_DIR"

echo "Stopped. Check:"
if [[ "$OS" == "Darwin" ]]; then
  echo "  route -n get default"
else
  echo "  ip route show default"
fi
