# KernelSU WireGuard Server for Android — Implementation Plan

## 1. Product goal

Build a KernelSU module that makes a rooted Android phone a home WireGuard server.

The module will:

- run a WireGuard server on the phone;
- update a DuckDNS hostname with the home router's public IP;
- create, revoke, export, and inspect WireGuard peers;
- offer a local KernelSU Manager WebUI for setup and recovery; and
- offer a browser management panel available only to devices already connected to the VPN.

The router exposes only the WireGuard UDP port.  The management panel is not port-forwarded and is not exposed through DuckDNS.

## 2. Scope and non-goals

### In scope

- KernelSU module packaging and lifecycle scripts.
- WireGuard server configuration and peer management.
- DuckDNS IPv4 updates.
- VPN-only web management panel.
- Home-LAN access and optional full-tunnel routing.
- Status, structured logs, startup recovery, and uninstall cleanup.

### Out of scope for the first release

- A Play Store / normal Android application.
- Publicly reachable management UI.
- Multi-user roles or fine-grained authorization.
- Automated router port-forward configuration.
- IPv6 deployment, certificate automation, or multi-WAN support.

## 3. Intended topology

```text
Remote phone / laptop
        |
        | WireGuard UDP to: myhome.duckdns.org:51820
        v
Home router public address
        |
        | Router UDP forward: 51820 -> reserved Android Wi-Fi IP:51820
        v
Android phone
  Wi-Fi/LAN: 192.168.1.50
  WireGuard: 10.66.66.1/24 (wg0)
  VPN-only panel: http://10.66.66.1:51821
        |
        +-- home LAN: 192.168.1.0/24 (optional)
        +-- internet exit through phone Wi-Fi (optional full tunnel)
```

The phone must have a router DHCP reservation such as `192.168.1.50`; otherwise the router's forwarding destination may change.

## 4. Preconditions and compatibility gate

Do not begin feature work until the target phone passes this gate.

1. KernelSU is installed and its Manager can install and enable a basic test module.
2. The phone has a working network interface and root shell.
3. Check the commands needed by the module:

   ```sh
   command -v ip
   command -v wg
   command -v iptables || command -v nft
   ```

4. Verify the Android TUN device is usable by the packaged `wireguard-go` binary:

   ```sh
   wireguard-go wg-test
   ip link show wg-test
   ip link delete wg-test
   ```

5. Verify IPv4 forwarding can be enabled:

   ```sh
   sysctl -w net.ipv4.ip_forward=1
   ```

6. Create a temporary server and peer.  From a device using mobile data, verify a WireGuard handshake through the router port forward.

### Decision

- **`wireguard-go` TUN test works:** use the packaged userspace backend on every supported device.
- **Test fails:** stop and diagnose the phone's TUN/SELinux/root environment. A rooted phone still needs permission to create a TUN interface.

The project deliberately does not use the kernel WireGuard backend. This avoids a dependency on a kernel module that varies by device and ROM. It still requires a tested `wireguard-go` binary for the device ABI, normally `arm64-v8a` and optionally `armeabi-v7a`.

## 5. Module structure

```text
wireguard-server-ksu/
├── module.prop
├── customize.sh
├── service.sh
├── boot-completed.sh
├── uninstall.sh
├── action.sh
├── scripts/
│   ├── lib.sh
│   ├── server.sh
│   ├── peers.sh
│   ├── routes.sh
│   ├── duckdns.sh
│   └── diagnose.sh
├── bin/
│   ├── arm64-v8a/
│   │   ├── wg-serverd
│   │   └── wireguard-go
│   └── armeabi-v7a/
│       ├── wg-serverd
│       └── wireguard-go
├── webroot/
│   ├── index.html
│   ├── app.js
│   └── style.css
├── remote-ui/
│   └── static assets served by wg-serverd
└── data/
    ├── config/
    ├── peers/
    ├── runtime/
    └── logs/
```

`module.prop` should use an immutable module ID, for example `wireguard-server-ksu`.

