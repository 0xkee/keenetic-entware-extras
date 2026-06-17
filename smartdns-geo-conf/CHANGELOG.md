# Changelog

All notable changes to `smartdns-geo-conf` are documented here.

Format: [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/)
Versioning: [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html)

## [0.10.5] — 2026-06-17

### Fixed
- **DNS probe timeout**: increased from 2s to 3s (`+time=3`) in both
  `collect_dns_tests_json()` and `collect_dns_server_checks_json()`. Reduces
  false-positive ✗ indicators when upstream DNS (DoT/DoH via VPN) is momentarily
  slow. Early-exit logic (skip after 2 fails) limits worst-case impact.

## [0.10.4] — 2026-06-16

### Added
- **Custom DNS providers** (`dns-providers-custom.conf`) — user-defined DNS servers
  preserved across package upgrades. Supports UDP, DoT, DoH protocols. Template with
  examples created on first install by postinst. Custom providers appear in WebUI
  dropdown alongside built-in catalog.

## [0.10.3] — 2026-06-15

### Fixed
- **CPU-safe DNS checks for degraded networks**: reduced dig timeout from 3s to
  2s for local SmartDNS queries, added `+tries=1` everywhere. Added early-exit
  logic: if 2+ DNS tests fail (timeout), remaining tests are skipped with
  "SKIPPED" result instead of blocking CPU for 3s×N. Prevents cascade CPU
  overload on routers with blocked/slow uplinks (e.g., RKN blocking).
- `collect_dns_server_checks_json()`: same early-exit for upstream reachability
  checks — if 2+ upstreams timeout, skip remaining (network is clearly down).

## [0.10.2] — 2026-06-15

### Changed
- `scripts/status.sh`: refactored text output to use declarative accumulator API
  (`status_line`, `status_section`, `status_emit_text`). Added `text_output()`
  function parallel to `json_output()`. No visual output change.

## [0.10.1] — 2026-06-15

### Changed
- `scripts/status.sh`: refactored `json_output()` to use declarative
  `status_detail`/`status_check_result`/`status_emit_json` API from lib/status.sh.
  No change to JSON output format.

## [0.10.0] — 2026-06-15

### Changed
- `default` DNS provider renamed → `system`. More accurate: resolves from
  Keenetic system DNS config (`/tmp/ndnproxymain.conf`), not necessarily ISP-assigned.
  Update `config.conf` if you used `OTHER_DNS_PROVIDER="default"` or `ZONE_DNS_PROVIDER="default"`.
- `dns-providers.conf`: added `*_LABEL` variables for each provider (used by WebUI dynamic list)

## [0.9.0] — 2026-06-15

### Added
- **`system` (Keenetic DNS) provider** — provider option for both `OTHER_DNS_PROVIDER` and
  `ZONE_DNS_PROVIDER`. Uses plain UDP to system DNS servers (read dynamically from
  `/tmp/ndnproxymain.conf` at config generation time). Lowest latency, no encryption overhead.
- `_get_isp_dns_ips()` helper in `generate-conf.sh` — parses ISP nameservers from
  `/tmp/ndnproxymain.conf` (filters out SmartDNS :6053 and loopback)
- New protocol type `udp` in provider catalog (`dns-providers.conf`)

## [0.8.0] — 2026-06-09

### Changed
- **Dynamic DNS zone generation** — replaced 235 static zone files (`config/zones/*.conf`)
  with runtime generation from `dns-providers.conf` + `zone-routing-rules.conf`
- **Configurable DNS providers** — new `OTHER_DNS_PROVIDER` and `ZONE_DNS_PROVIDER`
  settings in config. Supports: google, cloudflare, quad9, mullvad, controld, adguard (international);
  yandex, adguard, alidns, tencent (regional/zone)
- `generate-conf.sh` fully rewritten — dynamic provider lookup, zone routing from rules file
- `status.sh` — shows Zone DNS / Other DNS providers in text and JSON output

### Added
- `config/dns-providers.conf` — catalog of 15 DNS providers with IPs, hostnames, protocols
- `config/zone-routing-rules.conf` — IDN TLDs (30 countries) + extra CDN domains (80+ countries)
- `OTHER_DNS_PROVIDER` / `ZONE_DNS_PROVIDER` config options (space-separated provider names)
- **DNS Server Checks** — `status.sh --json` now includes `dns_server_checks` array:
  direct reachability test for each configured upstream provider (dig @IP, TTL=15s cache)

