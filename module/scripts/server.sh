#!/system/bin/sh
set -u

MODDIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DATA="$MODDIR/data"
CONFIG="$DATA/config/server.env"
PRIVATE_KEY="$DATA/config/server-private.key"
PUBLIC_KEY="$DATA/config/server-public.key"
PEERS="$DATA/config/peers.txt"
RUNTIME="$DATA/runtime"
LOGDIR="$DATA/logs"
LOGFILE="$LOGDIR/server.log"
WGGO="$MODDIR/bin/wireguard-go"
WGCTL="$MODDIR/bin/wgctl"
PANEL="$MODDIR/bin/wgpanel"
PANEL_PID="$RUNTIME/wgpanel.pid"
SOCKET="$RUNTIME/wg0.sock"

write_log() {
  mkdir -p "$LOGDIR"
  printf '%s %-5s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" "$2" >> "$LOGFILE"
  /system/bin/log -t WGServerKSU "$1 $2" 2>/dev/null || true
  if [ -f "$LOGFILE" ] && [ "$(wc -c < "$LOGFILE")" -gt 1048576 ]; then
    mv "$LOGFILE" "$LOGFILE.1"
  fi
}

fail() { write_log ERROR "$1"; printf '%s\n' "$1" >&2; exit 1; }

load_config() {
  [ -f "$CONFIG" ] || fail "server is not configured"
  # This file is module-generated and values are validated before writing.
  . "$CONFIG"
  : "${WG_ADDRESS:?}" "${WG_PORT:?}" "${ENDPOINT:?}"
}

valid_endpoint() { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9.-]+:[0-9]{1,5}$'; }
valid_name() { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9_-]{1,32}$'; }

init() {
  endpoint=${1:-CHANGE-ME.duckdns.org:51820}
  valid_endpoint "$endpoint" || fail "invalid endpoint"
  [ ! -f "$CONFIG" ] || fail "server already configured"
  umask 077
  mkdir -p "$DATA/config" "$DATA/peers" "$RUNTIME" "$LOGDIR" || fail "cannot create module data"
  keys=$("$WGCTL" keygen) || fail "key generation failed"
  private=$(printf '%s\n' "$keys" | sed -n 's/^private=//p')
  public=$(printf '%s\n' "$keys" | sed -n 's/^public=//p')
  [ -n "$private" ] && [ -n "$public" ] || fail "key generation returned invalid data"
  printf '%s\n' "$private" > "$PRIVATE_KEY"
  printf '%s\n' "$public" > "$PUBLIC_KEY"
  : > "$PEERS"
  cat > "$CONFIG" <<EOF
WG_ADDRESS=10.66.66.1/24
WG_PORT=51820
ENDPOINT=$endpoint
ROUTING_MODE=vpn-only
LAN_CIDR=
EOF
  chmod 600 "$CONFIG" "$PRIVATE_KEY" "$PUBLIC_KEY" "$PEERS"
  write_log INFO "server initialized endpoint=$endpoint"
}

apply_routes() {
  [ "$ROUTING_MODE" = "vpn-only" ] && return 0
  wan=$(ip route show default 2>/dev/null | awk '/default/{print $5; exit}')
  [ -n "$wan" ] || { write_log WARN "no default route for $ROUTING_MODE mode"; return 0; }
  iptables -C FORWARD -i wg0 -o "$wan" -j ACCEPT 2>/dev/null || iptables -A FORWARD -i wg0 -o "$wan" -j ACCEPT
  iptables -C FORWARD -i "$wan" -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -A FORWARD -i "$wan" -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT
  iptables -t nat -C POSTROUTING -s 10.66.66.0/24 -o "$wan" -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s 10.66.66.0/24 -o "$wan" -j MASQUERADE
  printf '%s\n' "$wan" > "$RUNTIME/wan-interface"
  write_log INFO "routing mode=$ROUTING_MODE wan=$wan"
}

