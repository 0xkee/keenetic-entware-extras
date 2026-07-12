# Changelog

All notable changes to `webui` are documented here.

Format: [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/)
Versioning: [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html)

## [0.32.6] — 2026-07-12

### Added
- `status.sh`: firmware patch compatibility check — detects KeeneticOS version
  via ndmc, looks up patch set in `hash-map.conf`. CLI: `Firmware: 5.1.0 → patch v3 ✓`.
  JSON: `firmware`, `patch_set` details + `patch` check (ok/warn).

## [0.32.5] — 2026-07-11

### Fixed
- **Route Devices: missing devices from CIDR coverage overlaps** — for CIDR mixed
  verdict (e.g. 2.0.0.0/8 → 7%), Route Devices section only showed devices from
  sampled IPs, missing devices found via coverage overlap analysis. Now includes
  both sources, consistent with diagram, summary line, and batch table.

### Refactored
- `route-check.js`: extracted `_collectAllDevs(data)` helper that collects unique
  device names from `verdict_devs` + CIDR `coverage.overlaps`. Replaces 3 inline
  copies of the same logic (summary line, batch table, route devices section).
- Removed all `!== 'lo'` device filtering from `route-check.js` (4 places) and
  `route-diagram.js` (3 places). Loopback device now passes through all display
  stages — no special-case treatment.

## [0.32.4] — 2026-07-11

### Refactored
- `route-check.js`: batch table switched to append-only rendering — new rows are
  appended to existing `<tbody>` instead of full DOM rebuild on each result.
  Removed 15-line state preservation hack (`openDomains`/`openDetails` scanning).
- `route-check.js`: extracted `_createBatchTableEl()` and `_buildBatchRowPair()`
  from monolithic `_renderBatchTable()` for better separation of concerns.

## [0.32.3] — 2026-07-11

### Added
- `EW.isTunnelIface(dev)` helper in shared.js — client-side tunnel prefix detection
  (mirrors `is_tunnel_iface` from lib/ip.sh)

### Changed
- Route diagram: simplified to two-icon model (globe for ISP + shield for tunnel),
  removed Policy/signpost path type entirely. Path coloring: green for geo-split,
  blue for all other active paths. Removed gateway "via" sublabel under path nodes.
- Route diagram: CIDR mixed verdict now activates devices from coverage overlaps
  and default route in diagram paths
- Route check details: "Default Route" section → "Route Devices" — shows unique
  devices grouped by verdict with table names (more informative for multi-path)
- Route check summary: cleaned up — removed gateway "via" text, shows "tunnel"
  prefix instead of "system", "policy" label for default verdict in legend
- Route check: CIDR mixed devs collected from both sampled IPs and coverage
  overlaps (summary, batch table, and legend)

### Fixed
- Dashboard card header "ENTWARE EXTRAS" is now a clickable link to Summary page
  with pointer cursor (hand icon) on hover
- Interface blacklist: added `rai` (5 GHz), `rax` (6 GHz), `xfrm`/`xfrms` (IPsec)
  exclusions in `api-router.lua` → `system_interfaces()`

## [0.32.2] — 2026-07-07

### Added
- Route Check: CIDR notation support in input (e.g. `5.0.0.0/8`). API `validate_cidr()`
  allows `/` in host parameter for CIDR format. Updated placeholder and examples.

## [0.32.1] — 2026-07-06

### Fixed
- WISP interfaces (wwan) now display NDM description instead of raw "wwan0"
- Inactive WISP interfaces (link: down) hidden from dropdown — only active shown
- Compound NDM id support (WifiMasterN/WifiStationM) via `type:` field parsing
- Consolidated label-required filters for eth*/usb*/wwan* in `system_interfaces()`

## [0.32.0] — 2026-07-05

### Added
- **Patch set v3** for KeeneticOS 5.1.0 — Angular moved to signal-based architecture:
  enum renamed `Vo` → `Mo`, `set order()` setter replaced by writable signal `order=V([])`,
  `templateMap` is now a computed signal (`templateMap()`). New `#2+3` combined patch hooks
  `getTemplate()` for `__ewLastOrder` side-effect (was in setter). Default card layout split
  into desktop/mobile sub-arrays (both patched with `#QS-desktop` / `#QS-mobile`).
  9/9 patches verified against `main-8787931.js`.
- `hash-map.conf`: `DEFAULT:5.1.0 v3` (exact match); `DEFAULT:5.1 v2` retained for betas
- Stock backup: `stock-backup-5.1.0-mipsel/`

## [0.31.2] — 2026-07-05

