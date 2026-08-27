# opkg Repository — keenetic-entware-extras

Pre-built `.ipk` packages for Keenetic routers running Entware.

## Channels

| Channel | URL | Description |
|---------|-----|-------------|
| **stable** | `https://0xkee.github.io/keenetic-entware-extras/stable` | Recommended. Tested releases |
| **dev** | `https://0xkee.github.io/keenetic-entware-extras/dev` | Bleeding edge. Latest builds |

## Quick Setup

Add the **stable** repository (recommended):

```sh
cat >> /opt/etc/opkg.conf << 'EOF'
src/gz kee https://0xkee.github.io/keenetic-entware-extras/stable
EOF
opkg update
```

## Switch Channel

Switch from stable to dev:

```sh
sed -i 's|/stable$|/dev|' /opt/etc/opkg.conf
opkg update
```

Switch from dev to stable:

```sh
sed -i 's|/dev$|/stable|' /opt/etc/opkg.conf
opkg update && opkg upgrade
```

## Available Packages

| Package | Description |
|---------|-------------|
| `keenetic-entware-extras` | Shared libraries for all packages |
| `geo-split` | Geo-based policy routing (subnets + ip rules) |
| `geo-split-data` | Zone lists and GeoIP data |
| `smartdns-geo-conf` | SmartDNS geo-aware DNS configuration |
| `smartdns-redirect` | DNS redirect with netfilter hooks |
| `net-check` | Network connectivity diagnostics |
| `webui` | Web dashboard (nginx + Lua) |

All packages are `Architecture: all` — compatible with any Entware-supported Keenetic router (mipsel, mips, aarch64).

## Install

```sh
# Core libraries (dependency for all other packages)
opkg install keenetic-entware-extras

# Geo-based split routing
opkg install geo-split geo-split-data

# SmartDNS configuration
opkg install smartdns-geo-conf smartdns-redirect

# Network diagnostics
opkg install net-check

# Web dashboard
opkg install webui
```

## Update

```sh
opkg update && opkg upgrade
```

## Uninstall

```sh
# Remove individual packages
opkg remove webui
opkg remove net-check
opkg remove smartdns-redirect smartdns-geo-conf
opkg remove geo-split geo-split-data

# Remove core libraries (last)
opkg remove keenetic-entware-extras

# Remove repository config
sed -i '/kee/d' /opt/etc/opkg.conf
opkg update
```
