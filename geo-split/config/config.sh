#!/opt/bin/sh
# Configuration for geo-split.
# Split routing by GeoIP subnets and domain lists.
# Edit these values to match your router setup.
# shellcheck disable=SC2034  # all variables are used by sourcing scripts
# NOTE: _CONFIG_DIR must be set by the sourcing script before sourcing this file

# Derived path to lists directory (geo-split-data subproject)
_LISTS_DIR="${_CONFIG_DIR%/*/*}/geo-split-data/lists"

# Target outgoing interface for matched GEO traffic
# "auto" or empty = detect ISP automatically from default route
# Explicit: "lte_br1" (ISP), "nwg0" (VPN), "ppp0", etc.
ROUTE_OUT="auto"

# Source LAN/tunnel interfaces for ip rule iif (space-separated)
# Each interface gets its own ip rule → custom route table
# Keenetic bridges: br0 = Home LAN, br1 = Guest network
ROUTE_IN="br0"

# Domain routing table (custom /32 host routes — higher priority, checked first)
DOMAIN_ROUTE_TABLE="1000"
DOMAIN_RULE_PRIORITY="50"

# Subnet routing table (GeoIP CIDRs — lower priority, checked after domains)
SUBNET_ROUTE_TABLE="1001"
SUBNET_RULE_PRIORITY="51"

# ip-full binary path (Entware package ip-full, supports -batch)
IP_FULL="/opt/sbin/ip"

# Base path for temporary batch files (ip-full -batch route loading)
# fill_routes_batch() appends .${table}.batch to avoid race conditions
BATCH_FILE="/opt/tmp/geo-routes"

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
LOG_TAG="geo-split"

# Max age of cached subnet list in seconds (7 days)
MAX_CACHE_AGE=604800

# Number of download retries per interface on failure
DOWNLOAD_RETRIES=2

# Delay between retries in seconds
DOWNLOAD_RETRY_DELAY=3

# Cache file for last successful download interface
LAST_IFACE_CACHE="/opt/tmp/geo-split-last-iface"

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

# PID file (written on start, removed on stop; mtime used for uptime)
PIDFILE="/opt/var/run/geo-split.pid"
