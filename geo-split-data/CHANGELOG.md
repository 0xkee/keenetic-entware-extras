# Changelog

All notable changes to `geo-split-data` are documented here.

Format: [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/)
Versioning: [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html)

## [Unreleased]

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
