# Implementation notes

## Two generations of the plugin

| | Legacy | Current |
|---|---|---|
| Installer | `http://119.3.40.126/router_plugin/plugin_install.sh` | `http://119.3.40.126/router_plugin_new/plugin_install.sh` |
| Binary | `acc-gw.linux.<arch>` (Go, version `202407250931`) | `acc-gw.router.<arch>` (C++, version `1.2.2.52` in October 2026), in `acc-bundle-<arch>.tar.gz` |
| Config | uci `/etc/config/accelerator` | `/etc/config/accelerator.ini`, `acc_firewall.ini`, `acc_version.ini`, `ipdatacloud_country.xdb` |

The image first used the legacy plugin. With it, the Leigod app found the container (UDP broadcast to 6066, a WebSocket
exchange on 5588, UPnP) but then asked for the router's username and password to *install* the plugin — the app
did not accept the old plugin as installed. The community manager script
([openwrt-leigodacc-manager](https://github.com/miaoermua/openwrt-leigodacc-manager)) installs from `router_plugin_new`,
so the image now runs the current engine. The bundles exist for `amd64`, `arm64` and `arm` (`mipsel` is missing).

## The current installer

`plugin_install.sh` downloads `acc-lib.tar.gz` (`lib/base.sh`, `lib/setup.sh`, `platform/{openwrt,asus,xiaomi}.sh`) and runs
a 9-step state machine. On OpenWrt:

- detects the firewall backend (iptables if present, else nftables) and the mode: `tproxy` if `xt_TPROXY` loads, otherwise `tun`
- extracts the bundle to `/usr/sbin/leigod` (binary, `monitor.sh`, `acc.init`, `uninstall-runtime.sh` → `leigod_uninstall.sh`)
  and moves `ipdatacloud_country.xdb` to `/etc/config`; `acc_upgrade_monitor` is a symlink to the binary
- writes `accelerator.ini` (`opapi.xxghh.biz` URLs), `acc_firewall.ini` (`backend`, `mode`, `tproxy_ip=10.20.30.40`) and `acc_version.ini`
- installs `/etc/init.d/acc` (procd), which runs `acc-gw.router.<arch> -r daemon -m <mode> -p 5588 [-l 10.20.30.40]`
  and `acc_upgrade_monitor -r upgrade`

The entrypoint reproduces these files and runs the same two commands under its own respawn loop.

## Getting it to run in a container

- **Board detection** (`Board.cpp`): `/etc/board.json` (Leigod's own routers), then `/etc/openwrt_release` / `/etc/os-release`
  → "openwrt router, brand: openwrt, model: OpenWrt router". The image ships OpenWrt-looking release files
- **`ps` format**: the daemon finds its children with `ps w | grep ...` and parses OpenWrt busybox columns
  (`PID USER VSZ STAT COMMAND`). Alpine's busybox prints `PID USER TIME COMMAND`, so the daemon read `-r` as the process name,
  believed `web` was not running and forked a new one every 5 s. `/usr/sbin/ps` prints the OpenWrt columns
- **Bridge**: device discovery (`NetlinkListener.cpp`) scans `/sys/class/net/*/bridge` for a bridge (ignoring `docker0` and `br-miot`)
  and falls back to `br-lan`; pcap also opens that bridge. There is no setting for it, so the entrypoint creates `br-lan`,
  enslaves the container interface and moves its addresses and routes onto the bridge (same MAC). veth and macvlan can be bridge ports, ipvlan cannot
- **Serial number**: read from `/sys/class/net/eth0/address`. On RouterOS the interface is `vethN`, so a placeholder `eth0`
  (dummy, or a veth pair if the kernel has no dummy module) with the same MAC is created rather than renaming the RouterOS-managed interface
- **Process names**: `acc-gw.router.<arch>` and `acc_upgrade_monitor` exceed the 15-character `comm`, so `pidof` cannot find them;
  scripts match `/proc/*/cmdline` (only processes whose argv[0] is the plugin)
- `uci` is still used for a few lookups, so the image keeps OpenWrt's `uci`: `network.lan.ipaddr/netmask` (LAN subnet),
  `accelerator.base.token`, and for the app's traffic statistics `network.wan.ifname` → `network.wan.device` → `network.wan.neigh`
  → `accelerator.base.neigh` (the interface whose `/proc/net/dev` counters are reported). Without a WAN entry every `statistics`
  request from the app failed with "get wan traffic failed"; the entrypoint points both `network.lan` and `network.wan` at `br-lan`.
  `ubus` calls (Wi-Fi status, LED) fail harmlessly

## Runtime behaviour

- `daemon` supervises `web` (`-r web`, TCP 5588 app API, TCP 10001, UDP 6066 discovery) and per-category accelerator processes;
  the app API is a WebSocket on port 5588 carrying JSON `{"cmd": "...", "sn": "<eth0 MAC>", "data": {"token": ...}}`
  (e.g. `getRouterInfo`, `statistics`, `startAcc`), logged in `web_api.log` as `[api] request: ... response: ...`.
  In `tun` mode, starting acceleration creates `tun_<category>` interfaces and `fwmark 0x102`/`0x103` policy-routing rules;
  `acc_upgrade_monitor -r upgrade` checks for updates ("don't need to upgrade, local version: 1.2.2.52")
- Self-upgrade (seen 1.2.2.52 → 1.2.2.64): the monitor downloads the package, starts the new binary to install it and exits 0;
  the installer replaces the binary, kills `daemon` and starts a new `acc_upgrade_monitor` itself (reparented to tini).
  A second monitor only logs "acc upgrade monitor already running, will exit", so the entrypoint waits for an existing
  monitor to exit before starting its own
- Logs: `/tmp/acc/log/acc_daemon.log`, `web_api.log`, `acc_upgrade.log`; state: `/tmp/acc/acc_core_conf.json`
- Downloads a MAC vendor list for consoles (`mac.json`), a global config from `opapi.xxghh.biz`, and connects to
  `route-turn.xxghh.biz` (cloud relay for the app)
- Rules are created only when acceleration starts: chain `GAMEACC` in `mangle`/`nat` `PREROUTING` and `filter` `INPUT`,
  ipsets `direct_*`, `target_*`, `proxy_*`, TPROXY to `10.20.30.40` with mark `0x99`. On stop the entrypoint removes them
  the same way the official `acc.init` does, before killing the processes
- When acceleration starts for a device the plugin runs `conntrack -D --orig-src <device IP>`, so that connections opened
  before it are re-created through the accelerator instead of keeping their old NAT state; the image ships `conntrack-tools` for this
- A malformed request to the web API (e.g. a plain `POST /api`) makes `web` abort; `daemon` restarts it

## App discovery (UPnP)

Community guides say the app finds the router over UPnP (on OpenWrt miniupnpd must be enabled), and the plugin itself does not answer SSDP.
Alpine's miniupnpd only has the legacy iptables backend and would also offer port mappings,
so `ssdp.sh` implements just the discovery part with `socat` and `busybox httpd`: it answers `M-SEARCH`
for the IGD types and `ssdp:all` with a miniupnpd-style response, serves `rootDesc.xml` on port 5000, and sends `NOTIFY` every 30 s.
The strings match miniupnpd built for OpenWrt (`OS_NAME=OpenWrt`: friendly/model name `OpenWrt router`, manufacturer `OpenWrt`).
Answered searches, unanswered search types (once per source and type) and description requests are logged with a `UPnP` prefix.
With the description saying `Leigod <iface>` the app answered "路由器型号暂不支持加速"; with the OpenWrt strings it accepted the router.

## Legacy plugin notes

`acc-gw.linux` (Go 1.20, UPX-packed) picks the OpenWrt board from `ID=openwrt` in `/etc/os-release` and keeps all settings in uci
(`accelerator.base.neigh` = LAN interface). It logs to `/tmp/acc/acc-gw.log-N.log`, answers `POST /api {"cmd": ...}` on 5588
(e.g. `getRouterInfo` → `model` = uname arch, `brand` = openwrt, `fwver` = `DISTRIB_REVISION`), and periodically fetches and runs a
shell script from Leigod's servers. It is no longer used by the image.
