#!/bin/sh
# 最小 UPnP（SSDP）通告：让雷神 app 能在局域网里发现本机
#
# 雷神 app 绑定路由器插件时靠 UPnP 发现装了插件的路由器（OpenWrt 上需要开启 miniupnpd），
# 插件本身不发 SSDP。这里只模拟 miniupnpd 的 IGD 设备描述和 SSDP 应答，不提供端口映射。
#
#   ssdp.sh run      前台运行：HTTP 描述（:5000）+ M-SEARCH 应答 + 周期 NOTIFY
#   ssdp.sh reply    由 socat 为每个收到的 SSDP 报文调用（stdin 是报文）

PATH=/usr/sbin:/usr/bin:/sbin:/bin
. /opt/leigod/bin/common.sh

SSDP_ADDR=239.255.255.250
HTTP_PORT=5000
WWW_DIR="${LEIGOD_RUN_DIR}/upnp"
UUID_FILE="${LEIGOD_DIR}/upnp.uuid"
SERVER="OpenWrt/24.10 UPnP/1.1 MiniUPnPd/2.3.7"
MAX_AGE=120

uuid() {
    cat "$UUID_FILE"
}

# 应答的 ST 和对应的 USN
usn_for() {
    case "$1" in
        uuid:*) echo "$1" ;;
        *)      echo "uuid:$(uuid)::$1" ;;
    esac
}

# 本机支持的类型（不区分大小写匹配 M-SEARCH 的 ST）
st_supported() {
    case "$1" in
        upnp:rootdevice|uuid:"$(uuid)") return 0 ;;
        urn:schemas-upnp-org:device:InternetGatewayDevice:[12]) return 0 ;;
        urn:schemas-upnp-org:device:WANDevice:[12]) return 0 ;;
        urn:schemas-upnp-org:device:WANConnectionDevice:[12]) return 0 ;;
        urn:schemas-upnp-org:service:WANIPConnection:[12]) return 0 ;;
        urn:schemas-upnp-org:service:WANCommonInterfaceConfig:1) return 0 ;;
    esac
    return 1
}

cmd_reply() {
    local line st="" man="" method="" ip
    # 报文以空行结束；socat 不关闭 stdin，用超时防止卡住
    while IFS= read -r -t 1 line; do
        line=$(printf '%s' "$line" | tr -d '\r')
        [ -z "$method" ] && { method=$line; continue; }
        [ -z "$line" ] && break
        case "$(printf '%s' "${line%%:*}" | tr 'A-Z' 'a-z')" in
            st)  st=$(printf '%s' "${line#*:}" | sed 's/^ *//; s/ *$//') ;;
            man) man=${line#*:} ;;
        esac
    done
    case "$method" in "M-SEARCH "*) ;; *) return 0 ;; esac
    case "$man" in *ssdp:discover*) ;; *) return 0 ;; esac

    [ "$st" = "ssdp:all" ] && st="urn:schemas-upnp-org:device:InternetGatewayDevice:1"
    st_supported "$st" || return 0

    ip=$(lan_ip)
    printf 'HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=%s\r\nST: %s\r\nUSN: %s\r\nEXT:\r\nSERVER: %s\r\nLOCATION: http://%s:%s/rootDesc.xml\r\nOPT: "http://schemas.upnp.org/upnp/1/0/"; ns=01\r\n01-NLS: 1\r\nBOOTID.UPNP.ORG: 1\r\nCONFIGID.UPNP.ORG: 1337\r\n\r\n' \
        "$MAX_AGE" "$st" "$(usn_for "$st")" "$SERVER" "$ip" "$HTTP_PORT"
}

