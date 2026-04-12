# Architecture Targets — smartdns-ru

## Purpose

Custom SmartDNS configuration overlay for RU zone DNS splitting on Keenetic routers with Entware.
Resolves `.ru`/`.рф`/`.su` domains through Russian DNS servers, all other domains through international DNS.

## Key Design Decisions

### Port 6053 (not 53)
Keenetic uses its own internal DNS resolver on port 53.
SmartDNS binds to `0.0.0.0:6053` and Keenetic forwards queries to it.

### Two DNS Groups

| Group | Upstreams | Protocol | Purpose |
|-------|-----------|----------|---------|
| `ru` | Yandex (77.88.8.8/1), AdGuard (94.140.14.14/15) | DoT + UDP | Russian domains (.ru, .рф, .su) |
| `default` | Cloudflare (1.1.1.1, 1.0.0.1), Google (8.8.8.8, 8.8.4.4) | DoT + DoH + UDP | Everything else |

### DNS Routing Rules
- `.ru` → group `ru`
- `.xn--p1ai` (.рф) → group `ru`
- `.su` → group `ru`
- Everything else → group `default`

### IPv6
- `force-AAAA-SOA yes` — AAAA records disabled (IPv4 only)

## Integration with Keenetic

1. Keenetic DNS proxy forwards queries to `127.0.0.1:6053`
2. SmartDNS resolves through appropriate upstream group
3. Cached responses served with `serve-expired` for reliability

## Integration with geo-split

- `geo-split` depends on SmartDNS for domain resolution
- `dig @localhost` in geo-split scripts resolves through SmartDNS on port 6053
- SmartDNS `ru` group ensures Russian domains resolve through Russian DNS (correct IPs for geo-routing)

## Project Structure

```
smartdns-ru/
├── .project/
│   ├── target-arch.md       # this file
│   └── target-code.md       # code standards
├── config/
│   └── smartdns.conf        # SmartDNS configuration
├── scripts/
│   ├── install.sh           # install package, config, init script
│   └── uninstall.sh         # stop, remove custom init, restore defaults
└── README.md
```

## Deploy Layout on Router

```
/opt/etc/smartdns/smartdns.conf       # configuration (deployed by install.sh)
/opt/etc/init.d/S60smartdns           # custom init script (created by install.sh)
/opt/etc/init.d/S38smartdns           # default init (disabled, chmod -x)
/opt/sbin/smartdns                    # binary (installed via opkg)
/opt/var/run/smartdns.pid             # PID file (runtime)
/opt/var/log/smartdns.log             # log file (runtime)
```
