#!/system/bin/sh
set -u

MODDIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
# KernelSU replaces the module directory during ZIP updates. Keep all mutable
# configuration outside it so keys, peers, DuckDNS settings, and logs survive.
LEGACY_DATA="$MODDIR/data"
DATA="/data/adb/wireguard-server-ksu"
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
BACKEND_FILE="$RUNTIME/backend"
VPN_ROUTE_TABLE=51820
VPN_ROUTE_PREF=1001

write_log() {
  mkdir -p "$LOGDIR"
  printf '%s %-5s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" "$2" >> "$LOGFILE"
  /system/bin/log -t WGServerKSU "$1 $2" 2>/dev/null || true
  if [ -f "$LOGFILE" ] && [ "$(wc -c < "$LOGFILE")" -gt 1048576 ]; then
    mv "$LOGFILE" "$LOGFILE.1"
  fi
}

fail() { write_log ERROR "$1"; printf '%s\n' "$1" >&2; exit 1; }

migrate_data() {
  [ -d "$DATA" ] && return 0
  if [ -d "$LEGACY_DATA" ]; then
    mkdir -p "$(dirname "$DATA")" || return 1
    mv "$LEGACY_DATA" "$DATA" 2>/dev/null || {
      mkdir -p "$DATA" || return 1
      cp -a "$LEGACY_DATA"/. "$DATA"/ || return 1
    }
  else
    mkdir -p "$DATA" || return 1
  fi
  chmod 700 "$DATA" 2>/dev/null || true
}

load_config() {
  migrate_data || fail "cannot prepare persistent module data"
  [ -f "$CONFIG" ] || fail "server is not configured"
  # This file is module-generated and values are validated before writing.
  . "$CONFIG"
  : "${WG_ADDRESS:?}" "${WG_PORT:?}" "${ENDPOINT:?}"
}

valid_endpoint() { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9.-]+:[0-9]{1,5}$'; }
valid_name() { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9_-]{1,32}$'; }

init() {
  migrate_data || fail "cannot prepare persistent module data"
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
# Full tunnel is the default: client profiles route IPv4 traffic through the
# phone and the server applies forwarding/NAT rules on its upstream network.
ROUTING_MODE=full
LAN_CIDR=
EOF
  chmod 600 "$CONFIG" "$PRIVATE_KEY" "$PUBLIC_KEY" "$PEERS"
  write_log INFO "server initialized endpoint=$endpoint"
}

apply_routes() {
  [ "$ROUTING_MODE" = "vpn-only" ] && return 0
  # Android commonly keeps the default route in a per-network table (for
  # example `wlan0`) rather than the main table, so `ip route show default`
  # can be empty even while the phone has working internet access.
  wan=$(ip route show default 2>/dev/null | awk '/default/{print $5; exit}')
  [ -n "$wan" ] || wan=$(ip route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit }}')
  [ -n "$wan" ] || { write_log WARN "no default route for $ROUTING_MODE mode"; return 0; }
  # Android's main table commonly has no default route. Route VPN-sourced
  # packets through a module-owned table based on the active network route.
  gateway=$(ip route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "via") { print $(i + 1); exit }}')
  if [ -n "$gateway" ]; then
    ip route replace default via "$gateway" dev "$wan" table "$VPN_ROUTE_TABLE" || write_log WARN "could not set VPN default route via $wan"
  else
    ip route replace default dev "$wan" table "$VPN_ROUTE_TABLE" || write_log WARN "could not set VPN default route via $wan"
  fi
  ip rule add pref "$VPN_ROUTE_PREF" from 10.66.66.0/24 lookup "$VPN_ROUTE_TABLE" 2>/dev/null || true
  # Android's tetherctrl_FORWARD chain ends in DROP. Insert module rules
  # before Android-owned chains, rather than appending unreachable rules.
  while iptables -D FORWARD -i wg0 -o "$wan" -j ACCEPT 2>/dev/null; do :; done
  while iptables -D FORWARD -i "$wan" -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; do :; done
  while iptables -t nat -D POSTROUTING -s 10.66.66.0/24 -o "$wan" -j MASQUERADE 2>/dev/null; do :; done
  iptables -I FORWARD 1 -i wg0 -o "$wan" -j ACCEPT
  iptables -I FORWARD 1 -i "$wan" -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT
  iptables -t nat -I POSTROUTING 1 -s 10.66.66.0/24 -o "$wan" -j MASQUERADE
  printf '%s\n' "$wan" > "$RUNTIME/wan-interface"
  write_log INFO "routing mode=$ROUTING_MODE wan=$wan"
}

remove_routes() {
  if [ -f "$RUNTIME/wan-interface" ]; then
    wan=$(cat "$RUNTIME/wan-interface")
    while iptables -D FORWARD -i wg0 -o "$wan" -j ACCEPT 2>/dev/null; do :; done
    while iptables -D FORWARD -i "$wan" -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; do :; done
    while iptables -t nat -D POSTROUTING -s 10.66.66.0/24 -o "$wan" -j MASQUERADE 2>/dev/null; do :; done
    rm -f "$RUNTIME/wan-interface"
    write_log INFO "routing rules removed wan=$wan"
  fi
  while ip rule del pref "$VPN_ROUTE_PREF" from 10.66.66.0/24 lookup "$VPN_ROUTE_TABLE" 2>/dev/null; do :; done
  ip route flush table "$VPN_ROUTE_TABLE" 2>/dev/null || true
}

