#!/bin/sh
# 容器入口（由 tini 启动）
#
#   1. 生成 uci 配置（插件靠 /etc/os-release 的 ID=openwrt 走 OpenWrt 分支，配置都通过 uci 读写）
#   2. 从雷神服务器下载/更新插件，失败时用 /etc/leigod/bin 里的缓存
#   3. 配置旁路网关（转发、NAT），后台运行 dnsmasq、UPnP 通告和插件，退出的自动重启
#   4. 收到 SIGTERM 时让插件自行清理规则后退出，再撤销网关规则

PATH=/usr/sbin:/usr/bin:/sbin:/bin
. /opt/leigod/bin/common.sh

CONF_KEYS="LAN_IF GATEWAY MASQUERADE DNS DNS_UPSTREAM FILTER_AAAA UPNP ACC_MODE PLUGIN_URL UPDATE_ON_START"
PIDS=""
PLUGIN_LOOP_PID=""
SLEEP_PID=""

die() {
    log "ERROR: $*"
    exit 1
}

# 记录最终配置，leigodctl 等后启动的进程读取（RouterOS 的 container shell 不一定带容器环境变量）
write_env_conf() {
    local k v
    mkdir -p "$LEIGOD_RUN_DIR"
    : > "$LEIGOD_RUN_DIR/env.conf"
    for k in $CONF_KEYS; do
        eval "v=\$$k"
        printf "%s='%s'\n" "$k" "$(printf '%s' "$v" | sed "s/'/'\\\\''/g")" >> "$LEIGOD_RUN_DIR/env.conf"
    done
}

# USE_IPTABLES_NFT_BACKEND=1 用 nft，0 用 legacy；默认：nf_tables 可用且 legacy 里没有更多规则时用 nft
select_iptables_backend() {
    local backend nft legacy n
    case "$USE_IPTABLES_NFT_BACKEND" in
        1) backend=nft ;;
        0) backend=legacy ;;
        *)
            if ! xtables-nft-multi iptables -w 10 -S >/dev/null 2>&1; then
                backend=legacy
            else
                nft=$(xtables-nft-multi iptables-save 2>/dev/null | grep -c '^-A')
                legacy=$(xtables-legacy-multi iptables-save 2>/dev/null | grep -c '^-A')
                if [ "$legacy" -gt "$nft" ]; then backend=legacy; else backend=nft; fi
            fi
            ;;
    esac
    # 插件直接调用 iptables，把命令指向选定的后端
    for n in iptables ip6tables; do
        ln -sf "xtables-${backend}-multi" "/usr/sbin/$n"
        ln -sf "xtables-${backend}-multi" "/usr/sbin/$n-save"
        ln -sf "xtables-${backend}-multi" "/usr/sbin/$n-restore"
    done
    log "iptables 后端: ${backend}"
}

check_env() {
    if [ ! -c /dev/net/tun ]; then
        mkdir -p /dev/net
        mknod /dev/net/tun c 10 200 2>/dev/null && chmod 666 /dev/net/tun
    fi
    [ -c /dev/net/tun ] || log "WARN: /dev/net/tun 不可用（docker 需要 --device /dev/net/tun），tun 加速模式无法使用"
    iptables -w -S >/dev/null 2>&1 || die "无法操作 iptables（docker 需要 --cap-add NET_ADMIN）"
    ipset list -n >/dev/null 2>&1 || log "WARN: ipset 不可用（内核缺少 ip_set 模块？），插件会退回较慢的模式"
}

# 插件读写的 uci 配置：/etc/config 是指向 /etc/leigod/config 的软链接
setup_uci() {
    local addr
    mkdir -p "$LEIGOD_DIR/config"
    if [ ! -s /etc/config/accelerator ]; then
        # 与官方安装脚本 plugin_common.sh 的 install_openwrt_series_config 相同
        touch /etc/config/accelerator
        uci -q batch <<EOT
set accelerator.base=system
set accelerator.bind=bind
set accelerator.device=hardware
set accelerator.Phone=acceleration
set accelerator.PC=acceleration
set accelerator.Game=acceleration
set accelerator.Unknown=acceleration
set accelerator.base.url='https://opapi.nn.com/speed/router/plug/check'
set accelerator.base.heart='https://opapi.nn.com/speed/router/heartbeat'
set accelerator.base.base_url='https://opapi.nn.com/speed'
commit accelerator
EOT
        log "已生成 /etc/config/accelerator"
    fi
    # 插件抓包、扫描设备、设置 TPROXY 用的网卡（OpenWrt 上 luci "设备管理 -> 路由设备"）
    uci -q set accelerator.base.neigh="$LAN_IF"
    uci -q commit accelerator

    # 插件从 network.lan 取本机网段
    addr=$(lan_addr)
    : > /etc/config/network
    uci -q batch <<EOT
set network.loopback=interface
set network.loopback.device='lo'
set network.loopback.proto='static'
set network.loopback.ipaddr='127.0.0.1'
set network.loopback.netmask='255.0.0.0'
set network.lan=interface
set network.lan.device='$LAN_IF'
set network.lan.proto='static'
set network.lan.ipaddr='${addr%/*}'
set network.lan.netmask='$(prefix_to_mask "${addr#*/}")'
commit network
EOT
}