`customize.sh` detects the ABI, installs only the matching daemon binary, initializes restrictive file permissions, and creates data directories. It must not start services or create an interface.

## 6. Persistent state

Store secrets and runtime configuration separately.

| Data | Storage | Rules |
|---|---|---|
| Server private key | `data/config/server-private.key` | root only; never shown in UI/logs |
| Server public key | derived or `data/config/server-public.key` | safe to show |
| Peer private config | `data/peers/<id>.conf` | root only; export on demand |
| Peer metadata | `data/peers/<id>.json` | name, IP, public key, created/revoked state |
| Server settings | KernelSU persistent config or `data/config/settings.json` | port, subnet, LAN route, DuckDNS enabled |
| DuckDNS token | protected config/secret file | never returned by APIs or logs |
| Runtime state | `data/runtime/` | PID, active WAN interface, last update result |
| Logs | `data/logs/` | rotating files |

Use an atomic write pattern: write a temporary file under the same directory, validate it, chmod it, then rename it into place. Take one exclusive lock for every action that changes peers, the interface, or routing.

## 7. Configuration defaults

```text
Interface name:       wg0
WireGuard address:    10.66.66.1/24
VPN subnet:           10.66.66.0/24
WireGuard port:       51820/UDP
Management address:   10.66.66.1:51821
Peer pool:            10.66.66.2 - 10.66.66.254
Mode:                 VPN-only initially
DuckDNS interval:     10 minutes
```

The first setup screen accepts a different private IPv4 subnet and port, validates that it does not overlap the current Wi-Fi LAN, then generates the server key pair.

## 8. Lifecycle design

### Install

1. Validate KernelSU environment, device ABI, and that its matching `wireguard-go` binary is present.
2. Install files, daemon, `wireguard-go`, and WebUI assets.
3. Create data directories with restricted permissions.
4. Do not create a server configuration automatically.
5. Show “not configured” in the module description/UI.

### `service.sh`

1. Resolve `MODDIR=${0%/*}`; never hardcode the module path.
2. Exit if the module is not configured or disabled.
3. Start the supervisor/daemon only if it is not already running.
4. The daemon waits for usable network connectivity; it does not assume Wi-Fi exists at late-start.

### `boot-completed.sh`

1. Reconcile the running daemon and server state.
2. Recreate `wg0` if enabled and missing.
3. Reapply module-owned routes/NAT rules idempotently.
4. Perform an immediate DuckDNS update if enabled.

### Stop / restart

The UI must have explicit Start, Stop, and Restart actions.

- **Stop:** halt daemon, stop DuckDNS timer, remove management listener, bring down `wg0`, then remove module-owned routes/rules.
- **Restart:** perform stop, validate configuration, then start.
- Every action records success/failure in the log.

### Uninstall

`uninstall.sh` must:

1. stop the daemon and kill only its recorded PID;
2. stop `wireguard-go` if used;
3. remove `wg0`;
4. remove only firewall/routing entries tagged or owned by the module;
5. remove module data; and
6. log cleanup results while the directory remains available.

Do not touch unrelated interfaces, routes, firewall rules, or KernelSU modules.

## 9. WireGuard implementation

### Server start sequence

1. Load/validate settings and server key.
2. Detect the active default-route interface; do not hardcode `wlan0`.
3. Start the packaged `wireguard-go wg0` backend and wait until its TUN interface exists.
4. Assign `10.66.66.1/24` to `wg0`.
5. Set server private key and UDP listen port.
6. Apply every enabled peer using exact `wg set` arguments or a validated generated configuration.
7. Enable `net.ipv4.ip_forward=1` while the server is active.
8. Apply selected routing mode.
9. Start the VPN-only management listener on `10.66.66.1:51821`.
10. Write status and log result.

All actions must be idempotent: running Start twice must not duplicate NAT rules, create duplicate processes, or corrupt peer configuration.

### Peer operations

Peer names must match a conservative pattern such as `[A-Za-z0-9_-]{1,32}`. Never interpolate unvalidated browser text into shell commands.

