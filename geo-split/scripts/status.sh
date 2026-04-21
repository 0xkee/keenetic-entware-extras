#!/opt/bin/sh
# Show geo-split diagnostic status.
# shellcheck disable=SC3043
# shellcheck disable=SC1091
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../../lib/common.sh"
. "$SCRIPT_DIR/../../lib/lists.sh"
_CONFIG_DIR="$(cd "$SCRIPT_DIR/../config" && pwd)"
. "$_CONFIG_DIR/config.sh"
. "$SCRIPT_DIR/../../lib/ip.sh"

STATUS_OK=0

# Show routing config and active interface(s) from route tables
show_mode() {
  echo "  Mode:"

  # Geo zone from SUBNET_URL
  local _geo_zone=""
  if [ -n "${SUBNET_URL:-}" ]; then
    _geo_zone=$(basename "$SUBNET_URL" .zone | tr 'a-z' 'A-Z')
  fi
  echo "    Geo zone:    ${_geo_zone:-unknown}"

  # Route in: configured LAN sources
  echo "    Route in:    $ROUTE_IN"

  # Route out: configured target
  if [ "${ROUTE_OUT:-auto}" = "auto" ] || [ -z "${ROUTE_OUT:-}" ]; then
    echo "    Route out:   auto (detect ISP)"
  else
    echo "    Route out:   $ROUTE_OUT"
  fi

  # Active out: ground truth from both route tables
  local active_ifaces
  active_ifaces=$( {
    ip route show table "$DOMAIN_ROUTE_TABLE" 2>/dev/null
    ip route show table "$SUBNET_ROUTE_TABLE" 2>/dev/null
  } | sed -n 's/.*dev \([^ ]*\).*/\1/p' | sort -u | tr '\n' ' ' | sed 's/ $//')

  if [ -n "$active_ifaces" ]; then
    echo "    Active out:  $active_ifaces (tables $DOMAIN_ROUTE_TABLE,$SUBNET_ROUTE_TABLE)"
  else
    echo "    Active out:  — detached"
  fi
}

# Show ip rule iif status for each ROUTE_IN interface (both tables)
show_ip_rules() {
  echo "  IP rules:"
  local iface rules_output
  rules_output=$(ip rule show)
  for iface in $ROUTE_IN; do
    if echo "$rules_output" | grep -qE "iif $iface.*lookup $DOMAIN_ROUTE_TABLE"; then
      echo "    iif $iface → table $DOMAIN_ROUTE_TABLE (domains) ✓"
    else
      echo "    iif $iface → table $DOMAIN_ROUTE_TABLE (domains) ✗"; STATUS_OK=1
    fi
    if echo "$rules_output" | grep -qE "iif $iface.*lookup $SUBNET_ROUTE_TABLE"; then
      echo "    iif $iface → table $SUBNET_ROUTE_TABLE (subnets) ✓"
    else
      echo "    iif $iface → table $SUBNET_ROUTE_TABLE (subnets) ✗"; STATUS_OK=1
    fi
  done
}

