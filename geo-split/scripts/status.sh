#!/opt/bin/sh
# Show geo-split diagnostic status.
# shellcheck disable=SC3043
# shellcheck disable=SC1091
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../../lib/common.sh"
_CONFIG_DIR="$(cd "$SCRIPT_DIR/../config" && pwd)"
. "$_CONFIG_DIR/config.sh"
. "$SCRIPT_DIR/../../lib/ip.sh"

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

# Show routing config and active interface(s) from route tables
show_mode() {
  # Route in: configured LAN sources
  echo "  Route in:    $ROUTE_IN"

  # Route out: configured target
  if [ "${ROUTE_OUT:-auto}" = "auto" ] || [ -z "${ROUTE_OUT:-}" ]; then
    echo "  Route out:   auto (detect ISP)"
  else
    echo "  Route out:   $ROUTE_OUT"
  fi

  # Active out: ground truth from both route tables
  local active_ifaces
  active_ifaces=$( {
    ip route show table "$DOMAIN_ROUTE_TABLE" 2>/dev/null
    ip route show table "$SUBNET_ROUTE_TABLE" 2>/dev/null
  } | sed -n 's/.*dev \([^ ]*\).*/\1/p' | sort -u | tr '\n' ' ' | sed 's/ $//')

  if [ -n "$active_ifaces" ]; then
    echo "  Active out:  $active_ifaces (tables $DOMAIN_ROUTE_TABLE,$SUBNET_ROUTE_TABLE)"
  else
    echo "  Active out:  — detached"
  fi
}

# Show ip rule iif status for each ROUTE_IN interface (both tables)
show_ip_rule() {
  local iface rules_output
  rules_output=$(ip rule show)
  for iface in $ROUTE_IN; do
    if echo "$rules_output" | grep -qE "iif $iface.*lookup $DOMAIN_ROUTE_TABLE"; then
      echo "  IP rule:     iif $iface → table $DOMAIN_ROUTE_TABLE (domains) ✓"
    else
      echo "  IP rule:     iif $iface → table $DOMAIN_ROUTE_TABLE (domains) ✗"; STATUS_OK=1
    fi
    if echo "$rules_output" | grep -qE "iif $iface.*lookup $SUBNET_ROUTE_TABLE"; then
      echo "  IP rule:     iif $iface → table $SUBNET_ROUTE_TABLE (subnets) ✓"
    else
      echo "  IP rule:     iif $iface → table $SUBNET_ROUTE_TABLE (subnets) ✗"; STATUS_OK=1
    fi
  done
}

# Show route table entry counts (per table)
show_routes() {
  local count
  count=$(ip route show table "$DOMAIN_ROUTE_TABLE" 2>/dev/null | wc -l)
  if [ "$count" -gt 0 ]; then
    echo "  Domains:     $count routes in table $DOMAIN_ROUTE_TABLE ✓"
  else
    echo "  Domains:     0 routes in table $DOMAIN_ROUTE_TABLE ✗"; STATUS_OK=1
  fi

  count=$(ip route show table "$SUBNET_ROUTE_TABLE" 2>/dev/null | wc -l)
  if [ "$count" -gt 0 ]; then
    echo "  Subnets:     $count routes in table $SUBNET_ROUTE_TABLE ✓"
  else
    echo "  Subnets:     0 routes in table $SUBNET_ROUTE_TABLE ✗"; STATUS_OK=1
  fi
}

# Show subnet cache age and freshness
show_subnets() {
  if [ -f "$SUBNET_LIST_FILE" ]; then
    local age age_label max_label
    age=$(( $(date +%s) - $(file_mtime "$SUBNET_LIST_FILE") ))
    age_label="$(format_age "$age")"
    max_label="$(format_age "$MAX_CACHE_AGE")"
    if [ "$age" -lt "$MAX_CACHE_AGE" ]; then
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
    if [ "$age" -lt "$interval" ]; then
      echo "  Domains:     $count in cache, ${age_label} old (max ${max_label}) ✓"
    else
      echo "  Domains:     $count in cache, ${age_label} old (max ${max_label}) ✗ stale"; STATUS_OK=1
    fi
  else
    echo "  Domains:     ✗ (no cache file)"; STATUS_OK=1
  fi
}

# Show last successful download interface (from cache)
show_download_iface() {
  if [ -f "$LAST_IFACE_CACHE" ]; then
    local iface
    iface=$(cat "$LAST_IFACE_CACHE")
    echo "  DL iface:    $iface (cached)"
  else
    echo "  DL iface:    — (no history)"
  fi
}

# Show DNS resolver used for domain resolution (re-probes live).
# Uses detect_dns_port() from lib/ip.sh.
show_dns_resolver() {
  local result port label
  result=$(detect_dns_port)
  port="${result%% *}"
  label="${result#* }"

  if [ "$port" = "0" ]; then
    echo "  DNS:         system resolver"
  else
    echo "  DNS:         localhost:$port ($label)"
  fi
}

# Show cron job registration status
show_cron() {
  local cron_file="/opt/etc/crontab"
  if [ ! -f "$cron_file" ]; then
    echo "  Cron:        — ($cron_file missing)"; STATUS_OK=1
    return
  fi
  local count
  count=$(grep -c '^[^#]*geo-split' "$cron_file" 2>/dev/null) || count=0
  if [ "$count" -gt 0 ]; then
    echo "  Cron:        $count job(s) ✓"
  else
    echo "  Cron:        ✗ (no geo-split jobs)"; STATUS_OK=1
  fi
}

# Show NDM hook symlink status
show_ndm_hook() {
  local hook="/opt/etc/ndm/ifstatechanged.d/geo-split-hook"
  if [ -L "$hook" ]; then
    echo "  NDM hook:    $hook ✓"
  elif [ -f "$hook" ]; then
    echo "  NDM hook:    $hook (not a symlink) ✓"
  else
    echo "  NDM hook:    ✗ (missing)"; STATUS_OK=1
  fi
}

# Show installed package version
show_version() {
  local ver
  ver=$(opkg info geo-split 2>/dev/null | sed -n 's/^Version: //p')
  if [ -n "$ver" ]; then
    echo "  Version:     $ver"
  else
    echo "  Version:     — (not installed via opkg)"
  fi
}

# Show background update processes (if any update scripts are running)
show_background() {
  local pids
  # shellcheck disable=SC2009
  pids=$(ps 2>/dev/null | grep -E 'update-(subnets|domains)\.sh' | grep -v grep | awk '{print $1}' | tr '\n' ' ')
  if [ -n "$pids" ]; then
    echo "  Background:  update running (PIDs: ${pids})"
  else
    echo "  Background:  idle"
  fi
}

# Show domain source list count (how many domains are configured)
show_domain_sources() {
  if [ -f "$DOMAINS_LIST_FILE" ]; then
    local src_count
    src_count=$(grep -cEv '^[[:space:]]*(#|$)' "$DOMAINS_LIST_FILE" 2>/dev/null) || src_count=0
    echo "  Dom sources: $src_count domain(s) configured"
  else
    echo "  Dom sources: — (no list file)"
  fi
}

# --- main ---
echo "geo-split status:"
show_mode
show_ip_rule
show_routes
echo
show_subnets
show_domains
show_domain_sources
echo
show_cron
show_ndm_hook
show_download_iface
show_dns_resolver
show_background
echo
echo "  Loader:      $SUBNET_LOADER"
show_version

exit "$STATUS_OK"