### Fixed
- Config modal: `ROUTE_OUT` (Outgoing Interface) and `ZONE_DNS_INTERFACE` (Zone VPN Interface) now render as single-select (radio) instead of multi-select (checkbox) — `multi: false` in schema
- Unified display text "Default" → "Default route" across all iface_select triggers (initial render, reset, checkbox change handler)
- Radio change handler: use last `<span>` for trigger text (dot indicator spans no longer cause `[object Object]`)
- `loadIfaceMap()`: fixed fallback chain producing `[object Object]` for interfaces without label
- API `/api/system/interfaces`: exclude unlabeled `usb*` interfaces (USB tethering) from list

### Changed
- `renderDropdown()` preItems now support both single (radio) and multi (checkbox) modes
- `renderDropdown()` single-select options now show up/down dot indicators (same as multi)
- `saveConfig()` reads `radio:checked` for single iface_select, `selectionOrder` for multi

## [0.31.1] — 2026-07-05

### Changed
- **R-1**: Details rendering dedup — extracted `EW.renderDetailValue()`, `EW.renderUpdateBtn()`, `EW.detailValueStyle()` to shared.js; unified rendering in inject.js and app.js
- **R-2**: Toggle polling dedup — extracted `EW.createTogglePoller()` factory to shared.js; unified in inject.js and app.js
- **R-3**: Removed `_ensureIfaceMap()` from route-check.js, uses `EW.loadIfaceMap()`
- **R-4**: Exported `EW.ifaceLabelShort()`; removed `_ifaceLabel()` from route-diagram.js and route-check.js
- **R-5**: Extracted `EW.escapeHtml()` to shared.js; removed duplicates from app.js (`escapeHtml`) and route-check.js (`_esc`)
- **R-6**: Added `EW.getService(id)` helper; replaced lookup loops in app.js and inject.js
- **R-7**: Extracted Config Editor (~790 lines) from app.js to config-editor.js; app.js reduced from 1898 to ~1034 lines
- **R-8**: Unified Route Check and DNS Check modals via `_openCheckModal()` factory in route-check.js
- **R-9**: Extracted `EW.hasFailField()` to shared.js; removed from inject.js and inline from app.js

## [0.31.0] — 2026-07-04

### Added
- **Interface humanization system** (`shared.js`) — Linux device names (e.g. `br0`,
  `nwg0`) are now displayed as human-readable labels fetched from
  `/api/system/interfaces` (e.g. "Home network (br0)"). New module:
  `IFACE_DETAIL_KEYS` mapping, `loadIfaceMap()` eager loader,
  `ifaceLabelFull(dev)` / `_ifaceLabelShort(dev)` formatters,
  type-specific humanizers for space-lists, single-suffix routes,
  prefixed-lines, and gateway values.
- **Dual-render summary/detail values** (`app.js` + `layout.css`) — detail items
  with `shortValue` now render both `.ew-val-short` (condensed, no device suffix)
  and `.ew-val-full` (full, with device suffix). CSS toggle via `.ew-summary-mode`
  shows short in summary, full in detail view.
- **`cli-ui-naming.md`** — new documentation: CLI→UI naming conventions for
  interface labels, gateway values, and route display.

### Changed
- **`parseDetails()` gains `showDev` option** (`shared.js`) — when `true` (default),
  labels include `(dev)` suffix; when `false`, only human labels are shown.
  Returns `shortValue` property for summary mode rendering.
- **Stock dashboard: short interface labels** (`inject.js`) — `renderDetailsGrid()`
  passes `showDev: false` for stock Keenetic dashboard cards (no dev suffix).
- **SUMMARY_KEYS for geo-split** (`app.js`) — replaced `gateway` with `route_in`
  in summary key list for more relevant condensed view.
- **Modal form: human interface labels** (`app.js`) — interface multi-select trigger
  text and reset handler now use `EW.ifaceLabelFull()` instead of raw device names
  (3 call sites in `renderModalForm` and `handleResetField`).
- **Eager `loadIfaceMap()` call** on both custom dashboard init (`app.js`) and
  stock dashboard injection (`inject.js`).

### Fixed
- **`var priority` hoisting bug** (`app.js:setDetails`) — declaration moved before
  `shortValue` usage, fixing potential undefined reference in `setDetails()`.
- **Gateway display** (`shared.js:_humanizeGateway`) — "scope link" → "Direct",
  "none" → "—".

## [0.30.1] — 2026-07-04

### Changed
- **WebUI Cache: show actual `lua_shared_dict` size in KB** instead of boolean ✓.
  Size is injected by `api-router.lua` on every response (shell can't access
  nginx internals). Flush button (⟳) kept, tooltip renamed to "Flush UI Cache".