#### Create peer

1. Validate name and find an unused address in the peer pool.
2. Generate private/public keys and optional preshared key.
3. Persist metadata/config atomically.
4. Apply peer public key and `AllowedIPs = peer-address/32` to live `wg0`.
5. Return QR data and `.conf` download content only to the requesting management session.
6. Log peer ID/name/address but never its private key/config.

#### Revoke peer

1. Remove its public key from live `wg0`.
2. Mark peer revoked and move the secret config to a protected archive or delete it.
3. Free its address only after an explicit “reuse IP” decision.
4. Log revocation.

#### Status

Use `wg show` to report each enabled peer's latest handshake and transfer counters. Label a peer “recently active” only when its latest handshake is within a chosen period, such as 3 minutes. Do not claim that WireGuard supplies a permanent connected-session list.

## 10. Routing modes

Implement incrementally.

| Mode | Client `AllowedIPs` | Server behavior |
|---|---|---|
| VPN-only | `10.66.66.0/24` | panel/phone access only |
| Home LAN | VPN subnet + home LAN CIDR | forwarding between `wg0` and Wi-Fi; NAT if no return route exists |
| Full tunnel | `0.0.0.0/0` | home LAN plus NAT for internet traffic through phone Wi-Fi |

For every NAT/filter rule, use a unique module comment/tag where the firewall backend supports it. Cleanup must search and remove only rules matching that tag.

If interface changes break NAT, record a warning, detect the new default interface, and reconcile rules. Do not silently leave stale rules behind.

## 11. DuckDNS updater

### Settings

- enabled flag;
- subdomain without `.duckdns.org`;
- account token;
- interval, default 10 minutes;
- last attempt/result/time/public IPv4.

### Update algorithm

1. Check that a default route and DNS/network access are available.
2. Send an HTTPS request to DuckDNS with `domains`, `token`, and `verbose=true`.
3. Omit `ip` for normal IPv4 operation so DuckDNS detects the external IPv4 address.
4. Parse success only if the response is `OK`.
5. Save non-secret result metadata and log it.
6. On failure, retry with capped exponential backoff; retain normal interval after success.

The updater must never print its full URL because it contains the DuckDNS token.

## 12. Management UI design

### A. KernelSU Manager WebUI

This is an owner-side UI inside KernelSU Manager. It provides:

- first-run server setup;
- start/stop/restart;
- WireGuard/DuckDNS configuration;
- peer CRUD and QR/config export;
- LAN/full-tunnel mode;
- status, diagnostics, logs, and cleanup.

Its JavaScript calls only a fixed module command dispatcher. The dispatcher receives action names and validated JSON payloads, not raw shell snippets.

### B. VPN-only browser panel

This panel is for devices already connected through WireGuard:

```text
http://10.66.66.1:51821
```

It has the same full-management capability because this is a personal deployment. It must:

- listen specifically on `10.66.66.1`, not all network addresses;
- refuse requests not originating from the VPN subnet as a second check;
- never be router-forwarded;
- show peer list/status;
- create/revoke/export peers;
- show DuckDNS/server health and logs;
- provide Start/Stop/Restart.

Use a small purpose-built native daemon for the HTTP API and static UI. Avoid BusyBox CGI and avoid an API that accepts arbitrary shell commands.

HTTP is acceptable for the first version because the listener is inside the already encrypted WireGuard tunnel. HTTPS can be added later if desired.

## 13. API boundary

The management daemon exposes a narrow JSON API, for example:

```text
GET  /api/status
GET  /api/peers
POST /api/peers                 { "name": "laptop", "mode": "lan" }
GET  /api/peers/{id}/config
GET  /api/peers/{id}/qr
POST /api/peers/{id}/revoke
POST /api/server/start
POST /api/server/stop
POST /api/server/restart
POST /api/duckdns/update
GET  /api/logs?lines=200
POST /api/logs/clear
```

The daemon maps these requests to an internal allowlist of module operations. It validates IDs, peer names, addresses, numeric ports, and routing mode before invoking any root operation.

