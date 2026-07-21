# Changelog

All notable changes to `net-check` are documented here.

Format: [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/)
Versioning: [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html)

## [0.0.1] - 2026-07-21

Initial pre-release. Full CLI network diagnostics tool for Keenetic routers
with Entware.

### Commands

- **`all`** — full diagnostics suite (8 steps): geo → connectivity → ipv6-leak
  → dns → compare → cdn → tls → speed
- **`geo`** — egress point verification via GeoIP per WAN interface
- **`connectivity`** — ping, TCP :443, traceroute hops, packet loss, MTU
  discovery, DNS/TCP/TLS/Total timing
- **`dns`** — DNS resolution & geolocation for all check targets; detects ISP
  DNS filtering (NXDOMAIN/bogon) and split-DNS zone alignment
- **`compare`** — HTTP reachability matrix across WAN interfaces with TTFB,
  failure classification, route verification, and historical diff (▲/▼ markers)
- **`cdn`** / **`cdn-all`** — CDN geo-steering analysis via EDNS Client Subnet;
  comparison table with per-interface edge country + geo-steering verdict
- **`tls-check`** / **`tls-check-targets`** — TLS certificate fingerprint
  comparison across paths; MITM proxy detection via known CA list
- **`speed`** — download + upload throughput via Cloudflare endpoint
- **`ipv6-leak`** — detects IPv6 traffic bypassing tunnel via ISP interface

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