- **SmartDNS Cache: removed flush button** — `UPDATE_ACTIONS` now uses
  service-scoped keys (`webui:cache` instead of `cache`). `parseDetails()`
  accepts `opts.serviceId` for scoped action lookup with global fallback.
- **CPU tooltip** — hover CPU bar shows load average (load1 / cores) and
  explains the difference from stock UI real-time utilization.
  Values may differ from stock UI — noted as normal and not a cause for concern.

## [0.30.0] — 2026-07-03

### Added
- **WebUI card: Cache field with Flush button** — new `Cache` detail field
  (between Http and Pid) showing internal `lua_shared_dict` status (always ✓).
  Includes a refresh button (⟳) that flushes all status cache entries via
  `POST /api/webui/flush-cache`, forcing fresh data on next poll cycle.
- **Version badge → project page link** — version badges in custom dashboard
  cards are now clickable links to the project forum page (keenetic.ru).

### Changed
- **Renamed `GEO_UPDATE_ACTIONS` → `UPDATE_ACTIONS`** in `shared.js` — now
  supports per-action tooltip text via object values `{ url, tooltip }`.
  String values (backward-compatible) default to "Force Reload" tooltip.

## [0.29.2] — 2026-07-03

### Changed
- **Diagram CPU optimization: `steps(20)` animation** — marching-ants path
  animations now use CSS `steps(20)` instead of `linear`, reducing browser
  repaints from ~60fps to ~20fps per animated SVG element (~65% CPU reduction).
- **Diagram SVG `<defs>` + `<use>` icons** — all 11 icon types (client, router,
  cloud, DNS, query, globe, shield, signpost, zone, result, server) are now
  defined once per SVG in `<defs>` and referenced via `<use>`, cutting DOM node
  count by ~60% per diagram and reducing paint area on animation repaints.
- **DNS diagram: removed match_rule from Zone icon** — the Zone node now shows
  only the group name, not the domain-like match rule pattern. Technical details
  remain in the collapsible section.
- **Tech details: multi-value fields on separate lines** — Servers (with paired
  hostname labels), IPs, Providers, and Interface lists now render one per line
  instead of comma-separated, with thin horizontal dividers between groups and
  label names aligned to the top. Applies to both Route Check and DNS Check.
- **Default history pills now blue** — `rc-pill--default` changed from gray to
  blue, matching the card border color and batch table styling for default/policy
  verdicts in both Route Check and DNS Check.
- **Batch mode: tech details state preserved** — expanded technical details
  inside batch table rows no longer collapse when new results arrive during
  Check All. Both diagram expansion and summary/details expansion are preserved.

## [0.29.1] — 2026-07-02

### Changed
- **DNS Check card border colored by result** — zone-specific override groups get
  a green border (matched rule), plain `default` stays blue; errors stay red.
  Unifies border coloring with Route Check (`_getVerdictClass` now type-aware).
- **DNS diagram: non-matched group path stays gray** (inactive), matching Route
  Diagram's convention. Group TYPE distinguished by icon color only: zone-specific
  overrides have a blue icon (`route-icon--primary`), default is neutral gray.
- **DNS diagram: branch nodes centered** between Zone and Result icons, matching
  Route Diagram's centered WAN-path node layout.
- **DNS batch table: per-row icon and color by zone group** — `⇄` green for
  zone-specific groups, `→` blue for `default` (was always `✓` green).
- **DNS batch table: IP column shows total count** when a domain resolves to
  more than one address, e.g. `142.250.27.18 (3)`.
- **DNS Check: colored history pills** — pills now colored by zone group verdict
  (green for zone-specific overrides, gray for default), matching Route Check's
  colored pill behavior. Saved to localStorage on both single and batch results.
- **DNS summary: IP count moved to end** — `N IPs` prefix replaced with
  `ip (N)` suffix in the summary line for cleaner reading.

## [0.29.0] — 2026-07-02

### Changed
- **DNS Check diagram redesigned to match Route Check style** — always shows both
  DNS groups as permanent branches, one node per group. Requires
  `smartdns-geo-conf` ≥ 0.10.7.
- **Diagram coloring unified with Route Check** — matched branch green, non-matched
  gray; Domain/Zone/Result icons neutral gray; DNS group icon blue only for
  zone-specific overrides.
- **Diagram spacing formula unified with Route Check** — fixes branch nodes
  overlapping with 2+ DNS groups.
- **Card legend and summary line unified with Route Check's format** — summary
  shows plain `default` instead of `none (default)` for unmatched zones.
- New magnifying-glass icon (`_iconQuery`) for the "Domain" node.
- Removed duplicate "DNS: <domain>" title inside the SVG.

