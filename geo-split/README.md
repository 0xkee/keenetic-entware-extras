# geo-split

> 📖 **[User Manual (RU)](docs/user-manual.ru.md)** — step-by-step installation, configuration, troubleshooting.

Split routing for Keenetic/Entware — route traffic by GeoIP subnets and domain lists through different network interfaces.

Typical use cases:
- 🇷🇺 **EAEU → ISP:** EAEU subnets (RU+BY+KZ+AM+KG) go through ISP, everything else — through tunnel
- 🔒 **Selected → tunnel:** specific subnets/domains routed into a tunnel
- 🌍 **Multi-zone:** any combination of countries or alliances (CIS, BRICS, EU, etc.) — 232 zones, 40+ unions

## Installation

Primary method — via opkg:

```sh
opkg install geo-split_<ver>_all.ipk
```

Dependencies (`keenetic-entware-extras`, `geo-split-data`, `ip-full`, `curl`, `bind-dig`, `aggregate`) are installed automatically.

> `config/config.conf` — conffile: preserved during `opkg upgrade`.

After installation:

```sh
# 1. Edit configuration
vi /opt/keenetic-entware-extras/geo-split/config/config.conf

# 2. Start
/opt/etc/init.d/S99geo-split start
```

## Removal

```sh
opkg remove geo-split
```

Automatically performs: service stop, cron job removal, NDM hook cleanup, batch file deletion.

## Routing (ROUTE_OUT / ROUTE_IN)

Two key parameters control routing:

| Parameter | Description | Default |
|-----------|-------------|---------|
| `ROUTE_OUT` | Where to send GEO traffic (outgoing interface) | `"auto"` |
| `ROUTE_IN` | Traffic source (LAN interfaces for `ip rule iif`) | `"br0"` |

**`ROUTE_OUT` semantics:**
- `"auto"` or empty → auto-detect ISP via `ip route show default`
- Explicit interface name (`"lte_br1"`, `"nwg0"`, `"ppp0"`) → use directly

## Architecture

### Principle: async data + instant rules

Data loading (CIDR subnets, DNS domain resolution) runs **asynchronously** via cron. Routing rule attachment is **instant** from cache (~1 sec for 13K+ routes via `ip-full -batch`). This separation ensures fast startup and reliable operation during reboots and interface switches.

### Approach: route-based (no iptables)

Instead of `iptables mangle MARK` (which conflicts with Keenetic NDM per-device routing), a **route-based** approach is used:

1. `ip rule add iif br0 table 1000 priority 50` — domain routes (/32 host routes)
2. `ip rule add iif br0 table 1001 priority 51` — subnet routes (GeoIP CIDRs)
3. Loaders populate the tables: domains → table 1000, subnets → table 1001
4. Traffic not matching any route passes through the normal routing path

Domain table (prio 50) is checked first — allows pinpoint routing of individual domains over subnets.

The project intentionally avoids iptables mangle/MARK as they conflict with per-device routing in Keenetic NDM.

## Flows

### Boot flow (`S99geo-split start`)

Sequential execution (cold start: sequential to avoid temp-file conflicts on routers with limited RAM):

```
1. update-subnets.sh  — checks cache, downloads if stale, populates subnet table
2. update-domains.sh  — checks cache, resolves if stale, populates domain table
3. attach-rules.sh    — attaches ip rules for all ifaces from ROUTE_IN
```

### Cron flow (`S99geo-split refresh`, every 15 min)

```
update-subnets.sh & update-domains.sh  (parallel)
```

Both scripts check cache freshness (`MAX_CACHE_AGE`, `DOMAINS_UPDATE_INTERVAL`) — actual downloading only happens if cache is stale. Routing tables are repopulated as needed. The `refresh` command does not touch ip rules.

### NDM hook flow (interface up/down)

```
Interface UP:
  sleep 2 (debounce)
  → update-subnets.sh --refill & update-domains.sh --refill  (parallel)
  → attach-rules.sh                                          (background)

Interface DOWN:
  → detach-rules.sh
```

Hook listens to interface depending on `ROUTE_OUT`:
- `"auto"` → interface with default route
- Explicit name → only the specified interface

## Management commands

```sh
/opt/etc/init.d/S99geo-split <command>
```

| Command | Action | Mode |
|---------|--------|------|
| `start` | `update-subnets.sh` → `update-domains.sh` → `attach-rules.sh` | Sequential |
| `stop` | `detach-rules.sh` — removes ip rules + flushes route tables | Synchronous |
| `restart` | `stop` → `sleep 1` → `start` | Synchronous |
| `status` | `status.sh` — diagnostics | Synchronous |
| `refresh` | `update-subnets.sh` & `update-domains.sh` (check freshness) | Parallel |
| `update` | `update-subnets.sh --force` & `update-domains.sh --force` | Parallel |
| `update-subnets` | `update-subnets.sh --force` | Synchronous |
| `update-domains` | `update-domains.sh --force` | Synchronous |

### Route diagnostics

