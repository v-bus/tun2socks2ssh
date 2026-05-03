#!/usr/bin/env bash
set -u

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

get_real_gateway() {
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

get_route_gateway() {
  local target="$1"
  route -n get "$target" 2>/dev/null | awk '/gateway:/ {print $2; exit}'
}

get_route_interface() {
  local target="$1"
  route -n get "$target" 2>/dev/null | awk '/interface:/ {print $2; exit}'
}

tun_is_ready() {
  ifconfig "$TUN_IF" >/dev/null 2>&1 || return 1
  ifconfig "$TUN_IF" 2>/dev/null | grep -q "UP" || return 1
  return 0
}

restore_ssh_route() {
  local real_gw="$1"
  if [[ -z "$real_gw" ]]; then
    log "ERROR: real gateway for $REAL_IF is empty; cannot restore SSH host route"
    return 1
  fi

  log "Restoring SSH host route: $SSH_IP -> $real_gw via $REAL_IF"
  route delete -host "$SSH_IP" >/dev/null 2>&1 || true
  route add -host "$SSH_IP" "$real_gw" >/dev/null 2>&1
}

restore_default_route_to_tun() {
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

restore_split_default_routes() {
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

check_and_restore() {
  local real_gw ssh_gw ssh_if default_gw default_if
  real_gw="$(get_real_gateway)"
  if [[ -z "$real_gw" ]]; then
    log "WARN: no real gateway for $REAL_IF; network may be disconnected"
    return 0
  fi

  ssh_gw="$(get_route_gateway "$SSH_IP")"
  ssh_if="$(get_route_interface "$SSH_IP")"

  # Always protect SSH first. /32 host route is more specific than default.
  if [[ "$ssh_gw" != "$real_gw" || "$ssh_if" != "$REAL_IF" ]]; then
    log "SSH route wrong: gateway=$ssh_gw interface=$ssh_if; expected gateway=$real_gw interface=$REAL_IF"
    restore_ssh_route "$real_gw" || log "ERROR: failed to restore SSH route"
  fi

  if [[ "$ROUTE_MODE" == "default" ]]; then
    default_gw="$(get_route_gateway default)"
    default_if="$(get_route_interface default)"
    if [[ "$default_gw" != "$TUN_GW" || "$default_if" != "$TUN_IF" ]]; then
      log "Default route wrong: gateway=$default_gw interface=$default_if; expected gateway=$TUN_GW interface=$TUN_IF"
      restore_default_route_to_tun || log "ERROR: failed to restore default route"
    fi
  else
    local test_gw test_if
    test_gw="$(get_route_gateway 8.8.8.8)"
    test_if="$(get_route_interface 8.8.8.8)"
    if [[ "$test_gw" != "$TUN_GW" && "$test_if" != "$TUN_IF" ]]; then
      log "Split route seems wrong for 8.8.8.8: gateway=$test_gw interface=$test_if; expected $TUN_GW/$TUN_IF"
      restore_split_default_routes || log "ERROR: failed to restore split routes"
    fi
  fi
}

log "tun2socks-routeguard started"
log "CONFIG=$CONFIG REAL_IF=$REAL_IF SSH_IP=$SSH_IP TUN_IF=$TUN_IF TUN_GW=$TUN_GW ROUTE_MODE=$ROUTE_MODE"

while true; do
  check_and_restore
  sleep "$CHECK_INTERVAL"
done
