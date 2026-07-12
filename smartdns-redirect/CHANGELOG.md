# Changelog

All notable changes to `smartdns-redirect` are documented here.

Format: [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/)
Versioning: [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html)

## [0.3.5] - 2026-07-12

### Fixed
- DNS redirect on non-br0 interfaces (nwg1, br1): `REDIRECT` → `DNAT` to br0 IP

## [0.3.4] - 2026-06-15

### Changed
- `scripts/status.sh`: refactored text output to use declarative accumulator API
  (`status_line`, `status_section`, `status_emit_text`). Added `text_output()`
  function parallel to `json_output()`. No visual output change.

## [0.3.3] - 2026-06-15

### Changed
- `scripts/status.sh`: refactored `json_output()` to use declarative
  `status_detail`/`status_check_result`/`status_emit_json` API from lib/status.sh.
  No change to JSON output format.

## [0.3.2] - 2026-06-13

### Added
- User manual (`docs/user-manual.ru.md`) included in .ipk package
- Updated description: compatibility with `smartdns-geo-conf` (renamed from `smartdns-conf-ru-split`)

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