```sh
# Check which interface traffic will use
geo-split/scripts/route-check.sh ozon.ru

# Check a CIDR subnet (coverage analysis against geo-split tables)
geo-split/scripts/route-check.sh 5.0.0.0/8

# Check from a specific client's perspective (MAC)
geo-split/scripts/route-check.sh github.com --from AA:BB:CC:DD:EE:FF

# JSON for automation / WebUI
geo-split/scripts/route-check.sh --json ozon.ru
```

Accepts domains, IPs, and CIDR notation. For CIDRs: samples 1–3 IPs for kernel route verdict + coverage analysis from geo-split routing tables (overlap detection, `geo_split_pct`).

Verdicts: `⇒` geo-split | `⊙` tunnel | `⚠` mixed (CDN) | `→` default

## Configuration

Config file: `config/config.conf`

### Full parameter table

| Parameter | Default | Description |
|-----------|---------|-------------|
| `GEO_ZONE` | `"eas"` | Geo-zone: ISO 3166-1 code (ru, cn) or alliance (eas, cis, brics). See `lib/geo.sh` |
| `ROUTE_OUT` | `"auto"` | Target outgoing interface. `auto` = ISP from default route |
| `ROUTE_GW` | `"auto"` | Gateway: `auto` = detect, `none` = dev-only, or explicit IP |
| `ROUTE_IN` | `"br0"` | Inbound LAN interfaces (space-separated) |
| `DOMAIN_ROUTE_TABLE` | `"1000"` | Routing table for domains (/32 host routes) |
| `DOMAIN_RULE_PRIORITY` | `"50"` | ip rule priority for domain table |
| `SUBNET_ROUTE_TABLE` | `"1001"` | Routing table for GeoIP subnets (CIDR) |
| `SUBNET_RULE_PRIORITY` | `"51"` | ip rule priority for subnet table |
| `SUBNET_URL_PATTERN` | `ipdeny.com/…/{cc}.zone` | URL pattern for subnet download (`{cc}` = country code) |
| `SUBNET_URL` | `""` | URL override (legacy): ignores GEO_ZONE |
| `SUBNET_LOADER` | `"cidr-plain"` | Loader from `loaders/` directory |
| `SUBNET_AGGREGATE` | `1` | CIDR aggregation (1 = enabled, requires `aggregate`) |
| `MAX_CACHE_AGE` | `604800` | Max subnet cache age, seconds (7 days) |
| `DOWNLOAD_RETRIES` | `2` | Download attempts per interface |
| `DOWNLOAD_RETRY_DELAY` | `3` | Delay between attempts (seconds) |
| `DOWNLOAD_INTERFACES` | `"default *"` | Download interfaces (glob patterns), failover by list |
| `DNS_FULL_RESOLVER_PORT` | `""` | DNS resolver port (empty = auto-detect: SmartDNS 6153 → 6053 → system) |
| `DOMAINS_LIST_FILE` | `geo-split-data/lists/domains.txt` | Domain list file (`@include` supported) |
| `DOMAINS_UPDATE_INTERVAL` | `3600` | Domain update interval, seconds (1 hour; `0` = disable) |
| `REFRESH_NICE_ADJUST` | `10` | CPU-priority adjustment for refresh cron jobs (0=disabled, 1-19=lower priority) |

### Configuration examples

**EAEU → ISP (default, no config needed):**
```sh
GEO_ZONE="eas"
ROUTE_OUT="auto"
```

**Russia only:**
```sh
GEO_ZONE="ru"
```

**CIS via tunnel (access to RU services from abroad):**
```sh
GEO_ZONE="cis"
ROUTE_OUT="nwg0"
```

**GEO traffic through a specific ISP interface:**
```sh
ROUTE_OUT="lte_br0"
```

**Multiple LAN interfaces (home + guest network):**
```sh
ROUTE_IN="br0 br1"
```

**Disable domain resolution:**
```sh
DOMAINS_UPDATE_INTERVAL=0
```

## Files

| File | Purpose |
|------|---------|
| `scripts/attach-rules.sh` | Attach ip rules for all ifaces from `ROUTE_IN` (domain prio 50, subnet prio 51) |
| `scripts/detach-rules.sh` | Detach ip rules + flush route tables |
| `scripts/update-subnets.sh` | Download GeoIP subnets via loader + populate subnet table |
| `scripts/update-domains.sh` | DNS resolution of domains (dig → /32 host routes in domain table) |
| `scripts/ndm-hook.sh` | NDM hook: reconcile routing tables on interface state changes |
| `scripts/route-check.sh` | Route diagnostics: determine where traffic to a host/IP/CIDR routes |
| `scripts/wan-paths.sh` | List all WAN egress paths (ISP + tunnel interfaces) as JSON via NDM API |
| `scripts/status.sh` | Diagnostics: mode, rules, tables, caches |
| `loaders/cidr-plain.sh` | Loader: plain CIDR (default) |
| `loaders/ripe-json.sh` | Loader: RIPE JSON API (requires `jq`) |
| `config/config.conf` | Configuration (mode, interfaces, URL, intervals) |
| `init.d/S99geo-split` | Init script (start/stop/restart/status/refresh/update) |

