# Architecture Targets — geo-split

## Purpose
Split routing of traffic through different network interfaces based on GeoIP CIDR lists and domain resolution.
Replaces the legacy `/opt/etc/unblock/` system. Supports routing traffic both to VPN and away from VPN.

## Existing System Analysis (`/opt/etc/unblock/`)

Backup: `backups/router-1-unblock-20260407/`

### Files on Host
| File | Purpose |
|------|---------|
| `config` | Variables: `IFACE`, `FILE`, `URL` |
| `parser.sh` | Main script: resolves domains/CIDRs → `ip route table 1000` |
| `fetch-ru-cidr.sh` | Downloads GEO CIDR list from GitHub |
| `start-stop.sh` | NDM hook handler (interface up/down events) |
| `uninstall.sh` | Cleanup script |

### Integration Points
- **NDM hook**: `/opt/etc/ndm/ifstatechanged.d/ip_rule_switch` → symlink to `start-stop.sh`
- **Cron daily**: `/opt/etc/cron.daily/routing_table_update` → symlink to `parser.sh`
- **Cron weekly**: `/opt/etc/cron.weekly/fetch-ru-cidr.sh` → symlink to `fetch-ru-cidr.sh`
- **Routing table**: `table 1000` with `ip rule iif br0 table 1000 priority 5`
- **PID file**: `/opt/tmp/parser.sh.pid` (prevents concurrent runs)

### Routing Architecture (current)
- Policy routing via `ip route table 1000` (NO ipset)
- `ip rule add iif br0 table 1000 priority 5` — all LAN traffic matched
- Routes added per CIDR/resolved IP: `ip route add table 1000 <ip> dev <IFACE>`
- VPN interface: `IFACE=lte_br1` (currently DOWN)
- DNS resolution via `dig @localhost` (SmartDNS on port 6053)
- All scripts use `#!/bin/sh` (BusyBox ash, no bash)

### Limitations of Current System
- No ipset — each route added individually (slow for large CIDR lists)
- `grep -qP` used in `parser.sh` — PCRE not supported in BusyBox grep
- No error recovery / retry logic  
- No logging granularity (only syslog via `logger`)
- Hardcoded paths, no modular config

## Host Network Topology (router-1)

### Key Interfaces
| Interface | Role | Network |
|-----------|------|---------|
| `br0` | LAN (Home) | 10.0.0.0/24 |
| `br1` | Guest | 10.1.30.0/24 |
| `lte_br0` | WAN/ISP (LTE modem, primary uplink) | DHCP |
| `lte_br1` | WAN/ISP (LTE modem, secondary uplink) | DHCP |
| `lte_br*` | could any amount of uplinks | most likely DHCP |
| `nwg0`–`nwg6` | WireGuard tunnels | various |
| `ovpn_br0/br1` | OpenVPN | DOWN |

### DNS
- See [`smartdns-ru/`](../../smartdns-ru/) subproject for DNS server configuration
- SmartDNS on port 6053, two groups: `ru` and `default`
- `dig @localhost` resolves through SmartDNS

### Routing Tables
- Keenetic fwmark-based: tables 4096–4115, 16384–16401 (DO NOT use fwmark — conflicts with NDM)
- Tables `1000` (domains) + `1001` (subnets) reserved for geo-split (route-based: `ip rule iif br0 table 1000/1001`)

## Target Architecture (geo-split/)

### Routing (ROUTE_OUT / ROUTE_IN)

geo-split uses two config variables instead of multiple mode/interface combos:

| Variable | Purpose | Default |
|----------|---------|---------|
| `ROUTE_OUT` | Target outgoing interface for matched GEO traffic | `"auto"` |
| `ROUTE_IN` | Source LAN interfaces for `ip rule iif` | `"br0"` |

**ROUTE_OUT semantics:**
- `"auto"` or empty → auto-detect ISP interface from `ip route show default`
- Explicit name (e.g. `"lte_br1"`, `"nwg0"`, `"ppp0"`) → use directly

**Interface resolution logic** (`resolve_target_interface()` in `attach-rules.sh`):
- `ROUTE_OUT=auto` or empty: calls `detect_isp_interface()` (parses default route)
- `ROUTE_OUT=<name>`: uses the value directly as target interface

### Project Structure
```
geo-split/
├── .project/
│   ├── target-arch.md       # this file
│   └── target-code.md       # code standards
├── config/
│   └── config.sh            # ROUTE_OUT, ROUTE_IN, URLs
├── lists/
│   └── *.cidr               # CIDR lists (downloaded)
├── scripts/
│   ├── attach-rules.sh      # ip rules only (connect LAN to tables)
│   ├── detach-rules.sh      # remove ip rules + flush route tables
│   ├── ndm-hook.sh          # NDM interface up/down hook
│   ├── status.sh            # diagnostic status
│   ├── update-domains.sh    # resolve DNS + fill table 1000 (domains)
│   └── update-subnets.sh    # download GeoIP + fill table 1001 (subnets)
└── README.md
```

### Deploy on Router
```
/opt/keenetic-entware-extras/                              # project root (remote_base)
/opt/keenetic-entware-extras/lib/common.sh                 # shared library
/opt/keenetic-entware-extras/geo-split/config/config.sh   # config
/opt/keenetic-entware-extras/geo-split/scripts/*.sh       # scripts
/opt/keenetic-entware-extras/geo-split/loaders/           # subnet loaders
/opt/keenetic-entware-extras/geo-split-data/lists/        # domain lists + geoip zones
/opt/etc/init.d/S99geo-split                              # init script (system path)
/opt/etc/ndm/ifstatechanged.d/geo-split-hook              # NDM hook (system path)
/opt/etc/crontab                                           # cron entries (system path)
```
