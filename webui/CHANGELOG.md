# Changelog

All notable changes to `webui` are documented here.

Format: [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/)
Versioning: [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html)

## [Unreleased]

## [0.16.5] - 2026-06-03

### Fixed
- Status flicker eliminated. Root cause: race condition where in-flight successful
  response arrived after newer error, overwriting Error badge with Running.
  Fix: `_inflightControllers` aborts previous request on new poll start.
  Ticker CSS-class guard (`status--success`/`status--caution`) prevents uptime
  counter from overwriting error/stopped badge. inject.js: always-show-ERROR on
  catch (its ticker already had guard). Removed LOADING_DELAY and complex state machine.

## [0.16.0] - 2026-06-03

### Added
- Summary tab: cards display in responsive 2-column grid layout (auto 1-column on narrow screens).
- Dashboard-style detail items: label above value, no horizontal dividers, auto-fill multi-column grid.
- Long values with spaces+colons (ports, addresses) auto-wrap into multi-line.
- WebUI "Save & Restart": modal shows "Restarting..." and polls until server returns.

### Fixed
- WebUI config save now properly restarts nginx (was silently failing due to
  inherited listen socket FD from io.popen + background `&` not working in nginx-lua).
  Fix: `ngx.timer.at()` deferred restart + `exec 3>&- ... 15>&-` FD cleanup.

## [0.15.1] - 2026-06-03

### Fixed
- Status cards no longer flicker "Loading..." on periodic refresh (every 5s).
  Previous status remains visible until fresh data arrives. Loading indicator
  only appears if fetch takes longer than 3 seconds (LOADING_DELAY).
  Removed CSS `.status--loading` animation-delay workaround from layout.css.

## [0.15.0] - 2026-06-03

### Added
- Config editor for **Geo-Split**: ROUTE_OUT, ROUTE_GW, ROUTE_IN (interfaces),
  SUBNET_URL, SUBNET_LOADER (select dropdown), SUBNET_AGGREGATE (toggle 1/0),
  DOMAINS_UPDATE_INTERVAL, DNS_FULL_RESOLVER_PORT, MAX_CACHE_AGE, DOWNLOAD_INTERFACES.
- Config editor for **SmartDNS Config**: SMARTDNS_PORT.
- Config editor for **WebUI**: LISTEN_PORT, INJECT_SIDEBAR (toggle 1/0),
  DASH_POLL_INTERVAL.
- New field type `select` (dropdown) in config editor — used for SUBNET_LOADER.
- Unified toggle on/off values: toggles now support custom truthy/falsy values
  (e.g. `1`/`0`) via `on`/`off` schema properties. Default remains `yes`/`no`.
- Generic port validation in API: any config key ending with `_PORT` is validated
  as 1-65535 automatically. DASH_POLL_INTERVAL validated as ≥ 1000ms.
- CSS: `select.ew-modal__input` styling for dark-theme select dropdowns.

## [0.14.1] - 2026-06-03

### Fixed
- Interface labels now work for DOWN interfaces (VPN/WireGuard/OpenVPN that are
  not connected). Replaced IP-address matching with deterministic NDM `id`-based
  mapping (`Bridge<N>`→`br<N>`, `Wireguard<N>`→`nwg<N>`, `UsbLte<N>`→`lte_br<N>`,
  `OpenVPN<N>`→`ovpn_br<N>`). IP-matching kept as fallback for 3rd-party types.

### Changed
- Config editor: interface status dot moved before label text (was after).

## [0.14.0] - 2026-06-02

### Added
- Config editor modal (smartdns-redirect): stock Keenetic-style dialog with
  schema-driven form, Save & Restart, Cancel, Reset All buttons.
  Fields: Upstream Port (number), Interfaces (multi-checkbox pills),
  IPv6 Redirect (toggle), Watchdog Service (text), Preserve Filter Profiles (toggle).
- Reset-to-default buttons per field (always visible, dimmed when == default).
  Reset All button in modal footer restores all fields to defaults.
- Interface labels from NDM — generic IP-address matching between Linux ifaces
  and `ndmc -c "show interface"` descriptions. Shows human names
  (e.g. "Home network", "Beeline 4G", "FirstVDS Holland") with fallback.
- API: `GET /api/smartdns-redirect/config` — returns both config and defaults
  (enables diff-save and reset-to-default on frontend).
- API: `POST /api/smartdns-redirect/config` — saves only non-default values
  to config.conf (empty payload → removes config.conf). Auth-guarded, validates port.
- API: `GET /api/system/interfaces` — lists interfaces with IFF_UP flag state
  (accurate for VPN/WireGuard) and ndmc human labels.
- Edit button (pencil icon, square 32×32) on cards with config schema support.
  Hidden in Summary mode via CSS class.

### Changed
- "All Services" tab renamed to "Summary".
- Removed per-card refresh button; replaced with Edit button (config editor).
- Interface checkboxes: custom styled (rounded square, blue fill + checkmark),
  pill-shape items with transparent background.
- Toggle fields: horizontal row layout (switch left, label clickable via `for`).
- Modal visual: matches card style (8px radius, subtle shadow, light borders).

## [0.13.1] - 2026-06-02

### Added
- System info: CPU load as percentage with progress bar (load1/cores normalized).
  API returns core count from `/proc/cpuinfo`.
- System info: inline SVG icons (12px, gray) for each metric — host, uptime, CPU,
  RAM, disk. Icons + text labels combined.
- System info auto-refreshes every 5s (included in `refreshAll()` cycle).
- Multi-column detail grid: `grid-template-columns: repeat(auto-fill, minmax(280px, 1fr))`
  — details fill 2-3 columns on wide screens, 1 on mobile.

### Changed
- Page layout: removed `max-width:1200px`, content now fills full viewport width
  with comfortable `padding: 24px 32px`.

## [0.13.0] - 2026-06-02

### Added
- System info bar in page header: hostname, uptime, RAM% with bar, /opt disk%
  with bar. Color-coded: normal (blue), >75% (yellow), >90% (red).
- Loading skeleton shimmer animation instead of "Loading..." text.
- Mobile-friendly tabs: horizontal scroll with hidden scrollbar on small screens.
- Rate limiting for POST API: 1 req/sec burst 3 per IP (nginx limit_req,
  map-based — only POST requests are rate-limited, GET unaffected).
- CORS headers: Access-Control-Allow-Origin restricted to same scheme+host.

## [0.12.0] - 2026-06-02

### Added
- Custom dashboard: toggle switches (start/stop) in each service card header.
  Same behavior as stock dashboard inject — POST /api/{service}/start|stop
  with fast-polling until state settles.
- Custom dashboard: hash-routing for tabs — `#geo-split`, `#smartdns`,
  `#smartdns-redirect`, `#webui` deep-links. Updates URL on tab switch.
- API auth guard: POST requests to /api/* now require valid session
  (via access_by_lua subrequest to /auth → stock httpd). GET status
  endpoints remain open (read-only monitoring).
- Stock-style scrollbar: thin 6px, dark track/thumb with CSS variables,
  rounded corners, hover highlight. Firefox + WebKit.

### Fixed
- Page scroll: stock Keenetic CSS sets `overflow:hidden` on html/body
  (Angular modal management). Added `overflow-y:auto!important` override
  in layout.css — custom page at /custom/ now scrolls properly.

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
