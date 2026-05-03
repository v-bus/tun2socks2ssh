#!/usr/bin/env bash
set -u

OS="$(uname -s)"
CONFIG="${TUN2SOCKS_CONFIG:-/usr/local/etc/tun2socks.conf}"

if [[ ! -f "$CONFIG" ]]; then
  echo "Config not found: $CONFIG" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG"

: "${REAL_IF:?REAL_IF is required}"
: "${SSH_IP:?SSH_IP is required}"
: "${TUN_IF:?TUN_IF is required}"
: "${TUN_GW:?TUN_GW is required}"
: "${CHECK_INTERVAL:=3}"
: "${LOG_FILE:=/var/log/tun2socks-routeguard.log}"
: "${ROUTE_MODE:=default}"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

get_real_gateway_darwin() {
  local gw
  gw="$(ipconfig getoption "$REAL_IF" router 2>/dev/null | head -n 1 || true)"
  if [[ -z "$gw" ]]; then
    gw="$(route -n get default 2>/dev/null | awk -v rif="$REAL_IF" '
      /gateway:/ {g=$2}
      /interface:/ {i=$2}
      END {if (i==rif) print g}' || true)"
  fi
  echo "$gw"
}

get_real_gateway_linux() {
  local gw
  gw="$(ip -4 route show dev "$REAL_IF" 2>/dev/null | awk '/default/ {print $3; exit}')"
  if [[ -z "$gw" ]]; then
    gw="$(ip -4 route show default 2>/dev/null | awk '/default/ {print $3; exit}')"
  fi
  echo "$gw"
}

get_real_gateway() {
  if [[ "$OS" == "Darwin" ]]; then
    get_real_gateway_darwin
  else
    get_real_gateway_linux
  fi
}

get_route_gateway_darwin() {
  local target="$1"
  route -n get "$target" 2>/dev/null | awk '/gateway:/ {print $2; exit}'
}

get_route_interface_darwin() {
  local target="$1"
  route -n get "$target" 2>/dev/null | awk '/interface:/ {print $2; exit}'
}

linux_parse_route_line() {
  local line="$1"
  echo "$line" | awk '{
    gw=""; dev=""
    for(i=1;i<=NF;i++) {
      if ($i=="via") gw=$(i+1)
      if ($i=="dev") dev=$(i+1)
    }
    print gw "\t" dev
  }'
}

get_route_gateway_linux() {
  local target="$1"
  local line
  line="$(ip -4 route get "$target" 2>/dev/null | head -n 1)"
  linux_parse_route_line "$line" | cut -f1
}

get_route_interface_linux() {
  local target="$1"
  local line
  line="$(ip -4 route get "$target" 2>/dev/null | head -n 1)"
  linux_parse_route_line "$line" | cut -f2
}

get_route_gateway() {
  local target="$1"
  if [[ "$OS" == "Darwin" ]]; then
    get_route_gateway_darwin "$target"
  else
    get_route_gateway_linux "$target"
  fi
}

get_route_interface() {
  local target="$1"
  if [[ "$OS" == "Darwin" ]]; then
    get_route_interface_darwin "$target"
  else
    get_route_interface_linux "$target"
  fi
}

tun_is_ready_darwin() {
  ifconfig "$TUN_IF" >/dev/null 2>&1 || return 1
  ifconfig "$TUN_IF" 2>/dev/null | grep -q "UP" || return 1
  return 0
}

tun_is_ready_linux() {
  ip link show "$TUN_IF" 2>/dev/null | grep -q "state UP" || return 1
  return 0
}

tun_is_ready() {
  if [[ "$OS" == "Darwin" ]]; then
    tun_is_ready_darwin
  else
    tun_is_ready_linux
  fi
}

restore_ssh_route_darwin() {
  local real_gw="$1"
  if [[ -z "$real_gw" ]]; then
    log "ERROR: real gateway for $REAL_IF is empty; cannot restore SSH host route"
    return 1
  fi

  log "Restoring SSH host route: $SSH_IP -> $real_gw via $REAL_IF"
  route delete -host "$SSH_IP" >/dev/null 2>&1 || true
  route add -host "$SSH_IP" "$real_gw" >/dev/null 2>&1
}

restore_ssh_route_linux() {
  local real_gw="$1"
  if [[ -z "$real_gw" ]]; then
    log "ERROR: real gateway for $REAL_IF is empty; cannot restore SSH host route"
    return 1
  fi

  log "Restoring SSH host route: $SSH_IP -> $real_gw via $REAL_IF"
  ip route del "$SSH_IP/32" >/dev/null 2>&1 || true
  ip route replace "$SSH_IP/32" via "$real_gw" dev "$REAL_IF" >/dev/null 2>&1
}

restore_ssh_route() {
  local real_gw="$1"
  if [[ "$OS" == "Darwin" ]]; then
    restore_ssh_route_darwin "$real_gw"
  else
    restore_ssh_route_linux "$real_gw"
  fi
}

