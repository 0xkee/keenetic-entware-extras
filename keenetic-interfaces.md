# Keenetic Network Interfaces Reference

Developer reference for network interface prefixes on Keenetic routers (KeeneticOS 5.0+).
Used in [`api-system.lua`](webui/lua/api-system.lua) interface blacklist and [`lib/ip.sh`](lib/ip.sh) tunnel detection.

## Interface Table

| Prefix | Description | Type | Show in UI | Example |
|--------|-------------|------|:----------:|---------|
| `br0`, `br1` | LAN / Guest bridge | user | ✅ | `br0` (Home) |
| `eth[0-9]` | Physical Ethernet (IPoE WAN) | user | ⚠️ label | `eth3` → ISP |
| `ppp[0-9]`, `pppoe[0-9]` | PPPoE WAN | user | ✅ | `ppp0` |
| `lte_br*` | 3G/4G USB modem | user | ✅ | `lte_br0` |
| `nwg*` | WireGuard (NDM-managed) | tunnel | ✅ | `nwg0` |
| `awg*` | AmneziaWG | tunnel | ✅ | `awg0` |
| `wg*` | WireGuard (manual) | tunnel | ✅ | `wg0` |
| `ovpn*` | OpenVPN | tunnel | ✅ | `ovpn0` |
| `l2tp*` | L2TP VPN | tunnel | ✅ | `l2tp0` |
| `pptp*` | PPTP VPN | tunnel | ✅ | `pptp0` |
| `sstp*` | SSTP VPN | tunnel | ✅ | `sstp0` |
| `ipsec*` | IPsec tunnel | tunnel | ✅ | `ipsec0` |
| `tun[0-9]*` | Generic TUN device | tunnel | ✅ | `tun0` |
| `tap*` | Generic TAP device | tunnel | ✅ | `tap0` |
| `wwan*` | WiFi client (WISP) | user | ⚠️ label | `wwan0` |
| `usb*` | USB tethering | user | ⚠️ label | `usb0` |
| `lo` | Loopback | infra | ❌ | `lo` |
| `ra[0-9]` | 2.4 GHz WiFi radio (MediaTek) | infra | ❌ | `ra0` |
| `rai[0-9]` | 5 GHz WiFi radio (MediaTek) | infra | ❌ | `rai0` |
| `rax[0-9]` | 6 GHz WiFi radio (WiFi 6E) | infra | ❌ | `rax0` |
| `apcli*` | WiFi client bridge (WISP) | user | ⚠️ label | `apcli0` |
| `xfrm*`, `xfrms*` | IPsec xfrm state interfaces | infra | ❌ | `xfrms1` |
| `tunl*` | IPv4 tunnel device | infra | ❌ | `tunl0` |
| `ip6tnl*` | IPv6 tunnel device | infra | ❌ | `ip6tnl0` |
| `sit*` | IPv6-in-IPv4 (SIT) | infra | ❌ | `sit0` |
| `gre*` | GRE tunnel | infra | ❌ | `gre0` |
| `vti*` | VPN tunnel interface | tunnel | ✅ | `vti0` |
| `ethoip*` | EtherIP | infra | ❌ | `ethoip0` |
| `dummy*` | Dummy device | infra | ❌ | `dummy0` |
| `ezcfg*` | EZConfig | infra | ❌ | `ezcfg0` |
| `ifb*` | IFB (traffic shaping) | infra | ❌ | `ifb0` |
| `*.N` | VLAN sub-interface | infra | ❌ | `eth2.1` |

**Legend:**
- **Type:** `user` = user-facing WAN/LAN, `tunnel` = VPN/tunnel, `infra` = kernel/radio infrastructure
- **Show in UI:** ✅ = always shown, ⚠️ label = shown only if NDM assigned a label, ❌ = blacklisted

## Usage in Project

| Component | File | Purpose |
|-----------|------|---------|
| Interface blacklist | `webui/lua/api-system.lua` → `M.interfaces()` | Excludes infra interfaces from API |
| Tunnel detection | `lib/ip.sh` → `is_tunnel_iface()` | Classifies dev as tunnel for route-check / wan-paths |
| UI tunnel check | `webui/static/shared.js` → `EW.isTunnelIface()` | Client-side tunnel classification for route diagram |
| Config dropdowns | `webui/static/config-editor.js` | `iface_select` type populates from API |
