# TODO — net-check

## CLI / UX

- [x] **Geo-zone context in tests** — shared `load_zone_context()` in `wan.sh`, shows
  `Geo zone: eas (ru by kz am kg) → eth3 (isp), default → nwg0 (tunnel)` in headers
  of `cmd_geo`, `cmd_connectivity`, `cmd_compare`, `cmd_cdn_all`, `cmd_dns`
- [ ] **BusyBox traceroute compat** — `cmd-connectivity.sh` uses `traceroute -i` (interface bind)
  and `-w` (wait), neither supported by BusyBox traceroute (only full traceroute has them;
  no standalone `traceroute` package in Entware aarch64). `command -v` finds BusyBox traceroute
  → shows Hops column → all values "—". Fix: detect BusyBox (`traceroute --help 2>&1 | grep -q BusyBox`)
  and skip hops or run without `-i`/`-w`
- [ ] **Resolver info in cmd_geo** — show `Resolver: SmartDNS (via :53)` like dns test does;
  useful for diagnosing when GeoIP service resolves via different DNS
- [ ] **Target endpoint in cmd_connectivity description** — show tested host
  (`gstatic.com/generate_204`) for transparency
- [x] Section descriptions for all commands (like dns-leak has Method/interpretation)
- [x] `--iface <dev>` flag: run checks only on a specific interface
- [x] `--no-color` flag + auto-detect tty (respects `NO_COLOR` env)
- [x] Colored section banners + summary footer
- [x] Summary footer for `all` command: timing + pass/fail counts
- [x] Spinner progress indicator for `all` command (background on stderr, buffered output)
- [x] `--verbose` flag: show curl timings breakdown (DNS→TCP→TLS→TTFB→Transfer waterfall)
  - curl already provides `time_namelookup`, `time_connect`, `time_appconnect`, `time_starttransfer`
  - Currently only TTFB shown — display full breakdown (like httpstat)
- [x] `--quiet` flag: one-line summary per command (pass/fail + count)
- [x] Machine-readable exit codes for cron/monitoring: `exit 0` = all_ok, `exit 1` = degraded, `exit 2` = fail
- [x] Move `CURL_UA` from hardcoded global to `defaults.conf` (overridable via `config.conf`)

## `all` command — section order

Current order (cognitively bottom-up through network stack, 8 steps):

1. **geo** — Egress Point Verification (Layers 3+7)
2. **connectivity** — Basic Connectivity (Layers 3–7)
3. **ipv6-leak** — IPv6 Leak Test (Layers 3+7)
4. **dns** — DNS Leak & ISP Filtering (Layer 7)
5. **compare** — HTTP Target Comparison (Layers 4–7)
6. **cdn-all** — CDN Geo-Steering Analysis (Layers 3+7)
7. **tls** — TLS Certificate Check (Layers 5–7)
8. **speed** — Throughput Test (Layers 4+7)

## Data & caching

- [x] **Dedicated data directory** `/opt/tmp/net-check/` instead of `/tmp` for cache + results
  - Add `DATA_DIR="/opt/tmp/net-check"` to `defaults.conf`
  - `mkdir -p "$DATA_DIR"` in `packaging/net-check/postinst` (install-time only)
  - Lazy `mkdir -p` in script as safety net (postinst may not have run on dev deploys)
  - Migrate: `CACHE_FILE="${DATA_DIR}/compare-last.json"`, geo cache, `mktemp` prefix
  - Pattern: same as `keenetic-entware-extras/postinst` → `mkdir -p /opt/tmp`

