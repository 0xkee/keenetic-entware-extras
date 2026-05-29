# Changelog

All notable changes to `smartdns-conf-ru-split` are documented here.

Format: [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/)
Versioning: [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html)

## [Unreleased]

### Fixed
- `smartdns.conf` — misleading comment about leading dot in nameserver rules;
  clarified that `/.ru/ru` and `/ru/ru` are equivalent (suffix match)

## [0.4.3] - 2026-05-16

### Added
- TCP listeners (`bind-tcp`) on ports 6053 and 6153 — fixes TCP DNS timeout
  when `smartdns-redirect` forwards TCP traffic to SmartDNS

## [0.4.2] - 2026-05-12

### Fixed
- Toggle script state persistence across reboots

### Changed
- Default DNS config uses DoH for international resolvers
