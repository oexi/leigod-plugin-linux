# Leigod Router Plugin in Docker

Runs the Leigod (雷神加速器) router plugin — the OpenWrt build of `acc-gw` installed by the official
[`plugin_install.sh`](http://119.3.40.126/router_plugin/plugin_install.sh) — in a Docker container on any Linux box or RouterOS.
The container becomes a **Leigod bypass gateway**: point a device's gateway and DNS at it, then accelerate it in the Leigod app.

- Multi-arch image `ghcr.io/oexi/leigod-plugin-linux`: `linux/amd64`, `linux/arm64`, `linux/arm/v7`, each running Leigod's native static binary (no emulation)
- Downloads the plugin from Leigod's server on every start (falls back to the cached copy when offline)
- Configures the bypass gateway (forwarding, NAT, DNS) and announces itself over UPnP so the app can find it
- Only devices whose gateway points at the container go through it; the main router is not touched

## Run

The container needs its **own IP on the LAN subnet** (macvlan, or a RouterOS veth on the LAN bridge).
Edit the subnet, parent interface, IP and MAC in [`docker/docker-compose.yml`](docker/docker-compose.yml), then:

```sh
docker compose -f docker/docker-compose.yml up -d
docker exec leigod leigodctl status
```

Requirements: `NET_ADMIN` + `NET_RAW`, `/dev/net/tun`, `net.ipv4.ip_forward=1` and `send_redirects=0` in the container
(set as sysctls in the compose file; on RouterOS the entrypoint sets them itself), and a persistent volume on `/etc/leigod`.

**Keep the container's MAC address fixed.** The plugin reports the LAN MAC as its serial number;
a new MAC means a new router in the app, and the devices have to be set up again.

RouterOS: see [docs/routeros.md](docs/routeros.md).

## Set up LAN devices

On each device to accelerate (Switch / PS5 / Xbox / PC / phone):

| Setting | Value |
|---|---|
| IP / subnet mask | Same subnet as the main router (or keep DHCP) |
| **Gateway** | **The container's IP** |
| **DNS** | **The container's IP** |

Then bind the router in the Leigod app (路由器加速 → install/bind the router plugin):

1. Set the **phone's** gateway and DNS to the container too (static IP in the Wi-Fi settings), so the app talks to the container rather than the main router
2. If the main router (or RouterOS itself) has UPnP enabled, disable it while binding; the app finds routers over UPnP,
   and the container answers as an OpenWrt UPnP gateway
3. If the app says the router is not supported (路由器型号暂不支持加速), check whether it reached the container:

   ```sh
   docker logs leigod | grep UPnP                        # SSDP searches answered / description fetched by the phone
   docker exec leigod leigodctl plugin-log | grep '\[api\] req'   # requests from the app to the plugin (port 5588)
   ```

The plugin accelerates **by device category** (phone, PC, console, unknown): starting acceleration for a category in the app
accelerates every device of that category whose traffic passes through the container.
Devices are classified automatically (mDNS, NetBIOS, MAC vendor, HTTP User-Agent); fix a wrong guess with

```sh
docker exec leigod leigodctl devices
docker exec leigod leigodctl device AA:BB:CC:DD:EE:FF Windows   # XBox Switch PlayStation SteamDeck Windows MacBook Android iPhone ...
```

The plugin only proxies IPv4. The container's DNS drops AAAA answers (`FILTER_AAAA=1`) so that devices using it as DNS
do not bypass the accelerator over IPv6.

## Configuration

Environment variables:

| Variable | Default | Description |
|---|---|---|
| `LAN_IF` | interface of the default route | LAN interface |
| `GATEWAY` | `1` | Forward traffic of clients that use the container as gateway |
| `MASQUERADE` | `1` | SNAT forwarded traffic to the container's IP, so replies come back through it |
| `DNS` | `1` | Run dnsmasq on port 53 |
| `DNS_UPSTREAM` | from `/etc/resolv.conf` | Space-separated upstream DNS servers, e.g. `223.5.5.5 119.29.29.29` |
| `FILTER_AAAA` | `1` | Do not return IPv6 addresses from the container's DNS |
| `UPNP` | `1` | Announce the container over SSDP (needed for the app to find it) |
| `ACC_MODE` | `auto` | Plugin mode: `auto`, `tproxy`, `dnat` or `tun` |
| `UPDATE_ON_START` | `1` | Download the latest plugin on every start; `0` uses the cached copy once one exists |
| `PLUGIN_URL` | `http://119.3.40.126/router_plugin` | Where `acc-gw.linux.<arch>` is downloaded from |
| `USE_IPTABLES_NFT_BACKEND` | auto | `1` = iptables-nft, `0` = iptables-legacy (by default nft unless the kernel lacks nf_tables) |

`/etc/leigod` holds the plugin's uci config (`config/accelerator`: binding token, device types, acceleration state),
the cached plugin (`bin/acc-gw`) and the UPnP UUID.

## Manage

```sh
leigodctl status              # plugin, LAN address, binding and per-category acceleration state
leigodctl log [-f]            # this image's log (also in docker logs)
leigodctl plugin-log [-f]     # the plugin's own log
leigodctl devices             # devices seen on the LAN and their types
leigodctl device <MAC> <type> # override a device type
leigodctl restart             # restart the plugin
```

## Security note

The plugin regularly downloads and runs shell scripts pushed by Leigod's servers, and its local API (port 5588)
has a shell-command handler for the app. This is how it behaves on routers too. In this image it runs as root
inside the container only: do **not** use `--privileged` or `network_mode: host`.

## Status

Verified (2026-10-05, plugin version `202407250931`): the plugin starts on arm64 and armv7 (amd64 only as far as running the binary, under QEMU),
detects TPROXY + ipset, installs its rules, scans LAN devices; clients get internet and DNS through the container; SSDP discovery returns the container.

**Not verified yet:** binding in the Leigod app and actual acceleration — they need a Leigod account and a real LAN.
See [docs/implementation.md](docs/implementation.md) for how the plugin was made to run outside OpenWrt.

## License

[MIT](LICENSE) for this project's scripts and docs. The image also contains OpenWrt's `uci` (LGPL-2.1), see [third-party notices](THIRD_PARTY_NOTICES.md).

This project is not affiliated with or endorsed by Leigod. The plugin is Leigod's proprietary software;
it is not included here and is downloaded from Leigod's server when the container starts.
