# Third-party notices

This project's own scripts and docs are under the [MIT license](LICENSE). The Docker image also contains:

| Component | License | Notes |
|---|---|---|
| [uci](https://git.openwrt.org/project/uci.git) (`/sbin/uci`) | LGPL-2.1 | OpenWrt's configuration CLI, built unmodified from source in `docker/Dockerfile` and statically linked with [libubox](https://git.openwrt.org/project/libubox.git) (ISC) |
| Alpine Linux packages | various | busybox, curl, dnsmasq, ipset, iproute2, iptables, socat, tini, installed from the Alpine repositories |

The Leigod router plugin (`acc-gw.router`, with its IP database) is proprietary software of Leigod (雷神). It is **not** included in this repository or the image;
the container downloads it from Leigod's server (`http://119.3.40.126/router_plugin_new/`) when it starts.