### Removed
- **Dead code**: `_renderVerdict()` and `_iconInterface()` removed from
  `route-diagram.js`.

## [0.28.1] — 2026-07-01

### Fixed
- **Batch table: expanded diagrams collapse on update** — When checking multiple
  domains, each new result caused full table re-render, closing any expanded
  diagram rows. Now `_renderBatchTable` preserves open/closed state across
  incremental re-renders by tracking expanded domains.
- **Route diagram: policy path not shown / not active** — `_buildPaths` early-returned
  when `all_paths` was injected from wan-paths cache, skipping policy path append.
  Now always appends policy path from `data.default_route`. For `verdict=default`,
  policy signpost is active (blue) and ISP globe is inactive (gray). Label under
  signpost icon always shows "Policy" instead of interface name.

## [0.28.0] — 2026-07-01

### Fixed
- **Interface labels: ppp0/eth0 now resolve to human names** — Expanded
  `NDM_TYPE_TO_PREFIX` with PPPoE, PPTP, L2TP, AmneziaWG types for deterministic
  id→prefix mapping. Replaced whitelist filter in `system_interfaces()` with
  blacklist (excludes only infra: lo, tunnels, radios, VLANs). `eth*` ports
  included only when NDM resolves a label (IPoE WAN with IP). Fixes: ppp0
  showing as raw "ppp0" instead of ISP name.

### Added
- **Route diagram: policy path (signpost icon)** — NDM default route (def/deg.def)
  always shown on diagram as a separate path with signpost icon (🪧). Helps
  visualize where traffic goes "normally" vs where geo-split/tunnel redirects it.
  Active when verdict=default+fwmark, inactive otherwise. Blue path animation
  (same as tunnel).
- **Verdict display: "⊙ policy"** — when verdict is "default" but client has an
  fwmark (VPN policy), legend and batch table show "policy" instead of "default"
  to clarify that NDM policy routing determined the path.

## [0.27.3] — 2026-06-30

### Fixed
- **nginx: map_hash_bucket_size 64** — fix `[emerg] could not build map_hash`
  on MIPS routers (bucket_size 32 < sizeof(elt) + key_len for 28-char URIs in
  `$diag_limit_key` map). Affected: all MIPS 1004Kc routers. aarch64  unaffected (default bucket=64).

## [0.27.2] — 2026-06-30

### Changed
- **user-manual.ru.md**: complete rewrite for v0.27 — Route Check, DNS Check,
  Config Editor, dashboard cards/tabs, API with TTLs, troubleshooting updates
- **README.md**: added diagnostic API endpoints table

## [0.27.1] — 2026-06-30

### Fixed
- **Route check: client selection works** — API passes `--from <MAC>` to route-check.sh
  (MAC→fwmark resolved inside script). Non-VPN clients no longer show tunnel verdict.
- **Route diagram: source label** — shows client name (from backend `from_name` field)
  instead of always "Home network". Shows "Router" when `from=local`.
- **Long client names** — truncated to 18 chars with ellipsis in SVG diagram

### Changed
- **api-router.lua**: removed `resolve_mac_to_mark()` — fwmark resolution moved to
  route-check.sh for CLI/API consistency
- **Default verdict icon**: `→` → `⇒` (U+21D2, double arrow — visually heavier)

## [0.27.0] — 2026-06-30

### Added
- **Route diagram: Server node** — destination server rack icon + domain/IP label at right end of topology
- **Route diagram: DNS bypass arc** — when query is IP, green rectangular arc bypasses DNS node (DNS stays dimmed with gray path through it)
- **Colored history pills** — verdict-based pill colors (green=geo-split, blue=tunnel, orange=mixed); localStorage migrated to `[{d, v}]` format with backward-compat
- **Verdict in card legend** — `github.com ⊙ tunnel` shown in card border label (icon + text)

### Changed
- **Route diagram: tunnel path blue** — dedicated `route-path--tunnel` CSS class (animated blue, matches shield icon)
- **Summary line: pipeline format** — `2 IPs → geo subnet (table 1001) → Beeline 4G` with `→` arrows, `geo`/`system` prefix, no domain duplication
- **Summary line: unified verdict icons** — `⇄` geo-split, `⊙` tunnel, `⚠` mixed, `→` default (batch table + legend)
- **Summary line: text-overflow ellipsis** — truncated with "..." instead of horizontal scrollbar
- **Batch table: "Interface" → "Via"** column header rename
- **Input row: flex proportions** — input `flex:2`, interface dropdown `flex:3` (responsive, no fixed min-width)
- **Batch table: table-layout fixed** — column widths stable, `nowrap` + `text-overflow: ellipsis` on cells
- **Diagram: .rc-result__diagram overflow hidden** — SVG stays within card bounds
- **Node label spacing** — unified gap between icons and labels across all diagram nodes

