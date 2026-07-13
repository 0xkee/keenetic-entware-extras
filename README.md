# Keenetic Entware Extras

> 📖 **[User Manual (RU)](user-manual.ru.md)** — installation, kee-status, bug-report.

Shell scripts and `.ipk` packages for Keenetic routers with Entware.
Includes subprojects: **geo-split** (GeoIP/domain split routing), **smartdns-geo-conf** (DNS split), **smartdns-redirect** (DNAT LAN :53 → local DNS), **webui** (dashboard).

## Packages

| Package | Description |
|---------|-------------|
| `keenetic-entware-extras` | Base package — shared libraries (`lib/common.sh`, `lib/ip.sh`, `lib/lists.sh`, `lib/status.sh`, `lib/geo.sh`, `lib/zones.sh`) + CLI `kee-status` |
| `geo-split` | GeoIP + domain split routing. Depends on `keenetic-entware-extras` |
| `geo-split-data` | Data: domain lists, GeoIP zones, whitelist. Conffiles — preserved on upgrade |
| `smartdns-geo-conf` | Multi-zone split DNS: route queries by GeoIP zones (RU, EAEU, BRICS, 40+ alliances) to configurable providers with zone-routing-rules |
| `smartdns-redirect` | Universal DNS DNAT: intercept LAN `:53` → local DNS |
| `webui` | Custom dashboard for Keenetic/Entware services on :8080 + Config Editor, Route Check, DNS Check, stock WebUI integration |

## Installation via opkg

Primary installation method for users.

```sh
# Copy .ipk files to router
scp *.ipk root@<router-ip>:/tmp/

# Install (order matters — base first, then data, then geo-split)
opkg install /tmp/keenetic-entware-extras_<ver>_all.ipk
opkg install /tmp/geo-split-data_<ver>_all.ipk
opkg install /tmp/geo-split_<ver>_all.ipk
```

Dependencies (`ip-full`, `curl`, `bind-dig`, `aggregate`) are installed automatically via opkg.

## Diagnostics

After installing the `keenetic-entware-extras` package, the
[`kee-status`](scripts/kee-status.sh:1) command is available — aggregated
status of all subpackages. Runs `scripts/status.sh` of each installed package
(no streaming), displays one line per package (`Alive` / `FAIL`), and
under failed ones — only lines with `✗`, grouped by subsections
(`Service:`, `Rules:`, `DNS Tests:`, etc.).

```sh
kee-status                # colored output in TTY
kee-status --no-color     # plain text for logs / ndmc
NO_COLOR=1 kee-status     # same via env
```

Exit code: `0` if all `Alive`, `1` if any `FAIL`.

## Subprojects

### [geo-split](geo-split/README.md)

Split routing for Keenetic: route traffic by GeoIP subnets and domain lists through different network interfaces (ISP/VPN). Supports bypass, vpn, auto modes.

### [smartdns-geo-conf](smartdns-geo-conf/README.md)

Multi-zone split DNS: route domain queries by configurable GeoIP zones (RU, EAEU, CIS, BRICS, EU, 40+ alliances) to regional DNS providers (Yandex/AdGuard DoT), everything else → Google/Cloudflare DoH. Supports custom zone-routing-rules, multiple DNS provider profiles, and VPN-bypass binding.

### [smartdns-redirect](smartdns-redirect/README.md)

Universal DNS DNAT: `iptables PREROUTING REDIRECT` for LAN clients (`br0`) — bypass Keenetic ndnproxy, direct resolution through local DNS (SmartDNS/AdGuard Home/Unbound/dnsmasq). Persistence via NDM `netfilter.d` hook, watchdog via cron. Measured latency improvement: `~130ms → <80ms`.

## Project structure

```
keenetic-entware-extras/
├── lib/                  # shared libraries
│   ├── common.sh         # logging, error handling, JSON helpers
│   ├── ip.sh             # IP/interface utilities
│   ├── lists.sh          # list processing (@include, dedup)
│   ├── status.sh         # status check/show helpers for diagnostics
│   ├── geo.sh            # geo-zone unions (40+ alliances, 294 lines)
│   └── zones.sh          # zone labels (249 zones, 255 lines)
├── geo-split/            # split routing subproject
│   ├── scripts/          # attach, detach, update, status, ndm-hook
│   ├── config/           # defaults.conf (defaults) + config.conf (user overrides)
│   ├── loaders/          # CIDR loaders (plain, RIPE JSON)
│   ├── init.d/           # S99geo-split
│   └── docs/             # architecture, comparisons
├── geo-split-data/       # data (lists, GeoIP zones)
│   ├── lists/            # domains.txt, ru-whitelist.txt
│   └── scripts/          # fetch-zones.sh
├── smartdns-geo-conf/    # DNS split
│   ├── config/           # smartdns.conf
│   ├── scripts/          # status.sh, toggle.sh
│   ├── init.d/           # S37smartdns-conf
│   └── docs/             # user-manual.ru.md
├── smartdns-redirect/    # DNS DNAT for LAN
│   ├── config/           # defaults.conf (defaults) + config.conf (user overrides)
│   ├── scripts/          # dns-redirect, watchdog, status, netfilter-hook
│   ├── init.d/           # S39smartdns-redirect
│   └── docs/             # user-manual.ru.md
├── webui/                # custom dashboard (nginx + lua)
│   ├── config/           # nginx.conf, logrotate.conf
│   ├── scripts/          # status.sh, patch-stock-ui.sh
│   ├── lua/              # api-router, serve-index
│   └── init.d/           # S80nginx-webui
├── packaging/            # .ipk metadata
│   ├── keenetic-entware-extras/
│   ├── geo-split/
│   ├── geo-split-data/
│   ├── smartdns-geo-conf/
│   ├── smartdns-redirect/
│   └── webui/
├── scripts/              # build-ipk.sh, kee-status.sh (aggregated status CLI)
└── LICENSE               # MIT
```

## Requirements

- Keenetic with Entware installed
- Dependencies are installed automatically via opkg:
  - `ip-full` — iproute2 for policy routing
  - `curl` — GeoIP data download
  - `bind-dig` — DNS resolution of domains
  - `aggregate` — CIDR subnet aggregation

## Development

For contributors and developers.

**Full deploy procedure** (spike/full modes, state control, rollback, troubleshooting): [`.project/deploy-workflow.md`](.project/deploy-workflow.md).

```sh
# Linting
shellcheck -x -s sh scripts/*.sh
shellcheck -x -s sh geo-split/scripts/*.sh

# Spike deploy (fast iteration, routers without sftp-server)
scp -O -r lib/ geo-split/ root@<router-ip>:/opt/keenetic-entware-extras/

# Full deploy: build all .ipk packages
./scripts/build-ipk.sh all
```

## License

[MIT](LICENSE)
