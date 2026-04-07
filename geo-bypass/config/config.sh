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

# URL to fetch GEO IP subnets (RIPE data)
# RU ip4 example
# Alternative: https://stat.ripe.net/data/country-resource-list/data.json?resource=RU
SUBNET_URL="https://raw.githubusercontent.com/herrbischoff/country-ip-blocks/master/ipv4/ru.cidr"

# Local cached subnet list
SUBNET_LIST_FILE="${_CONFIG_DIR:-.}/../lists/ru-subnets.txt"

# Log tag
LOG_TAG="geo-bypass"

# Max age of cached list in seconds (24 hours)
MAX_CACHE_AGE=86400

# Number of download retries on failure
DOWNLOAD_RETRIES=3

# Delay between retries in seconds
DOWNLOAD_RETRY_DELAY=5

# Optional domains list file (resolved via dig → added to ipset)
# Leave empty or comment out to skip domain resolution
DOMAINS_LIST_FILE="${_CONFIG_DIR:-.}/../lists/domains.txt"

# Cache file for resolved domain IPs (auto-generated, do not edit)
DOMAINS_CACHE_FILE="${_CONFIG_DIR:-.}/../lists/domains-resolved.txt"

# Max age of domain IP cache in seconds (1 hour)
DOMAINS_CACHE_AGE=3600
