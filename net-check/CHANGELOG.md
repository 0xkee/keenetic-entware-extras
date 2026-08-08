# Changelog

All notable changes to `net-check` are documented here.

Format: [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/)
Versioning: [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html)

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
