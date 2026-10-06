# syntax=docker/dockerfile:1
#
# 雷神加速器路由器插件（acc-gw）旁路网关镜像，linux/amd64、linux/arm64、linux/arm/v7
#
#   docker buildx build --platform linux/amd64,linux/arm64,linux/arm/v7 -f docker/Dockerfile .
#
# 官方插件（acc-gw.router 引擎）是静态链接的程序，各架构都有原生版本；它只认 OpenWrt / 华硕 / 小米等固件，
# 这里在 Alpine 上补一个 uci 命令、OpenWrt 格式的 ps，并把 /etc/os-release 标成 OpenWrt。
# 插件本身不在镜像里，容器启动时从雷神服务器下载。

ARG ALPINE_VERSION=3.22

# ---------- uci 命令（OpenWrt 的配置工具，插件通过它读 /etc/config/network 等）----------
FROM alpine:${ALPINE_VERSION} AS uci
ARG UCI_COMMIT=74f6277aabffc943d026f406df57c22595134c42
RUN apk add --no-cache build-base cmake git libubox-dev libubox-static
RUN git clone https://git.openwrt.org/project/uci.git /src \
    && git -C /src checkout -q "${UCI_COMMIT}" \
    && cd /src && cmake -DBUILD_LUA=OFF -DBUILD_STATIC=ON -DCMAKE_BUILD_TYPE=Release . && make cli \
    && strip -o /uci uci

FROM alpine:${ALPINE_VERSION}
ARG TARGETARCH

RUN apk add --no-cache busybox-extras conntrack-tools curl dnsmasq ipset iproute2 iproute2-tc iptables iptables-legacy socat tini

COPY --from=uci /uci /sbin/uci
COPY rootfs/ /
COPY LICENSE THIRD_PARTY_NOTICES.md /usr/share/doc/leigod-plugin-linux/

# 插件文件名后缀：acc-gw.router.{amd64,arm64,arm}（按镜像架构而不是内核选择）
# 插件按 /etc/os-release 的 ID=openwrt 判断固件类型（Alpine 的是指向 /usr/lib/os-release 的软链接）
RUN case "${TARGETARCH}" in \
        amd64|arm64) echo "${TARGETARCH}" ;; \
        arm) echo arm ;; \
        *) echo "unsupported arch ${TARGETARCH}" >&2; exit 1 ;; \
    esac > /opt/leigod/plugin-arch \
    && rm -f /etc/os-release && cp /opt/leigod/os-release /etc/os-release \
    && ln -sf /etc/leigod/config /etc/config \
    && ln -sf /etc/leigod/bin /usr/sbin/leigod \
    && ln -s /opt/leigod/bin/leigodctl /usr/local/bin/leigodctl

# 插件配置（/etc/config）、插件程序（/usr/sbin/leigod）、UPnP UUID
VOLUME /etc/leigod

ENTRYPOINT ["/sbin/tini", "--", "/opt/leigod/bin/leigod-docker.sh"]
