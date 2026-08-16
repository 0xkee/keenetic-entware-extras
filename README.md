# Keenetic Entware Extras

> 📖 **[User Manual (RU)](user-manual.ru.md)** — installation, kee-status, bug-report.

Shell scripts and `.ipk` packages for Keenetic routers with Entware.
Includes subprojects: **geo-split** (GeoIP/domain split routing), **smartdns-geo-conf** (DNS split), **smartdns-redirect** (DNAT LAN :53 → local DNS), **net-check** (network diagnostics), **webui** (dashboard).

## Packages

| Package | Description |
|---------|-------------|
| `keenetic-entware-extras` | Base package — shared libraries (`lib/common.sh`, `lib/ip.sh`, `lib/lists.sh`, `lib/status.sh`, `lib/geo.sh`, `lib/zones.sh`) + CLI `kee-status` |
| `geo-split` | GeoIP + domain split routing. Depends on `keenetic-entware-extras` |
| `geo-split-data` | Data: domain lists, GeoIP zones, allowlist. Conffiles — preserved on upgrade |
| `smartdns-geo-conf` | Multi-zone split DNS: route queries by GeoIP zones (RU, EAEU, BRICS, 40+ alliances) to configurable providers with zone-routing-rules |
| `smartdns-redirect` | Universal DNS DNAT: intercept LAN `:53` → local DNS |
| `net-check` | Network connectivity diagnostics: reachability verification, anomaly detection, CDN geo-steering, DNS leak testing |
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

Split routing for Keenetic: route traffic by GeoIP subnets and domain lists through different network interfaces (ISP/tunnel). Supports direct, tunnel, auto routing modes.

### [smartdns-geo-conf](smartdns-geo-conf/README.md)

Multi-zone split DNS: route domain queries by configurable GeoIP zones (RU, EAEU, CIS, BRICS, EU, 40+ alliances) to regional DNS providers (Yandex/AdGuard DoT), everything else → Google/Cloudflare DoH. Supports custom zone-routing-rules, multiple DNS provider profiles, and tunnel interface binding.

### [smartdns-redirect](smartdns-redirect/README.md)

Universal DNS DNAT: `iptables PREROUTING DNAT` for LAN clients (`br0`) — redirects past Keenetic ndnproxy, direct resolution through local DNS (SmartDNS/AdGuard Home/Unbound/dnsmasq). Persistence via NDM `netfilter.d` hook, watchdog via cron. Measured latency improvement: `~130ms → <80ms`.

### [net-check](net-check/README.md)

Network connectivity diagnostics and degradation control. End-to-end reachability verification across WAN interfaces, MITM/DPI anomaly detection, CDN geo-steering analysis, DNS leak testing, path quality comparison.

### [webui](webui/README.md)

Custom dashboard for Keenetic/Entware services on `:8080`. Config Editor, Route Check, DNS Check, stock WebUI sidebar integration via Lua patches.

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
├── net-check/            # network diagnostics
│   ├── config/           # check-targets, dns-providers, cdn-domains
│   ├── scripts/          # net-check.sh, domain-check.sh, status.sh
│   └── scripts/lib/      # cmd modules (geo, dns, cdn, tls, speed, ipv6-leak)
├── webui/                # custom dashboard (nginx + lua)
│   ├── config/           # nginx.conf, logrotate.conf
│   ├── scripts/          # status.sh, patch-stock-ui.sh
│   ├── lua/              # api-router (+ api-config, api-data, api-system, api-utils), serve-index, stock-css-init
│   └── init.d/           # S80nginx-webui
├── packaging/            # .ipk metadata
│   ├── keenetic-entware-extras/
│   ├── geo-split/
│   ├── geo-split-data/
│   ├── smartdns-geo-conf/
│   ├── smartdns-redirect/
│   ├── net-check/
│   └── webui/
├── scripts/              # build-ipk.sh, kee-status.sh (aggregated status CLI)
└── LICENSE               # MIT
```

## Requirements

- Keenetic with Entware installed
- All dependencies are installed automatically via `opkg install <pkg>.ipk`

**Base** (`keenetic-entware-extras`): `cron`

**Per sub-package** - see related packages.

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