# Show route table entry counts and fill freshness (per table)
show_routes() {
  echo "  Routes:"
  local count stamp age_label

  count=$(ip route show table "$DOMAIN_ROUTE_TABLE" 2>/dev/null | wc -l)
  stamp="/opt/var/run/geo-split-table-${DOMAIN_ROUTE_TABLE}.filled"
  if [ "$count" -gt 0 ]; then
    if [ -f "$stamp" ]; then
      age_label="$(format_age "$(( $(date +%s) - $(file_mtime "$stamp") ))")"
      echo "    Domains:     $count routes in table $DOMAIN_ROUTE_TABLE, filled ${age_label} ago ✓"
    else
      echo "    Domains:     $count routes in table $DOMAIN_ROUTE_TABLE ✓"
    fi
  else
    echo "    Domains:     0 routes in table $DOMAIN_ROUTE_TABLE ✗"; STATUS_OK=1
  fi

  count=$(ip route show table "$SUBNET_ROUTE_TABLE" 2>/dev/null | wc -l)
  stamp="/opt/var/run/geo-split-table-${SUBNET_ROUTE_TABLE}.filled"
  if [ "$count" -gt 0 ]; then
    if [ -f "$stamp" ]; then
      age_label="$(format_age "$(( $(date +%s) - $(file_mtime "$stamp") ))")"
      echo "    Subnets:     $count routes in table $SUBNET_ROUTE_TABLE, filled ${age_label} ago ✓"
    else
      echo "    Subnets:     $count routes in table $SUBNET_ROUTE_TABLE ✓"
    fi
  else
    echo "    Subnets:     0 routes in table $SUBNET_ROUTE_TABLE ✗"; STATUS_OK=1
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
      echo "    Subnets:     cache ${age_label} old (max ${max_label}) ✓"
    else
      echo "    Subnets:     cache ${age_label} old (max ${max_label}) ✗ stale"; STATUS_OK=1
    fi
  else
    echo "    Subnets:     ✗ (no cache file)"; STATUS_OK=1
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
      echo "    Domains:     $count in cache, ${age_label} old (max ${max_label}) ✓"
    else
      echo "    Domains:     $count in cache, ${age_label} old (max ${max_label}) ✗ stale"; STATUS_OK=1
    fi
  else
    echo "    Domains:     ✗ (no cache file)"; STATUS_OK=1
  fi
}

# Show domain source list count (how many domains are configured)
show_domain_sources() {
  if [ -f "$DOMAINS_LIST_FILE" ]; then
    local src_count
    src_count=$(list_count_expanded "$DOMAINS_LIST_FILE") || src_count=0
    echo "  Domain sources: $src_count domain(s) configured"
  else
    echo "  Domain sources: — (no list file)"
  fi
}

# Show last successful download interface (from cache)
show_download_iface() {
  if [ -f "$LAST_IFACE_CACHE" ]; then
    local iface
    iface=$(cat "$LAST_IFACE_CACHE")
    echo "    DL iface:    $iface (cached)"
  else
    echo "    DL iface:    — (no history)"
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
    echo "    DNS:         system resolver"
  else
    echo "    DNS:         localhost:$port ($label)"
  fi
}

# Show cron job registration status
show_cron() {
  local cron_file="/opt/etc/crontab"
  if [ ! -f "$cron_file" ]; then
    echo "    Cron:        — ($cron_file missing)"; STATUS_OK=1
    return
  fi
  local count
  count=$(grep -c '^[^#]*geo-split' "$cron_file" 2>/dev/null) || count=0
  if [ "$count" -gt 0 ]; then
    echo "    Cron:        $count job(s) ✓"
  else
    echo "    Cron:        ✗ (no geo-split jobs)"; STATUS_OK=1
  fi
}

# Show NDM hook symlink status
show_ndm_hook() {
  local hook="/opt/etc/ndm/ifstatechanged.d/geo-split-hook"
  if [ -L "$hook" ]; then
    echo "    NDM hook:    $hook ✓"
  elif [ -f "$hook" ]; then
    echo "    NDM hook:    $hook (not a symlink) ✓"
  else
    echo "    NDM hook:    ✗ (missing)"; STATUS_OK=1
  fi
}

# Show installed package version
show_version() {
  local ver
  ver=$(installed_pkg_version geo-split)
  if [ -n "$ver" ]; then
    echo "    Version:     $ver"
  else
    echo "    Version:     — (not installed via opkg)"
  fi
}

# Show background update processes (if any update scripts are running)
show_background() {
  local pids
  # shellcheck disable=SC2009
  pids=$(ps 2>/dev/null | grep -E 'update-(subnets|domains)\.sh' | grep -v grep | awk '{print $1}' | tr '\n' ' ')
  if [ -n "$pids" ]; then
    echo "    Background:  update running (PIDs: ${pids})"
  else
    echo "    Background:  idle"
  fi
}

