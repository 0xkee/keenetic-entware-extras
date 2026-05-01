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
    _geo_zone=$(basename "$SUBNET_URL" .zone | tr '[:lower:]' '[:upper:]')
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
  pids=$(ps w 2>/dev/null | grep -E 'update-(subnets|domains)\.sh' | grep -v grep | awk '{print $1}' | tr '\n' ' ')
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
  local running="false" version_val=""
  local domain_routes=0 subnet_routes=0 active_out="" domain_cache=0
  local geo_zone=""

  # Running: PIDFILE exists = service is attached
  if [ -f "$PIDFILE" ]; then
    running="true"
    local age
    age=$(( $(date +%s) - $(file_mtime "$PIDFILE") ))
    uptime_seconds_val="$age"
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
    geo_zone=$(basename "$SUBNET_URL" .zone | tr '[:lower:]' '[:upper:]')
  fi

  # Version
  version_val=$(installed_pkg_version geo-split)

  # IP rules: newline-separated, "!" prefix marks failed lines (for red in UI)
  # e.g. "br0: #1000 domains\nbr0: #1001 subnets" or "!br0: #1000 domains"
  local rules_detail="" _iface _rules_out _pfx
  _rules_out=$(ip rule show 2>/dev/null) || _rules_out=""
  for _iface in $ROUTE_IN; do
    _pfx=""
    echo "$_rules_out" | grep -qE "iif $_iface.*lookup $DOMAIN_ROUTE_TABLE" || _pfx="!"
    rules_detail="${rules_detail:+${rules_detail}
}${_pfx}${_iface}: #${DOMAIN_ROUTE_TABLE} domains"
    _pfx=""
    echo "$_rules_out" | grep -qE "iif $_iface.*lookup $SUBNET_ROUTE_TABLE" || _pfx="!"
    rules_detail="${rules_detail}
