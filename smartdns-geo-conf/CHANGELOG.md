# Changelog

All notable changes to `smartdns-geo-conf` are documented here.

Format: [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/)
Versioning: [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html)

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
