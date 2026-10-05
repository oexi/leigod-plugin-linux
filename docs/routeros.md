# RouterOS

Example for a LAN bridge `bridge` on `192.168.88.0/24` with the router at `192.168.88.1`, container IP `192.168.88.3`
and a disk mounted as `usb1` (RouterOS 7.20+ syntax; on older versions use `name=` instead of `list=` and `mounts=` instead of `mountlists=`):

```routeros
# The container's interface, attached to the LAN bridge; its MAC is the plugin's serial number and stays fixed
/interface/veth add name=veth-leigod address=192.168.88.3/24 gateway=192.168.88.1
/interface/bridge/port add bridge=bridge interface=veth-leigod

# Persistent /etc/leigod
/container/mounts add list=leigod src=/usb1/leigod dst=/etc/leigod

/container/config set registry-url=https://ghcr.io tmpdir=/usb1/pull
/container add remote-image=oexi/leigod-plugin-linux:latest interface=veth-leigod \
    root-dir=/usb1/containers/leigod mountlists=leigod dns=192.168.88.1 logging=yes start-on-boot=yes
/container start [find interface=veth-leigod]
```

- The veth must be a port of the **LAN bridge**: devices can only use a gateway on their own subnet.
  Inside the container the veth (e.g. `veth10`) is put into a bridge `br-lan` and a placeholder `eth0` with the same MAC is created;
  the RouterOS side is not changed
- Do **not** set `cmd` or `entrypoint`: RouterOS then runs the command directly and skips the image's entrypoint
- `logging=yes` sends the log to `/log`; `leigodctl` works inside the container (`/container shell [find interface=veth-leigod]`)
- To point only some devices at the container, give their DHCP leases their own gateway/DNS (DHCP options 3 and 6):

  ```routeros
  /ip/dhcp-server/option add name=leigod-gw code=3 value="'192.168.88.3'"
  /ip/dhcp-server/option add name=leigod-dns code=6 value="'192.168.88.3'"
  /ip/dhcp-server/option/sets add name=leigod options=leigod-gw,leigod-dns
  /ip/dhcp-server/lease set [find mac-address=AA:BB:CC:DD:EE:FF] dhcp-option-set=leigod
  ```

- The entrypoint uses `tproxy` mode when the RouterOS kernel supports TPROXY and ipset, otherwise `tun`
  (logged as `加速模式: ...`, also in `leigodctl status`). If iptables fails with the nft backend, set `USE_IPTABLES_NFT_BACKEND=0`
  (`/container/envs add list=leigod key=USE_IPTABLES_NFT_BACKEND value=0`, then `envlists=leigod` on the container)
- If RouterOS's own UPnP is enabled on the LAN bridge, the app may find RouterOS instead of the container;
  disable it (`/ip/upnp set enabled=no`) while binding
