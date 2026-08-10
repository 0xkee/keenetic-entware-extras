1# Changelog

All notable changes to `net-check` are documented here.

Format: [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/)
Versioning: [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html)

## [0.2.7] - 2026-08-10

### Changed
- **Performance: GeoIP pre-warm** — after Phase 2 parallel probes in DNS and
  CDN commands, all resolved IPs are batch-geolocated (deduplicated, sequential)
  before Phase 3 rendering. Phase 3 `geolocate_ip()` calls now always hit
  fresh cache — eliminates ~160 sequential HTTP requests on cold cache

### Fixed
- **Historical diff cache: quoted verdict values** — `load_prev_cache()` now
  quotes verdict values in eval'd variable assignments, preventing shell errors
  when verdict contains spaces (e.g. "Untrusted CA")

## [0.2.6] - 2026-08-10

### Changed
- **Fork/exec optimization for table rendering** — reduced ~3800 fork/exec
  calls during compare/tls/cdn/dns table output (30 targets × 4 interfaces):
  - `parse_curl_metrics()` → single awk (18→2 forks per call)
  - `to_ms()` → pure shell arithmetic (1→0 forks per call)
  - JSON construction in hot loops → inline printf (6-11→0 forks per cell)
  - `prev_verdict_for()` → pre-parsed cache lookup (4→1 fork per cell)
  - `tbl_cell_v()` — global-variable variant of `tbl_cell()` (1→0 forks)
  - `precache_geo_cc()` / `geo_cc_fast()` — pre-cached CC lookup (3→0 forks)
  - `_cdn_format_cell_v()` — global-variable variant for CDN cells

## [0.2.5] - 2026-08-10

### Changed
- **Rich status dashboard** — `status.sh` output significantly improved:
  - Each WAN path shows external IP, country code, and detailed tunnel type
    (wireguard/openvpn/gre/etc instead of generic "tunnel")
  - Fail reason shown in header: `✗ Fail (nwg2 unreachable)`
  - DNS leak enriched with provider name and country from cache
  - IPv6 leak check added to System section
  - Context section shows SmartDNS and geo-split status when available
  - `?/?` no longer shown when no cache exists; `Last check: never` hidden
  - Path columns aligned with printf formatting for readability
- **JSON output enriched** — added `iface_type`, `ext_ip`, `cc`, `ipv6_leak`
  fields to JSON output for WebUI consumption

## [0.2.4] - 2026-08-10

### Fixed
- **DNS queries now use SmartDNS directly** — `dig` on the router goes through
  `ndnproxymain` (:53), not SmartDNS, because PREROUTING DNAT only intercepts
  LAN clients. DNS/check commands now query SmartDNS on its actual port
  (`@127.0.0.1 -p 6053`) when detected. Label changed from misleading
  `"SmartDNS (via :53)"` to accurate `"SmartDNS (:6053)"`.

## [0.2.3] - 2026-08-10

### Changed
- **DRY batch runner** — extracted duplicated "batched parallel fetch with
  progress" pattern (~200 lines across 4 files) into `batch_run_parallel()`
  helper in `output.sh`. Callbacks: `_compare_run_batch`, `_tls_run_batch`,
  `_cdn_run_batch`, `_dns_run_batch`.
- **DRY auto-width** — extracted duplicated first-column width calculation
  (~5 lines × 3 files) into `auto_label_width()` helper in `output.sh`.
- **Progress shows section label** — progress indicator now displays section
  name: `HTTP: 12/36...`, `TLS: 12/36...`, `CDN: 5/18...`, `DNS: 12/36...`
  (was generic `Fetching: N/M...`).

## [0.2.2] - 2026-08-10

### Changed
- **`cmd_all` unbuffered text output** — in text mode, section output now streams
  line-by-line via pipe instead of buffering to a temp file. JSON mode unchanged.