remove_routes() {
  [ -f "$RUNTIME/wan-interface" ] || return 0
  wan=$(cat "$RUNTIME/wan-interface")
  while iptables -D FORWARD -i wg0 -o "$wan" -j ACCEPT 2>/dev/null; do :; done
  while iptables -D FORWARD -i "$wan" -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; do :; done
  while iptables -t nat -D POSTROUTING -s 10.66.66.0/24 -o "$wan" -j MASQUERADE 2>/dev/null; do :; done
  rm -f "$RUNTIME/wan-interface"
  write_log INFO "routing rules removed wan=$wan"
}

client_allowed_ips() {
  case "$ROUTING_MODE" in
    vpn-only) printf '10.66.66.0/24' ;;
    lan) [ -n "$LAN_CIDR" ] || fail "set LAN_CIDR before using lan routing"; printf '10.66.66.0/24, %s' "$LAN_CIDR" ;;
    full) printf '0.0.0.0/0' ;;
  esac
}

start_panel() {
  [ -x "$PANEL" ] || { write_log WARN "management panel binary is missing"; return 0; }
  if [ -f "$PANEL_PID" ] && kill -0 "$(cat "$PANEL_PID")" 2>/dev/null; then return 0; fi
  "$PANEL" "$MODDIR" >> "$LOGFILE" 2>&1 &
  echo $! > "$PANEL_PID"
  write_log WARN "management panel started publicly address=0.0.0.0:51821"
}

start() {
  load_config
  [ -x "$WGGO" ] && [ -x "$WGCTL" ] || fail "module binaries are missing"
  mkdir -p "$RUNTIME"
  if ip link show wg0 >/dev/null 2>&1; then
    write_log INFO "wg0 already exists; reconciling configuration"
  else
    "$WGGO" wg0 >> "$LOGFILE" 2>&1 || fail "wireguard-go could not create wg0"
    i=0
    while [ ! -S "$SOCKET" ] && [ "$i" -lt 20 ]; do sleep 1; i=$((i + 1)); done
    [ -S "$SOCKET" ] || fail "WireGuard UAPI socket did not appear"
    ip addr replace "$WG_ADDRESS" dev wg0 || fail "cannot assign WireGuard address"
    ip link set up dev wg0 || fail "cannot bring wg0 up"
  fi
  "$WGCTL" configure --socket "$SOCKET" --private-file "$PRIVATE_KEY" --port "$WG_PORT" --peers-file "$PEERS" >> "$LOGFILE" 2>&1 || fail "WireGuard configuration failed"
  sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || write_log WARN "could not enable IPv4 forwarding"
  [ "$ROUTING_MODE" != "lan" ] || [ -n "$LAN_CIDR" ] || fail "lan mode requires LAN_CIDR"
  apply_routes
  start_panel
  write_log INFO "wg0 started port=$WG_PORT address=$WG_ADDRESS"
}

stop() {
  if [ -f "$PANEL_PID" ]; then kill "$(cat "$PANEL_PID")" 2>/dev/null || true; rm -f "$PANEL_PID"; fi
  remove_routes
  if ip link show wg0 >/dev/null 2>&1; then
    ip link delete wg0 >/dev/null 2>&1 && write_log INFO "wg0 stopped" || write_log WARN "could not delete wg0"
  fi
  [ ! -e "$SOCKET" ] || rm -f "$SOCKET"
}

set_lan_cidr() {
  cidr=${1:-}
  printf '%s' "$cidr" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}/([0-9]|[12][0-9]|3[0-2])$' || fail "invalid LAN CIDR"
  load_config
  sed "s|^LAN_CIDR=.*|LAN_CIDR=$cidr|" "$CONFIG" > "$CONFIG.new" || fail "could not update LAN CIDR"
  mv "$CONFIG.new" "$CONFIG"
  write_log INFO "LAN CIDR updated cidr=$cidr"
}

