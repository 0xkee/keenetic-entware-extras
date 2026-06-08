#!/opt/bin/sh
# Show geo-split diagnostic status.
# shellcheck disable=SC1091
# shellcheck disable=SC3043
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../../lib/common.sh"
. "$SCRIPT_DIR/../../lib/status.sh"
. "$SCRIPT_DIR/../../lib/lists.sh"
. "$SCRIPT_DIR/../../lib/ip.sh"
. "$SCRIPT_DIR/../../lib/geo.sh"
_CONFIG_DIR="$(cd "$SCRIPT_DIR/../config" && pwd)"
. "$_CONFIG_DIR/defaults.conf"
[ -f "$_CONFIG_DIR/config.conf" ] && . "$_CONFIG_DIR/config.conf"

STATUS_OK=0
_st_uptime_seconds=0
_st_version=""

# --- Check functions ---
# Pure data collection. May set STATUS_OK=1 on failures.

# Sets: _ck_geo_zone, _ck_active_zones, _ck_active_out, _ck_gateway
check_mode() {
  _ck_geo_zone="${GEO_ZONE:-ru}"
  _ck_active_zones="$(resolve_geo_zone "$_ck_geo_zone")"
  _ck_gateway=""
  # head -5: all routes in a table share the same dev (filled by fill_routes_batch),
  # so a few lines suffice to extract unique interface names (~11K → 10 lines).
  _ck_active_out=$( {
    ip route show table "$DOMAIN_ROUTE_TABLE" 2>/dev/null | head -5
    ip route show table "$SUBNET_ROUTE_TABLE" 2>/dev/null | head -5
  } | sed -n 's/.*dev \([^ ]*\).*/\1/p' | sort -u | tr '\n' ' ' | sed 's/ $//')
  # Gateway: extract "via <IP>" from first route, or "scope link" if none
  local _gw_ip
  _gw_ip=$(ip route show table "$SUBNET_ROUTE_TABLE" 2>/dev/null | \
    awk '/via /{for(i=1;i<=NF;i++)if($i=="via"){print $(i+1);exit}}')
  if [ -n "$_gw_ip" ]; then
    _ck_gateway="via $_gw_ip"
  elif [ -n "$_ck_active_out" ]; then
    _ck_gateway="scope link"
  fi
}

# Sets: _ck_rules_detail (newline-separated, "!" prefix for failed)
check_ip_rules() {
  local _iface _rules_out _pfx
  _ck_rules_detail=""
  _rules_out=$(ip rule show 2>/dev/null) || _rules_out=""
  for _iface in $ROUTE_IN; do
    _pfx=""
    if ! echo "$_rules_out" | grep -qE "iif $_iface.*lookup $DOMAIN_ROUTE_TABLE"; then
      _pfx="!"; STATUS_OK=1
    fi
    _ck_rules_detail="${_ck_rules_detail:+${_ck_rules_detail}
}${_pfx}${_iface}: #${DOMAIN_ROUTE_TABLE} domains"
    _pfx=""
    if ! echo "$_rules_out" | grep -qE "iif $_iface.*lookup $SUBNET_ROUTE_TABLE"; then
      _pfx="!"; STATUS_OK=1
    fi
    _ck_rules_detail="${_ck_rules_detail}
${_pfx}${_iface}: #${SUBNET_ROUTE_TABLE} subnets"
  done
}

# Sets: _ck_domain_routes, _ck_subnet_routes
check_routes() {
  _ck_domain_routes=$(table_route_count "$DOMAIN_ROUTE_TABLE")
  _ck_subnet_routes=$(table_route_count "$SUBNET_ROUTE_TABLE")
  [ "$_ck_domain_routes" -gt 0 ] || STATUS_OK=1
  [ "$_ck_subnet_routes" -gt 0 ] || STATUS_OK=1
}

