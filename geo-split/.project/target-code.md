# Code Quality Targets — geo-split

Inherits all rules from root [`.project/target-code.md`](../../.project/target-code.md).

## Additional Constraints

### Shebang
- `#!/opt/bin/sh` — all geo-split scripts use POSIX sh only

### Available Tools on Host (required)
- `curl` — HTTPS downloads for CIDR lists
- `ip` — policy routing: `ip route`, `ip rule`
- `ipset` — ipset management: `ipset create`, `ipset restore`, `ipset swap`
- `grep -E` — regex matching (NO `-P` / PCRE)

### Available Tools on Host (optional)
- `dig` (bind-dig) — DNS resolution for domain lists: `dig +short <domain> @localhost`

### DNS Specifics
- See [`smartdns-geo-conf/`](../../smartdns-geo-conf/) for DNS server configuration
- `dig @localhost` resolves through SmartDNS on port 6053

### Routing Specifics
- `ip rule add iif br0 table 1000 priority 50` — domains table
- `ip rule add iif br0 table 1001 priority 51` — subnets table
- Per-subnet routes in table 1001 + domain /32 routes in table 1000 via `ip-full -batch`
- Fallback: BusyBox `ip route add` loop if `ip-full` not installed

### Loader Pipe Convention
- Loaders live in `loaders/` — each is a standalone script receiving URL via `$1`
- Loader outputs CIDRs to stdout (one per line), caller pipes to cache file
- `update-subnets.sh` calls: `loaders/${SUBNET_LOADER}.sh "$SUBNET_URL" > cache`
- Adding a new source = new loader file + config change (no code modifications)

### Async Cron Pattern
- Data scripts (`update-subnets.sh`, `update-domains.sh`) check cache freshness internally
- Cron calls them frequently (every 15 min), but actual download happens only when stale
- `MAX_CACHE_AGE` (subnets, default 7d), `DOMAINS_UPDATE_INTERVAL` (domains, default 1h)
- `--force` flag bypasses freshness check for manual/emergency updates
- Boot: load from cache first (instant), then background-update if stale

### Dependencies (Entware)
- `ipset` — `opkg install ipset`
- `ip-full` — `opkg install ip-full` (for `-batch` bulk route loading)
- `curl` — `opkg install curl`
- `bind-dig` (optional) — `opkg install bind-dig` (for domain DNS resolution)
