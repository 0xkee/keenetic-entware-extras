# net-check

Network connectivity diagnostics and degradation control for Keenetic/Entware.

End-to-end reachability verification across WAN interfaces,
MITM/DPI anomaly detection, CDN geo-steering analysis,
DNS leak testing, path quality comparison.

> 📖 **[User Manual (RU)](docs/user-manual.ru.md)**

## Usage

```sh
# Full diagnostics (9 steps: geo → conn → ipv6 → dns → dns-leak → comp → cdn → tls → speed)
net-check.sh all

# Deep check — single resource (HTTP + DNS + TLS + CDN)
net-check.sh check youtube.com

# Deep check — multiple resources (bulk tables)
net-check.sh check youtube.com google.com github.com

# Per-interface diagnostics
net-check.sh geo              # Egress point verification (GeoIP)
net-check.sh conn             # TCP/TLS timing, traceroute, loss, MTU
net-check.sh ipv6             # IPv6 leak detection
net-check.sh speed            # Download/upload throughput

# Bulk resource checks (all targets from config)
net-check.sh comp             # HTTP reachability comparison table
net-check.sh dns              # DNS resolution & ISP filtering
net-check.sh dns-leak         # DNS leak test (resolver chain discovery)
net-check.sh cdn              # CDN geo-steering analysis
net-check.sh tls              # TLS certificate MITM check

# Single-resource variants
net-check.sh cdn youtube.com  # CDN analysis for one domain
net-check.sh tls youtube.com  # TLS check for one host

# Bulk checks with custom domains (instead of config)
net-check.sh comp youtube.com google.com
net-check.sh dns youtube.com google.com

# Options
net-check.sh --json check youtube.com   # JSON output
net-check.sh --privacy all              # Anonymize IPs, ASN, geo
net-check.sh --iface nwg0 comp         # Check via specific interface
net-check.sh --quiet all                # One-line summary per section
```

## Configuration

- `config/defaults.conf` — default settings (do not edit)
- `config/config.conf` — user overrides (create if needed)
- `config/check-targets.conf` — HTTP/DNS/TLS target list
- `config/cdn-domains.conf` — CDN domains for steering analysis
- `config/dns-providers.conf` — DNS provider identification
- `config/anomaly-markers.conf` — ISP block page detection
- `config/mitm-issuers.conf` — known MITM proxy CA patterns

All config files are protected from overwrite on package upgrade.

## Exit Codes

- `0` — all checks passed
- `1` — degraded (some checks failed)
- `2` — critical failure

## File structure

```
net-check/
├── config/
│   ├── defaults.conf           # Default settings (do not edit)
│   ├── config.conf             # User overrides (create if needed)
│   ├── check-targets.conf      # HTTP/DNS/TLS target list
│   ├── check-targets-custom.conf # User custom targets (not overwritten)
│   ├── cdn-domains.conf        # CDN domains for steering analysis
│   ├── cdn-domains-custom.conf # User custom CDN domains (not overwritten)
│   ├── dns-providers.conf      # DNS provider identification
│   ├── anomaly-markers.conf    # ISP block page detection patterns
│   ├── mitm-issuers.conf       # Known MITM proxy CA patterns
│   ├── known-cas.conf          # Known national/regional CAs (allowlist)
│   ├── privacy-providers.conf  # Privacy provider patterns for anonymization
│   └── wellknown-ips.conf      # Well-known public DNS resolver IPs
├── scripts/
│   ├── net-check.sh            # Main entry point
│   ├── domain-check.sh         # Shortcut: deep single-resource check
│   ├── status.sh               # Diagnostics for init.d status
│   └── lib/                    # Command modules and shared libraries
│       ├── cmd-all.sh          # "all" command orchestration
│       ├── cmd-geo.sh          # Egress point verification (GeoIP)
│       ├── cmd-connectivity.sh # TCP/TLS timing, traceroute, loss, MTU
│       ├── cmd-ipv6-leak.sh    # IPv6 leak detection
│       ├── cmd-dns.sh          # DNS resolution & ISP filtering
│       ├── cmd-dns-leak.sh     # DNS leak test (resolver chain)
│       ├── cmd-compare.sh      # HTTP reachability comparison table
│       ├── cmd-cdn.sh          # CDN geo-steering analysis
│       ├── cmd-tls.sh          # TLS certificate MITM check
│       ├── cmd-speed.sh        # Download/upload throughput
│       ├── cmd-check.sh        # Deep single-resource check
│       ├── batch.sh            # Adaptive batch sizing, parallel runner
│       ├── wan.sh              # WAN discovery, iface_type
│       ├── geoip.sh            # IP geolocation API
│       ├── geo-cache.sh        # Geo cache operations + lookups
│       ├── zone.sh             # Geo-zone context, routing
│       ├── http-core.sh        # curl, content check, metrics
│       ├── verdict.sh          # Failure classification, reason labels
│       ├── privacy.sh          # Privacy filter (IP/ASN anonymization)
│       ├── output.sh           # Errors, usage, config reader
│       ├── sections.sh         # Spinner, banners, verbosity
│       ├── table.sh            # Table framework
│       └── colors.sh           # Colors, marks, emoji
└── docs/
    └── user-manual.ru.md       # User manual (Russian)
```

### domain-check.sh

Shortcut for deep single-resource check. Equivalent to `net-check.sh check <domain>`:

```sh
domain-check.sh youtube.com
```

## Dependencies

- `curl` — HTTP checks, GeoIP services, dns-leak test APIs
- `bind-dig` — DNS/CDN checks, EDNS Client Subnet, dns-leak probing
- `iputils-ping` — ICMP connectivity, loss/jitter measurement
- `netcat` (recommended) — TCP connect checks
- `openssl-util` (recommended) — TLS certificate inspection
- `traceroute` (optional) — path tracing

## Standards

Measurement methodology follows ITU-T Y.1540 (IP packet transfer parameters)
and ITU-T Y.1541 (network performance objectives).