# Sets: _ck_subnet_freshness_seconds, _ck_subnet_fresh (true/false)
check_subnets() {
  _ck_subnet_freshness_seconds=0
  _ck_subnet_fresh="false"
  if [ -f "$SUBNET_LIST_FILE" ]; then
    _ck_subnet_freshness_seconds=$(( $(date +%s) - $(file_mtime "$SUBNET_LIST_FILE") ))
    if [ "$_ck_subnet_freshness_seconds" -lt "$MAX_CACHE_AGE" ]; then
      _ck_subnet_fresh="true"
    else
      STATUS_OK=1
    fi
  else
    STATUS_OK=1
  fi
}

# Sets: _ck_domain_cache, _ck_domain_freshness_seconds, _ck_domain_fresh (true/false)
check_domains() {
  _ck_domain_cache=0
  _ck_domain_freshness_seconds=0
  _ck_domain_fresh="false"
  [ -n "${DOMAINS_CACHE_FILE:-}" ] && [ -n "${DOMAINS_LIST_FILE:-}" ] || return 0
  if [ -f "$DOMAINS_CACHE_FILE" ]; then
    local interval="${DOMAINS_UPDATE_INTERVAL:-3600}"
    _ck_domain_cache=$(wc -l < "$DOMAINS_CACHE_FILE")
    _ck_domain_freshness_seconds=$(( $(date +%s) - $(file_mtime "$DOMAINS_CACHE_FILE") ))
    if [ "$_ck_domain_freshness_seconds" -lt "$interval" ]; then
      _ck_domain_fresh="true"
    else
      STATUS_OK=1
    fi
  else
    STATUS_OK=1
  fi
}

# Sets: _ck_domain_sources
check_domain_sources() {
  _ck_domain_sources=0
  if [ -n "${DOMAINS_LIST_FILE:-}" ] && [ -f "$DOMAINS_LIST_FILE" ]; then
    _ck_domain_sources=$(list_count_expanded "$DOMAINS_LIST_FILE") || _ck_domain_sources=0
  fi
}

# Sets: _ck_cron_ok (0=ok, 1=fail), _ck_cron_count, _ck_cron_shift
check_cron() {
  _ck_cron_ok=1
  _ck_cron_count=0
  _ck_cron_shift=""
  if [ -f "/opt/etc/crontab" ]; then
    _ck_cron_count=$(grep -c '^[^#]*geo-split' /opt/etc/crontab 2>/dev/null) || _ck_cron_count=0
    if [ "$_ck_cron_count" -gt 0 ]; then
      _ck_cron_ok=0
      # Extract offset from "N-59/15" minute field (N = shift)
      _ck_cron_shift=$(grep '^[^#]*geo-split' /opt/etc/crontab 2>/dev/null | head -1 | awk '{split($1,a,"-"); print a[1]}')
    else
      STATUS_OK=1
    fi
  else
    STATUS_OK=1
  fi
}

# Sets: _ck_ndm_hook_ok (0=ok, 1=fail), _ck_ndm_hook_type (symlink|file|missing)
check_ndm_hook() {
  local hook="/opt/etc/ndm/ifstatechanged.d/geo-split-hook"
  _ck_ndm_hook_ok=1
  _ck_ndm_hook_type="missing"
  if [ -L "$hook" ]; then
    _ck_ndm_hook_ok=0; _ck_ndm_hook_type="symlink"
  elif [ -f "$hook" ]; then
    _ck_ndm_hook_ok=0; _ck_ndm_hook_type="file"
  else
    STATUS_OK=1
  fi
}

# Sets: _ck_dl_iface
check_download_iface() {
  _ck_dl_iface=""
  if [ -f "$LAST_IFACE_CACHE" ]; then
    _ck_dl_iface=$(cat "$LAST_IFACE_CACHE")
  fi
}

# Sets: _ck_dns_resolver
check_dns_resolver() {
  local result port label
  _ck_dns_resolver="system resolver"
  result=$(detect_dns_port)
  port="${result%% *}"
  label="${result#* }"
  if [ "$port" != "0" ]; then
    _ck_dns_resolver="localhost:${port} (${label})"
  fi
}

# Sets: _ck_bg_status ("idle"|"running"), _ck_bg_pids
check_background() {
  _ck_bg_status="idle"
  _ck_bg_pids=""
  # shellcheck disable=SC2009
  _ck_bg_pids=$(ps w 2>/dev/null | grep -E 'update-(subnets|domains)\.sh' | grep -v grep | awk '{print $1}' | tr '\n' ' ')
  if [ -n "$_ck_bg_pids" ]; then
    _ck_bg_status="running"
  fi
}