# 校验下载的插件：ELF 且能输出版本号
plugin_version() {
    [ "$(head -c 4 "$1" 2>/dev/null | tail -c 3)" = "ELF" ] || return 1
    chmod +x "$1"
    "$1" --version 2>&1 | grep -oE '[0-9]{8,}' | head -n 1
}

fetch_plugin() {
    local arch url tmp new cur
    arch=$(plugin_arch)
    url="${PLUGIN_URL%/}/acc-gw.linux.${arch}"
    mkdir -p "$(dirname "$PLUGIN_BIN")"
    cur=$(plugin_version "$PLUGIN_BIN")

    if [ -n "$cur" ] && [ "$UPDATE_ON_START" != "1" ]; then
        log "插件版本 ${cur}（UPDATE_ON_START=0，不检查更新）"
        return 0
    fi

    tmp="${PLUGIN_BIN}.download"
    rm -f "$tmp"
    log "下载插件: $url"
    if curl -fsSL --connect-timeout 10 --retry 2 -m 300 -o "$tmp" "$url" && new=$(plugin_version "$tmp"); then
        if [ -n "$cur" ] && cmp -s "$tmp" "$PLUGIN_BIN"; then
            rm -f "$tmp"
            log "插件已是最新：版本 ${cur}"
        else
            mv -f "$tmp" "$PLUGIN_BIN"
            log "插件已${cur:+从 ${cur} }更新为版本 ${new}（acc-gw.linux.${arch}）"
        fi
        return 0
    fi
    rm -f "$tmp"
    [ -n "$cur" ] || die "插件下载失败且没有缓存，请检查网络（PLUGIN_URL=${PLUGIN_URL}）"
    log "WARN: 插件下载失败，使用缓存的版本 ${cur}"
}

# 子进程退出后 5 秒重启（相当于 procd 的 respawn）
respawn() {
    local name=$1 child
    shift
    trap 'kill -TERM "$child" 2>/dev/null; wait "$child"; exit 0' TERM
    while :; do
        "$@" &
        child=$!
        wait "$child"
        log "${name} 退出 ($?)，5 秒后重启"
        sleep 5
    done
}

run_plugin() {
    mkdir -p "$PLUGIN_DATA_DIR" "$PLUGIN_TMP_DIR"
    cd "$PLUGIN_DATA_DIR" || exit 1
    log "启动插件: acc-gw --env release -i ${LAN_IF} --mode ${ACC_MODE}"
    exec "$PLUGIN_BIN" --env release -i "$LAN_IF" -d "$PLUGIN_DATA_DIR" --mode "$ACC_MODE" >/dev/null 2>&1
}

cleanup() {
    trap - TERM INT
    # 先停插件：它收到 SIGTERM 后删除自己的 iptables / ipset / 策略路由
    if [ -n "$PLUGIN_LOOP_PID" ]; then
        kill -TERM "$PLUGIN_LOOP_PID" 2>/dev/null
        wait "$PLUGIN_LOOP_PID" 2>/dev/null
    fi
    [ -n "$PIDS" ] && kill -TERM $PIDS 2>/dev/null
    [ -n "$SLEEP_PID" ] && kill "$SLEEP_PID" 2>/dev/null
    wait 2>/dev/null
    /opt/leigod/bin/gateway.sh down
    log "已停止"
}

on_term() {
    log "收到停止信号"
    cleanup
    exit 0
}

# 日志文件只保留本次启动的内容
mkdir -p "$(dirname "$LEIGOD_LOG_FILE")" "$LEIGOD_DIR"
: > "$LEIGOD_LOG_FILE"

load_conf
detect_lan_if || die "找不到局域网网卡（LAN_IF=${LAN_IF:-自动}）"
write_env_conf
select_iptables_backend
check_env
fetch_plugin

trap on_term TERM INT
/opt/leigod/bin/gateway.sh up || die "网关环境配置失败"
setup_uci
if [ "$GATEWAY" = 1 ] && [ "$(cat /proc/sys/net/ipv4/ip_forward)" != 1 ]; then
    log "WARN: net.ipv4.ip_forward 未开启，局域网设备无法通过本容器上网（docker 加 --sysctl net.ipv4.ip_forward=1）"
fi
if [ "$GATEWAY" = 1 ] && [ "$(cat /proc/sys/net/ipv4/conf/all/send_redirects)" != 0 ]; then
    log "WARN: net.ipv4.conf.all.send_redirects 未关闭，客户端可能被 ICMP 重定向到主路由而绕过本机" \
        "（docker 加 --sysctl net.ipv4.conf.all.send_redirects=0）"
fi

if [ "$DNS" = 1 ]; then
    respawn dnsmasq /opt/leigod/bin/gateway.sh dns &
    PIDS="$PIDS $!"
fi
if [ "$UPNP" = 1 ]; then
    respawn "UPnP 通告" /opt/leigod/bin/ssdp.sh run &
    PIDS="$PIDS $!"
fi
respawn 插件 run_plugin &
PLUGIN_LOOP_PID=$!

ip4=$(lan_ip)
log "局域网设备设置：网关 = ${ip4}    DNS = ${ip4}"

# 每分钟检查网关规则（防火墙重载、LAN 地址变化）
while :; do
    sleep 60 &
    SLEEP_PID=$!
    wait "$SLEEP_PID"
    /opt/leigod/bin/gateway.sh ensure
done
