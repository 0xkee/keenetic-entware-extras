# Changelog

All notable changes to `smartdns-redirect` are documented here.

Format: [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/)
Versioning: [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html)

## [Unreleased]

## [0.2.3] - 2026-05-15

### Changed
- Move pidfile from `/tmp` to `/opt/tmp`

## [0.2.2] - 2026-05-12

### Fixed
- Watchdog false-positive restart detection
- Netfilter hook compatibility with newer iptables

### Added
- Configurable DNS target port and address