### Fixed
- **`cmd_all` progress visibility** — removed `2>&1` from step command
  redirections so stderr (progress lines) goes to real terminal, not temp file.
  `[ -t 2 ]` now correctly detects TTY during batch execution.
- **DNS table: auto-width Domain column** — `console.cloud.google.com` (26 chars)
  no longer overflows the 22-char column. Dynamic width (min 22, max 32).
- **IPv6-ready IP columns** — `Resolved IP` widened from 18 to 24 chars in DNS
  and TLS single-host tables. Accommodates shortened IPv6 addresses.

## [0.2.1] - 2026-08-10

### Changed
- **Streaming output for single commands** — `net-check.sh geo`, `comp`, etc.
  now stream table rows in real time (removed spinner + buffered output wrapper).
  `_spinner_msg()` function removed from main dispatcher.
- **Progress indicator for batch commands** — `comp`, `cdn`, `tls`, `dns`
  show `Fetching: N/M...` on stderr during parallel phase (text mode, tty only;
  suppressed for `--json` and non-tty). Replaces animated spinner.
- **`cmd_all` runs without spinner** — `start_spinner`/`stop_spinner` removed
  from Step 1 (geo) and data-driven loop (steps 2–9). `section_banner` suffices.
- **Auto-width first column in comparison tables** — `cmp_header()` accepts
  4th parameter `_label_w` (default 20). `cmd_compare`, `cmd_tls_check_targets`,
  `cmd_cdn_all` compute max hostname length (min 20, max 30) before rendering.
  `cmp_row_start()` uses `_CMP_LABEL_W` for consistent alignment.

## [0.2.0] - 2026-08-10

### Added
- **Granular TLS failure classification** — `classify_failure()` now sub-classifies
  `ssl_verify_result` codes: `Untrusted CA` (18/19/20/21), `Cert expired` (10),
  `Cert revoked` (23), `Hostname mismatch` (62). Only unknown codes → `MITM detected`.
  Fixes sberbank.ru false positive (Russian national CA ≠ MITM).
- **New per-path verdicts**: `DNS resolution failed` (curl exit 6),
  `Server error (5xx)`, `Empty response` (curl exit 52),
  `Partial transfer` (curl exit 18)
- **New overall verdicts** in `determine_verdict()`: `cert_issue` (all paths fail
  with same cert error), `dns_issue` (all DNS failures), `server_down` (all 5xx).
  Sub-classifies `all_fail` to distinguish infra issues from network filtering.
- **`known-cas.conf`** — allowlist of national/regional CAs (Russia НУЦ, Kazakhstan
  QAZNET, China CFCA/CNNIC, Turkey TÜBİTAK, India NIC, Iran, Korea, Thailand,
  Brazil ICP-Brasil). TLS check shows `NCA`/`NatCA` instead of flagging as MITM.
- **`_check_known_ca()`** helper — issuer matching against `known-cas.conf`
  (used by TLS comparison table to distinguish national CAs from MITM proxies)

### Changed
- `short_reason()`: new compact tags — `UNTCA`, `EXPRD`, `REVKD`, `SSLNM`,
  `DNSFL`, `SVERR`, `EMPTY`, `PARTL`
- `determine_verdict()`: extended input format `iface:status:ttfb:reason`
  (backward-compatible — reason field optional)
- TLS comparison table: `known_ca` path status (`NCA` tag, dim color),
  `known_ca` per-host verdict (`NatCA` display)

## [0.1.3] - 2026-08-10

### Fixed
- `load_zone_context()`: detect standby tunnel interfaces from source-based routing tables for non-geo segment enumeration

## [0.1.2] - 2026-08-08

### Fixed
- `cdn-all`: restored `ℹ️ cached` marker in CDN comparison table verdict —
  `cc_cached` was computed but never displayed
- `dns-leak`: added `ℹ️ cached` marker for GeoIP cache hits on resolver IPs —
  `geolocate_ip()` was called without cache tracking

