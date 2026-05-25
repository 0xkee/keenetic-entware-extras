# Changelog

All notable changes to `geo-split` are documented here.

Format: [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/)
Versioning: [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html)

## [Unreleased]

## [0.10.7] - 2026-05-25

### Added
- Zone sizes research doc (`docs/zone-sizes-research.md`): country CIDR counts, hardware compatibility matrix, usage scenarios

## [0.10.6] - 2026-05-16

### Changed
- Domain resolution interval reduced from 4h to 1h (`DOMAINS_UPDATE_INTERVAL=3600`)
- Skip route table rebuild when resolved IPs haven't changed (`cmp` diff check)
- Guard against empty resolution results (DNS down → keep old cache)

## [0.10.5] - 2026-05-15

### Changed
- Move all runtime files (pidfile, batch, caches) from `/tmp` to `/opt/tmp`

## [0.10.4] - 2026-05-12

### Fixed
- Status script reliability improvements
- Race condition on cold boot with slow DNS resolution

### Changed
- Async subnet loading on boot for faster startup
