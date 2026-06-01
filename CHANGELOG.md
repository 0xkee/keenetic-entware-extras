# Changelog

All notable changes to `keenetic-entware-extras` (base package) are documented here.

Format: [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/)
Versioning: [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html)

## [Unreleased]

## [0.11.1] - 2026-06-01

### Changed
- `kee-status.sh`: parse status word from sub-script first line instead of
  fragile grep/exit-code heuristic; added echo separator between packages in `-d`

## [0.11.0] - 2026-06-01

### Added
- `lib/common.sh`: `is_service_enabled()` — checks if init.d symlink exists
  (used by hooks/cron to respect user disable)
- `scripts/kee-status.sh`: "Disabled" status in yellow for services with
  removed init.d symlink

## [0.10.0] - 2026-05-31

### Added
- `lib/ip.sh`: new `detect_gateway()` — auto-detects nexthop IP for ISP interface
  (main table first, fallback to Keenetic policy tables 4096+)
- `lib/ip.sh`: new `resolve_target_gateway()` — resolves ROUTE_GW config
  (auto/none/<ip>) for policy routing setup

### Changed
- `lib/ip.sh`: `fill_routes_batch()` accepts optional `$5` gateway arg;
  adds `via <gateway>` to routes when ISP interface has a nexthop —
  fixes Ethernet ISP compatibility (previously all routes were scope-link)

## [0.9.5] - 2026-05-29

### Added
- `scripts/bug-report.sh` — one-command diagnostics collector for forum bug reports;
  gathers firmware version, package versions, all service statuses (via `kee-status -d`),
  DNS checks, route/rule state, and log tails

## [0.9.4] - 2026-05-26

### Fixed
- `lib/ip.sh` — `detect_out_iface()` now checks main table default route first;
  fixes incorrect ISP detection on multi-WAN routers where backup ISP (e.g. LTE
  in Keenetic table 16384) appeared before active WISP in `ip route show table all`

## [0.9.3] - 2026-05-15

### Fixed
- `lib/status.sh` — uptime calculation now uses monotonic clock (`/proc/<pid>/stat`
  field 22) instead of `stat -t` wall-clock timestamps; fixes wrong uptime on routers
  with bad RTC battery (clock skew after NTP sync)
- `lib/common.sh` — `update_pid_file()` now stores boot-relative uptime (line 2)
  for clock-skew-immune marker file age calculation

### Changed
- `postinst` ensures `/opt/tmp` directory exists (runtime data moved from `/tmp`)

## [0.9.2] - 2026-05-12

### Added
- `kee-status` aggregated diagnostic command (`/opt/bin/kee-status`)
- `lib/status.sh` shared check/show functions for service diagnostics

### Changed
- `lib/ip.sh` — improved CIDR aggregation and ISP interface detection
- `lib/common.sh` — enhanced router IP detection logic
