#!/bin/sh
# 容器入口（由 tini 启动）
#
#   1. 把容器网卡放进网桥 br-lan（插件只在网桥上找局域网设备），IP 和路由移到网桥上
#   2. 从雷神服务器下载/更新插件（acc-bundle-<arch>.tar.gz），失败时用 /etc/leigod/bin 里的缓存
#   3. 生成插件配置（/etc/config/*.ini、uci network），配置旁路网关（转发、NAT）
#   4. 后台运行 dnsmasq、UPnP 通告和插件，退出的自动重启
#   5. 收到 SIGTERM 时清理插件的规则、结束插件，再撤销网关规则

PATH=/usr/sbin:/usr/bin:/sbin:/bin
. /opt/leigod/bin/common.sh

CONF_KEYS="LAN_IF GATEWAY MASQUERADE DNS DNS_UPSTREAM FILTER_AAAA UPNP ACC_MODE PLUGIN_URL UPDATE_ON_START UPGRADE_MONITOR"
PIDS=""
PLUGIN_LOOP_PID=""
SLEEP_PID=""
TPROXY_IP="10.20.30.40"

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

# 插件的两个硬性要求：
#   - 只在网桥上监听邻居表、抓包识别设备：把容器网卡放进网桥 br-lan，IP 和路由移到网桥上
#     （网桥用网卡的 MAC，局域网里看到的地址不变）
#   - 用 /sys/class/net/eth0/address 作为 SN：网卡不叫 eth0 时（RouterOS 上叫 vethN），
#     建一个同 MAC 的占位接口 eth0（不改 RouterOS 管理的网卡名）
setup_bridge() {
    local port=$LAN_IF mac mtu addrs routes a r
    if [ "$port" = "$BRIDGE" ]; then
        log "网桥 ${BRIDGE} 已存在"
        return 0
    fi
    mac=$(cat "/sys/class/net/${port}/address")
    mtu=$(cat "/sys/class/net/${port}/mtu")
    addrs=$(ip -4 -o addr show dev "$port" scope global | awk '{print $4}')
    routes=$(ip -4 route show dev "$port" | grep -v ' proto kernel ')

    ip link add "$BRIDGE" type bridge stp_state 0 forward_delay 0 || die "创建网桥 ${BRIDGE} 失败"
    ip link set dev "$BRIDGE" address "$mac" mtu "$mtu"
    for a in $addrs; do
        ip addr del "$a" dev "$port"
    done
    ip link set dev "$port" master "$BRIDGE" || die "无法把 ${port} 加入网桥（ipvlan 网卡不能加入网桥，请改用 macvlan 或 veth）"
    ip link set dev "$port" up
    ip link set dev "$BRIDGE" up
    for a in $addrs; do
        ip addr add "$a" dev "$BRIDGE"
    done
    # 默认路由等非直连路由搬到网桥上
    echo "$routes" | while read -r r; do
        # shellcheck disable=SC2086
        [ -n "$r" ] && ip route replace $r dev "$BRIDGE"
    done
    log "已将 ${port} 加入网桥 ${BRIDGE}（MAC ${mac}，地址 $(echo $addrs)）"

    if ! iface_exists eth0; then
        { ip link add eth0 type dummy || ip link add eth0 type veth peer name eth0-peer; } 2>/dev/null \
            || die "无法创建占位接口 eth0"
        ip link set dev eth0 address "$mac"
        log "已创建占位接口 eth0（MAC ${mac}，插件用它作为 SN）"
    fi
    LAN_IF=$BRIDGE
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
    iptables -w -S >/dev/null 2>&1 || die "无法操作 iptables（docker 需要 --cap-add NET_ADMIN）"
}

# 加速模式：tproxy（需要内核 TPROXY 和 ipset）优先，否则 tun（与官方安装脚本的探测顺序相同）
detect_acc_mode() {
    local ok=1
    case "$ACC_MODE" in
        tproxy|tun) log "加速模式: ${ACC_MODE}（ACC_MODE 指定）"; return 0 ;;
    esac
    iptables -w -t mangle -N LEIGOD_PROBE 2>/dev/null
    iptables -w -t mangle -A LEIGOD_PROBE -p udp -j TPROXY --on-port 1 --on-ip 127.0.0.1 --tproxy-mark 0x1/0x1 2>/dev/null || ok=0
    iptables -w -t mangle -F LEIGOD_PROBE 2>/dev/null
    iptables -w -t mangle -X LEIGOD_PROBE 2>/dev/null
    if [ $ok = 1 ]; then
        { ipset create leigod_probe hash:net && ipset destroy leigod_probe; } 2>/dev/null || ok=0
    fi
    if [ $ok = 1 ]; then
        ACC_MODE=tproxy
    elif [ -c /dev/net/tun ]; then
        ACC_MODE=tun
        log "WARN: 内核不支持 TPROXY 或 ipset，降级为 tun 模式"
    else
        die "TPROXY/ipset 和 /dev/net/tun 都不可用（docker 需要 --device /dev/net/tun）"
    fi
    log "加速模式: ${ACC_MODE}"
}

