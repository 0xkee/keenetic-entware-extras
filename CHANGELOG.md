# Changelog

All notable changes to `keenetic-entware-extras` (base package) are documented here.

Format: [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/)
Versioning: [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html)

## [Unreleased]

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
