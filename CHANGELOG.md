# Changelog

All notable changes to `keenetic-entware-extras` (base package) are documented here.<!--  -->

Format: [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/)
Versioning: [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html)

## [Unreleased]

## [0.16.19] - 2026-08-28

### Changed
- Docs: installation instructions updated for opkg feed (`opkg install <pkg>` instead of `.ipk` filenames)
- `releases/README.md`: opkg repo docs overhaul — channels table, feed name `kee`, switch/install/uninstall sections
- `user-manual.ru.md`: installation section rewritten for opkg feed (was `.ipk` filenames)
- `scripts/install.sh`: minor UI fixes (menu spacing, emoji alignment in summary)

## [0.16.18] - 2026-08-28

### Fixed
- `scripts/install.sh` — crash when running via `ssh host "curl ... | sh"` (no TTY): `/dev/tty` exists but not functional without `-t` flag, now properly detected with subshell open test
- `scripts/install.sh` — prompt text leaked into `$choice` variable (printf to stdout captured by `$()` subshell), now outputs prompt to stderr
- `scripts/install.sh` — menu descriptions misaligned (manual spacing), now uses `printf %-26s` for consistent column layout
- `scripts/install.sh` — "up to date" packages were force-reinstalled unconditionally ("migrating to feed"), now correctly skipped

### Changed
- `scripts/install.sh` — refactored package catalog from 12 individual variables + case-based lookup to single `CATALOG` string with loop-based `pkg_name()`/`pkg_desc()` helpers
- `scripts/install.sh` — `indent()` changed from `sed` to `while read` loop for line-buffered (real-time) output streaming over SSH
- `scripts/install.sh` — validate user input in `parse_choice()`: reject non-numeric tokens before catalog lookup
- `scripts/install.sh` — show menu with available packages even when no TTY, then die with usage hint
- `scripts/install.sh` — interactive menu: added `F)` option for force reinstall of all packages (explicit `--force` for CLI)

### Added
- `scripts/install.sh` — bootstrap installer (`curl | sh`): auto-installs wget-ssl, configures opkg feed, interactive package menu, `--force` reinstall, `--all` mode, deploy.sh-style emoji output with summary
- `scripts/generate-packages-index.sh` — opkg Packages index generator for self-hosted repo (dev script, not shipped in .ipk)
- CI: `release.yml` auto-deploys .ipk to `dev/` channel on gh-pages after GitHub Release
- CI: `promote.yml` workflow for manual dev→stable promotion
- opkg repo: `gh-pages` orphan branch with `dev/` and `stable/` channels (7 packages, Packages + Packages.gz indexes)

## [0.16.17] - 2026-08-22

