# Architecture Targets — geo-bypass

## Purpose
Selective routing of traffic through VPN tunnels based on CIDR lists and domain resolution.
Replacement for the existing `/opt/etc/unblock/` system on the host.

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
- **PID file**: `/tmp/parser.sh.pid` (prevents concurrent runs)

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
- See [`smartdns/`](../../smartdns/) subproject for DNS server configuration
- SmartDNS on port 6053, two groups: `ru` and `default`
- `dig @localhost` resolves through SmartDNS

### Routing Tables
- Keenetic fwmark-based: tables 4096–4115, 16384–16401 (DO NOT use fwmark — conflicts with NDM)
- Table `1000` reserved for geo-bypass/unblock (route-based: `ip rule iif br0 table 1000`)

## Target Architecture (geo-bypass/)

### Routing Modes

geo-bypass supports 3 routing modes via `ROUTE_MODE` in `config/config.sh`:

| Mode | Target Interface | Description |
|------|-----------------|-------------|
| `bypass` | `ISP_INTERFACE` (or auto-detect) | GEO traffic goes directly via ISP, bypassing VPN |
| `vpn` | `VPN_INTERFACE` | GEO traffic is routed through VPN tunnel |
| `auto` | auto-detect via `ip route show default` | Same as bypass with automatic ISP interface detection |

**Interface resolution logic** (`resolve_target_interface()` in `apply-routes.sh`):
- `bypass`: uses `ISP_INTERFACE` if set, otherwise auto-detects via default route
- `vpn`: uses `VPN_INTERFACE` directly
- `auto`: always auto-detects ISP interface from `ip route show default`

### Project Structure
```
geo-bypass/
├── .project/
│   ├── target-arch.md       # this file
│   └── target-code.md       # code standards
├── config/
│   └── config.sh            # ROUTE_MODE, interfaces, ipset, URLs
├── lists/
│   └── *.cidr               # CIDR lists (downloaded)
├── scripts/
│   ├── apply-routes.sh      # resolve interface + ipset + ip rule
│   ├── update-domains.sh    # download/update CIDR lists
│   └── install.sh           # install hooks, cron, symlinks
└── README.md
```

### Deploy on Router
```
/opt/etc/keenetic-entware/geo-bypass/config.sh    # config
/opt/scripts/keenetic-entware/geo-bypass/*.sh      # scripts
/opt/etc/ndm/ifstatechanged.d/geo-bypass-hook     # NDM hook
/opt/etc/cron.daily/geo-bypass-update              # cron symlink
/opt/tmp/geo-bypass/                               # runtime data (lists, PID)
```
