#!/opt/bin/sh
# Configuration for geo-bypass.
# Edit these values to match your router setup.
# shellcheck disable=SC2034  # all variables are used by sourcing scripts
# NOTE: _CONFIG_DIR must be set by the sourcing script before sourcing this file

# Routing mode: bypass | vpn | auto
#   bypass — GEO traffic goes directly via ISP, bypassing VPN
#   vpn    — GEO traffic is routed through VPN tunnel
#   auto   — auto-detect ISP interface, route GEO traffic via ISP (same as bypass + auto-detect)
ROUTE_MODE="auto"

# ISP (direct) interface — used in bypass/auto modes
# Empty = auto-detect via `ip route show default`
ISP_INTERFACE=""

# VPN interface — used in vpn mode
VPN_INTERFACE="nwg0"

# ipset name for GEO subnets
IPSET_NAME="geo-bypass"

# Custom routing table number
ROUTE_TABLE="1000"

# IP rule priority (lower = higher priority)
RULE_PRIORITY="100"

# Firewall mark for geo-bypass traffic (must NOT overlap with Keenetic NDM marks).
# Keenetic uses bits 0-27 (0x0FFFFAxx range). Bits 28-31 are free.
# Bit 29 (0x20000000) is safe and confirmed working.
FWMARK="0x20000000"
FWMARK_MASK="0x20000000"

# URL to fetch GEO IP subnets (plain CIDR list)
# RU ip4 example
# Alternative: https://stat.ripe.net/data/country-resource-list/data.json?resource=RU (requires ripe-json loader + jq)
SUBNET_URL="https://ipbl.herrbischoff.com/geoip/ru.netset"

# Loader script name in loaders/ directory (without .sh)
# Available: cidr-plain (default), ripe-json (requires jq)
SUBNET_LOADER="cidr-plain"

# Local cached subnet list
SUBNET_LIST_FILE="${_CONFIG_DIR:-.}/../lists/ru-subnets.txt"

# Log tag
LOG_TAG="geo-bypass"

# Max age of cached subnet list in seconds (7 days)
MAX_CACHE_AGE=604800

# Number of download retries per interface on failure
DOWNLOAD_RETRIES=2

# Delay between retries in seconds
DOWNLOAD_RETRY_DELAY=3

# Outgoing interfaces to try for downloads (in order of preference).
# "default" = system default route (no --interface).
# Tries each interface with DOWNLOAD_RETRIES attempts before moving to next.
DOWNLOAD_INTERFACES="default nwg* ovpn_br*"

# Optional domains list file (resolved via dig → added to ipset)
# Leave empty or comment out to skip domain resolution
DOMAINS_LIST_FILE="${_CONFIG_DIR:-.}/../lists/domains.txt"

# Cache file for resolved domain IPs (auto-generated, do not edit)
DOMAINS_CACHE_FILE="${_CONFIG_DIR:-.}/../lists/domains-resolved.txt"

# Domain resolution update interval in seconds (1 hour)
# 0 = disable automatic domain updates
DOMAINS_UPDATE_INTERVAL=3600