# --- Show functions (text) ---

show_mode() {
  check_mode
  echo "  Mode:"
  echo "    Geo zone:    $_ck_geo_zone → [$_ck_active_zones]"
  echo "    Route in:    $ROUTE_IN"
  if [ "${ROUTE_OUT:-auto}" = "auto" ] || [ -z "${ROUTE_OUT:-}" ]; then
    echo "    Route out:   auto (detect ISP)"
  else
    echo "    Route out:   $ROUTE_OUT"
  fi
  if [ -n "$_ck_active_out" ]; then
    echo "    Active out:  $_ck_active_out (tables $DOMAIN_ROUTE_TABLE,$SUBNET_ROUTE_TABLE)"
    # Show gateway from first route in subnet table (if present)
    local _active_gw
    _active_gw=$(ip route show table "$SUBNET_ROUTE_TABLE" 2>/dev/null | \
      awk '/via /{for(i=1;i<=NF;i++)if($i=="via"){print $(i+1);exit}}')
    if [ -n "$_active_gw" ]; then
      echo "    Gateway:     $_active_gw"
    else
      echo "    Gateway:     — (dev-only, scope link)"
    fi
  else
    echo "    Active out:  — detached"
  fi
}

show_ip_rules() {
  check_ip_rules
  echo "  IP rules:"
  local line _iface _tbl_desc _mark
  echo "$_ck_rules_detail" | while IFS= read -r line; do
    [ -z "$line" ] && continue
    if echo "$line" | grep -q '^!'; then
      line="${line#!}"; _mark="✗"
    else
      _mark="✓"
    fi
    _iface="${line%%:*}"
    _tbl_desc="${line#*: #}"
    echo "    iif $_iface → table ${_tbl_desc%% *} (${_tbl_desc#* }) $_mark"
  done
}

show_routes() {
  check_routes
  echo "  Routes:"
  local stamp age_label

  stamp="${TABLE_STAMP_PREFIX}${DOMAIN_ROUTE_TABLE}.filled"
  if [ "$_ck_domain_routes" -gt 0 ]; then
    if [ -f "$stamp" ]; then
      age_label="$(format_age "$(( $(date +%s) - $(file_mtime "$stamp") ))")"
      echo "    Domains:     $_ck_domain_routes routes in table $DOMAIN_ROUTE_TABLE, filled ${age_label} ago ✓"
    else
      echo "    Domains:     $_ck_domain_routes routes in table $DOMAIN_ROUTE_TABLE ✓"
    fi
  else
    echo "    Domains:     0 routes in table $DOMAIN_ROUTE_TABLE ✗"
  fi

  stamp="${TABLE_STAMP_PREFIX}${SUBNET_ROUTE_TABLE}.filled"
  if [ "$_ck_subnet_routes" -gt 0 ]; then
    if [ -f "$stamp" ]; then
      age_label="$(format_age "$(( $(date +%s) - $(file_mtime "$stamp") ))")"
      echo "    Subnets:     $_ck_subnet_routes routes in table $SUBNET_ROUTE_TABLE, filled ${age_label} ago ✓"
    else
      echo "    Subnets:     $_ck_subnet_routes routes in table $SUBNET_ROUTE_TABLE ✓"
    fi
  else
    echo "    Subnets:     0 routes in table $SUBNET_ROUTE_TABLE ✗"
  fi
}

show_subnets() {
  check_subnets
  if [ -f "$SUBNET_LIST_FILE" ]; then
    local age_label max_label
    age_label="$(format_age "$_ck_subnet_freshness_seconds")"
    max_label="$(format_age "$MAX_CACHE_AGE")"
    if [ "$_ck_subnet_fresh" = "true" ]; then
      echo "    Subnets:     cache ${age_label} old (max ${max_label}) ✓"
    else
      echo "    Subnets:     cache ${age_label} old (max ${max_label}) ✗ stale"
    fi
  else
    echo "    Subnets:     ✗ (no cache file)"
  fi
}