restore_default_route_to_tun_darwin() {
  if ! tun_is_ready; then
    log "WARN: $TUN_IF is not ready; default route not changed"
    return 1
  fi

  log "Restoring default route: default -> $TUN_GW via $TUN_IF"
  route change default "$TUN_GW" >/dev/null 2>&1 || {
    route delete default >/dev/null 2>&1 || true
    route add default "$TUN_GW" >/dev/null 2>&1
  }
}

restore_default_route_to_tun_linux() {
  if ! tun_is_ready; then
    log "WARN: $TUN_IF is not ready; default route not changed"
    return 1
  fi

  log "Restoring default route: default -> dev $TUN_IF"
  ip route replace default dev "$TUN_IF" >/dev/null 2>&1
}

restore_default_route_to_tun() {
  if [[ "$OS" == "Darwin" ]]; then
    restore_default_route_to_tun_darwin
  else
    restore_default_route_to_tun_linux
  fi
}

restore_split_default_routes_darwin() {
  if ! tun_is_ready; then
    log "WARN: $TUN_IF is not ready; split routes not changed"
    return 1
  fi
  local routes=(
    "1.0.0.0/8" "2.0.0.0/7" "4.0.0.0/6" "8.0.0.0/5"
    "16.0.0.0/4" "32.0.0.0/3" "64.0.0.0/2" "128.0.0.0/1"
    "198.18.0.0/15"
  )
  log "Restoring split-default routes through $TUN_GW"
  for net in "${routes[@]}"; do
    route delete -net "$net" >/dev/null 2>&1 || true
    route add -net "$net" "$TUN_GW" >/dev/null 2>&1 || true
  done
}

restore_split_default_routes_linux() {
  if ! tun_is_ready; then
    log "WARN: $TUN_IF is not ready; split routes not changed"
    return 1
  fi
  local routes=(
    "1.0.0.0/8" "2.0.0.0/7" "4.0.0.0/6" "8.0.0.0/5"
    "16.0.0.0/4" "32.0.0.0/3" "64.0.0.0/2" "128.0.0.0/1"
    "198.18.0.0/15"
  )
  log "Restoring split-default routes through $TUN_IF"
  for net in "${routes[@]}"; do
    ip route replace "$net" dev "$TUN_IF" >/dev/null 2>&1 || ip route add "$net" dev "$TUN_IF" >/dev/null 2>&1 || true
  done
}

restore_split_default_routes() {
  if [[ "$OS" == "Darwin" ]]; then
    restore_split_default_routes_darwin
  else
    restore_split_default_routes_linux
  fi
}

check_and_restore() {
  local real_gw ssh_gw ssh_if default_gw default_if def_line default_dev test_gw test_if

  real_gw="$(get_real_gateway)"
  if [[ -z "$real_gw" ]]; then
    log "WARN: no real gateway for $REAL_IF; network may be disconnected"
    return 0
  fi

  ssh_gw="$(get_route_gateway "$SSH_IP")"
  ssh_if="$(get_route_interface "$SSH_IP")"

  if [[ "$ssh_gw" != "$real_gw" || "$ssh_if" != "$REAL_IF" ]]; then
    log "SSH route wrong: gateway=$ssh_gw interface=$ssh_if; expected gateway=$real_gw interface=$REAL_IF"
    restore_ssh_route "$real_gw" || log "ERROR: failed to restore SSH route"
  fi

  if [[ "$ROUTE_MODE" == "default" ]]; then
    if [[ "$OS" == "Darwin" ]]; then
      default_gw="$(get_route_gateway default)"
      default_if="$(get_route_interface default)"
      if [[ "$default_gw" != "$TUN_GW" || "$default_if" != "$TUN_IF" ]]; then
        log "Default route wrong: gateway=$default_gw interface=$default_if; expected gateway=$TUN_GW interface=$TUN_IF"
        restore_default_route_to_tun || log "ERROR: failed to restore default route"
      fi
    else
      def_line="$(ip -4 route show default 2>/dev/null | head -n 1)"
      default_dev="$(echo "$def_line" | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')"
      if [[ "$default_dev" != "$TUN_IF" ]]; then
        log "Default route wrong: dev=$default_dev; expected dev=$TUN_IF (line=$def_line)"
        restore_default_route_to_tun || log "ERROR: failed to restore default route"
      fi
    fi
  else
    test_gw="$(get_route_gateway 8.8.8.8)"
    test_if="$(get_route_interface 8.8.8.8)"
    if [[ "$test_gw" != "$TUN_GW" && "$test_if" != "$TUN_IF" ]]; then
      log "Split route seems wrong for 8.8.8.8: gateway=$test_gw interface=$test_if; expected $TUN_GW/$TUN_IF"
      restore_split_default_routes || log "ERROR: failed to restore split routes"
    fi
  fi
}

log "tun2socks-routeguard started"
log "CONFIG=$CONFIG REAL_IF=$REAL_IF SSH_IP=$SSH_IP TUN_IF=$TUN_IF TUN_GW=$TUN_GW ROUTE_MODE=$ROUTE_MODE OS=$OS"

while true; do
  check_and_restore
  sleep "$CHECK_INTERVAL"
done
