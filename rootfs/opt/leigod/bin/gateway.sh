#!/bin/sh
# 旁路网关环境：转发、NAT、放行本机服务
#
#   gateway.sh up       开启转发、NAT，放行 DNS / UPnP
#   gateway.sh down     撤销 up 添加的规则
#   gateway.sh ensure   规则被冲掉 / LAN 地址变化时补回（入口脚本每分钟调用）
#   gateway.sh dns      前台运行 dnsmasq
#
# 加速相关的规则（GAMEACC 链、ipset、fwmark 0x99 策略路由）由插件自己维护，这里不碰。

PATH=/usr/sbin:/usr/bin:/sbin:/bin
. /opt/leigod/bin/common.sh

STATE_FILE="${LEIGOD_RUN_DIR}/gateway.state"
IPT="iptables -w"

# 容器里 /proc/sys 可能只读（root 下 -w 仍为真），写失败忽略，由 docker --sysctl 预先设置
sysctl_set() {
    local f="/proc/sys/$1"
    [ -w "$f" ] && [ "$(cat "$f")" != "$2" ] && echo "$2" 2>/dev/null > "$f"
    return 0
}

sysctl_up() {
    sysctl_set net/ipv4/ip_forward 1
    # 客户端和主路由在同一网段：不能发 ICMP 重定向把客户端"指"回主路由，否则流量绕过本机
    sysctl_set net/ipv4/conf/all/send_redirects 0
    sysctl_set net/ipv4/conf/default/send_redirects 0
    sysctl_set "net/ipv4/conf/${LAN_IF}/send_redirects" 0
    # 严格反向路径过滤会丢弃 TPROXY / tun 回来的包
    for i in all default "$LAN_IF"; do
        f="/proc/sys/net/ipv4/conf/$i/rp_filter"
        [ -w "$f" ] && [ "$(cat "$f")" = "1" ] && echo 2 2>/dev/null > "$f"
    done
    return 0
}

chain_reset() {
    $IPT -t "$1" -N "$2" 2>/dev/null || $IPT -t "$1" -F "$2"
}

jump_add() {
    $IPT -t "$1" -C "$2" -j "$3" 2>/dev/null || $IPT -t "$1" -I "$2" 1 -j "$3"
}

jump_del() {
    while $IPT -t "$1" -D "$2" -j "$3" 2>/dev/null; do :; done
    $IPT -t "$1" -F "$3" 2>/dev/null
    $IPT -t "$1" -X "$3" 2>/dev/null
}

rules_up() {
    local cidr="$1"

    chain_reset filter LEIGOD_IN
    if [ "$DNS" = "1" ]; then
        $IPT -A LEIGOD_IN -i "$LAN_IF" -p udp --dport 53 -j ACCEPT
        $IPT -A LEIGOD_IN -i "$LAN_IF" -p tcp --dport 53 -j ACCEPT
    fi
    if [ "$UPNP" = "1" ]; then
        $IPT -A LEIGOD_IN -i "$LAN_IF" -p udp --dport 1900 -j ACCEPT
        $IPT -A LEIGOD_IN -i "$LAN_IF" -p tcp --dport 5000 -j ACCEPT
    fi
    jump_add filter INPUT LEIGOD_IN

    if [ "$GATEWAY" = "1" ]; then
        # 兼容 FORWARD 默认策略为 DROP 的环境
        chain_reset filter LEIGOD_FWD
        $IPT -A LEIGOD_FWD -i "$LAN_IF" -j ACCEPT
        $IPT -A LEIGOD_FWD -o "$LAN_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
        jump_add filter FORWARD LEIGOD_FWD

        # 未加速的流量由本机转发给主路由；做 SNAT 让回程也经过本机（否则主路由直接回给客户端，
        # 本机只看到单向流量，conntrack 状态不完整）
        chain_reset nat LEIGOD_NAT
        if [ "$MASQUERADE" = "1" ] && [ -n "$cidr" ]; then
            $IPT -t nat -A LEIGOD_NAT -s "$cidr" ! -d "$cidr" -o "$LAN_IF" -j MASQUERADE
        fi
        jump_add nat POSTROUTING LEIGOD_NAT
    else
        jump_del filter FORWARD LEIGOD_FWD
        jump_del nat POSTROUTING LEIGOD_NAT
    fi
}

rules_down() {
    jump_del filter INPUT LEIGOD_IN
    jump_del filter FORWARD LEIGOD_FWD
    jump_del nat POSTROUTING LEIGOD_NAT
}

rules_present() {
    $IPT -C INPUT -j LEIGOD_IN 2>/dev/null || return 1
    if [ "$GATEWAY" = "1" ]; then
        $IPT -C FORWARD -j LEIGOD_FWD 2>/dev/null || return 1
        $IPT -t nat -C POSTROUTING -j LEIGOD_NAT 2>/dev/null || return 1
    fi
    return 0
}

signature() {
    echo "${LAN_IF} $(lan_cidr) gw=${GATEWAY} masq=${MASQUERADE} dns=${DNS} upnp=${UPNP}"
}

cmd_up() {
    local i=0
    while [ -z "$(lan_addr)" ] && [ $i -lt 60 ]; do
        [ $i = 0 ] && log "等待 ${LAN_IF} 获取 IPv4 地址..."
        sleep 1
        i=$((i + 1))
    done
    [ "$GATEWAY" = "1" ] && sysctl_up
    rules_up "$(lan_cidr)"
    mkdir -p "$LEIGOD_RUN_DIR"
    signature > "$STATE_FILE"
    log "网关环境就绪：LAN ${LAN_IF} $(lan_addr)，转发=${GATEWAY} NAT=${MASQUERADE} DNS=${DNS} UPnP=${UPNP}"
}

cmd_ensure() {
    if [ "$(cat "$STATE_FILE" 2>/dev/null)" = "$(signature)" ] && rules_present; then
        return 0
    fi
    log "检测到网关规则缺失或 LAN 地址变化，重新应用"
    cmd_up
}

cmd_dns() {
    local up
    set -- --keep-in-foreground --conf-file=/dev/null --pid-file= \
        --interface="$LAN_IF" --except-interface=lo --bind-dynamic --port=53 \
        --cache-size=2048 --user=dnsmasq --group=dnsmasq --log-facility=-

    # 插件只代理 IPv4。设备从主路由拿到 IPv6 时，游戏解析到 AAAA 就可能直接走 IPv6 出主路由、
    # 绕过加速；本机 DNS 不返回 AAAA（只影响 DNS 指向本机的设备）
    [ "$FILTER_AAAA" = "1" ] && set -- "$@" --filter-AAAA

    if [ -n "$DNS_UPSTREAM" ]; then
        set -- "$@" --no-resolv
        for up in $DNS_UPSTREAM; do
            set -- "$@" --server="$up"
        done
    else
        set -- "$@" --resolv-file=/etc/resolv.conf
    fi

    log "启动 dnsmasq，监听 ${LAN_IF} 的 53 端口，过滤 AAAA=${FILTER_AAAA}"
    exec dnsmasq "$@"
}

load_conf
if ! detect_lan_if; then
    log "ERROR: 找不到局域网网卡（LAN_IF=${LAN_IF:-自动}）"
    [ "$1" = "down" ] && { rules_down; exit 0; }
    exit 1
fi

case "$1" in
    up)     cmd_up ;;
    down)   rules_down; rm -f "$STATE_FILE" ;;
    ensure) cmd_ensure ;;
    dns)    cmd_dns ;;
    *)
        echo "用法: $0 {up|down|ensure|dns}" >&2
        exit 2
        ;;
esac
