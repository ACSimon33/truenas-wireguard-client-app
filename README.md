# TrueNAS WireGuard Client App

Generic WireGuard client container for running a persistent site-to-site VPN
endpoint as a TrueNAS SCALE Custom App.

The image is intentionally small: it renders a `wg-quick` config from
environment variables, stores changed configs as timestamped history, brings up
one WireGuard interface, optionally refreshes a dynamic DNS endpoint, and
removes the interface when the app is stopped.

## Why this exists

Manual host-level WireGuard changes on TrueNAS SCALE can be lost during system
upgrades. Running the client as a Custom App keeps the configuration in the
TrueNAS app database, lets you start and stop it from the GUI, and keeps the
Docker image lifecycle separate from the TrueNAS OS lifecycle.

## TrueNAS requirements

For the tunnel to affect the TrueNAS host network, install the image as a
Custom App with:

- Host Network enabled.
- Privileged enabled.
- Restart Policy set to `Unless Stopped` or `Always`.
- No port forwarding.
- Environment variables from the table below.

Privileged mode gives the container broad host access. That is necessary for the
simple Custom App setup because WireGuard, routes, iptables, and sysctl changes
must happen in the host network namespace. Only run images you built yourself or
trust.

## Environment variables

Required:

| Variable | Example | Description |
| --- | --- | --- |
| `WG_ADDRESS` | `10.255.0.2/32` | WireGuard address for this TrueNAS client. |
| `WG_PRIVATE_KEY` | `...` | Private key for this client. |
| `PEER_PUBLIC_KEY` | `...` | Public key of the remote WireGuard peer, for example OPNsense. |
| `PEER_ENDPOINT` | `wg.example.com:51820` | Remote endpoint hostname/IP and UDP port. |
| `PEER_ALLOWED_IPS` | `172.20.10.0/24,10.255.0.1/32` | Routes sent through the tunnel. |

Optional:

| Variable | Default | Description |
| --- | --- | --- |
| `WG_IF` | `wg0` | WireGuard interface name. |
| `WG_LISTEN_PORT` | empty | Optional local listen port. |
| `WG_DNS` | empty | Optional DNS line for `wg-quick`. Usually not needed here. |
| `WG_MTU` | empty | Optional MTU override. |
| `WG_TABLE` | empty | Optional routing table override. |
| `WG_FWMARK` | empty | Optional WireGuard fwmark. |
| `CONFIG_HISTORY_DIR` | `/config` | Directory for timestamped generated config history. |
| `WG_REPLACE_EXISTING` | `false` | Set to `true` to tear down an already-existing interface with the same `WG_IF` during startup. |
| `PEER_PRESHARED_KEY` | empty | Optional preshared key. |
| `PEER_PERSISTENT_KEEPALIVE` | `25` | Keepalive interval in seconds. |
| `RESOLVE_INTERVAL` | `0` | Set to seconds, for example `300`, to periodically re-resolve `PEER_ENDPOINT`. |
| `PRE_UP` | empty | Semicolon or newline separated `wg-quick` `PreUp` commands. |
| `POST_UP` | empty | Semicolon or newline separated `wg-quick` `PostUp` commands. |
| `PRE_DOWN` | empty | Semicolon or newline separated `wg-quick` `PreDown` commands. |
| `POST_DOWN` | empty | Semicolon or newline separated `wg-quick` `PostDown` commands. |

Use a `WG_IF` name that this app owns. If another host service already uses
`wg0`, either stop it first or set `WG_IF` to a different interface name.

On each startup, the app renders a config from the environment. Changed configs
are written to `${CONFIG_HISTORY_DIR}/${WG_IF}-YYYYMMDDTHHMMSSZ.conf`, and
`${CONFIG_HISTORY_DIR}/${WG_IF}.conf` is updated as a symlink to the newest
version. If the rendered config matches the newest saved version, no duplicate
history file is created.

Secret file alternatives are also supported for key material:

- `WG_PRIVATE_KEY_FILE`
- `PEER_PUBLIC_KEY_FILE`
- `PEER_PRESHARED_KEY_FILE`

## Example for the site layout

Assumptions:

- Site A LAN: `172.20.10.0/24`
- Site A TrueNAS IP: `172.20.10.10/32`
- Site A endpoint: `wg.example.com:51820`
- Site B LAN: `172.21.20.0/24`
- Site B TrueNAS WireGuard IP: `10.255.0.2/32`

TrueNAS Custom App environment variables:

```text
WG_ADDRESS=10.255.0.2/32
WG_PRIVATE_KEY=<site-b-private-key>
PEER_PUBLIC_KEY=<site-a-public-key>
PEER_ENDPOINT=wg.example.com:51820
PEER_ALLOWED_IPS=172.20.10.0/24,10.255.0.1/32
PEER_PERSISTENT_KEEPALIVE=25
RESOLVE_INTERVAL=300
```

With that setup, TrueNAS B can reach Site A through the tunnel. For TrueNAS
replication, point Site B at the Site A TrueNAS address (`172.20.10.10`), or
point Site A at `10.255.0.2` if you only need SSH to the TrueNAS B host.

If Site A should reach other hosts on `172.21.20.0/24` through TrueNAS B, add
forwarding rules. Replace `br0` with the actual TrueNAS LAN interface:

```text
PRE_UP=sysctl -w net.ipv4.ip_forward=1
POST_UP=iptables -A FORWARD -i wg0 -o br0 -j ACCEPT; iptables -A FORWARD -i br0 -o wg0 -j ACCEPT
POST_DOWN=iptables -D FORWARD -i wg0 -o br0 -j ACCEPT; iptables -D FORWARD -i br0 -o wg0 -j ACCEPT
```

If the Site B router does not have a static route back to `172.20.10.0/24`, add
masquerading so Site B LAN hosts see traffic as coming from TrueNAS B:

```text
POST_UP=iptables -A FORWARD -i wg0 -o br0 -j ACCEPT; iptables -A FORWARD -i br0 -o wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -s 172.20.10.0/24 -o br0 -j MASQUERADE; iptables -t nat -A POSTROUTING -s 10.255.0.0/24 -o br0 -j MASQUERADE
POST_DOWN=iptables -D FORWARD -i wg0 -o br0 -j ACCEPT; iptables -D FORWARD -i br0 -o wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -s 172.20.10.0/24 -o br0 -j MASQUERADE; iptables -t nat -D POSTROUTING -s 10.255.0.0/24 -o br0 -j MASQUERADE
```

On OPNsense, the peer for TrueNAS B must include routes that match what you want
to reach behind Site B, for example `10.255.0.2/32` and, if forwarding the whole
LAN, `172.21.20.0/24`.