- [x] **GeoIP response caching** with TTL to avoid ipinfo.io rate-limiting
  - File per interface: `${DATA_DIR}/geo-<iface>.json` (e.g. `geo-nwg0.json`)
  - `GEO_CACHE_TTL=600` (10 min) in `defaults.conf` — safe: ipinfo.io free = 1000 req/day;
    10 min TTL means repeated `all` runs reuse cache, but single run with 2-3 ifaces always fits
  - Check via existing `is_cache_fresh()` from `lib/common.sh`
  - Fresh → read from file; stale → fetch API and overwrite
  - Cache format: `{"ip":"185.x.x.x","country":"NL","asn":"AS12345","org":"VDS"}`
  - **Handle 429 (rate limit ban):** if curl returns HTTP 429 from ipinfo.io, emit
    `"⚠️ GeoIP rate-limited (HTTP 429) — using stale cache"` and fall back to
    stale cache file if it exists, otherwise show `"rate-limited, no cache"`
  - `status.sh` benefits too — currently has no geo data

- [x] **Compare results cache → data dir**
  - Change `CACHE_FILE` path in `defaults.conf` from `/tmp/net-check-last.json`
    to `"${DATA_DIR}/compare-last.json"`
  - All consumers (`status.sh`, `cmd_compare`, `cmd_all` footer) already use
    `$CACHE_FILE` variable — zero code changes beyond defaults.conf

- [x] **Parallel execution safety** — per-instance `_RUN_DIR` (`${DATA_DIR}/run-$$`)
  isolates temp files between concurrent instances. Persistent caches stay shared
  in `DATA_DIR`. Atomic write (temp+mv) for geo cache, CDN geo cache, and
  compare-last.json prevents partial reads during concurrent access.

## v0.3

- [x] **Parallel checks** (`curl ... &` + `wait`) for faster `all`/`compare`
- [x] **Content fingerprint verification** (expected string in body)
- [x] **Anomaly page markers** from `config/anomaly-markers.conf`
- [x] **Anti-bot / WAF-protected targets** (chatgpt.com 403 problem)
- [x] **IPv6 leak test** (`curl -6`)
- [x] **Traceroute integration** (Level A → `connectivity`)
- [x] **Performance/throughput tests** (Level G)
- [x] **Certificate issuer check** (`openssl s_client` — Level C deep TLS)
- [x] **JSON wrapping for `all` command** (currently text-only even with `--json`)

## v0.5 — quick wins (source: [alternatives comparison](../docs/knowledge/net-check-alternatives-comparison.md))

### Bugs

- [x] **`tls-check` not per-interface** — partially resolved via per-iface `dig` + `openssl s_client -connect <resolved_ip>:443`
  *(openssl TCP connection still goes via system routing — see Future section)*
- [x] **`dns-leak` not per-interface** — now queries via iface-specific DNS from `/tmp/ndnproxymain.conf`

### Improvements

- [x] **CDN HTTP probe: cookies / custom headers** — 4th field in `cdn-domains.conf` for per-domain header overrides
- [x] **CDN + compare HTTP overlap** — extracted shared `http_probe()` in `http-core.sh` used by CDN
- [x] **Packet loss / jitter** — `ping -c 5 -I $iface 8.8.8.8`, parse loss%/jitter. Added to `connectivity`
- [x] **Upload speed test** — `speed --upload` flag, POST to Cloudflare `__up` endpoint
- [x] **MTU discovery** — binary search `ping -M do` per iface, exact to 1 byte. Added to `connectivity`
- [x] **DNS manipulation detection** — merged into unified `dns` command (v0.10: zone resolution + blocking)
- [x] **Historical diff** — `compare` loads previous `$CACHE_FILE`, shows `▼ NEW_FAIL` / `▲ RECOVERED` markers

## v0.6

- [x] **`--privacy` flag** — post-processing anonymization: IPs → `#.#.#.#`, ASN → `AS*****`,
  city → planet names, org → fake ISP (`config/privacy-providers.conf`), CC → random from `lib/zones.sh`.
  Well-known DNS IPs and private ranges preserved. New: `lib/privacy.sh`
- [x] **Exact MTU discovery** — binary search replaces 3-step coarse probe (1500/1400/1300/<1300);
  now finds precise path MTU to 1-byte accuracy (e.g. 1420 WireGuard, 1460 PPPoE)

## v0.7 — Performance & caching