## [0.1.1] - 2026-08-08

### Added
- CDN table (`cdn-all`): category group separators (`── Global ──`,
  `── International ──`, `── Zone ──`) matching other comparison tables

## [0.1.0] - 2026-08-08

### Changed
- **i18n: worldwide check-targets** — `check-targets.conf` expanded to 40+ country
  zones with runtime zone filtering via `_cat_config()` (only active zone loaded)
- **i18n: worldwide cdn-domains** — `cdn-domains.conf` expanded with zone CDN
  entries for 12+ countries, runtime zone filtering
- **i18n: CHECK_ZONE** — new `CHECK_ZONE="auto"` setting in `defaults.conf`;
  set to any ISO code or union name for standalone use without smartdns-geo-conf
- **i18n: custom targets** — user customizations now go into `*-custom.conf`
  (conffiles); main configs updated with package, not conffiles
- `anomaly-markers.conf`: added international block page markers (TR, IR, CN, IN)
- `_get_isp_dns()`: fallback to `/etc/resolv.conf` for non-Keenetic routers

## [0.0.5] - 2026-08-01

### Added
- `check-targets.conf`: new targets — Avito (zone-ru), Kufar + Beltelecom
  (zone-by), Nur.kz + Krisha (zone-kz), Spotify (intl-streaming), Perplexity
  (intl-ai), Telegram + Reddit (intl-services), AWS + Google Cloud (intl-cloud)
- `cdn-domains.conf`: VK CDN (zone-ru), Facebook CDN + jsDelivr CDN
- `http-core.sh`: curl exit 92 → "HTTP/2 protocol error" (H2ERR) classification

### Removed
- `check-targets.conf`: 21vek.by (zone-by), kaspi.kz (zone-kz) — server-side
  geo-blocks for non-local IPs, always fail from abroad
- `cdn-domains.conf`: cdn.ozon.ru — HTTP/2 PROTOCOL_ERROR on root URL probe

### Changed
- `cdn-domains.conf`: Instagram CDN endpoint i.instagram.com → scontent.cdninstagram.com
  (i.instagram.com returns app-level errors for non-app requests)

## [0.0.4] - 2026-08-01

### Changed
- `wan.sh`: ► active route detection now uses kernel FIB with auto-detected VPN
  fwmark (`--as auto` mode). New `_detect_auto_fwmark()` finds the first VPN
  tunnel fwmark from ip rules, `fib_active_dev()` queries `ip route get` with
  fwmark + iif br0 — correctly simulates VPN-policy LAN client. Zone IPs hit
  geo-split tables (prio 50/51), intl IPs hit fwmark rule (prio 100+) → tunnel.
  Replaces old `route_dev_for_ip()` which queried without fwmark (always returned
  default route for intl targets). Removed `intl-*` category heuristic fallback.

## [0.0.3] - 2026-07-30

### Changed
- `status.sh`: colored status marks and bold section headers via `lib/status.sh` color system; `--color`/`--no-color` flag support
- `output.sh`: `setup_colors()` delegates to `lib/status.sh:status_setup_colors()` — single source of ANSI color codes
- `net-check.sh`: added `lib/status.sh` to source chain

## [0.0.2] - 2026-07-30

### Fixed

- **dns-leak: false LEAK on multi-tunnel setups** — resolvers at VPN tunnel
  exit countries (NL, LV, SE, NO etc.) were incorrectly flagged as leaks.
  New 3-level classification: known provider → tunnel exit → real leak.
  Only ISP-country resolvers are flagged as leaks when tunnels are configured.
- **dns-leak: whoami fallback ISP WAN IP false positive** — queries #2/#3
  in the whoami fallback bypass SmartDNS and return the router's WAN IP,
  causing false leak detection. Now skipped when SmartDNS is active.
- **dns-leak: inverted elif logic** — without SmartDNS, ISP DNS was flagged
  as a leak instead of being treated as the expected resolver.

