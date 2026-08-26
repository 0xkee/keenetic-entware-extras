# opkg Repository — keenetic-entware-extras

Pre-built `.ipk` packages for Keenetic routers running Entware.

## Quick Setup

Add the repository to your Entware opkg config:

```sh
cat >> /opt/etc/opkg.conf << 'EOF'
src/gz kee-extras https://0xkee.github.io/keenetic-entware-extras/releases/all
EOF
opkg update
```

## Install Packages

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

## Architecture

All packages are `Architecture: all` — compatible with any Entware-supported
Keenetic router (mipsel, mips, aarch64).

## Updates

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
sed -i '/kee-extras/d' /opt/etc/opkg.conf
opkg update
```

## Manual Install (without repository)

Download `.ipk` from [GitHub Releases](https://github.com/0xkee/keenetic-entware-extras/releases):

```sh
wget https://github.com/0xkee/keenetic-entware-extras/releases/download/<tag>/<pkg>.ipk
opkg install ./<pkg>.ipk
```
