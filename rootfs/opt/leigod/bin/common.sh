# shellcheck shell=sh
# leigod-docker.sh / gateway.sh / ssdp.sh / leigodctl 共用的函数与变量

LEIGOD_HOME="/opt/leigod"
LEIGOD_DIR="/etc/leigod"                 # 持久化卷：配置（/etc/config 指向这里）、插件、UPnP UUID
LEIGOD_RUN_DIR="/run/leigod"
LEIGOD_LOG_FILE="/var/log/leigod.log"    # 本镜像脚本的日志（插件自己的日志在 PLUGIN_LOG_DIR）
# 以下路径是插件（acc-gw.router 引擎）写死的
PLUGIN_DIR="/usr/sbin/leigod"            # 工作目录，指向 /etc/leigod/bin（插件自升级后也能保留）
PLUGIN_CONF_DIR="/etc/config"            # accelerator.ini、acc_firewall.ini、acc_version.ini、IP 库
PLUGIN_LOG_DIR="/tmp/acc/log"            # acc_daemon.log、web_api.log
PLUGIN_PREFIX="acc-gw.router"
PLUGIN_URL_DEFAULT="http://119.3.40.126/router_plugin_new"
BRIDGE="br-lan"                          # 插件只在网桥上找局域网设备

log() {
    echo "$*"
    echo "$(date '+%F %T') $*" >> "$LEIGOD_LOG_FILE"
    return 0
}

# 默认值；容器环境变量优先（入口脚本启动时写入 env.conf，leigodctl 等后启动的进程读取）
load_conf() {
    : "${LAN_IF:=}"
    : "${GATEWAY:=1}"
    : "${MASQUERADE:=1}"
    : "${DNS:=1}"
    : "${DNS_UPSTREAM:=}"
    : "${FILTER_AAAA:=1}"
    : "${UPNP:=1}"
    : "${ACC_MODE:=auto}"
    : "${PLUGIN_URL:=$PLUGIN_URL_DEFAULT}"
    : "${UPGRADE_MONITOR:=1}"
    : "${UPDATE_ON_START:=1}"
    # shellcheck disable=SC1091
    [ -f "$LEIGOD_RUN_DIR/env.conf" ] && . "$LEIGOD_RUN_DIR/env.conf"
    return 0
}

iface_exists() {
    ip link show dev "$1" >/dev/null 2>&1
}

# 未指定 LAN_IF 时取默认路由所在网卡
detect_lan_if() {
    if [ -z "$LAN_IF" ]; then
        LAN_IF=$(ip -4 route show default 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i + 1); exit}}')
    fi
    [ -n "$LAN_IF" ] && iface_exists "$LAN_IF"
}

# LAN 口第一个 IPv4 地址/前缀，如 192.168.1.2/24
lan_addr() {
    ip -4 -o addr show dev "$LAN_IF" scope global 2>/dev/null | awk '{print $4; exit}'
}

lan_ip() {
    lan_addr | cut -d/ -f1
}

# LAN 网段，如 192.168.1.0/24
lan_cidr() {
    ip -4 -o route show dev "$LAN_IF" scope link proto kernel 2>/dev/null | awk '$1 ~ /\// {print $1; exit}'
}

# 前缀长度转点分掩码
prefix_to_mask() {
    local p=$1 m="" i n
    for _ in 1 2 3 4; do
        if [ "$p" -ge 8 ]; then n=255; p=$((p - 8))
        else n=$((256 - (1 << (8 - p)))); p=0; fi
        m="${m:+$m.}$n"
    done
    echo "$m"
}

# 镜像架构对应的插件文件后缀（构建时写入；arm64 内核上跑 armv7 镜像时 uname -m 仍是 aarch64）
plugin_arch() {
    cat "$LEIGOD_HOME/plugin-arch"
}

plugin_bin() {
    echo "${PLUGIN_DIR}/${PLUGIN_PREFIX}.$(plugin_arch)"
}

# 按 cmdline 找插件进程：acc-gw.router.<arch> 超过 15 个字符，进程名被截断，pidof 找不到。
# 只看 argv[0] 是插件本身的进程（引擎会执行 sh -c "ps w | grep acc-gw.router..."，不能算进去）；
# 参数是要求 cmdline 中包含的固定字符串，如 "-r daemon"，省略则返回全部插件进程
plugin_pids() {
    local pattern=$1 p cmdline
    for p in /proc/[0-9]*; do
        cmdline=$( { tr '\0' ' ' < "$p/cmdline"; } 2>/dev/null ) || continue
        case "${cmdline%% *}" in
            *"/${PLUGIN_PREFIX}."*|*/acc_upgrade_monitor) ;;
            *) continue ;;
        esac
        case "$cmdline" in
            *"$pattern"*) echo "${p#/proc/}" ;;
        esac
    done
}

plugin_version() {
    "$1" -v 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+){3}' | head -n 1
}