## 14. Logging and diagnostics

Use rotating module logs:

```text
data/logs/server.log
data/logs/server.log.1
data/logs/server.log.2
```

Maximum size: 1 MB each. Each entry includes timestamp, level, component, and safe message:

```text
2026-08-25T21:15:05+07:00 INFO  wireguard: wg0 started udp_port=51820
2026-08-25T21:15:06+07:00 INFO  duckdns: update result=NOCHANGE
2026-08-25T21:20:01+07:00 WARN  duckdns: request failed curl_exit=6
```

Log:

- install, start, stop, reboot reconciliation, and uninstall;
- interface/routing/NAT actions and failures;
- peer create/revoke/export events without secret data;
- DuckDNS attempts/results/retries;
- daemon/UI lifecycle and validation failures.

Never log WireGuard private keys, preshared keys, DuckDNS token, full client configs, QR payloads, or raw HTTP authorization headers.

Emit concise duplicate events to Android logcat with tag `WGServerKSU`.

## 15. Build milestones

### Milestone 1: compatibility prototype

- Minimal KernelSU module.
- Validate backend and start manually.
- One static server peer and one test client.
- Confirm external UDP forwarding/handshake.

**Exit criteria:** remote mobile-data client handshakes and can ping `10.66.66.1`.

### Milestone 2: reliable server lifecycle

- Server state file and idempotent start/stop.
- Reboot recovery.
- Safe cleanup/uninstall.
- Basic log viewer in KernelSU WebUI.

**Exit criteria:** five consecutive reboots preserve a working server and Stop removes all module-owned live networking state.

### Milestone 3: peer management

- Key generation, address allocation, live peer updates.
- QR code/file export from KernelSU WebUI.
- Handshake/traffic status.

**Exit criteria:** create, connect, revoke, and re-add peers without restarting the server.

### Milestone 4: DuckDNS

- Settings UI and protected token storage.
- Immediate/manual/periodic updates and backoff.
- Status and logs.

**Exit criteria:** hostname resolves to the router's current public IPv4 after boot and after a forced update.

### Milestone 5: VPN-only remote panel

- Native management daemon and static browser UI.
- Bind/restrict access to `wg0` address.
- Full peer/server/log actions.

**Exit criteria:** a connected peer can create a new peer from `10.66.66.1:51821`; the same port is unreachable from home Wi-Fi and the public internet.

### Milestone 6: LAN and full-tunnel modes

- Default-interface detection.
- Module-owned forwarding/NAT rules.
- DNS and leak checks.

**Exit criteria:** both selected modes work after Wi-Fi reconnect and reboot, with no duplicate/stale rules.

## 16. Final acceptance checklist

- [ ] Phone gets a stable LAN address through router DHCP reservation.
- [ ] Router forwards only WireGuard UDP port to phone.
- [ ] DuckDNS name resolves to router public IPv4.
- [ ] Remote client connects via mobile data using DuckDNS endpoint.
- [ ] Latest handshake and traffic counters appear for the peer.
- [ ] Connected VPN client reaches only the VPN panel at `10.66.66.1:51821`.
- [ ] Connected client can create, export, and revoke a peer.
- [ ] VPN-only, home-LAN, and full-tunnel modes behave as selected.
- [ ] DuckDNS automatically updates after reboot/network recovery.
- [ ] Logs reveal a failed WireGuard start, failed route setup, and failed DuckDNS update without leaking secrets.
- [ ] Reboot restores the enabled server once.
- [ ] Stop and uninstall remove `wg0`, daemon, and only module-owned routes/firewall rules.

## 17. Operational notes

- Configure a single UDP router port-forward rather than DMZ when practical.
- Keep the phone charging and disable battery optimization that could disrupt Wi-Fi.
- Use a dedicated device if possible.
- Back up server and peer keys before an uninstall if continued client identity matters.
- Create the first peer locally; remote management is available only after a client already has a working WireGuard configuration.