show_domains() {
  check_domains
  [ -n "${DOMAINS_CACHE_FILE:-}" ] && [ -n "${DOMAINS_LIST_FILE:-}" ] || return 0
  if [ -f "$DOMAINS_CACHE_FILE" ]; then
    local age_label max_label
    local interval="${DOMAINS_UPDATE_INTERVAL:-3600}"
    age_label="$(format_age "$_ck_domain_freshness_seconds")"
    max_label="$(format_age "$interval")"
    if [ "$_ck_domain_fresh" = "true" ]; then
      echo "    Domains:     $_ck_domain_cache in cache, ${age_label} old (max ${max_label}) ✓"
    else
      echo "    Domains:     $_ck_domain_cache in cache, ${age_label} old (max ${max_label}) ✗ stale"
    fi
  else
    echo "    Domains:     ✗ (no cache file)"
  fi
}

show_domain_sources() {
  check_domain_sources
  if [ -f "${DOMAINS_LIST_FILE:-}" ]; then
    echo "  Domain sources: $_ck_domain_sources domain(s) configured"
  else
    echo "  Domain sources: — (no list file)"
  fi
}

show_cron() {
  check_cron
  if [ ! -f "/opt/etc/crontab" ]; then
    echo "    Cron:        — (/opt/etc/crontab missing)"
    return
  fi
  if [ "$_ck_cron_count" -gt 0 ]; then
    local _shift_info=""
    [ -n "$_ck_cron_shift" ] && _shift_info=" (shift ${_ck_cron_shift}m)"
    echo "    Cron:        $_ck_cron_count job(s)${_shift_info} ✓"
  else
    echo "    Cron:        ✗ (no geo-split jobs)"
  fi
}

show_ndm_hook() {
  check_ndm_hook
  local hook="/opt/etc/ndm/ifstatechanged.d/geo-split-hook"
  case "$_ck_ndm_hook_type" in
    symlink) echo "    NDM hook:    $hook ✓" ;;
    file)    echo "    NDM hook:    $hook (not a symlink) ✓" ;;
    *)       echo "    NDM hook:    ✗ (missing)" ;;
  esac
}

show_download_iface() {
  check_download_iface
  if [ -n "$_ck_dl_iface" ]; then
    echo "    DL iface:    $_ck_dl_iface (cached)"
  else
    echo "    DL iface:    — (no history)"
  fi
}

show_dns_resolver() {
  check_dns_resolver
  echo "    DNS:         $_ck_dns_resolver"
}

show_background() {
  check_background
  if [ "$_ck_bg_status" = "running" ]; then
    echo "    Background:  update running (PIDs: ${_ck_bg_pids})"
  else
    echo "    Background:  idle"
  fi
}

show_uptime() {
  status_check_uptime "$PIDFILE"
  if [ "$_st_uptime_seconds" -gt 0 ] 2>/dev/null; then
    echo "    Uptime:      $(format_age "$_st_uptime_seconds") ✓"
  else
    echo "    Uptime:      — (not running)"; STATUS_OK=1
  fi
}

show_version() {
  status_check_version "geo-split"
  if [ -n "$_st_version" ]; then
    echo "    Version:     $_st_version"
  else
    echo "    Version:     — (not installed via opkg)"
  fi
}

# --- JSON output ---

