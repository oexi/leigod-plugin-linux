# Implementation notes

Findings from running plugin version `202407250931` (the one served by `router_plugin/` in October 2026).

## The official installer

`plugin_install.sh` sources `plugin_common.sh` from the same server and, on OpenWrt:

- downloads `acc-gw.linux.<arch>` (`amd64`, `arm64`, `arm`, `mipsle`) to `/usr/sbin/leigod`
- creates the uci config `/etc/config/accelerator` (sections `base`, `bind`, `device`, `Phone`, `PC`, `Game`, `Unknown`
  and the `opapi.nn.com` URLs) — the entrypoint does the same on first start
- installs `/etc/init.d/acc` (procd, runs the binary without arguments, respawn) and a LuCI page

The binary is a static Go 1.20 program (UPX-packed, `nn.com/app/acc/cmd/gw`) with a built-in libpcap, so it has no library dependencies.
It calls `iptables`, `ipset`, `ip`, `tc` and `uci` as external commands.

## Getting it to run outside OpenWrt

The plugin picks a "board" at start: `/etc/board.json`, `/koolshare` / `/jffs/softcenter` (Asuswrt-Merlin), `/lib/libsec2_router.so`,
and `ID=openwrt` in `/etc/os-release`. On a plain Linux it falls back to a stub board (`fw: STUB-001`) that only looks for a
bridge named `br0` and exits without one.

With `ID=openwrt` it uses the OpenWrt board, which reads and writes everything through the `uci` CLI. The image therefore:

- replaces `/etc/os-release` with an OpenWrt one and adds `/etc/openwrt_release`
- builds OpenWrt's `uci` from source (static libubox) and links `/etc/config` to the volume `/etc/leigod/config`
- sets `accelerator.base.neigh` to the LAN interface (the LuCI "acc interface" option; without it the plugin looks for a bridge)
- writes `network.lan.ipaddr` / `netmask` from the container's address (the plugin reads the LAN subnet from there)
- provides `/etc/init.d/acc` that just kills the plugin, so the entrypoint restarts it

Other uci/ubus calls (Wi-Fi, DHCP, LED settings for Leigod's own routers) fail harmlessly.

## Runtime behaviour

- Command line used: `acc-gw --env release -i <LAN_IF> -d /etc/leigod/data --mode auto`.
  `--env debug` logs to stdout but talks to Leigod's **test** servers (`test-opapi.nn.com`), so it is not used
- Logs (debug level) go to `/tmp/acc/acc-gw.log-N.log`; version and start time to `/var/nn/acc-gw.app.ver` / `.start`
- A lock (`/tmp/acc-gw.running.lock`) makes a second instance — including `acc-gw --version` — exit with "this app already running";
  `--version` prints the bare version number to stderr
- Serial number: the plugin reports `{"model":"<arch>","sn":"<LAN MAC>","mac":"<LAN MAC>","brand":"openwrt"}`
- Listens on TCP 5588 (local API for the app, incl. bind/unbind and a `shellExec` handler), UDP 6066, and TCP/UDP `10.20.30.40:6699`
  (transparent proxy, `IP_TRANSPARENT`)
- Startup detection logs e.g. `[detect] ipset:1, tun:true, tcp:[TPROXY], udp:[TPROXY]`; `--mode auto` falls back to DNAT or tun
- Rules: chain `GAMEACC` in `mangle`/`nat` `PREROUTING` and `filter` `INPUT`; ipsets `acctarget_<cat>` (device IPs),
  `accproxy_<cat>` (game server IPs), `accdirect_<cat>`; TPROXY with mark `0x99`, `ip rule fwmark 0x99 lookup 99`.
  DNS (UDP 53) of target devices is also sent to the proxy. Private destinations are excluded
- Device discovery: `ip neigh` on the LAN interface, then mDNS / NetBIOS / Xbox / Steam Deck queries, MAC vendor lookup
  (`api.maclookup.app`), and sniffed HTTP User-Agents (pcap `tcp and dst port 80`). Manual types are `accelerator.device.<mac without colons>`
  with the LuCI numbering (1 Xbox, 2 Switch, 3 PlayStation, 4 Steam Deck, 5 Windows, 6 MacBook, 7 Android, 8 iPhone, 9 unknown, 20–22 VR)
- Remote config: the plugin periodically fetches a global config and a shell script (`/tmp/acc/acc-gw.shelltmp.sh`) and runs it;
  the current script only acts on Leigod's own A7000/A8000/N300 boxes and exits elsewhere (it logs an `[ERR] [cfg] exit status 1` with the script text)

## App discovery (UPnP)

According to community guides, the app finds the router over UPnP, and the plugin itself does not answer SSDP
(on OpenWrt, miniupnpd must be enabled). Alpine's miniupnpd only has the legacy iptables backend and would also offer port mappings,
so `ssdp.sh` implements just the discovery part with `socat` and `busybox httpd`: it answers `M-SEARCH`
for the IGD types and `ssdp:all` with a miniupnpd-style response, serves `rootDesc.xml` on port 5000, and sends `NOTIFY` every 30 s.
What exactly the app does after discovery is not known (the APK is packed), so this needs confirming with the real app.
