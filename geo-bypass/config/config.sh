#!/opt/bin/sh
# Configuration for geo-bypass.
# Edit these values to match your router setup.
# shellcheck disable=SC2034  # all variables are used by sourcing scripts
# NOTE: _CONFIG_DIR must be set by the sourcing script before sourcing this file

# Derived path to lists directory (geo-bypass-data subproject)
_LISTS_DIR="${_CONFIG_DIR%/*/*}/geo-bypass-data/lists"

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

# Custom routing table number
ROUTE_TABLE="1000"

# IP rule priority (lower = higher priority)
RULE_PRIORITY="50"

# LAN interfaces for ip rule iif (space-separated).
# Each interface gets its own ip rule → custom route table.
# Keenetic bridges: br0 = Home LAN, br1 = Guest network
LAN_INTERFACES="br0"

# ip-full binary path (Entware package ip-full, supports -batch)
IP_FULL="/opt/sbin/ip"

# Temporary batch file for ip-full -batch route loading
BATCH_FILE="/opt/tmp/geo-routes.batch"

# URL to fetch GEO IP subnets (plain CIDR list)
# RU ip4 example
# Source: ipdeny.com — based on RIR allocations (RIPE/ARIN/etc), more complete
# coverage than MaxMind GeoLite2 (e.g. includes OZON 185.73.192.0/22).
# Alternative: https://stat.ripe.net/data/country-resource-list/data.json?resource=RU (requires ripe-json loader + jq)
# Alternative: SUBNET_URL="https://ipbl.herrbischoff.com/geoip/ru.netset"
SUBNET_URL="https://www.ipdeny.com/ipblocks/data/countries/ru.zone"

# Loader script name in loaders/ directory (without .sh)
# Available: cidr-plain (default), ripe-json (requires jq)
SUBNET_LOADER="cidr-plain"

# Aggregate (merge) adjacent/overlapping CIDR subnets after download
# Reduces route entries count (default: enabled)
SUBNET_AGGREGATE=1

# Local cached subnet list
SUBNET_LIST_FILE="$_LISTS_DIR/ru-subnets.txt"

# Log tag
LOG_TAG="geo-bypass"

# Max age of cached subnet list in seconds (7 days)
MAX_CACHE_AGE=604800

# Number of download retries per interface on failure
DOWNLOAD_RETRIES=2

# Delay between retries in seconds
DOWNLOAD_RETRY_DELAY=3

# Cache file for last successful download interface
LAST_IFACE_CACHE="/opt/tmp/geo-bypass-last-iface"

# Outgoing interfaces to try for downloads (in order of preference).
# "default" = system default route (no --interface).
# Tries each interface with DOWNLOAD_RETRIES attempts before moving to next.
DOWNLOAD_INTERFACES="default nwg* ovpn* l2tp* pptp* sstp* ipsec*"

# DNS resolver port for full A-record resolution (all IPs, no speed-check).
# Empty = auto-detect (probe localhost:6153, then :6053, then system resolver).
# Set to specific port to skip auto-detection.
DNS_FULL_RESOLVER_PORT=""

# Optional domains list file (resolved via dig → cached for routing)
# Leave empty or comment out to skip domain resolution
DOMAINS_LIST_FILE="$_LISTS_DIR/domains.txt"

# Cache file for resolved domain IPs (auto-generated, do not edit)
DOMAINS_CACHE_FILE="$_LISTS_DIR/domains-resolved.txt"

# Domain resolution update interval in seconds (1 hour)
# 0 = disable automatic domain updates
DOMAINS_UPDATE_INTERVAL=3600
