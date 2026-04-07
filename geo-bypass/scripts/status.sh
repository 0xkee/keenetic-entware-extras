#!/opt/bin/sh
# Show geo-bypass diagnostic status.
# shellcheck disable=SC3043
# shellcheck disable=SC1091
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../../lib/common.sh"
_CONFIG_DIR="$SCRIPT_DIR/../config"
. "$_CONFIG_DIR/config.sh"

STATUS_OK=0

# Format seconds as human-readable age (e.g. "2d 5h", "45m")
format_age() {
  local seconds="$1"
  local days hours mins
  days=$((seconds / 86400))
  hours=$(( (seconds % 86400) / 3600 ))
  mins=$(( (seconds % 3600) / 60 ))
  if [ "$days" -gt 0 ]; then echo "${days}d ${hours}h"
  elif [ "$hours" -gt 0 ]; then echo "${hours}h ${mins}m"
  else echo "${mins}m"
  fi
}

# Detect ISP interface from default route
detect_isp_interface() {
  ip route show default | sed -n 's/.*dev \([^ ]*\).*/\1/p' | grep -v '^br' | head -1
}

# Show routing mode and active interface(s) from route table
show_mode() {
  echo "  Mode:        $ROUTE_MODE"

  # Show active interface from real routes in table (ground truth)
  local active_ifaces
  active_ifaces=$(ip route show table "$ROUTE_TABLE" 2>/dev/null \
    | sed -n 's/.*dev \([^ ]*\).*/\1/p' | sort -u | tr '\n' ' ' | sed 's/ $//')

  if [ -n "$active_ifaces" ]; then
    echo "  Interface:   $active_ifaces (active in table $ROUTE_TABLE)"
  else
    echo "  Interface:   — detached"
  fi
}

# Show ipset existence and entry count
show_ipset() {
  local count mem
  if ipset list "$IPSET_NAME" -t >/dev/null 2>&1; then
    # Try "Number of entries" header first, fallback to counting members
    count=$(ipset list "$IPSET_NAME" -t 2>/dev/null | awk '/Number of entries/ {print $NF}')
    if [ -z "$count" ]; then
      count=$(ipset list "$IPSET_NAME" 2>/dev/null | grep -c '/')
    fi
    mem=$(ipset list "$IPSET_NAME" -t 2>/dev/null | awk '/Size in memory/ {print $NF}')
    if [ -n "$mem" ]; then
      mem=" / $(( mem / 1024 ))KB"
    fi
    echo "  Ipset:       $IPSET_NAME (${count:-0} entries${mem}) ✓"
  else
    echo "  Ipset:       $IPSET_NAME ✗ (not loaded)"; STATUS_OK=1
  fi
}

# Show ip rule iif status for each LAN interface
show_ip_rule() {
  local iface rules_output
  rules_output=$(ip rule show)
  for iface in $LAN_INTERFACES; do
    if echo "$rules_output" | grep -qE "iif $iface.*lookup $ROUTE_TABLE"; then
      echo "  IP rule:     iif $iface → table $ROUTE_TABLE ✓"
    else
      echo "  IP rule:     iif $iface → table $ROUTE_TABLE ✗"; STATUS_OK=1
    fi
  done
}

# Show route table entry count
show_routes() {
  local count
  count=$(ip route show table "$ROUTE_TABLE" 2>/dev/null | wc -l)
  if [ "$count" -gt 0 ]; then
    echo "  Routes:      $count in table $ROUTE_TABLE ✓"
  else
    echo "  Routes:      0 in table $ROUTE_TABLE ✗"; STATUS_OK=1
  fi
}

# Show subnet cache age and freshness
show_subnets() {
  if [ -f "$SUBNET_LIST_FILE" ]; then
    local age age_label max_label
    age=$(( $(date +%s) - $(file_mtime "$SUBNET_LIST_FILE") ))
    age_label="$(format_age "$age")"
    max_label="$(format_age "$MAX_CACHE_AGE")"
    if [ "$age" -le "$MAX_CACHE_AGE" ]; then
      echo "  Subnets:     cache ${age_label} old (max ${max_label}) ✓"
    else
      echo "  Subnets:     cache ${age_label} old (max ${max_label}) ✗ stale"; STATUS_OK=1
    fi
  else
    echo "  Subnets:     ✗ (no cache file)"; STATUS_OK=1
  fi
}

# Show domain cache count, age and freshness
show_domains() {
  [ -n "${DOMAINS_CACHE_FILE:-}" ] && [ -n "${DOMAINS_LIST_FILE:-}" ] || return 0
  local interval="${DOMAINS_UPDATE_INTERVAL:-3600}"
  if [ -f "$DOMAINS_CACHE_FILE" ]; then
    local count age age_label max_label
    count=$(wc -l < "$DOMAINS_CACHE_FILE")
    age=$(( $(date +%s) - $(file_mtime "$DOMAINS_CACHE_FILE") ))
    age_label="$(format_age "$age")"
    max_label="$(format_age "$interval")"
    if [ "$age" -le "$interval" ]; then
      echo "  Domains:     $count in cache, ${age_label} old (max ${max_label}) ✓"
    else
      echo "  Domains:     $count in cache, ${age_label} old (max ${max_label}) ✗ stale"; STATUS_OK=1
    fi
  else
    echo "  Domains:     ✗ (no cache file)"; STATUS_OK=1
  fi
}

# --- main ---
echo "geo-bypass status:"
show_mode
show_ipset
show_ip_rule
show_routes
show_subnets
show_domains
echo "  Loader:      $SUBNET_LOADER"

exit "$STATUS_OK"
