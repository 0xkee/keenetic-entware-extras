# Changelog

All notable changes to `geo-split` are documented here.

Format: [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/)
Versioning: [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html)

## [0.17.5] - 2026-07-28

### Changed
- Scripts: simplify `_CONFIG_DIR` assignment — replace `$(cd ... && pwd)` subshell
  with `${SCRIPT_DIR%/*}/config` parameter expansion (6 files)

## [0.17.4] - 2026-07-12

### Added
- `status.sh`: route-out type detection — `Active out` now shows `isp` or `tunnel`
  suffix (e.g. `nwg0 (tunnel, tables 1000,1001)`). JSON: `route_out_type` field.

## [0.17.3] - 2026-07-11

### Changed
- `route-check.sh`: removed `lo`-specific filtering from `devs_seen` — loopback
  device now passes through all stages like any other dev (consistent with routes
  and coverage data). Filtering for display is handled by the frontend.

## [0.17.2] - 2026-07-11

### Refactored
- `route-check.sh`: extracted `_cidr_overlap_routes()` → `cidr_overlap_routes()` in `lib/ip.sh`
- `route-check.sh`: simplified CIDR coverage analysis — removed subshell temp-file hack,
  variables now persist directly via `while read < file`
- `route-check.sh`: added `_csv_to_json_arr()` helper, deduplicating two identical
  while-loops for CSV→JSON array conversion
- `route-check.sh`: JSON output restructured — optional fields built compactly,
  mega-printf split into 4 readable statements (−59 LOC total)

## [0.17.1] - 2026-07-11

### Fixed
- `wan-paths.sh`: geo-split ROUTE_OUT tunnel detection — reports `type: "tunnel"`
  instead of `"isp"` when ROUTE_OUT points to a VPN/tunnel interface

## [0.17.0] - 2026-07-07

### Added
- **CIDR support in route-check**: `route-check.sh` accepts CIDR notation (e.g. `5.0.0.0/8`)
  in addition to domains and IPs. Hybrid analysis: samples 1-3 IPs for kernel route verdict
  + coverage analysis from geo-split routing tables (overlap detection). JSON output includes
  `input_type`, `coverage` (total_ips, overlaps, geo_split_pct) fields.
- `lib/ip.sh`: new functions `is_cidr()`, `cidr_sample_ips()`, `cidr_total_ips()`

## [0.16.1] - 2026-07-06

### Changed
- **Support .gz zone files**: `update-subnets.sh` reads `.zone.gz` (gzip-compressed)
  zone files from geo-split-data with transparent `gzip -dc` decompression in pipe.
  Falls back to plain `.zone` for backward compatibility with geo-split-data <0.6.0.
- Runtime-downloaded zones saved as `.zone.gz` (default gzip level, low CPU on router)

## [0.16.0] - 2026-06-30

### Added
- `route-check.sh --from <MAC>`: check route as specific client. Resolves MAC → fwmark
  via iptables mangle HOTSPOT chain internally. Non-VPN clients correctly show default
  route (no longer auto-detect stray VPN fwmark). Resolves client name via ndmc hotspot.
- JSON output: `from_mac`, `from_name` fields when `--from` is used

### Fixed
- **Client selection bug**: non-VPN clients no longer inherit first VPN tunnel fwmark
  from auto-detect. When `--from` specifies a client without VPN policy, FWMARK stays
  empty → route lookup uses main table (correct behavior)

### Changed
- Default verdict CLI symbol: `→` → `⇒` (visually heavier, distinct from tunnel `=`)
- FWMARK env-var no longer required for client checks; `--from` replaces the
  `FWMARK=0x... route-check.sh host iif` pattern

## [0.15.0] - 2026-06-29

### Added
- `route-check.sh`: diagnostic tool — determines where traffic to a host/IP routes
- `wan-paths.sh`: list all WAN egress paths as JSON for WebUI diagram
- CDN mixed verdict: detects when domain IPs route through different interfaces
- Per-IP verdict tracking (geo-split/tunnel/default for each resolved IP)
- JSON output: `verdict_details[]`, `verdict_devs[]`, per-route `verdict` field
- CLI: "⚠ mixed (dev1,dev2)" verdict display with per-IP annotations

## [0.14.0] - 2026-06-18

