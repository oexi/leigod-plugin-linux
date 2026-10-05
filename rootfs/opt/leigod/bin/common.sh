# shellcheck shell=sh
# leigod-docker.sh / gateway.sh / ssdp.sh / leigodctl 共用的函数与变量

LEIGOD_HOME="/opt/leigod"
LEIGOD_DIR="/etc/leigod"                 # 持久化卷：uci 配置、插件缓存、UPnP UUID
LEIGOD_RUN_DIR="/run/leigod"
LEIGOD_LOG_FILE="/var/log/leigod.log"    # 本镜像脚本的日志（插件自己的日志在 PLUGIN_TMP_DIR）
PLUGIN_BIN="${LEIGOD_DIR}/bin/acc-gw"
PLUGIN_DATA_DIR="${LEIGOD_DIR}/data"
# 插件写死的路径：/tmp/acc 是 --tmp 默认值，日志 acc-gw.log-N.log 和云端下发的脚本都在这里
PLUGIN_TMP_DIR="/tmp/acc"
PLUGIN_URL_DEFAULT="http://119.3.40.126/router_plugin"

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

plugin_pid() {
    pidof acc-gw 2>/dev/null | awk '{print $1}'
}

# 插件当前的日志文件（acc-gw.log-N.log 中最新的）
plugin_log_file() {
    ls -t "$PLUGIN_TMP_DIR"/acc-gw.log-*.log 2>/dev/null | head -n 1
}
