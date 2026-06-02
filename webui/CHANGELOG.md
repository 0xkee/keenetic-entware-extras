# Changelog

All notable changes to `webui` are documented here.

Format: [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/)
Versioning: [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html)

## [Unreleased]

## [0.11.2] - 2026-06-02

### Improved
- Error diagnostics: show actual script error message when status API fails
  (previously showed generic "Unknown format"). Applies to both custom dashboard
  (app.js) and stock dashboard card (inject.js).
- api-router.lua: fallback error response now includes `"running":false` for
  proper status display in both UIs.

## [0.11.1] - 2026-06-01

### Changed
- `status.sh`: status word (`✓ Alive` / `⚠ Disabled` / `✗ Fail`) printed on
  title line for machine-parseable extraction by `kee-status`

## [0.11.0] - 2026-06-01

### Added
- `status.sh`: upstream (stock httpd) reachability check — `"upstream"` field
  in details (address string) + `checks.upstream` ("ok"|"warn") in JSON output;
  text mode shows "Upstream:" section. Dashboard card renders automatically.

## [0.10.1] - 2026-06-01

### Fixed
- Stock httpd proxy: replaced hardcoded `upstream keenetic_ui { server 127.0.0.1:80 }`
  with dynamic `$stock_httpd` variable (LAN IP from `listen.conf`). Fixes 403 error
  when "Web access from the Internet" is disabled — stock httpd rejects requests
  from loopback in this configuration.

### Added
- Init command `update-listen`: force re-detect LAN IP and restart
  (`S80nginx-webui update-listen`)

## [0.10.0] - 2026-06-01

### Changed
- Init script moved to `init.d/S80nginx-webui` (symlink in `/opt/etc/init.d/`);
  enables graceful user disable by removing the symlink
- postinst creates symlink instead of copying init script
- prerm stops service and removes symlink
- API routes: start/stop actions now call `enable`/`disable` commands
  (persistent state that survives reboot; hooks respect it)

### Added
- `status.sh`: `"enabled"` field in JSON output; text mode shows "⚠ Disabled"
  warning when service symlink is absent

## [0.9.0] - 2026-05-26

### Changed
- Simplified hash-map.conf: removed per-build JS hash entries, now uses only
  `DEFAULT:<version>` entries with cascade lookup (exact → major.minor)
- Removed WARN log on successful DEFAULT fallback (was noise on every new fw build)
- patch-stock-ui.sh: firmware version is now the primary patch selection mechanism

## [0.8.9] - 2026-05-26

### Added
- v2.sh patch set for KeeneticOS 5.1 (Angular minifier renamed enum Po→Vo)
- Version-based fallback in hash-map.conf (DEFAULT:5.0 → v1, DEFAULT:5.1 → v2)
- Firmware version detection via ndmc in patch-stock-ui.sh fallback logic

## [0.8.8] - 2026-05-15

### Changed
- Move pidfile and logs from `/tmp` to `/opt/tmp`

## [0.8.7] - 2026-05-12

### Added
- Logrotate config for nginx-webui logs
- Cards position dialog for dashboard customization

### Fixed
- Inject.js sidebar integration with stock Keenetic WebUI
- Nginx proxy headers for API router

### Changed
- CSS injection uses stock Keenetic variables for theme consistency
