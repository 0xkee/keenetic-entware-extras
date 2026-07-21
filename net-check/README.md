# net-check

Network connectivity diagnostics and degradation control for Keenetic/Entware.

End-to-end reachability verification across WAN interfaces,
MITM/DPI anomaly detection, CDN geo-steering analysis,
DNS leak testing, path quality comparison.

## Usage

```sh
# Full diagnostics (all checks: geo → connectivity → dns-leak → compare → cdn)
net-check.sh all

# Check single target across all WAN interfaces
net-check.sh youtube.com

# Egress point verification (GeoIP)
net-check.sh geo

# Basic connectivity (ping, TCP :443, Path MTU)
net-check.sh connectivity

# DNS leak test
net-check.sh dns-leak

# Check all HTTP targets from config
net-check.sh domains

# Full comparison table (+ saves cache for status.sh)
net-check.sh compare

# CDN geo-steering analysis (single domain)
net-check.sh cdn cdn.youtube.com

# CDN analysis for all configured domains
net-check.sh cdn-all

# JSON output (for WebUI/automation)
net-check.sh --json all
```

## Configuration

- `config/defaults.conf` — default settings (do not edit)
- `config/config.conf` — user overrides (create if needed)
- `config/check-targets.conf` — target list
- `config/cdn-domains.conf` — CDN domains for steering analysis

## Dependencies

- `curl` — HTTP checks, GeoIP services
- `bind-dig` — DNS/CDN checks, EDNS Client Subnet
- `netcat` (recommended) — TCP connect checks
- `openssl-util` (optional) — TLS certificate inspection
- `traceroute` (optional) — Path tracing

## Standards

Measurement methodology follows ITU-T Y.1540 (IP packet transfer parameters)
and ITU-T Y.1541 (network performance objectives).
