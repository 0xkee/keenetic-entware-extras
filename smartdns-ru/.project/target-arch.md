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
| `ru` | Yandex (77.88.8.8/1), AdGuard (94.140.14.140/141) | DoT + UDP | Russian domains (.ru, .рф, .su) |
| `default` | Google (8.8.8.8/4.4), Cloudflare (1.1.1.1, 1.0.0.1) | UDP + DoH | Everything else |

### DNS Routing Rules
- `.ru` → group `ru`
- `.xn--p1ai` (.рф) → group `ru`
- `.su` → group `ru`
- Everything else → group `default`

### IPv6
- `force-AAAA-SOA yes` — AAAA records disabled (IPv4 only)

### Init Script: Stock S38smartdns

Uses the stock init script from the `smartdns` Entware package (`/opt/etc/init.d/S38smartdns`).
No custom init — the stock `rc.func`-based script provides `start/stop/restart/check`.
Diagnostics via standalone `scripts/status.sh`.

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
│   └── smartdns.conf        # SmartDNS configuration (source → /opt/etc/smartdns/)
├── scripts/
│   └── status.sh            # diagnostic status (standalone)
├── docs/
│   ├── current-state-assessment.md
│   ├── dns-landscape-research.md
│   └── improvement-plan.md
└── README.md

packaging/smartdns-ru/
├── control                  # package metadata (Version, Depends)
├── conffiles                # protected config paths
├── postinst                 # create cache dir, restart smartdns
├── prerm                    # stop smartdns
└── postrm                   # cleanup runtime files
```

## Deploy Layout on Router

```
/opt/etc/smartdns/smartdns.conf                              # configuration (conffiles-protected)
/opt/etc/init.d/S38smartdns                                  # stock init (from smartdns package)
/opt/keenetic-entware-extras/smartdns-ru/scripts/status.sh   # diagnostic script
/opt/keenetic-entware-extras/smartdns-ru/README.md           # readme
/opt/keenetic-entware-extras/smartdns-ru/LICENSE              # license
/opt/sbin/smartdns                                            # binary (from smartdns package)
/opt/var/run/smartdns.pid                                     # PID file (runtime)
/opt/var/cache/smartdns.cache                                 # persistent cache (runtime)
```