### Added
- `lib/privacy.sh` — shared privacy filter: `priv_mask_ip_asn()` (IPv4 + ASN width-preserving masking), `priv_mask_ipv6()`, `priv_basic_filter()` pipeline. Preserves RFC 1918, loopback, and well-known DNS IPs. Used by `bug-report.sh` and `net-check --privacy`
- `scripts/bug-report.sh`: privacy filter enabled by default — public IPs (#.#.#.#), ASN (AS****), IPv6 (#::#) are masked. Use `--no-privacy` for raw output. Removed old inline sed masking for ndnproxymain.conf
- `scripts/build-ipk.sh`: `lib/privacy.sh` added to BASE_DATA

## [0.16.16] - 2026-08-16

### Changed
- README: fix `REDIRECT` → `DNAT` in smartdns-redirect description, update `webui/lua/` file listing
- `scripts/check-privacy.sh`: exclude `CHANGELOG.md` from scan (historical records); add `KNOWN_FP` filter for conffile names (`ru-whitelist`) and functional domains (`rkn.gov.ru`)

## [0.16.15] - 2026-07-30

### Changed
- `lib/status.sh`: colored status marks (✓/✗/⚠), bold section headers; new `status_setup_colors()` with TTY-aware auto-detection
- `lib/status.sh`: `_status_parse_color_arg()` — `--color`/`--no-color` flag support for all status scripts
- `scripts/kee-status.sh`: passes `--color` to sub-scripts in `--details` mode for colored sub-output

## [0.16.14] - 2026-07-28

### Fixed
- `lib/lists.sh`: `list_count()` — missing `local` on `_cnt` var caused global namespace leak
- `lib/ip.sh`: `is_ipv4()` now validates each octet is 0–255 (previously `999.999.999.999` was accepted); `is_cidr()` reuses `is_ipv4()` for host-part validation
- `lib/ip.sh`: `detect_out_iface()` refactored to use `is_tunnel_iface()` via `_first_non_tunnel_default_iface()` helper — previously `sit*`, `gre*`, `vti*`, `ip6tnl*`, `xfrm*` were not excluded

### Changed
- `lib/common.sh`: `log()` / `log_error()` use `${0##*/}` / `${tag%.sh}` instead of `$(basename "$0" .sh)` — eliminates subshell fork per log call
- `lib/common.sh`: `format_age()` uses `printf '%s\n'` (was `echo`) — consistent with rest of file
- `tests/run-all.sh`: non-executable test files now emit `SKIP` warning instead of silently skipping

### Tests
- `tests/test-lib-ip.sh`: `is_ipv4` octet-range tests; `cidr_sample_ips /30` case
- `tests/test-lib-common.sh`: `json_escape_val` tab escape; `json_kv_bool` no-arg default
- `tests/test-lib-lists.sh`: `list_read` / `list_count` failure on missing file

## [0.16.13] - 2026-07-28

### Changed
- `scripts/bug-report.sh`: rewritten diagnostic collection

## [0.16.12] - 2026-07-27

### Fixed
- `lib/status.sh`: `status_check_port()` — normalize IPv6 listen addresses from
  netstat to RFC 3986 `[addr]:port` format. Previously raw netstat output like
  `fdce:...:d24c:6053` was ambiguous (port indistinguishable from last IPv6 group).
  Now displays `[fdce:...:d24c]:6053`. Fixes display in smartdns-redirect
  "Upstream probe", smartdns-geo-conf "Ports", and webui status JSON.
  Sort: IPv4 (LAN, loopback) → IPv6 (LAN, loopback).

### Changed
- `lib/geo.sh`, `lib/ip.sh`, `lib/common.sh`: legal terminology

## [0.16.10] - 2026-07-27

### Added
- `lib/common.sh`: `detect_router_ip6()` — detect global-scope IPv6 address on
  br0 bridge (used by smartdns-redirect for automatic IPv6 DNS DNAT)

## [0.16.8] - 2026-07-12

### Added
- `kee-status.sh`: package versions shown in summary mode (without `--details`) —
  dim `vX.Y.Z` suffix after Alive/FAIL label

## [0.16.7] - 2026-07-11

### Added
- `lib/ip.sh`: `cidr_overlap_routes()` — finds routes in a routing table that overlap
  with a given CIDR (moved from `geo-split/scripts/route-check.sh` for reuse)

## [0.16.6] - 2026-07-11

### Fixed
- `bug-report.sh`: reachability test false positive when tunnel is default route —
  `ping -I <dev>` (SO_BINDTODEVICE) conflicts with routing when default goes to
  a different interface. Now uses `ping -I <src_ip>` to leverage policy routing rules.
  Both ICMP and HTTP probes are run for richer diagnostics (ping OK/FAIL + HTTP status code).

## [0.16.5] - 2026-06-29

### Added
- `lib/common.sh`: `get_ms()` millisecond timer, `json_kv`/`json_kv_bool` helpers
- `lib/ip.sh`: `is_tunnel_iface()` tunnel interface detection

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
  non-tunnel interfaces having MTU >= 1500 (set -e + `&&` chain in while pipeline).
  Now shows only tunnel MTU (informational, no ⚠ — reduced MTU is expected).

## [0.16.0] - 2026-06-13

### Fixed
- `lib/ip.sh`: `detect_out_iface()` now excludes `awg*` (AmneziaWG) from ISP auto-detection.
  Previously, if awg0 was the default route, it would be incorrectly returned as ISP interface.
- `scripts/bug-report.sh`: DNS `+nocookie` fix — Keenetic ndnproxy doesn't support
  EDNS COOKIE, caused empty "System resolver" output on all routers.

### Added
- `scripts/bug-report.sh`: routing effectiveness diagnostic — detects when geo-split
  is ineffective (routes to same interface as default + no Keenetic tunnel policy).
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
  Mediterranean, Greater China, East Asia+ASEAN, CELAC, US/EU-sanctioned, internet_restricted
- `lib/geo.sh`: new "🚫 Sanctions & restrictions" section (us_sanctioned,
  eu_sanctioned, swift_cut, internet_restricted)

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
  - New section: tunnel interfaces list (nwg/awg/ovpn/tun/tap)
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