### Removed
- SVG verdict badge inside diagram (redundant with legend)
- Verdict icon prefix from summary (moved to legend)
- Domain duplication in summary (shown in legend + server node)
- DNS time from summary

## [0.26.0] — 2026-06-29

### Added
- **Route Check** diagnostic modal with SVG network topology diagram
- **DNS Check** diagnostic modal with horizontal flow diagram
- CDN mixed verdict: orange badge, all paths highlighted, per-IP routes table
- All DNS IPs shown on diagram (up to 3 + "+N more")
- **Batch mode**: Check All history items with sequential requests
- Client/interface selector with VPN policy detection (MAC → fwmark)
- Rate-limited diagnostic API endpoints in `api-router.lua`
- History pills with delete, localStorage persistence

## [0.25.5] — 2026-06-17

### Fixed
- **False-positive red indicators**: status badges no longer show red "Stopped"/"Error"
  when service is actually running but API is momentarily unreachable. New 5-state badge:
  green (running), yellow (warnings), gray (stopped/disabled), blue (stale/no data),
  red (only for genuine crash: enabled=true but process dead).
- **Stale-while-revalidate**: on fetch error, previous badge preserved for 30s before
  showing neutral "stale" indicator. Eliminates flicker from transient network issues.
- **Cold start false "Stopped"**: Lua placeholder changed from `running:false` to
  `status:"pending"` — frontend no longer shows false "Stopped" during cache warm-up.
- **Stopped vs Failed**: `enabled:true` + `running:false` = red "Failed" (crash);
  `enabled:false` = gray "Stopped"/"Disabled" (user-intended). Previously all
  `running:false` showed red.
- **Toggle flash suppression**: "Failed" badge no longer flashes during service
  restart when fast-poller is active.

### Changed
- SmartDNS disabled state: "DEFAULT MODE" (yellow) → "DISABLED" (gray) in both
  stock dashboard card and custom dashboard.
- Card accent border now reflects 5 states (was: running/error only).
- `updateCardAccent(id, state)` — simplified string-based API.

### Added
- CSS `.status--stopped` (gray) and `.status--stale` (blue) badge styles.
- CSS `.ew-chip--stale` for stock dashboard chip.
- CSS `.dashboard-card--caution` and `.dashboard-card--stale` for card accent border.
- `_lastGoodData` tracking + `STALE_MAX` (30s) in app.js.

## [0.25.4] - 2026-06-16

### Fixed
- **Tooltip CSS conflict**: `.ew-modal__help::after` properties (`bottom`, `transform`)
  leaked from generic `[data-tooltip]::after` in common.css — tooltip was stretched/misplaced.
  Added explicit resets and unified tooltip rule for both help icon and reset button.
- **Reset button tooltip**: replaced native `title` with styled `data-tooltip` (same as `?`
  icon). Right-aligned, pre-line whitespace, 150ms hover delay. Removed `opacity` from
  `.ew-modal__reset` (replaced with transparent `color`) to prevent tooltip fade-through.
- **Sidebar duplication (×5)**: added DOM-level dedupe guard in `tryInject()` — checks
  container for existing `.entware-menu-section` before appending. MutationObserver now
  removes duplicate sections if somehow created.

## [0.25.3] - 2026-06-15

### Fixed
- **Cold-start cache stampede fix** (`api-router.lua`): when nginx restarts and
  no stale data exists yet, concurrent workers no longer all execute status.sh
  simultaneously. Instead, only the first worker runs the script; others return a
  `{"status":"loading"}` placeholder. Prevents CPU cascade on MIPS routers.
- **LOCK_TTL increased** from 15s to 45s: safety margin for slow script execution
  under system load. Lock is released immediately on script completion; 45s is
  only the ceiling for crash/hang protection.

## [0.25.2] - 2026-06-15

### Changed
- `scripts/status.sh`: refactored text output to use declarative accumulator API
  (`status_line`, `status_section`, `status_emit_text`). Added `text_output()`
  function parallel to `json_output()`. No visual output change.

## [0.25.1] - 2026-06-15

### Changed
- `scripts/status.sh`: refactored `json_output()` to use declarative
  `status_detail`/`status_check_result`/`status_emit_json` API from lib/status.sh.
  No change to JSON output format.

## [0.25.0] - 2026-06-15

### Added
- **Search bar on all dropdowns**: DNS provider multi-selects (`ZONE_DNS_PROVIDER`,
  `OTHER_DNS_PROVIDER`) and plain `select` fields now have a search/filter input —
  same as zone_selector and iface_select already had.