# Show service uptime from PID file written by S99geo-split start
show_uptime() {
  if [ -f "$PIDFILE" ]; then
    local age age_label
    age=$(( $(date +%s) - $(file_mtime "$PIDFILE") ))
    age_label="$(format_age "$age")"
    echo "    Uptime:      $age_label ✓"
  else
    echo "    Uptime:      — (not running)"; STATUS_OK=1
  fi
}

# Collect structured data and emit JSON for webui.
json_output() {
  local running="false" uptime_val="" version_val=""
  local domain_routes=0 subnet_routes=0 active_out="" domain_cache=0
  local geo_zone=""

  # Running: PIDFILE exists = service is attached
  if [ -f "$PIDFILE" ]; then
    running="true"
    local age
    age=$(( $(date +%s) - $(file_mtime "$PIDFILE") ))
    uptime_val="$(format_age "$age")"
  fi

  # Route counts
  domain_routes=$(ip route show table "$DOMAIN_ROUTE_TABLE" 2>/dev/null | wc -l)
  subnet_routes=$(ip route show table "$SUBNET_ROUTE_TABLE" 2>/dev/null | wc -l)

  # Active output interfaces
  active_out=$( {
    ip route show table "$DOMAIN_ROUTE_TABLE" 2>/dev/null
    ip route show table "$SUBNET_ROUTE_TABLE" 2>/dev/null
  } | sed -n 's/.*dev \([^ ]*\).*/\1/p' | sort -u | tr '\n' ' ' | sed 's/ $//')

  # Domain cache count
  if [ -n "${DOMAINS_CACHE_FILE:-}" ] && [ -f "$DOMAINS_CACHE_FILE" ]; then
    domain_cache=$(wc -l < "$DOMAINS_CACHE_FILE")
  fi

  # Geo zone from SUBNET_URL (e.g. ".../ru.zone" → "RU")
  if [ -n "${SUBNET_URL:-}" ]; then
    geo_zone=$(basename "$SUBNET_URL" .zone | tr 'a-z' 'A-Z')
  fi

  # Version
  version_val=$(installed_pkg_version geo-split)

  # Run all checks silently to set STATUS_OK
  show_ip_rules >/dev/null 2>&1 || true
  show_routes >/dev/null 2>&1 || true
  show_subnets >/dev/null 2>&1 || true
  show_domains >/dev/null 2>&1 || true

  printf '{'
  json_kv_bool "running" "$([ "$running" = "true" ] && echo 0 || echo 1)"
  printf ','
  json_kv "uptime" "$uptime_val"
  printf ','
  json_kv_bool "ok" "$STATUS_OK"
  printf ',"details":{'
  json_kv "geo_zone" "${geo_zone:-unknown}"
  printf ','
  json_kv "route_in" "$ROUTE_IN"
  printf ','
  json_kv "route_out" "${ROUTE_OUT:-auto}"
  printf ','
  json_kv "active_out" "${active_out:-detached}"
  printf ','
  json_kv_num "domain_routes" "$domain_routes"
  printf ','
  json_kv_num "subnet_routes" "$subnet_routes"
  printf ','
  json_kv_num "domain_cache" "$domain_cache"
  printf ','
  json_kv "version" "${version_val:-unknown}"
  printf '}}\n'
}

# --- main ---
if [ "${1:-}" = "--json" ]; then
  json_output
  exit "$STATUS_OK"
fi

echo "geo-split status:"
show_mode
echo
show_ip_rules
echo
show_routes
echo
echo "  Caches:"
show_subnets
show_domains
echo
show_domain_sources
echo
echo "  System:"
show_uptime
show_cron
show_ndm_hook
show_download_iface
show_dns_resolver
show_background
echo "    Loader:      $SUBNET_LOADER"
show_version

exit "$STATUS_OK"