### Fixed
- **NDM hook: tables not refilled on interface switch** — when uplink interface
  went down, kernel removed routes from custom tables before the hook ran. The old
  hook checked `ip route show table X | grep "dev iface"` which always returned
  empty (routes already gone) → hook exited without action → tables stayed empty
  until next 15-min cron. New reconciliation pattern checks table health on EVERY
  `ifstatechanged` event and refills if tables are empty or point to wrong interface.
- NDM hook: failover to backup ISP (already-UP interface) now triggers refill
  immediately instead of waiting for cron.

### Changed
- `ndm-hook.sh`: complete rewrite — reconciliation pattern replaces reactive
  UP/DOWN case handler. Single `tables_ok()` check covers all scenarios.
- `lib/ip.sh`: `fill_routes_batch()` stamp files now store interface name
  (was empty `touch`). Enables fast dev-mismatch detection in hook without
  `ip route` fork. Backward-compatible (status.sh reads only mtime).

## [0.13.2] - 2026-06-15

### Changed
- `scripts/status.sh`: refactored text output to use declarative accumulator API
  (`status_line`, `status_section`, `status_emit_text`). Added `text_output()`
  function parallel to `json_output()`. No visual output change.

## [0.13.1] - 2026-06-15

### Changed
- `scripts/status.sh`: refactored `json_output()` to use declarative
  `status_detail`/`status_check_result`/`status_emit_json` API from lib/status.sh.
  No change to JSON output format.

## [0.13.0] - 2026-06-07

### Added
- Multi-zone GeoIP support: `GEO_ZONE` config (country code or union name)
- All 240 country zones supported via pre-packaged geo-split-data files
- 40+ geopolitical unions (eas, cis, brics, eu, nato, asean, gcc, etc.)
- Shared zone library `lib/geo.sh` with `resolve_geo_zone()` function
- `active_zones` field in status JSON output (resolved country list)
- Backward-compatible `SUBNET_URL` override for custom URL configs

### Changed
- `update-subnets.sh`: multi-zone merge (cat all .zone files → aggregate → table)
- `defaults.conf`: `GEO_ZONE="eas"` replaces hardcoded `SUBNET_URL` for RU
- `status.sh`: shows resolved zone list ("eas → [ru by kz am kg]")
- Summary key `active_zones` shown on dashboard

## [0.12.5] - 2026-06-02

### Fixed
- WebUI "Unknown format": BusyBox sed SIGPIPE write error in `check_mode()` when
  extracting gateway from 8K+ route table via `sed | head -1` pipeline; stderr
  leaked into JSON output through api-router's `2>&1` redirect. Replaced with
  single-process awk that exits on first match (no pipe, no SIGPIPE).

## [0.12.4] - 2026-06-02

### Fixed
- Package: `scripts/bug-report.sh` was missing from .ipk build

## [0.12.3] - 2026-06-01

### Improved
- Performance: `check_mode()` in status.sh now reads only 5 routes per table
  instead of all ~11K to detect active interface (head -5 optimization)
- Performance: `check_routes()` uses `/proc/net/fib_triestat` to count routes
  instantly instead of dumping 8K+ lines through `ip route | wc -l`

### Added
- `table_route_count()` helper in lib/ip.sh — zero-cost route counting via
  kernel FIB trie stats with fallback to `wc -l`

## [0.12.2] - 2026-06-01

### Fixed
- Domain cache freshness drift: `touch -d "@$t_start"` anchors mtime to operation
  start, not end. Prevents +cron_interval delay when resolve takes >0s.

### Added
- Dependency: `coreutils-touch` (GNU touch with `-d` support for BusyBox routers)

## [0.12.1] - 2026-06-01

### Changed
- `status.sh`: status word (`✓ Alive` / `⚠ Disabled` / `✗ Fail`) printed on title line
  for machine-parseable extraction by `kee-status`
- `status.sh` JSON: added `gateway` field (`via <IP>` or `scope link`);
  reorganized grid — `ndm_hook` moved to row 4 (was row 2)

## [0.12.0] - 2026-06-01

### Changed
- Init script moved to `init.d/S99geo-split` (symlink in `/opt/etc/init.d/`);
  enables graceful user disable by removing the symlink
- postinst/prerm manage init.d symlink lifecycle
- NDM hook (`ndm-hook.sh`) respects disabled state via `is_service_enabled`
- Cron refresh calls real script path (works even if symlink restored later)

### Added
- `status.sh`: `"enabled"` field in JSON output; text mode shows "⚠ Disabled"
  warning when service symlink is absent

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