### Changed
- `api-router.lua`: unified lua_routes dispatch — replaced 4 duplicate if-blocks with
  a `lua_routes` table + `serve_cached_lua()` helper (~50 LOC → ~30 LOC, DRY)
- SmartDNS config editor: `ZONE_DNS_PROVIDER` and `OTHER_DNS_PROVIDER` options now loaded
  dynamically from `/api/system/dns-providers` (parsed from `dns-providers.conf`).
  No longer hardcoded in app.js — adding/removing providers in config auto-reflects in UI.
- `api-router.lua`: new endpoint `GET /api/system/dns-providers` (cached 1h, parses `*_LABEL`)
- **Unified `renderDropdown()` function**: all 5 dropdown variants (select, multi_select,
  zone_selector zones, zone_selector unions, iface_select) now rendered by a single
  shared function. Removes ~100 lines of copy-paste, ensures consistent behavior.

## [0.24.1] - 2026-06-11

### Changed
- **gzip_static for stock JS/CSS**: pre-compress all .js/.css assets at startup
  (patch-stock-ui.sh: `gzip -6 -k -f`). nginx serves .gz companions directly
  via `gzip_static on` — zero per-request CPU. main-*.js: 6.0MB → 1.4MB (76%).
  Eliminates 20s+ white page on MIPS routers caused by on-the-fly compression.

## [0.24.0] - 2026-06-10

### Added
- **Universal styled tooltips** (`data-tooltip` attribute on any element): dark background,
  centered, with fade animation. Supports `data-tooltip-pos="below"` for top-edge elements.
- **RAM sysinfo tooltip**: hover shows available/total MB + conservative estimate explanation
  (previously native `title`, now styled CSS tooltip below the bar).

### Changed
- **Details grid layout fix**: custom page uses `minmax(12rem, auto)` for detail view
  (6 columns on wide screens — no overflow); summary cards override to `minmax(7rem, auto)`
  for compact 2-column layout. Matches dashboard card proportions.
- **DNS Provider display**: shows provider nickname (`yandex`, `adguard`, `google`) instead
  of full hostname. Full domain shown in styled tooltip on hover. Clickable link preserved.
- **Multi-select selection order**: dropdown preserves the order items were selected
  (add to end, remove in place). Display text and saved config reflect user's selection
  sequence, not DOM order.

## [0.23.0] - 2026-06-10

### Added
- **DNS Servers check** display: upstream provider reachability (✓/✗ + clickable hostname link,
  no IP) in both stock dashboard card (inject.js) and custom detail view (app.js).
  Data from `dns_server_checks` array in status API, cached TTL=15s.
- **Zone selector flag emojis**: country dropdown now shows 🇷🇺 🇺🇸 🇩🇪 etc. flags
  from `lib/zones.sh`. Sort key strips flag prefix — alphabetical order preserved.

### Changed
- SmartDNS config editor: `ZONE_DNS_PROVIDER` migrated from single-select presets
  to multi-select checkboxes (individual providers: Yandex, AdGuard, AliDNS, Tencent, etc.)
- SmartDNS config editor: `OTHER_DNS_PROVIDER` migrated from single-select presets
  to multi-select checkboxes (individual providers: Google, Cloudflare, Quad9, Mullvad, etc.)
- Summary cards: DNS provider values now display each provider on a new line
  (both stock inject.js and custom app.js)
- New field type `multi_select` in config editor — checkbox dropdown for
  space-separated multi-value fields (reuses `iface_select` UI patterns)

## [0.22.0] - 2026-06-09

### Added
- SmartDNS config editor: `ZONE_DNS_PROVIDER` select (7 presets: Yandex, AdGuard, AliDNS+Tencent, etc.)
- SmartDNS config editor: `OTHER_DNS_PROVIDER` select (10 presets: Google, Cloudflare, Quad9, Mullvad, etc.)
- SmartDNS summary: shows `zone_dns_provider` and `other_dns_provider` fields

### Changed
- SmartDNS config: interface labels renamed — "Zone VPN Interface", "International VPN Interfaces"
- `api-router.lua`: smartdns keys whitelist updated with new provider config keys

## [0.21.3] - 2026-06-08

### Changed
- Detail grids: replaced `text-overflow: ellipsis` with auto-column reduction.
  Uses `repeat(auto-fit, minmax(7rem, auto))` — columns expand to fit content
  and reduce count automatically when space is limited.
- Summary mode cards: `auto-fit` grid with `minmax(18rem, 1fr)`.
- DNS Tests: each line wrapped in `.ew-dns-line` with `white-space: nowrap`;
  displayed as regular grid cell (not spanning full width).

