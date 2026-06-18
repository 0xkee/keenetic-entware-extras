# Changelog

All notable changes to `keenetic-entware-extras` (base package) are documented here.<!--  -->

Format: [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/)
Versioning: [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html)

## [0.16.4] - 2026-06-18

### Changed
- `lib/ip.sh`: `fill_routes_batch()` stamp files now store interface name
  (enables fast dev-mismatch detection by geo-split NDM hook without ip route fork)

## [0.16.3] - 2026-06-15

### Changed
- `lib/status.sh`: add declarative text output API (accumulator + emit pattern):
  `status_line`, `status_line_cont`, `status_section`, `status_blank`,
  `status_emit_text`. Refactored `status_show_*` helpers to use accumulator.
  Parallel to existing JSON accumulation API.

## [0.16.2] - 2026-06-15

### Changed
- `lib/status.sh`: add declarative JSON accumulation API (`status_detail`,
  `status_check_result`, `status_extra`, `status_emit_json`) — eliminates manual
  printf/json_kv boilerplate in status scripts.

## [0.16.1] - 2026-06-13

### Fixed
- `scripts/bug-report.sh`: MTU check no longer crashes script on routers with
  non-VPN interfaces having MTU >= 1500 (set -e + `&&` chain in while pipeline).
  Now shows only VPN/tunnel MTU (informational, no ⚠ — reduced MTU is expected).

## [0.16.0] - 2026-06-13

### Fixed
- `lib/ip.sh`: `detect_out_iface()` now excludes `awg*` (AmneziaWG) from ISP auto-detection.
  Previously, if awg0 was the default route, it would be incorrectly returned as ISP interface.
- `scripts/bug-report.sh`: DNS `+nocookie` fix — Keenetic ndnproxy doesn't support
  EDNS COOKIE, caused empty "System resolver" output on all routers.

### Added
- `scripts/bug-report.sh`: routing effectiveness diagnostic — detects when geo-split
  is ineffective (routes to same interface as default + no Keenetic VPN policy).
- `scripts/bug-report.sh`: edge-case diagnostics — IPv6 leak, full ip rule show,
  interface MTU, rp_filter, POSTROUTING NAT, ROUTE_OUT health check, crond status.
- `scripts/bug-report.sh`: Keenetic policy rules display (fwmark prio 100+).
- `scripts/bug-report.sh`: **client-path verification** section — simulates traffic
  from LAN client (`ip route get ... from <LAN> iif br0`) to prove policy routing works;
  split-routing verdict (GEO vs non-GEO interface comparison), ping through ROUTE_OUT,
  NAT/MASQUERADE detection for client traffic.

### Changed
- `scripts/bug-report.sh`: removed all hardcoded RU zone references (ya.ru, 77.88.8.8).
  Test targets now picked dynamically from user's `domains-resolved.txt` cache and live
  route tables. Non-GEO target (`1.1.1.1`) verified against tables before use.
  DNS/HTTP/routing checks now reflect the user's actual configured geo-zone.

## [0.15.0] - 2026-06-10

### Added
- `lib/zones.sh`: full ISO 3166-1 alpha-2 zone labels (249 countries/territories).
  Replaces deleted per-zone config files. Used by webui zone selector dropdown.

## [0.14.0] - 2026-06-08

### Added
- `lib/geo.sh`: 15+ new unions — FATF, AIIB, NDB, OPEC/OPEC+ (split), offshore,
  SWIFT-disconnected, Commonwealth, Francophonie, Lusophone, Global South,
  Mediterranean, Greater China, East Asia+ASEAN, CELAC, US/EU-sanctioned, censored
- `lib/geo.sh`: new "🚫 Sanctions & restrictions" section (us_sanctioned,
  eu_sanctioned, swift_cut, censored)

### Changed
- `lib/geo.sh`: UTF emoji icons added to every union comment (displayed as labels
  in WebUI union selector)
- `lib/geo.sh`: OPEC split into core OPEC (13 members) and OPEC+ (with allies)

## [0.13.0] - 2026-06-07

### Added
- `lib/geo.sh` — shared geo-zone library (40+ unions, `resolve_geo_zone()`)
- Multi-zone GeoIP support in geo-split (GEO_ZONE config, all 240 countries)
- Shared `/api/system/zones` endpoint for webui zone selection

### Changed
- Removed `smartdns-geo-conf/config/unions.conf` → data moved to `lib/geo.sh`

## [0.12.1] - 2026-06-02

### Fixed
- Package: `scripts/bug-report.sh` included in .ipk data (was missing)

## [0.12.0] - 2026-06-01

### Improved
- `scripts/bug-report.sh` — major diagnostic enhancement:
  - New section: service enabled/disabled state (symlink detection)
  - New section: user config.conf existence per package
  - New section: geo-split effective config (ROUTE_OUT, ROUTE_GW, ROUTE_IN, tables)
  - New section: VPN/tunnel interfaces list (nwg/awg/ovpn/tun/tap)
  - Routes section: ISP auto-detection via `detect_out_iface()` + `detect_gateway()`
  - Routes section: shows route type (via gateway vs scope-link) for both tables
  - WebUI upstream (stock httpd) reachability probe in connectivity section
  - Added `coreutils-touch` to opkg package grep
  - Added `watchdog` to logread filter
  - Added `/proc/net/fib_triestat` availability indicator
  - Increased logread tail from 15 to 20 lines

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