set_routing() {
  mode=${1:-}
  case "$mode" in vpn-only|lan|full) ;; *) fail "routing mode must be vpn-only, lan, or full" ;; esac
  load_config
  remove_routes
  sed "s|^ROUTING_MODE=.*|ROUTING_MODE=$mode|" "$CONFIG" > "$CONFIG.new" || fail "could not update routing mode"
  mv "$CONFIG.new" "$CONFIG"
  write_log INFO "routing mode updated mode=$mode"
  if ip link show wg0 >/dev/null 2>&1; then apply_routes; fi
}

next_address() {
  count=$(grep -c '|' "$PEERS" 2>/dev/null || true)
  number=$((count + 2))
  [ "$number" -le 254 ] || fail "peer address pool is full"
  printf '10.66.66.%s/32' "$number"
}

add_peer() {
  load_config
  name=${1:-}
  valid_name "$name" || fail "invalid peer name"
  grep -q "^$name|" "$PEERS" 2>/dev/null && fail "peer name already exists"
  address=$(next_address)
  umask 077
  keys=$("$WGCTL" keygen) || fail "peer key generation failed"
  private=$(printf '%s\n' "$keys" | sed -n 's/^private=//p')
  public=$(printf '%s\n' "$keys" | sed -n 's/^public=//p')
  server_public=$(cat "$PUBLIC_KEY")
  cat > "$DATA/peers/$name.conf" <<EOF
[Interface]
PrivateKey = $private
Address = $address

[Peer]
PublicKey = $server_public
Endpoint = $ENDPOINT
AllowedIPs = $(client_allowed_ips)
PersistentKeepalive = 25
EOF
  printf '%s|%s|%s\n' "$name" "$public" "$address" >> "$PEERS"
  chmod 600 "$DATA/peers/$name.conf" "$PEERS"
  if ip link show wg0 >/dev/null 2>&1; then start; fi
  write_log INFO "peer created name=$name address=$address"
  printf '%s\n' "$DATA/peers/$name.conf"
}

revoke_peer() {
  name=${1:-}
  valid_name "$name" || fail "invalid peer name"
  grep -q "^$name|" "$PEERS" 2>/dev/null || fail "peer not found"
  grep -v "^$name|" "$PEERS" > "$PEERS.new" || true
  mv "$PEERS.new" "$PEERS"
  rm -f "$DATA/peers/$name.conf"
  if ip link show wg0 >/dev/null 2>&1; then start; fi
  write_log INFO "peer revoked name=$name"
}

set_endpoint() {
  endpoint=${1:-}
  valid_endpoint "$endpoint" || fail "invalid endpoint"
  load_config
  sed "s|^ENDPOINT=.*|ENDPOINT=$endpoint|" "$CONFIG" > "$CONFIG.new" || fail "could not update endpoint"
  mv "$CONFIG.new" "$CONFIG"
  for peer_config in "$DATA"/peers/*.conf; do
    [ -f "$peer_config" ] || continue
    sed "s|^Endpoint = .*|Endpoint = $endpoint|" "$peer_config" > "$peer_config.new" && mv "$peer_config.new" "$peer_config"
  done
  write_log INFO "endpoint updated endpoint=$endpoint"
}

status() {
  if [ -S "$SOCKET" ]; then "$WGCTL" status --socket "$SOCKET"; else printf 'status=stopped\n'; fi
}

case "${1:-}" in
  init) shift; init "$@" ;;
  start) start ;;
  boot-start) [ -f "$CONFIG" ] && start || true ;;
  stop) stop ;;
  restart) stop; start ;;
  add-peer) shift; add_peer "$@" ;;
  revoke-peer) shift; revoke_peer "$@" ;;
  set-endpoint) shift; set_endpoint "$@" ;;
  set-routing) shift; set_routing "$@" ;;
  set-lan-cidr) shift; set_lan_cidr "$@" ;;
  status) status ;;
  *) printf 'usage: %s {init|start|stop|restart|add-peer|revoke-peer|set-endpoint|set-routing|set-lan-cidr|status}\n' "$0" >&2; exit 2 ;;
esac
