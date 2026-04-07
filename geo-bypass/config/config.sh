#!/opt/bin/bash
# Configuration for geo-bypass.
# Edit these values to match your router setup.

# ISP (direct) interface — traffic to .ru goes here, bypassing VPN
ISP_INTERFACE="eth3"

# VPN interface (for reference / exclusion)
VPN_INTERFACE="nwg0"

# ipset name for .ru subnets
IPSET_NAME="geo-bypass"

# Custom routing table number (1-252)
ROUTE_TABLE="100"

# IP rule priority (lower = higher priority)
RULE_PRIORITY="500"

# URL to fetch Russian IP subnets (RIPE data)
# Alternative: https://stat.ripe.net/data/country-resource-list/data.json?resource=RU
SUBNET_URL="https://raw.githubusercontent.com/herrbischoff/country-ip-blocks/master/ipv4/ru.cidr"

# Local cached subnet list
SUBNET_LIST_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lists/ru-subnets.txt"

# Log tag
LOG_TAG="geo-bypass"

# Max age of cached list in seconds (24 hours)
MAX_CACHE_AGE=86400