vpn_cidr() {
  ip route show dev wg0 proto kernel scope link 2>/dev/null | awk 'NR == 1 { print $1 }'
}

add_vpn_policy_route() {
  cidr=$(vpn_cidr)
  [ -n "$cidr" ] || { write_log WARN "could not determine WireGuard subnet for policy route"; return 0; }
  ip rule add pref 1000 to "$cidr" lookup main 2>/dev/null || true
  write_log INFO "VPN reply policy route enabled cidr=$cidr"
}

remove_vpn_policy_route() {
  cidr=$(vpn_cidr)
  [ -n "$cidr" ] || return 0
  while ip rule del pref 1000 to "$cidr" lookup main 2>/dev/null; do :; done
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

configure_native() {
  "$WGCTL" native-config --device wg0 --private-file "$PRIVATE_KEY" --port "$WG_PORT" --peers-file "$PEERS" >> "$LOGFILE" 2>&1
}

configure_userspace() {
  "$WGCTL" configure --socket "$SOCKET" --private-file "$PRIVATE_KEY" --port "$WG_PORT" --peers-file "$PEERS" >> "$LOGFILE" 2>&1
}

start_userspace() {
  "$WGGO" wg0 >> "$LOGFILE" 2>&1 || return 1
  i=0
  while [ ! -S "$SOCKET" ] && [ "$i" -lt 20 ]; do sleep 1; i=$((i + 1)); done
  [ -S "$SOCKET" ] || return 1
  configure_userspace || return 1
  printf '%s\n' userspace > "$BACKEND_FILE"
  write_log WARN "WireGuard backend=wireguard-go (kernel native unavailable)"
}

start_native_or_fallback() {
  if ip link add wg0 type wireguard >> "$LOGFILE" 2>&1; then
    if configure_native; then
      printf '%s\n' kernel > "$BACKEND_FILE"
      write_log INFO "WireGuard backend=kernel native"
      return 0
    fi
    write_log WARN "native WireGuard configuration failed; falling back to wireguard-go"
    ip link delete wg0 >/dev/null 2>&1 || true
  else
    write_log WARN "native WireGuard interface unavailable; falling back to wireguard-go"
  fi
  start_userspace
}

start() {
  migrate_data || fail "cannot prepare persistent module data"
  load_config
  [ -x "$WGGO" ] && [ -x "$WGCTL" ] || fail "module binaries are missing"
  mkdir -p "$RUNTIME"
  if ip link show wg0 >/dev/null 2>&1; then
    write_log INFO "wg0 already exists; reconciling configuration"
    if [ -S "$SOCKET" ]; then
      configure_userspace || fail "WireGuard userspace configuration failed"
      printf '%s\n' userspace > "$BACKEND_FILE"
    else
      if configure_native; then
        printf '%s\n' kernel > "$BACKEND_FILE"
      else
        write_log WARN "existing native wg0 could not be configured; falling back to wireguard-go"
        ip link delete wg0 >/dev/null 2>&1 || fail "could not remove failed native wg0"
        start_userspace || fail "wireguard-go fallback could not start"
      fi
    fi
  else
    start_native_or_fallback || fail "could not start native WireGuard or wireguard-go fallback"
  fi
  ip addr replace "$WG_ADDRESS" dev wg0 || fail "cannot assign WireGuard address"
  ip link set up dev wg0 || fail "cannot bring wg0 up"
  add_vpn_policy_route
  sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || write_log WARN "could not enable IPv4 forwarding"
  [ "$ROUTING_MODE" != "lan" ] || [ -n "$LAN_CIDR" ] || fail "lan mode requires LAN_CIDR"
  apply_routes
  start_panel
  write_log INFO "wg0 started port=$WG_PORT address=$WG_ADDRESS"
}

stop() {
  if [ -f "$PANEL_PID" ]; then kill "$(cat "$PANEL_PID")" 2>/dev/null || true; rm -f "$PANEL_PID"; fi
  remove_routes
  remove_vpn_policy_route
  if ip link show wg0 >/dev/null 2>&1; then
    ip link delete wg0 >/dev/null 2>&1 && write_log INFO "wg0 stopped" || write_log WARN "could not delete wg0"
  fi
  [ ! -e "$SOCKET" ] || rm -f "$SOCKET"
  rm -f "$BACKEND_FILE"
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
  ROUTING_MODE=$mode
  # Existing peer files are exported client configurations.  Keep their
  # AllowedIPs in sync with the selected server routing mode, otherwise a
  # client can remain limited to the VPN subnet after enabling full tunnel.
  allowed=$(client_allowed_ips)
  for peer_config in "$DATA"/peers/*.conf; do
    [ -f "$peer_config" ] || continue
    sed "s|^AllowedIPs = .*|AllowedIPs = $allowed|" "$peer_config" > "$peer_config.new" && mv "$peer_config.new" "$peer_config"
  done
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
  migrate_data || return 1
  if ! ip link show wg0 >/dev/null 2>&1; then printf 'status=stopped\n'; return 0; fi
  backend=$(cat "$BACKEND_FILE" 2>/dev/null || true)
  if [ "$backend" = userspace ] || [ -S "$SOCKET" ]; then
    printf 'backend=wireguard-go\n'
    "$WGCTL" status --socket "$SOCKET"
  else
    printf 'backend=kernel\n'
    "$WGCTL" native-status --device wg0
  fi
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
