# Changelog

All notable changes to `geo-split` are documented here.

Format: [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/)
Versioning: [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html)

## [Unreleased]

## [0.11.0] - 2026-05-31

### Fixed
- Routes in custom tables (1000/1001) now include `via <gateway>` when ISP
  interface has a nexthop; fixes "host unreachable" on Ethernet ISPs that don't do proxy-ARP for scope-link routes

### Added
- `lib/ip.sh`: `detect_gateway(dev)` — auto-detect nexthop IP from ISP default route
- `lib/ip.sh`: `resolve_target_gateway(dev)` — resolve gateway from config or auto-detect
- `config/defaults.conf`: `ROUTE_GW` option (`auto`|`none`|explicit IP)
  - `auto` (default) — detect from ISP route; uses `via` for Ethernet,
    dev-only for point-to-point (LTE/PPP) where no gateway exists
  - `none` — force legacy behavior (scope link, no gateway)
  - explicit IP — fixed gateway for all geo-split routes
- `status.sh`: display detected gateway in compact status output

## [0.10.8] - 2026-05-30

### Changed
- `DOWNLOAD_INTERFACES` default: `"default *"` — auto-detect all active VPN interfaces (awg-manager, OpenConnect, Tailscale, etc.) instead of manually listing glob patterns
- Glob expansion in `resolve_download_interfaces()` now skips infrastructure interfaces (`lo`, `br*`, `ifb*`)

## [0.10.7] - 2026-05-25

### Added
- Zone sizes research doc (`docs/zone-sizes-research.md`): country CIDR counts, hardware compatibility matrix, usage scenarios

## [0.10.6] - 2026-05-16

### Changed
- Domain resolution interval reduced from 4h to 1h (`DOMAINS_UPDATE_INTERVAL=3600`)
- Skip route table rebuild when resolved IPs haven't changed (`cmp` diff check)
- Guard against empty resolution results (DNS down → keep old cache)

## [0.10.5] - 2026-05-15

### Changed
- Move all runtime files (pidfile, batch, caches) from `/tmp` to `/opt/tmp`

## [0.10.4] - 2026-05-12

### Fixed
- Status script reliability improvements
- Race condition on cold boot with slow DNS resolution

### Changed
- Async subnet loading on boot for faster startup