### Changed

- **dns-leak: tunnel/direct status labels** — resolvers now show `tunnel ✅`
  (at VPN exit) or `direct ✅` (via ISP) instead of plain `✅`.
- **dns-leak: wider table columns** — Resolver IP 18→24 (IPv6 fit),
  Provider 40→50 (long names fit).
- **DNS_LEAK_WAIT** increased from 3s to 7s — multi-tunnel setups need more
  time for all probe responses to propagate.

## [0.0.1] - 2026-07-21

Initial pre-release. Full CLI network diagnostics tool for Keenetic routers
with Entware.

### Commands

- **`all`** — full diagnostics suite (9 steps): geo → conn → ipv6 → dns →
  dns-leak → comp → cdn → tls → speed
- **`geo`** — egress point verification via GeoIP per WAN interface
- **`conn`** — ping, TCP :443, traceroute hops, packet loss, MTU discovery,
  DNS/TCP/TLS/Total timing
- **`dns`** — DNS resolution & geolocation for all check targets; detects ISP
  DNS filtering (NXDOMAIN/bogon) and split-DNS zone alignment
- **`dns-leak`** — DNS leak test via subdomain probing; discovers recursive
  resolvers; 3-level fallback (dnscheck.tools → bash.ws → whoami)
- **`comp`** — HTTP reachability matrix across WAN interfaces with TTFB,
  failure classification, route verification, and historical diff (▲/▼ markers)
- **`cdn`** — CDN geo-steering analysis via EDNS Client Subnet; comparison
  table with per-interface edge country + geo-steering verdict
- **`tls`** — TLS certificate fingerprint
  comparison across paths; MITM proxy detection via known CA list
- **`speed`** — download + upload throughput via Cloudflare endpoint
- **`ipv6`** — detects IPv6 traffic bypassing tunnel via ISP interface
- **`check`** — deep single/multi-domain check: HTTP + DNS + TLS + CDN with
  per-interface comparison tables (always uses multi-domain layout)

### Features

- **Multi-WAN support** — all checks run per WAN interface with automatic
  detection (PPPoE, WireGuard, OpenVPN, etc.)
- **Geo-zone awareness** — integrates with `geo-split` / `smartdns-geo-conf`
  for route verification against expected zone routing
- **ISP blocking detection** — classifies failures: TIMEOUT, DPI, TLS error,
  MITM, RST, redirect loops, anomaly page markers
- **Privacy mode** (`--privacy`) — anonymizes IPs, ASN, cities, country codes
  in output for safe sharing
- **JSON output** (`--json`) — machine-readable output for all commands
- **Verbose/quiet modes** (`--verbose` / `--quiet`) — timing waterfall or
  one-line summary
- **No-color mode** (`--no-color` / `NO_COLOR`) — plain text with Unicode
  fallback for emoji
- **Exit codes** — `0` = all ok, `1` = degraded, `2` = critical
- **GeoIP caching** — file-based cache with TTL, HTTP 429 rate-limit handling
- **Adaptive parallelism** — batch size auto-tuned by CPU load; `nice` priority
  to reduce router contention
- **Ctrl+C** — clean termination of all child processes

### Configuration

- `config/defaults.conf` — all tunable parameters (URLs, timeouts, thresholds,
  batch sizes)
- `config/check-targets.conf` — HTTP check targets with geo-zone categories
- `config/cdn-domains.conf` — CDN domains for geo-steering analysis
- `config/dns-providers.conf` — DNS provider identification patterns
- `config/anomaly-markers.conf` — ISP/DPI block page detection strings
- `config/mitm-issuers.conf` — known MITM proxy CA patterns
- `config/wellknown-ips.conf` — well-known DNS resolver IPs
- `config/privacy-providers.conf` — fake provider names for privacy mode
- All config files protected from overwrite on package upgrade (`conffiles`)