### Removed
- `config/zones/` directory (235 static zone files — replaced by dynamic generation)
- `scripts/generate-zone-presets.sh` (dev-time zone generator, no longer needed)
- `scripts/patch-zone-labels.py` (emoji label patcher, no longer needed)

## [0.7.1] - 2026-06-07

### Changed
- Migrated unions data from `config/unions.conf` to shared `lib/geo.sh`
- `generate-conf.sh`: uses `resolve_geo_zone()` from lib/geo.sh
- `status.sh`: uses `resolve_geo_zone()` from lib/geo.sh
- Removed `config/unions.conf` (all data now in shared library)

## [0.7.0] - 2026-06-07

### Added
- 234 zone preset configs in `config/zones/` (was 5 EAEU only)
- Full ISO 3166-1 alpha-2 coverage: every country in any union now activates
- China zone: AliDNS + Tencent DNSPod (mainland-optimized)
- CIS zones: Yandex + AdGuard (regional CDN presence)
- Default zones: Cloudflare + Google DoT (global anycast)
- `scripts/generate-zone-presets.sh` — regenerate all zone presets

### Changed
- Unions now fully operational — no more "no zone preset" warnings

## [0.6.0] - 2026-06-07

### Changed
- **Package renamed**: `smartdns-conf-ru-split` → `smartdns-geo-conf`
- Directory: `smartdns-conf-ru-split/` → `smartdns-geo-conf/`
- Git tag prefix: `smartdns-conf-v` → `smartdns-geo-conf-v`
- LOG_TAG updated to `smartdns-geo-conf`

### Migration
- Users must `opkg remove smartdns-conf-ru-split` then `opkg install smartdns-geo-conf`
- Config file path changed: `/opt/keenetic-entware-extras/smartdns-geo-conf/config/config.conf`

## [0.5.1] - 2026-06-07

### Changed
- generate-conf.sh: skip "default" pseudo-value in interface lists (WebUI sends "default" for default route)

## [0.5.0] - 2026-06-06

### Added
- **Multi-zone DNS routing** — configurable `DNS_ZONE` in `config/config.conf`:
  single country (`ru`, `by`, `kz`, `am`, `kg`) or union (`eas`, `cis`, `brics`, etc.)
- **VPN interface binding** for international DNS (`OTHER_DNS_INTERFACES`) and
  zone DNS (`ZONE_DNS_INTERFACE`) — bypass MITM
- `config/config.conf` — user configuration file (preserved on opkg upgrade)
- `config/unions.conf` — 35+ geo-political unions reference (EAEU, CIS, BRICS,
  NATO, EU, Schengen, ASEAN, GCC, etc.)
- `config/zones/{ru,by,kz,am,kg}.conf` — static per-country DNS server presets
  with nameserver routing rules and CDN-optimized services
- `scripts/generate-conf.sh` — generates `dns-servers-other.conf` and
  `dns-zones-active.conf` from config.conf settings
- `init.d/S37smartdns-conf` — init script: generates configs at start,
  supports enable/disable/status commands

### Changed
- `smartdns.conf` — hardcoded DNS servers and zones replaced with
  `conf-file` includes (generated dynamically)
- `smartdns-default.conf` — uses generated `dns-servers-other.conf`
- `toggle.sh` — deprecated; thin wrapper over S37smartdns-conf
- `postinst` — installs S37 init script, calls generate-conf.sh

### Packaging
- Version bump: 0.4.4 → 0.5.0
- Added `conffiles`: config.conf preserved on upgrade
- Updated `prerm`/`postrm`: cleanup S37 + generated config snippets

## [0.4.4] - 2026-06-01

### Changed
- `status.sh`: status word (`✓ Alive` / `✗ Fail`) printed on title line

### Fixed
- `smartdns.conf` — misleading comment about leading dot in nameserver rules;
  clarified that `/.ru/ru` and `/ru/ru` are equivalent (suffix match)

## [0.4.3] - 2026-05-16

### Added
- TCP listeners (`bind-tcp`) on ports 6053 and 6153 — fixes TCP DNS timeout
  when `smartdns-redirect` forwards TCP traffic to SmartDNS

## [0.4.2] - 2026-05-12

### Fixed
- Toggle script state persistence across reboots

### Changed
- Default DNS config uses DoH for international resolvers
