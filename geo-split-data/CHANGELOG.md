# Changelog

All notable changes to `geo-split-data` are documented here.

Format: [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/)
Versioning: [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html)

## [0.6.1] - 2026-08-16

### Changed
- Legal terminology compliance: updated naming — allowlist, гео-ограничение — in README, user manual, domains.txt, ru-whitelist.txt comments
- Removed regulator reference from domains.txt

## [0.6.0] - 2026-07-06

### Changed
- **Zone files stored as .gz**: all `lists/geoip/*.zone` files are now gzip-compressed
  (`.zone.gz`). Saves ~60-70% flash space on routers (232 zones: ~3.5MB → ~1.2MB).
  `fetch-zones.sh` compresses with `gzip -9` at build time.

## [0.5.0] - 2026-06-07

### Added
- All 234 GeoIP country zones in fetch-zones.sh (was 5 EAEU only)
- Full ISO 3166-1 alpha-2 coverage for ipdeny.com data

### Changed
- `COUNTRIES` array expanded from 5 (EAEU) to ~240 (all available zones)

## [0.4.0] - 2026-05-12

### Added
- `ru-whitelist.txt` for manually curated Russian domains
- README included in .ipk package

### Changed
- `domains.txt` marked as conffile (preserved on opkg upgrade)