${_pfx}${_iface}: #${SUBNET_ROUTE_TABLE} subnets"
  done

  # Subnet cache freshness (seconds)
  local subnet_freshness_seconds=0
  if [ -f "$SUBNET_LIST_FILE" ]; then
    subnet_freshness_seconds=$(( $(date +%s) - $(file_mtime "$SUBNET_LIST_FILE") ))
  fi

  # Domain cache freshness (seconds)
  local domain_freshness_seconds=0
  if [ -n "${DOMAINS_CACHE_FILE:-}" ] && [ -f "$DOMAINS_CACHE_FILE" ]; then
    domain_freshness_seconds=$(( $(date +%s) - $(file_mtime "$DOMAINS_CACHE_FILE") ))
  fi

  # Domain sources count (expanded with @includes)
  local domain_sources=0
  if [ -n "${DOMAINS_LIST_FILE:-}" ] && [ -f "$DOMAINS_LIST_FILE" ]; then
    domain_sources=$(list_count_expanded "$DOMAINS_LIST_FILE") || domain_sources=0
  fi

  # Cron check: any geo-split jobs in crontab
  local cron_ok_val=1
  if [ -f "/opt/etc/crontab" ]; then
    grep -q '^[^#]*geo-split' /opt/etc/crontab 2>/dev/null && cron_ok_val=0
  fi

  # NDM hook presence
  local ndm_hook_ok_val=1
  [ -f "/opt/etc/ndm/ifstatechanged.d/geo-split-hook" ] && ndm_hook_ok_val=0

  # Last download interface
  local dl_iface=""
  if [ -f "$LAST_IFACE_CACHE" ]; then
    dl_iface=$(cat "$LAST_IFACE_CACHE")
  fi

  # DNS resolver detection
  local dns_resolver="system resolver"
  if command -v dig >/dev/null 2>&1; then
    local dns_result dns_port dns_label
    dns_result=$(detect_dns_port)
    dns_port="${dns_result%% *}"
    dns_label="${dns_result#* }"
    if [ "$dns_port" != "0" ]; then
      dns_resolver="localhost:${dns_port} (${dns_label})"
    fi
  fi

  # Background update processes
  local bg_status="idle"
  # shellcheck disable=SC2009
  if ps w 2>/dev/null | grep -E 'update-(subnets|domains)\.sh' | grep -qv grep; then
    bg_status="running"
  fi

  # Run all checks silently to set STATUS_OK
  show_ip_rules >/dev/null 2>&1 || true
  show_routes >/dev/null 2>&1 || true
  show_subnets >/dev/null 2>&1 || true
  show_domains >/dev/null 2>&1 || true

  printf '{'
  json_kv_bool "running" "$([ "$running" = "true" ] && echo 0 || echo 1)"
  printf ','
  json_kv_bool "ok" "$STATUS_OK"
  printf ',"details":{'
  json_kv "geo_zone" "${geo_zone:-unknown}"
  printf ','
  json_kv "zone_loader" "${SUBNET_LOADER}${dl_iface:+ via $dl_iface}"
  printf ','
  json_kv_bool "cron" "$cron_ok_val"
  printf ','
  json_kv "route_in" "$ROUTE_IN"
  printf ','
  # Combine route_out + active_out: "lte_br1 (auto)" when auto-resolved
  if [ "${ROUTE_OUT:-auto}" = "auto" ] && [ -n "$active_out" ] && [ "$active_out" != "detached" ]; then
    json_kv "route_out" "${active_out} (auto)"
  else
    json_kv "route_out" "${active_out:-detached}"
  fi
  printf ','
  json_kv_bool "ndm_hook" "$ndm_hook_ok_val"
  printf ','
  json_kv_num "subnets" "$subnet_routes"
  printf ','
  json_kv_num "domains" "$domain_routes"
  printf ','
  json_kv "rules" "$rules_detail"
  printf ','
  json_kv_num "subnet_freshness" "$subnet_freshness_seconds"
  printf ','
  json_kv_num "domain_freshness" "$domain_freshness_seconds"
  printf ','
  json_kv "_s1" ""
  printf ','
  json_kv_num "domain_sources" "$domain_sources"
  printf ','
  json_kv_num "domain_cache" "$domain_cache"
  printf ','
  json_kv "dns_resolver" "$dns_resolver"
  printf ','
  json_kv "background" "$bg_status"
  printf ','
  json_kv_num "uptime" "${uptime_seconds_val:-0}"
  printf ','
  json_kv "version" "${version_val:-unknown}"
  printf '},'

  # Checks section: "ok"|"warn"|"fail" per field
  printf '"checks":{'
  json_check "cron" "$(if [ "$cron_ok_val" = 0 ]; then printf ok; else printf fail; fi)"
  printf ','
  json_check "ndm_hook" "$(if [ "$ndm_hook_ok_val" = 0 ]; then printf ok; else printf fail; fi)"
  printf ','
  json_check "subnets" "$(if [ "$subnet_routes" -gt 0 ]; then printf ok; else printf fail; fi)"
  printf ','
  json_check "domains" "$(if [ "$domain_routes" -gt 0 ]; then printf ok; else printf fail; fi)"
  printf ','
  # subnet_freshness: file missing=fail, stale=warn, fresh=ok
  if [ ! -f "$SUBNET_LIST_FILE" ]; then
    _sf_status="fail"
  elif is_cache_fresh "$SUBNET_LIST_FILE" "$MAX_CACHE_AGE"; then
    _sf_status="ok"
  else
    _sf_status="warn"
  fi
  json_check "subnet_freshness" "$_sf_status"
  printf ','
  # domain_freshness: file missing=fail, stale=warn, fresh=ok
  if [ -z "${DOMAINS_CACHE_FILE:-}" ] || [ ! -f "$DOMAINS_CACHE_FILE" ]; then
    _df_status="fail"
  elif is_cache_fresh "$DOMAINS_CACHE_FILE" "${DOMAINS_UPDATE_INTERVAL:-3600}"; then
    _df_status="ok"
  else
    _df_status="warn"
  fi
  json_check "domain_freshness" "$_df_status"
  printf ','
  # rules: any "!" prefix in rules_detail means failure
  if echo "$rules_detail" | grep -q '^!'; then
    _r_status="fail"
  else
    _r_status="ok"
  fi
  json_check "rules" "$_r_status"
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
