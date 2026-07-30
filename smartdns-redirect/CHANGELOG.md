# Changelog

All notable changes to `smartdns-redirect` are documented here.

Format: [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/)
Versioning: [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html)

## [0.6.1] - 2026-07-30

### Changed
- `status.sh`: colored status marks and bold section headers via `lib/status.sh` color system; `--color`/`--no-color` flag support
- `status.sh`: `check_rule()` refactored from 4 duplicated case branches (−50 lines) to unified `status_line_cont()` API

## [0.6.0] - 2026-07-30

### Added
- **`REDIRECT_MODE` config parameter** — `force` (default, intercept all :53 DNS +
  block DoT :853) or `local` (intercept only DNS to router IP, external DNS passes
  through, DoT not blocked). For IoT devices or corporate laptops with hardcoded DNS.

## [0.5.0] - 2026-07-29

### Added
- **DoT blocking in `force` mode**: DNS-over-TLS (port 853) from LAN clients is blocked
  via iptables FORWARD REJECT alongside DNAT :53. Prevents clients from bypassing
  SmartDNS via direct DoT to external resolvers (8.8.8.8:853, 1.1.1.1:853 etc.).
  IPv4 + IPv6 rules. Watchdog monitors DoT block rules.

### Removed
- `DNS_STRICT` config parameter — replaced by `REDIRECT_MODE` (force/local).

## [0.4.3] - 2026-07-28

### Changed
- Scripts: simplify `_CONFIG_DIR` assignment — replace `$(cd ... && pwd)` subshell
  with `${SCRIPT_DIR%/*}/config` parameter expansion

## [0.4.2] - 2026-07-27

### Fixed
- **`status.sh --json` parent-disabled state**: when parent service (smartdns-geo-conf)
  is disabled, JSON now returns `enabled:false` — prevents webui showing 🔴 "Failed"
  for a non-failure state

### Changed
- **`status.sh --json` parent-disabled details**: human-readable `depends_on` and
  `action` fields (was: raw `parent_disabled: "smartdns-geo-conf"` / CLI command)
- **`status.sh --json` checks when disabled**: runtime checks (`running`, `upstream`,
  `rules`) now return `"skip"` instead of `"fail"` when self-disabled or parent-disabled

## [0.4.1] - 2026-07-27

### Added
- `watchdog.sh`: S38 existence guard — exits early when SmartDNS is disabled
  (S38 renamed by `S37smartdns-conf disable`), prevents watchdog from fighting
  intentional shutdown
- `netfilter-hook.sh`: same S38 existence guard — no iptables rule restoration
  when SmartDNS is intentionally disabled

## [0.4.0] - 2026-07-27

### Added
- Automatic IPv6 DNS leak prevention: no user configuration needed
  - Auto-DNAT: when SmartDNS has IPv6 bind + br0 has global IPv6 →
    ip6tables DNAT to SmartDNS (full IPv6 DNS through SmartDNS)
  - Auto-REJECT: otherwise → ip6tables INPUT REJECT with
    icmp6-port-unreachable (instant Happy Eyeballs fallback to IPv4 DNAT)
- `can_dnat_ipv6()` auto-detection: checks ip6tables, br0 IPv6, SmartDNS bind
- `status.sh`: IPv6 mode display — `dnat`, `reject`, or `none` (text + JSON)
- `status.sh`: `dnat_target_v6` field in JSON output when in DNAT mode
- `watchdog.sh`: checks IPv6 rules (DNAT or REJECT) based on auto-detected mode

### Changed
- `ENABLE_IPV6` config option removed — IPv6 handling is fully automatic
- Legacy `ENABLE_IPV6=yes` in user config.conf produces deprecation warning
- `del_all_rules()` now cleans up IPv6 filter INPUT REJECT rules in addition
  to nat PREROUTING rules
- `status.sh` JSON: `ipv6` field changed from `"yes"/"no"` to
  `"dnat"/"reject"/"none"`

### Removed
- `ENABLE_IPV6` option from `defaults.conf`
- `ipv6_enabled()` helper (replaced by `can_dnat_ipv6()`)
- `add_rule_if_missing_v6()` (replaced by `add_v6_dnat_rule()`)

## [0.3.7] - 2026-07-12

### Changed
- `status.sh`: details reordered — redirect chain (interfaces → dnat_target → rules)
  first, then upstream resolver, then infrastructure (ndm_hook, init)

## [0.3.6] - 2026-07-12

### Added
- `status.sh`: DNAT target IP shown in CLI (`DNAT to: 192.168.1.1:6053`) and
  JSON (`dnat_target` field) — visible when debugging multi-interface setups
- `status.sh`: per-interface rule breakdown in JSON (`rules_detail` array with
  iface/family/proto/ok for each expected iptables rule)

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