# 下载插件包并安装到 /etc/leigod/bin（/usr/sbin/leigod 指向这里）
fetch_plugin() {
    local arch url tmp bin new cur
    arch=$(plugin_arch)
    bin=$(plugin_bin)
    url="${PLUGIN_URL%/}/acc-bundle-${arch}.tar.gz"
    cur=$(plugin_version "$bin")

    if [ -n "$cur" ] && [ "$UPDATE_ON_START" != "1" ]; then
        log "插件版本 ${cur}（UPDATE_ON_START=0，不检查更新）"
    else
        tmp="$LEIGOD_RUN_DIR/bundle"
        rm -rf "$tmp"
        mkdir -p "$tmp"
        log "下载插件: $url"
        if curl -fsSL --connect-timeout 10 --retry 2 -m 300 -o "$tmp/bundle.tar.gz" "$url" \
            && tar -xzf "$tmp/bundle.tar.gz" -C "$tmp" \
            && [ -s "$tmp/ipdatacloud_country.xdb" ] \
            && chmod +x "$tmp/${PLUGIN_PREFIX}.${arch}" \
            && new=$(plugin_version "$tmp/${PLUGIN_PREFIX}.${arch}") && [ -n "$new" ]; then
            if [ -n "$cur" ] && cmp -s "$tmp/${PLUGIN_PREFIX}.${arch}" "$bin"; then
                log "插件已是最新：版本 ${cur}"
            else
                mv -f "$tmp/${PLUGIN_PREFIX}.${arch}" "$bin"
                log "插件已${cur:+从 ${cur} }更新为版本 ${new}（${PLUGIN_PREFIX}.${arch}）"
            fi
            mv -f "$tmp/ipdatacloud_country.xdb" "$PLUGIN_CONF_DIR/ipdatacloud_country.xdb"
            # app 卸载插件时调用工作目录下的 leigod_uninstall.sh
            [ -f "$tmp/uninstall-runtime.sh" ] && mv -f "$tmp/uninstall-runtime.sh" "$PLUGIN_DIR/leigod_uninstall.sh"
        else
            [ -n "$cur" ] || die "插件下载失败且没有缓存，请检查网络（PLUGIN_URL=${PLUGIN_URL}）"
            log "WARN: 插件下载失败，使用缓存的版本 ${cur}"
        fi
        rm -rf "$tmp"
    fi
    # 升级程序是同一个二进制（官方安装脚本也是软链接）
    ln -sf "${PLUGIN_PREFIX}.${arch}" "$PLUGIN_DIR/acc_upgrade_monitor"
    [ -s "$PLUGIN_CONF_DIR/ipdatacloud_country.xdb" ] || die "缺少 IP 库 ${PLUGIN_CONF_DIR}/ipdatacloud_country.xdb"
}

# 插件配置，与官方安装脚本（router_plugin_new 的 lib/setup.sh）生成的相同
write_plugin_conf() {
    local addr
    if [ ! -s "$PLUGIN_CONF_DIR/accelerator.ini" ]; then
        cat > "$PLUGIN_CONF_DIR/accelerator.ini" <<EOT
[base]
url="https://opapi.xxghh.biz/speed/router/plug/check"
channel="2"
appid="nnMobile_d0k3duup"
heart="https://opapi.xxghh.biz/speed/router/heartbeat"
base_url="https://opapi.xxghh.biz/speed"

[update]
domain="https://opapi.xxghh.biz/nn-version/version/plug/upgrade"

[device]
EOT
        log "已生成 ${PLUGIN_CONF_DIR}/accelerator.ini"
    fi
    cat > "$PLUGIN_CONF_DIR/acc_firewall.ini" <<EOT
[firewall]
backend=iptables
mode=${ACC_MODE}
tproxy_ip=${TPROXY_IP}
EOT
    cat > "$PLUGIN_CONF_DIR/acc_version.ini" <<EOT
[info]
version="$(plugin_version "$(plugin_bin)")"
EOT

    # 插件从 uci network.lan 取本机网段；app 的流量统计读 network.wan 的网卡（旁路网关只有一个口，都指向网桥）
    addr=$(lan_addr)
    [ -f "$PLUGIN_CONF_DIR/network" ] || touch "$PLUGIN_CONF_DIR/network"
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
set network.wan=interface
set network.wan.device='$LAN_IF'
set network.wan.proto='static'
commit network
EOT
}