Data (domain lists, GeoIP zones) are in a separate package [`geo-split-data`](../geo-split-data/).

## Loaders

Loaders are scripts in the `loaders/` directory that download CIDR subnets from external sources and output them to stdout (one subnet per line).

| Loader | Description | Dependencies |
|--------|-------------|--------------|
| `cidr-plain` | Plain-text CIDR, IPv6 filtering. Default | `curl` |
| `ripe-json` | RIPE Stat JSON API | `curl`, `jq` |

Loader selection in `config/config.conf`:

```sh
SUBNET_LOADER="cidr-plain"
SUBNET_URL="https://raw.githubusercontent.com/herrbischoff/country-ip-blocks/master/ipv4/ru.cidr"
```

## Diagnostics (status.sh)

```sh
/opt/etc/init.d/S99geo-split status
```

Example output:

```
geo-split status: ✓ Alive
  Mode:
    Geo zone:    eas → [ru by kz am kg]
    Route in:    br0
    Route out:   auto (detect ISP)
    Active out:  apcli0 (isp, tables 1000,1001)
    Gateway:     192.168.1.1

  IP rules:
    iif br0 → table 1000 (domains) ✓
    iif br0 → table 1001 (subnets) ✓

  Routes:
    Domains:     183 routes in table 1000, filled 32m 56s ago ✓
    Subnets:     9274 routes in table 1001, filled 33m 31s ago ✓

  Caches:
    Subnets:     cache 2d 6h 51m old (max 7d 0h 0m) ✓
    Domains:     183 in cache, 33m 11s old (max 1h 0m 0s) ✓

  Domain sources: 103 domain(s) configured

  System:
    Uptime:      2d 5h ✓
    Cron:        1 job(s) (shift 7m) ✓
    NDM hook:    /opt/etc/ndm/ifstatechanged.d/geo-split-hook ✓
    DL iface:    default (cached)
    DNS:         localhost:6153 (SmartDNS no-speed-check)
    Background:  idle
    Loader:      cidr-plain
    Version:     0.17.4
```

**Exit code:** `0` — all OK, `1` — issues detected (✗ in output).

## KeeneticOS components (firmware)

For `geo-split` to work, certain base components must be enabled in the Keenetic firmware. These are **firmware components** (not Entware packages) — enable them through the router's web UI or Keenetic CLI.

### Required

| Component | Purpose |
|-----------|---------|
| **OPKG** (package installation from Entware repository) | Without it there's no `/opt`, Entware, init scripts `/opt/etc/init.d/`, NDM hooks `/opt/etc/ndm/ifstatechanged.d/`. This is the basic prerequisite for the entire project. |
| **Filesystem drivers** (Ext4 / ExFAT — matching the USB drive) | Required to mount the drive with Entware. |

### NOT required

The project uses only policy routing (`ip rule` + separate routing tables). Therefore the following are **not needed**:

- ❌ "Netfilter subsystem kernel modules" (iptables MARK / mangle) — architectural decision: project uses a route-based approach without fwmark.
- ❌ `ipset`, `nftables` — not used.
- ❌ "DNS-Override" / DNS substitution modules — handled by the separate [`smartdns-geo-conf/`](../smartdns-geo-conf/README.md) subproject if needed.

### How to enable components

**Via web interface:**
1. Open *General Settings → Modify component set* (in different firmware versions may be called *Management → System Parameters → Component Update*).
2. In the *"System"* / *"Other"* section enable **OPKG** (often called "OPKG package support").
3. Ensure the filesystem driver matching your USB drive type (Ext4 or ExFAT) is enabled.
4. Apply changes → router will update firmware and reboot.

**Via Keenetic CLI** (telnet/ssh to the router itself, not Entware):
```
(config)> components install opkg
(config)> system configuration save
```

After that, connect a USB drive with Ext4 and install Entware following the [official Keenetic instructions](https://help.keenetic.com/hc/ru/articles/360021214160).

## Dependencies

| Package | Type | Purpose |
|---------|------|---------|
| `keenetic-entware-extras` | Depends | Base package (shared libraries) |
| `geo-split-data` | Depends | Domain lists and GeoIP zones |
| `ip-full` | Depends | `ip rule`, `ip route`, `ip -batch` |
| `curl` | Depends | Subnet download |
| `bind-dig` | Depends | DNS resolution of domains |
| `aggregate` | Depends | CIDR subnet aggregation |
| `coreutils-touch` | Depends | Cache file timestamp management |
| `jq` | Recommends | For `ripe-json` loader |

## For developers

Deploy to router (without .ipk):

```sh
scp -O -r geo-split/ root@<router>:/opt/keenetic-entware-extras/geo-split/
scp -O -r lib/ root@<router>:/opt/keenetic-entware-extras/lib/
ssh root@<router> '/opt/etc/init.d/S99geo-split restart'
```
