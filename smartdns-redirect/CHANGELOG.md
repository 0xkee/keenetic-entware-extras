# Changelog

All notable changes to `smartdns-redirect` are documented here.

Format: [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/)
Versioning: [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html)

## [Unreleased]

## [0.3.1] - 2026-06-01

### Changed
- `status.sh`: status word (`✓ Alive` / `⚠ Disabled` / `✗ Fail`) printed on
  title line; removed separate "Service: ⚠ Disabled" line

## [0.3.0] - 2026-06-01

### Changed
- Init script moved to `init.d/S39smartdns-redirect` (symlink in `/opt/etc/init.d/`);
  enables graceful user disable by removing the symlink
- postinst/prerm manage init.d symlink lifecycle
- Netfilter hook respects disabled state via `is_service_enabled`
- Watchdog respects disabled state (exits immediately if service disabled)

### Added
- `status.sh`: `"enabled"` field in JSON output; text mode shows "⚠ Disabled"
  warning when service symlink is absent

## [0.2.3] - 2026-05-15

### Changed
- Move pidfile from `/tmp` to `/opt/tmp`

## [0.2.2] - 2026-05-12

### Fixed
- Watchdog false-positive restart detection
- Netfilter hook compatibility with newer iptables

### Added
- Configurable DNS target port and address