# 插件写的规则（与官方 acc.init 的 _clean_acc_rules 相同）
clean_plugin_rules() {
    local tbl built name
    for tbl in mangle filter nat; do
        case "$tbl" in filter) built=INPUT ;; *) built=PREROUTING ;; esac
        iptables -w -t "$tbl" -D "$built" -j GAMEACC 2>/dev/null
        iptables -w -t "$tbl" -F GAMEACC 2>/dev/null
        iptables -w -t "$tbl" -X GAMEACC 2>/dev/null
    done
    for name in $(ipset list -n 2>/dev/null); do
        case "$name" in
            direct_*|target_*|proxy_*) ipset destroy "$name" 2>/dev/null ;;
        esac
    done
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

# daemon 自己拉起 web（端口 5588）等子进程；用完整路径启动，插件靠 ps 输出里的路径找自己的进程
run_plugin() {
    local args="-r daemon -m ${ACC_MODE} -p 5588"
    [ "$ACC_MODE" = tproxy ] && args="$args -l ${TPROXY_IP}"
    cd "$PLUGIN_DIR" || exit 1
    # 上一次留下的子进程（web 等）先结束
    # shellcheck disable=SC2046
    kill -9 $(plugin_pids "-r daemon") $(plugin_pids "-r web") $(plugin_pids "-r acc") 2>/dev/null
    log "启动插件: $(plugin_bin) ${args}"
    # shellcheck disable=SC2086
    exec "$(plugin_bin)" $args >/dev/null 2>&1
}

run_upgrade_monitor() {
    cd "$PLUGIN_DIR" || exit 1
    exec "$PLUGIN_DIR/acc_upgrade_monitor" -r upgrade >/dev/null 2>&1
}

cleanup() {
    trap - TERM INT
    [ -n "$PLUGIN_LOOP_PID" ] && kill -TERM "$PLUGIN_LOOP_PID" 2>/dev/null
    [ -n "$PIDS" ] && kill -TERM $PIDS 2>/dev/null
    [ -n "$SLEEP_PID" ] && kill "$SLEEP_PID" 2>/dev/null
    # 先清规则再结束插件：规则删除后流量立即回到正常路由
    clean_plugin_rules
    # shellcheck disable=SC2046
    kill -9 $(plugin_pids) 2>/dev/null
    wait 2>/dev/null
    /opt/leigod/bin/gateway.sh down
    log "已停止"
}

# 设备关机后内核只把它的邻居表条目标成 STALE，表里不到 gc_thresh1（默认 128）条时不会回收；
# 插件只在条目被删除时把设备判为离线，app 里关机的设备就一直在。
# 探测 STALE 的条目，没有回应的和解析失败（FAILED）的删掉（设备再发包时会重新加入）
reap_stale_neigh() {
    local ip state
    ip -4 neigh show dev "$BRIDGE" nud stale nud failed 2>/dev/null | awk '{print $1, $NF}' | while read -r ip state; do
        [ "$state" = STALE ] && arping -q -f -c 2 -w 3 -I "$BRIDGE" "$ip" >/dev/null 2>&1 && continue
        ip neigh del "$ip" dev "$BRIDGE" 2>/dev/null && log "设备 ${ip} 无响应，已从邻居表删除（插件将其视为离线）"
    done
}

on_term() {
    log "收到停止信号"
    cleanup
    exit 0
}

# 重启容器（RouterOS、docker restart）时文件系统保留，网络是全新的：清掉上次运行的状态，
# 相当于路由器重启后 /tmp 被清空（env.conf 里的 LAN_IF=br-lan、插件的锁和运行状态等）
rm -rf "$LEIGOD_RUN_DIR" /tmp/acc /tmp/leigod_* /tmp/acc_*
mkdir -p "$(dirname "$LEIGOD_LOG_FILE")" "$LEIGOD_DIR/config" "$LEIGOD_DIR/bin" "$LEIGOD_RUN_DIR"
# 日志文件只保留本次启动的内容
: > "$LEIGOD_LOG_FILE"

load_conf
detect_lan_if || die "找不到局域网网卡（LAN_IF=${LAN_IF:-自动}）"
[ -n "$(lan_addr)" ] || die "${LAN_IF} 没有 IPv4 地址"
setup_bridge
write_env_conf
select_iptables_backend
check_env
detect_acc_mode
fetch_plugin

trap on_term TERM INT
/opt/leigod/bin/gateway.sh up || die "网关环境配置失败"
write_plugin_conf
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
if [ "$UPGRADE_MONITOR" = 1 ]; then
    respawn 升级程序 run_upgrade_monitor &
    PIDS="$PIDS $!"
fi
respawn 插件 run_plugin &
PLUGIN_LOOP_PID=$!

ip4=$(lan_ip)
log "局域网设备设置：网关 = ${ip4}    DNS = ${ip4}"

# 每分钟检查网关规则（防火墙重载、LAN 地址变化）、清理已离线设备的邻居表条目
while :; do
    sleep 60 &
    SLEEP_PID=$!
    wait "$SLEEP_PID"
    /opt/leigod/bin/gateway.sh ensure
    reap_stale_neigh
done