- [x] **Privacy CC fix** — `--privacy` now masks country codes in comparison table headers
  `eth3 (CY)`, CDN comma-separated lists `NL,CY`, parenthesized multi-CC `(CC1 CC2)`
- [x] **Deep parallelization** — all 8 sections fully parallelized:
  - `geo`: per-interface GeoIP queries
  - `ipv6-leak`: per-interface IPv6 probes
  - `speed`: per-interface download/upload
  - `dns`: per-domain dig+geolocate (all domains simultaneously)
  - `compare`: all targets × interfaces in one parallel block
  - `cdn-all`: all domains × interfaces in one parallel block
  - `tls`: all hosts × interfaces in one parallel block
- [x] **DNS resolution cache** — `_resolve_a_cached()` with file cache TTL=60s, shared across sections
- [x] **WAN interface cache** — per-run in-memory cache avoids repeated wan-paths.sh fork
- [x] **PROBE_TIMEOUT config** — `defaults.conf` setting for ICMP/traceroute timeout (default 2s)
- [x] **MTU fast-path** — 3-tier typical values (1500/1420/1380) narrow binary search range
- [x] **Consolidate all timeouts into config** — HTTP_TIMEOUT, CONNECT_TIMEOUT, DNS_TIMEOUT,
  PROBE_TIMEOUT, SPEED_TIMEOUT, GEOIP_TIMEOUT now all in defaults.conf; 20+ config variables added

## v0.8 — UX & Performance

- [x] **Category group separators in `dns` and `tls`** — tables now show
  `── Global ──`, `── Zone ──`, `── International ──` dividers between
  category groups. Shared `tbl_group_sep()`/`tbl_group_reset()` in `output.sh`;
  `compare` refactored to use same helper (was inline). `_load_check_domains()`
  now preserves config order and returns `hostname|category` pairs
- [x] **`nice` process priority** — `NICE_ADJUST=10` in `defaults.conf`, re-exec
  with `nice -n $NICE_ADJUST` at startup. Reduces CPU contention during parallel checks
- [x] **Adaptive parallel batch size** — `PARALLEL_BATCH_SIZE=auto` (default).
  Reads `/proc/loadavg` + `nproc` for CPU pressure: idle → full batch,
  moderate → reduced, heavy → half. Explicit numeric value overrides auto
- [x] **Throughput Test: 2-column layout** — `speed` table uses "Down / Up" +
  "Time" columns instead of 4 separate columns. `format_speed_pair()` auto-selects
  unit when both match. JSON output unchanged

## Future

- [ ] **`tls-check` true per-interface binding** — `openssl s_client` ignores interface routing
  (blocked hosts show `unknown` on all paths even when reachable via tunnel). Options:
  - Entware `curl` doesn't expose certificate issuer in `-v` on this build
  - Investigate `socat` TCP relay: `socat - OPENSSL:host:443,bind=IF_IP`
  - Or compile curl with `--with-ssl-details` to get `issuer:` in verbose output
  - Or use `iptables -t nat PREROUTING` to force source IP per check
- [x] **Comparison table library** — extracted `cmp_header`/`cmp_row_start`/`cmp_cell`/`cmp_row_end`
  into `output.sh`; `compare`, `tls`, and `cdn-all` use shared table builder.
  Also extracted `_cdn_probe_iface()` and rewrote `cmd_cdn_all()` as comparison table.
- [x] geo-split integration: route verification via `ip route get` in `cmd_compare`;
  zone-aware check-targets.conf with `zone-<cc>` / `intl-<subcat>` categories
- [ ] geo-split integration: auto-recommend domains for split routing
- [ ] WebUI card + diagnostics modal
- [ ] Caching of results for WebUI dashboard
- [ ] History of check results (trending)
- [ ] Basic Connectivity - add how many incapsulated tunnels in each path by detecting mtu jumps (or better way)
- [ ] Throughput Test - add psevdo graph how each tunnel is fast (from min-max overall)