### Removed
- `white-space: nowrap` + `overflow: hidden` + `text-overflow: ellipsis` from `.ew-detail-value`.

## [0.21.2] - 2026-06-08

### Fixed
- Zone selector: union trigger text now shows country codes in parentheses on initial render (previously only after reset/re-select).
- Custom card detail values: fields no longer overflow card boundary (`min-width: 0` + `text-overflow: ellipsis`).

### Added
- DNS Tests: domain names are now clickable links (open in new tab, underline on hover).

## [0.21.1] - 2026-06-08

### Fixed
- Loading skeleton count: default changed from 6 to 9 (closer to real field counts).
- Skeleton cache off-by-one: DNS Tests item now counted in saveSkeletonCount for smartdns.

### Added
- Stock dashboard card: loading skeletons in expandable details grid (previously empty until first fetch).
- Skeleton CSS moved to common.css for shared use between custom and stock dashboard contexts.

## [0.21.0] - 2026-06-08

### Added
- **Status API response cache** (`lua_shared_dict`): deduplicates concurrent poll
  requests from multiple browser tabs. Only one nginx worker runs the status script
  per TTL window; all other clients get cached result instantly. Reduces CPU
  load by 73-84% with multiple open tabs.
- **Per-endpoint cache TTL** (`ENDPOINT_TTLS`): heavy scripts cached longer —
  geo-split 10s (detect_dns_port = 2×dig), smartdns 15s (DNS tests = N×dig +time=3),
  fast endpoints (smartdns-redirect, webui) stay at 5s. Reduces total fork rate
  from 48/min to 26/min (−46%).
- Cache invalidation on POST actions (start/stop, config save) — next poll after
  toggle always returns fresh state.
- Static data caching: `system/zones` parsed once per hour (STATIC_TTL=3600s),
  `system/interfaces` cached for 60s (IFACE_TTL).
- Design document: `docs/status-cache-design.md` — full analysis and architecture.

### Changed
- `worker_processes auto` — matches CPU core count (was hardcoded 2). On 4-core
  routers (KN-2310, KN-1011) now 4 workers → better io.popen parallelism.

## [0.20.2] - 2026-06-08

### Fixed
- **Union parser: underscore in names** — Lua pattern `%w+` → `[%w_]+` in
  api-router.lua. Unions with underscores (opec_plus, china_plus, swift_cut etc.)
  were silently dropped from API response.
- Zone code parser also updated (`%w+` → `[%w_]+`) for future-proofing.

## [0.20.1] - 2026-06-07

### Fixed
- **Stock sidebar broken after visiting custom page** (critical): Root cause was
  `setupRestore()` only called when `injectSidebar=1`. With default config
  (`injectSidebar=0`), the click capture handler and MutationObserver were never
  registered — after opening custom page via dashboard card click, there was NO
  mechanism to remove the iframe when stock sidebar was clicked. Fix: `setupRestore()`
  now called unconditionally in `tryInject()`.
- **Content not restored on iframe removal**: `removeIframe()` now restores `display`
  of Angular content children that were hidden by `showInContent()`. Previously the
  iframe was removed but Angular's router-outlet stayed `display:none`.
- **Browser Back from custom page**: `showInContent()` now pushes history state
  (same URL, `{__ew}` marker). Exit-only `popstate` handler in `setupRestore()`
  removes iframe on Back without re-showing on Forward (avoids Angular conflicts).
  Route-change watcher also removes iframe as safety net.
- **Custom page tabs: back/forward support**: `switchTab()` in app.js now uses
  `history.pushState()` instead of `replaceState()` for tab switches, with `popstate`
  listener to apply hash route on browser navigation.

## [0.20.0] - 2026-06-07

### Added
- **Search/filter** in all dropdown panels: type to filter items in real-time.
  Filter input appears at the top of every dropdown (zone selector, interface
  multi-select, union selector). Auto-focuses on open, resets on close.
- **Keyboard-driven workflow**: open dropdown → immediately type to narrow results.
- Group headers auto-hide when all items in a group are filtered out.

### Changed
- Union selector migrated from native `<select>` to custom dropdown with radio
  buttons, search filter, and unified styling matching zone/interface dropdowns.
- Dropdown panel `max-height` increased from 200px to 60vh (fills more screen,
  easier to browse large lists like 240 country zones).
- Radio buttons close dropdown automatically after selection (single-select UX).
- `select` field type (SUBNET_LOADER) migrated to custom dropdown (radio buttons).

### Removed
- Dead CSS: `.ew-modal__select-wrap`, `.ew-modal__select`, `.ew-modal__select option`,
  `.ew-modal__zone-panel .ew-modal__select` rules (~33 lines — old native `<select>` styling).