json_output() {
  # Run all checks once
  check_mode
  check_ip_rules
  check_routes
  check_subnets
  check_domains
  check_domain_sources
  check_cron
  check_ndm_hook
  check_download_iface
  check_dns_resolver
  check_background
  status_check_uptime "$PIDFILE"
  status_check_version "geo-split"

  # Running: PIDFILE exists = service is attached
  local running="false"
  [ -f "$PIDFILE" ] && running="true" || true

  # STATUS_OK already set by check functions above

  # Enabled: symlink exists in /opt/etc/init.d/
  local enabled_val=1
  is_service_enabled "S99geo-split" && enabled_val=0

  printf '{'
  json_kv_bool "enabled" "$enabled_val"
  printf ','
  json_kv_bool "running" "$([ "$running" = "true" ] && echo 0 || echo 1)"
  printf ','
  json_kv_bool "ok" "$STATUS_OK"
  printf ',"details":{'
  # Zone
  json_kv "geo_zone" "$_ck_geo_zone"
  printf ','
  json_kv "active_zones" "$_ck_active_zones"
  printf ','
  json_kv "zone_loader" "${SUBNET_LOADER}${_ck_dl_iface:+ via $_ck_dl_iface}"
  printf ','
  # Routing
  json_kv "route_in" "$ROUTE_IN"
  printf ','
  if [ "${ROUTE_OUT:-auto}" = "auto" ] && [ -n "$_ck_active_out" ] && [ "$_ck_active_out" != "detached" ]; then
    json_kv "route_out" "${_ck_active_out} (auto)"
  else
    json_kv "route_out" "${_ck_active_out:-detached}"
  fi
  printf ','
  json_kv "gateway" "${_ck_gateway:-none}"
  printf ','
  # Data
  json_kv_num "subnets" "$_ck_subnet_routes"
  printf ','
  json_kv_num "domains" "$_ck_domain_routes"
  printf ','
  json_kv "rules" "$_ck_rules_detail"
  printf ','
  json_kv_num "subnet_freshness" "$_ck_subnet_freshness_seconds"
  printf ','
  json_kv_num "domain_freshness" "$_ck_domain_freshness_seconds"
  printf ','
  json_kv_num "domain_sources" "$_ck_domain_sources"
  printf ','
  json_kv_num "domain_cache" "$_ck_domain_cache"
  printf ','
  # Infrastructure
  json_kv "dns_resolver" "$_ck_dns_resolver"
  printf ','
  # System
  json_kv_bool "ndm_hook" "$_ck_ndm_hook_ok"
  printf ','
  json_kv_bool "cron" "$_ck_cron_ok"
  printf ','
  json_kv "background" "$_ck_bg_status"
  printf ','
  json_kv_num "uptime" "$_st_uptime_seconds"
  printf ','
  json_kv "version" "${_st_version:-unknown}"
  printf '},'

  # Checks section: "ok"|"warn"|"fail" per field
  local _sf_status _df_status _r_status
  printf '"checks":{'
  json_check "cron" "$(if [ "$_ck_cron_ok" = 0 ]; then printf ok; else printf fail; fi)"
  printf ','
  json_check "ndm_hook" "$(if [ "$_ck_ndm_hook_ok" = 0 ]; then printf ok; else printf fail; fi)"
  printf ','
  json_check "subnets" "$(if [ "$_ck_subnet_routes" -gt 0 ]; then printf ok; else printf fail; fi)"
  printf ','
  json_check "domains" "$(if [ "$_ck_domain_routes" -gt 0 ]; then printf ok; else printf fail; fi)"
  printf ','
  if [ ! -f "$SUBNET_LIST_FILE" ]; then
    _sf_status="fail"
  elif is_cache_fresh "$SUBNET_LIST_FILE" "$MAX_CACHE_AGE"; then
    _sf_status="ok"
  else
    _sf_status="warn"
  fi
  json_check "subnet_freshness" "$_sf_status"
  printf ','
  if [ -z "${DOMAINS_CACHE_FILE:-}" ] || [ ! -f "$DOMAINS_CACHE_FILE" ]; then
    _df_status="fail"
  elif is_cache_fresh "$DOMAINS_CACHE_FILE" "${DOMAINS_UPDATE_INTERVAL:-3600}"; then
    _df_status="ok"
  else
    _df_status="warn"
  fi
  json_check "domain_freshness" "$_df_status"
  printf ','
  if echo "$_ck_rules_detail" | grep -q '^!'; then
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

# Pre-compute status word for title line
_status_word="✓ Alive"
if ! is_service_enabled "S99geo-split"; then
  _status_word="⚠ Disabled"
else
  # Quick core checks (show functions may re-run, harmless)
  check_ip_rules
  check_routes
  status_check_uptime "$PIDFILE"
  if [ "$STATUS_OK" -ne 0 ]; then
    _status_word="✗ Fail"
  fi
fi

echo "geo-split status: $_status_word"

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