write_desc() {
    local u model
    u=$(uuid)
    model="Leigod ${LAN_IF}"
    mkdir -p "$WWW_DIR"
    cat > "$WWW_DIR/rootDesc.xml" <<EOT
<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0" configId="1337">
<specVersion><major>1</major><minor>1</minor></specVersion>
<device>
<deviceType>urn:schemas-upnp-org:device:InternetGatewayDevice:1</deviceType>
<friendlyName>OpenWrt router</friendlyName>
<manufacturer>OpenWrt</manufacturer>
<manufacturerURL>https://openwrt.org/</manufacturerURL>
<modelDescription>OpenWrt router</modelDescription>
<modelName>${model}</modelName>
<modelNumber>1</modelNumber>
<modelURL>https://openwrt.org/</modelURL>
<serialNumber>00000000</serialNumber>
<UDN>uuid:${u}</UDN>
<serviceList><service>
<serviceType>urn:schemas-upnp-org:service:Layer3Forwarding:1</serviceType>
<serviceId>urn:upnp-org:serviceId:L3Forwarding1</serviceId>
<SCPDURL>/L3F.xml</SCPDURL><controlURL>/ctl/L3F</controlURL><eventSubURL>/evt/L3F</eventSubURL>
</service></serviceList>
<deviceList><device>
<deviceType>urn:schemas-upnp-org:device:WANDevice:1</deviceType>
<friendlyName>WANDevice</friendlyName>
<manufacturer>MiniUPnP</manufacturer>
<modelName>WAN Device</modelName>
<UDN>uuid:${u%?}1</UDN>
<serviceList><service>
<serviceType>urn:schemas-upnp-org:service:WANCommonInterfaceConfig:1</serviceType>
<serviceId>urn:upnp-org:serviceId:WANCommonIFC1</serviceId>
<SCPDURL>/WANCfg.xml</SCPDURL><controlURL>/ctl/CmnIfCfg</controlURL><eventSubURL>/evt/CmnIfCfg</eventSubURL>
</service></serviceList>
<deviceList><device>
<deviceType>urn:schemas-upnp-org:device:WANConnectionDevice:1</deviceType>
<friendlyName>WANConnectionDevice</friendlyName>
<manufacturer>MiniUPnP</manufacturer>
<modelName>MiniUPnPd</modelName>
<UDN>uuid:${u%?}2</UDN>
<serviceList><service>
<serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType>
<serviceId>urn:upnp-org:serviceId:WANIPConn1</serviceId>
<SCPDURL>/WANIPCn.xml</SCPDURL><controlURL>/ctl/IPConn</controlURL><eventSubURL>/evt/IPConn</eventSubURL>
</service></serviceList>
</device></deviceList>
</device></deviceList>
<presentationURL>http://$(lan_ip)/</presentationURL>
</device>
</root>
EOT
}

notify_one() {
    local nt=$1 ip
    ip=$(lan_ip)
    [ -n "$ip" ] || return 0
    printf 'NOTIFY * HTTP/1.1\r\nHOST: %s:1900\r\nCACHE-CONTROL: max-age=%s\r\nLOCATION: http://%s:%s/rootDesc.xml\r\nSERVER: %s\r\nNT: %s\r\nUSN: %s\r\nNTS: ssdp:alive\r\nOPT: "http://schemas.upnp.org/upnp/1/0/"; ns=01\r\n01-NLS: 1\r\nBOOTID.UPNP.ORG: 1\r\nCONFIGID.UPNP.ORG: 1337\r\n\r\n' \
        "$SSDP_ADDR" "$MAX_AGE" "$ip" "$HTTP_PORT" "$SERVER" "$nt" "$(usn_for "$nt")" \
        | socat -u - "UDP4-DATAGRAM:${SSDP_ADDR}:1900,ip-multicast-if=${ip},ip-multicast-ttl=2" 2>/dev/null
}

notify_loop() {
    while :; do
        for nt in upnp:rootdevice "uuid:$(uuid)" urn:schemas-upnp-org:device:InternetGatewayDevice:1 \
            urn:schemas-upnp-org:service:WANIPConnection:1; do
            notify_one "$nt"
        done
        sleep 30
    done
}

cmd_run() {
    local ip pids=""
    ip=$(lan_ip)
    [ -n "$ip" ] || { log "ERROR: ${LAN_IF} 没有 IPv4 地址，UPnP 通告未启动"; exit 1; }
    [ -s "$UUID_FILE" ] || cat /proc/sys/kernel/random/uuid > "$UUID_FILE"
    write_desc

    trap 'kill $pids 2>/dev/null; exit 0' TERM INT
    busybox-extras httpd -f -p "${ip}:${HTTP_PORT}" -h "$WWW_DIR" &
    pids="$pids $!"
    socat -T 2 "UDP4-RECVFROM:1900,ip-add-membership=${SSDP_ADDR}:${ip},reuseaddr,fork" \
        SYSTEM:"/opt/leigod/bin/ssdp.sh reply" 2>/dev/null &
    pids="$pids $!"
    notify_loop &
    pids="$pids $!"
    log "UPnP 通告已启动：http://${ip}:${HTTP_PORT}/rootDesc.xml"
    # 任一子进程退出就整体退出，由入口脚本重启
    while :; do
        for p in $pids; do
            kill -0 "$p" 2>/dev/null || { kill $pids 2>/dev/null; exit 1; }
        done
        sleep 5
    done
}

load_conf
detect_lan_if || { log "ERROR: 找不到局域网网卡（LAN_IF=${LAN_IF:-自动}）"; exit 1; }

case "$1" in
    run)   cmd_run ;;
    reply) cmd_reply ;;
    *)     echo "用法: $0 {run|reply}" >&2; exit 2 ;;
esac