## [0.19.1] - 2026-06-07

### Fixed
- Gateway IP field: clicking disabled text input now auto-selects "IP" radio
  (CSS `pointer-events: none` passes click to `<label>` → native radio activation)

### Changed
- DNS Redirect: `INTERFACES` field migrated from old inline pills (`interfaces`)
  to new dropdown multi-select (`iface_select`)

### Removed
- Dead code: old `interfaces` / `interface` field renderers, save/reset logic (~71 lines JS)
- Dead CSS: `.ew-modal__ifaces`, `.ew-modal__iface-item`, `.ew-modal__iface-name`,
  `.ew-modal__ifaces--radio` rules (~71 lines CSS)

## [0.19.0] - 2026-06-07

### Added
- Geo-split: `GEO_ZONE` zone_selector field (country/union dropdown)
- Shared `/api/system/zones` endpoint (used by smartdns and geo-split)
- Geo-split: `active_zones` in summary card detail keys

### Changed
- Geo-split settings: `ROUTE_IN` → dropdown multi-select (`iface_select`)
- Geo-split settings: `SUBNET_URL` → optional override (was primary config)
- Zones fetch: `/api/system/zones` replaces `/api/smartdns/zones` (backward compat kept)

## [0.18.2] - 2026-06-07

### Fixed
- Zone selector: encoding-agnostic parsing of zone headers in api-router.lua
  (fixes double em-dash display and potential nginx 500 on multi-byte separators)
- Zone selector: sorted alphabetically by country name (was by ISO code)
- Config modal: Escape key closes open dropdown first, not the entire modal

## [0.18.1] - 2026-06-07

### Changed
- Renamed SmartDNS service label: "SmartDNS Config" → "SmartDNS Geo-Config" (app.js, shared.js, inject.js)
- Updated api-router.lua paths: `smartdns-conf-ru-split/` → `smartdns-geo-conf/`

## [0.18.0] - 2026-06-07

### Added
- **Zone selector** (`zone_selector` type): radio Zone/Union + multiselect dropdown for countries, grouped select for unions
- **Interface multi-select dropdown** (`iface_select` type): custom dropdown with checkboxes, "Default route" option
- **DNS Tests display**: stock dashboard card (concise ✓/✗ domain) + custom detail view (with IPs)
- API endpoint `/api/smartdns/zones` — dynamic parsing of `unions.conf` + zone files

### Changed
- SmartDNS config editor: DNS_ZONE, ZONE_DNS_INTERFACE, OTHER_DNS_INTERFACES — new rich UI
- Restart command: S37smartdns-conf (generates configs before S38 restart)

## [0.17.1] - 2026-06-06

### Changed
- SmartDNS Config: service description updated to "Geo-zone DNS splitting"
- SmartDNS Config: SUMMARY_KEYS adds `dns_zone`, `active_zones` to dashboard card
- SmartDNS Config: CONFIG_SCHEMAS expanded with DNS_ZONE, OTHER_DNS_INTERFACES,
  ZONE_DNS_INTERFACE fields (config editor)

## [0.17.0] - 2026-06-04

### Added
- Visual polish: card box-shadow + hover glow, status chip backgrounds,
  header accent separator, system info bar styling, tab active glow,
  toggle micro-animation, background dot grid pattern.
- Boolean icons: "Ok" → green ✓, "Fail" → red ✗ in detail grids.
- Left accent border: green (running), gray (stopped), red (error) on cards.
- Numeric values in monospace font (15px, JetBrains Mono fallback).
- Version badge: monospace pill chip for version fields.
- Summary condensed mode: only 3-5 key metrics per service card in Summary tab,
  3-column detail grid, "View details →" link to full service tab.
- Smart loading skeletons: cached field count from localStorage, priority-aware.
- Created `webui/.project/target-gui.md` — GUI design principles document.

### Fixed
- `SUMMARY_KEYS` for geo-split: `active_out` → `gateway` (matches actual API key).

### Removed
- Refresh pulse animation on status badges (violated "Тишина" principle).

## [0.16.6] - 2026-06-03

### Changed
- Performance: `worker_processes 2` — parallel request handling, eliminates
  queue starvation when multiple tabs poll simultaneously (up to 10 tabs).
- Performance: replaced `curl --max-time 3` upstream probe with instant
  `netstat -tln` port check in status.sh — saves up to 3s per webui/status call.
- `FETCH_TIMEOUT` increased from 10s to 15s — prevents false timeout errors
  during peak polling load on slow connections.
- RAM indicator: added tooltip explaining conservative MemAvailable-based
  calculation (accounts for non-reclaimable kernel slab/conntrack).

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
