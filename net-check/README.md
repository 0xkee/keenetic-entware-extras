# net-check

Network connectivity diagnostics and degradation control for Keenetic/Entware.

End-to-end reachability verification across WAN interfaces,
MITM/DPI anomaly detection, CDN geo-steering analysis,
DNS leak testing, path quality comparison.

## Usage

```sh
# Full diagnostics (8 steps: geo → conn → ipv6 → dns → comp → cdn → tls → speed)
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

## Dependencies

- `curl` — HTTP checks, GeoIP services
- `bind-dig` — DNS/CDN checks, EDNS Client Subnet
- `netcat` (recommended) — TCP connect checks
- `openssl-util` (recommended) — TLS certificate inspection
- `traceroute` (optional) — path tracing

## Standards

Measurement methodology follows ITU-T Y.1540 (IP packet transfer parameters)
and ITU-T Y.1541 (network performance objectives).
