# WireGuard Server for KernelSU

Use a rooted Android phone as a WireGuard server through a self-contained KernelSU module. It uses the included userspace `wireguard-go` binary, so no kernel WireGuard module is required.

## Features

- WireGuard server on `wg0` (UDP `51820` by default)
- Built-in `wireguard-go`, controller, and browser management panel
- Peer creation/revocation, `.conf` download, QR PNG export, and activity status
- DuckDNS update on save, boot, and every 10 minutes
- VPN-only, home-LAN, and full-tunnel routing modes
- Start after boot through KernelSU `service.sh`
- Browser panel and KernelSU Manager WebUI
- Rotating module logs

## Compatibility

Current package: **arm64-v8a only**. It was tested on a Xiaomi M2012K10C with KernelSU Next 1.1.1 and Android kernel 4.14.

A target phone needs:

- KernelSU and root access
- an arm64-v8a CPU
- root access to `/dev/net/tun`
- a fixed/reserved router DHCP address

## Install

1. Install [the release ZIP](dist/wireguard-server-ksu-v0.5.0.zip) from KernelSU Manager.
2. Reboot when KernelSU stages the module.
3. Forward `51820/UDP` on the home router to the phone’s reserved LAN IP.

The module contains all binaries; no separate APK or WireGuard kernel module is needed.

## Network layout

```text
Remote client → UDP 51820 → DuckDNS/public IP → router → Android phone

Phone LAN:       192.168.1.x
WireGuard server: 10.66.66.1/24
Panel:            http://PHONE_LAN_IP:51821
```

## Endpoint choices

For remote clients, use a hostname:

```ini
Endpoint = your-name.duckdns.org:51820
```

For clients on the same home LAN, use the phone LAN IP:

```ini
Endpoint = 192.168.1.172:51820
```

The panel supports manual endpoint entry and a **Use current LAN endpoint** suggestion. Applying an endpoint updates stored client configs; download them again afterward.

## Management panel

Open from the LAN:

```text
http://PHONE_LAN_IP:51821
```

It shows server state, configured/current LAN endpoint, active peers, DuckDNS state, last update, public IP, and logs. It also creates/revokes peers and exports configs or QR codes.

To expose it publicly, forward `51821/TCP` to the phone and use `http://YOUR_DUCKDNS_NAME:51821`. This grants full VPN administration to anyone who can reach the panel.

## DuckDNS

Enter your subdomain and token in the panel. It updates immediately, at boot, and every 10 minutes. **Disable DuckDNS** deletes the saved token and stops updates.

## Routing modes

| Mode | Client access |
|---|---|
| `vpn-only` | VPN subnet/panel only |
| `lan` | VPN plus configured home-LAN CIDR |
| `full` | All IPv4 traffic through the phone |

Set the LAN CIDR (for example `192.168.1.0/24`) before enabling LAN mode. The module removes its own routing/NAT rules when stopped.

## Logs

- Panel log card
- Android logcat tag: `WGServerKSU`
- Module file: `data/logs/server.log`

## Repository layout

```text
cmd/wgctl/   WireGuard UAPI controller
cmd/wgpanel/ Browser panel and DuckDNS updater
module/      KernelSU module payload
dist/        Installable packages
PLAN.md      Implementation plan
```
