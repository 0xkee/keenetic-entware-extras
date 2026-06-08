#!/opt/bin/sh
# Show SmartDNS diagnostic status.
# shellcheck disable=SC1091
# shellcheck disable=SC3043  # 'local' supported by ash/busybox sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../../lib/common.sh"
. "$SCRIPT_DIR/../../lib/status.sh"
. "$SCRIPT_DIR/../../lib/geo.sh"

_CONFIG_DIR="${SCRIPT_DIR%/*}/config"
# shellcheck source=/dev/null
. "$_CONFIG_DIR/defaults.conf"
[ -f "$_CONFIG_DIR/config.conf" ] && . "$_CONFIG_DIR/config.conf"

STATUS_OK=0
_st_pid=""
_st_pid_source=""
_st_running="false"
_st_mem_kb="0"
_st_uptime_seconds=0
_st_port_ok="false"
_st_port_addrs=""
_st_version=""

# --- Check functions (specific to this service) ---

# Check config file: servers count and rules count.
# Sets: _ck_config_ok ("true"|"false"), _ck_servers, _ck_rules
check_config() {
  _ck_config_ok="false"
  _ck_servers=0
  _ck_rules=0
  if [ -f "$CONF" ]; then
    _ck_config_ok="true"
    # Count across main conf + all included files in SMARTDNS_CONF_DIR
    _ck_servers="$(grep -rch '^server' "$SMARTDNS_CONF_DIR"/ 2>/dev/null | awk '{s+=$1}END{print s+0}')"
    _ck_rules="$(grep -rch '^nameserver' "$SMARTDNS_CONF_DIR"/ 2>/dev/null | awk '{s+=$1}END{print s+0}')"
  fi
}

# Check persistent cache file.
# Sets: _ck_cache_size (du -h output), _ck_cache_kb (numeric kB for JSON)
check_cache() {
  _ck_cache_size=""
  _ck_cache_kb=""
  if [ -f "$CACHE_FILE" ]; then
    _ck_cache_size="$(du -h "$CACHE_FILE" 2>/dev/null | awk '{print $1}')"
    _ck_cache_kb="$(du -k "$CACHE_FILE" 2>/dev/null | awk '{print $1}')"
  fi
}

# Check split-DNS enabled state.
# Sets: _ck_enabled ("true"|"false"), _ck_zone, _ck_active_zones, _ck_other_ifaces
check_enabled() {
  _ck_enabled="false"
  _ck_zone="${DNS_ZONE:-ru}"
  _ck_active_zones=""
  _ck_other_ifaces="${OTHER_DNS_INTERFACES:-}"
  if [ -f "$STATE_FILE" ]; then
    _ck_enabled="true"
  fi
  _ck_active_zones="$(resolve_geo_zone "$_ck_zone")"
}

# --- Show functions (text, use lib + local checks) ---

show_config() {
  if [ "$_ck_config_ok" = "true" ]; then
    echo "    Config:      $CONF ($_ck_servers servers, $_ck_rules rules) ✓"
  else
    echo "    Config:      NOT found ✗"; STATUS_OK=1
  fi
}

show_cache() {
  if [ -n "$_ck_cache_size" ]; then
    echo "    Cache:       $_ck_cache_size ($CACHE_FILE) ✓"
  else
    echo "    Cache:       not found"
  fi
}

# Show listening ports (custom text for "none listening" case).
show_ports() {
  if [ "$_st_port_ok" = "true" ]; then
    local first=1
    echo "$_st_port_addrs" | tr ' ' '\n' | while IFS= read -r addr; do
      [ -z "$addr" ] && continue
      if [ "$first" = 1 ]; then
        echo "    Ports:       $addr ✓"
        first=0
      else
        echo "                 $addr ✓"
      fi
    done
  else
    echo "    Ports:       none listening ✗"; STATUS_OK=1
  fi
}

# Run a single DNS test via main SmartDNS port.
# Usage: dns_test <domain> <group_label>
dns_test() {
  local domain="$1" label="$2"
  local result ip_line
  result="$(dig +short +time=3 "$domain" @127.0.0.1 -p "$SMARTDNS_PORT" 2>/dev/null || echo "FAILED")"
  # dig +short may return multiple lines; take first A-record
  ip_line="$(echo "$result" | head -1)"
  if [ -n "$ip_line" ] && [ "$ip_line" != "FAILED" ]; then
    printf "    %-14s %s (%s) ✓\\n" "${domain}:" "$ip_line" "$label"
  else
    printf "    %-14s FAILED (%s) ✗\\n" "${domain}:" "$label"
    STATUS_OK=1
  fi
}

# Run DNS resolution tests (requires dig).
# Dynamic: tests first domain from each active zone + international.
show_dns_tests() {
  if ! command -v dig >/dev/null 2>&1; then
    echo "    DNS test:    skipped (dig not available)"
    return
  fi
  # Source test domains
  local test_domains_file="$_CONFIG_DIR/zones/test-domains.conf"
  if [ -f "$test_domains_file" ]; then
    # shellcheck source=/dev/null
    . "$test_domains_file"
  fi
  # Test each active zone (first domain only)
  if [ "$_ck_enabled" = "true" ]; then
    for cc in $_ck_active_zones; do
      local var_name="TEST_DOMAINS_${cc}"
      eval "local domains=\"\${${var_name}:-}\""
      if [ -n "$domains" ]; then
        local first_domain="${domains%% *}"
        dns_test "$first_domain" "${cc}-group"
      fi
    done
  fi
  # International (always)
  local intl_domains="${TEST_DOMAINS_other:-google.com}"
  local intl_first="${intl_domains%% *}"
  dns_test "$intl_first" "default-group"
}

# --- JSON output ---

# Run DNS tests and collect results for JSON.
# Sets: _json_dns_tests (JSON array string)
collect_dns_tests_json() {
  _json_dns_tests="["
  local first=1
  if ! command -v dig >/dev/null 2>&1; then
    _json_dns_tests="[]"
    return
  fi
  # Source test domains
  local test_domains_file="$_CONFIG_DIR/zones/test-domains.conf"
  if [ -f "$test_domains_file" ]; then
    # shellcheck source=/dev/null
    . "$test_domains_file"
  fi
  # Zone domains
  if [ "$_ck_enabled" = "true" ]; then
    for cc in $_ck_active_zones; do
      local var_name="TEST_DOMAINS_${cc}"
      eval "local domains=\"\${${var_name}:-}\""
      if [ -n "$domains" ]; then
        local d="${domains%% *}"
        local r
        r="$(dig +short +time=3 "$d" @127.0.0.1 -p "$SMARTDNS_PORT" 2>/dev/null | head -1 || true)"
        [ "$first" -eq 0 ] && _json_dns_tests="${_json_dns_tests},"
        _json_dns_tests="${_json_dns_tests}{\"domain\":\"$d\",\"group\":\"${cc}\",\"result\":\"${r:-FAILED}\"}"
        first=0
      fi
    done
  fi
  # International
  local intl_d="${TEST_DOMAINS_other:-google.com}"
  intl_d="${intl_d%% *}"
  local intl_r
  intl_r="$(dig +short +time=3 "$intl_d" @127.0.0.1 -p "$SMARTDNS_PORT" 2>/dev/null | head -1 || true)"
  [ "$first" -eq 0 ] && _json_dns_tests="${_json_dns_tests},"
  _json_dns_tests="${_json_dns_tests}{\"domain\":\"$intl_d\",\"group\":\"other\",\"result\":\"${intl_r:-FAILED}\"}"
  _json_dns_tests="${_json_dns_tests}]"
}

json_output() {
  printf '{'
  json_kv_bool "running" "$([ "$_st_running" = "true" ] && echo 0 || echo 1)"
  printf ','
  json_kv_bool "enabled" "$([ "$_ck_enabled" = "true" ] && echo 0 || echo 1)"
  printf ','
  json_kv_bool "ok" "$STATUS_OK"
  printf ',"details":{'
  json_kv "dns_zone" "$_ck_zone"
  printf ','
  json_kv "active_zones" "$_ck_active_zones"
  printf ','
  json_kv "other_interfaces" "$_ck_other_ifaces"
  printf ','
  json_kv "ports" "$_st_port_addrs"
  printf ','
  json_kv_num "servers" "$_ck_servers"
  printf ','
  json_kv_num "rules" "$_ck_rules"
  printf ','
  json_kv "cache" "$([ -n "$_ck_cache_kb" ] && format_size_kb "$_ck_cache_kb" || printf 'none')"
  printf ','
  json_kv "memory" "$([ "$_st_running" = "true" ] && [ "$_st_mem_kb" != "0" ] && format_size_kb "$_st_mem_kb" || printf '')"
  printf ','
  json_kv "pid" "$_st_pid"
  printf ','
  json_kv_num "uptime" "$_st_uptime_seconds"
  printf ','
  json_kv "version" "${_st_version:-unknown}"
  printf '},'

  # DNS tests array
  printf '"dns_tests":%s,' "$_json_dns_tests"

  # Checks section: "ok"|"warn"|"fail" per field
  printf '"checks":{'
  json_check "process" "$(if [ "$_st_running" = "true" ]; then printf ok; else printf fail; fi)"
  printf ','
  json_check "ports" "$(if [ "$_st_port_ok" = "true" ]; then printf ok; else printf fail; fi)"
  printf ','
  json_check "config" "$(if [ "$_ck_config_ok" = "true" ]; then printf ok; else printf fail; fi)"
  printf '}}\n'
}

# --- main ---

# Run all checks (data collection, no output)
status_detect_pid "$PIDFILE" "smartdns"
status_check_process
status_check_uptime "$PIDFILE"
status_check_port "" "any" "smartdns"
status_check_version "smartdns-geo-conf"
check_config
check_cache
check_enabled

# Set STATUS_OK based on critical checks
[ "$_st_running" = "false" ] && STATUS_OK=1
[ "$_st_port_ok" = "false" ] && STATUS_OK=1
[ "$_ck_config_ok" = "false" ] && STATUS_OK=1

if [ "${1:-}" = "--json" ]; then
  # Collect DNS test results for JSON
  collect_dns_tests_json
  json_output
  exit "$STATUS_OK"
fi

# Determine status word for title line
# Note: smartdns init (S38smartdns) is a regular file from opkg, not our symlink;
# this package has no standalone "disabled" state — it's always either running or failed.
_status_word="✓ Alive"
if [ "$STATUS_OK" -ne 0 ]; then
  _status_word="✗ Fail"
fi

echo "smartdns-geo-conf status: $_status_word"

echo "  Service:"
if [ "$_ck_enabled" = "true" ]; then
  echo "    Mode:        split-DNS (enabled) ✓"
  echo "    Zone:        $_ck_zone → [$_ck_active_zones]"
  if [ -n "$_ck_other_ifaces" ]; then
    echo "    Other: $_ck_other_ifaces"
  fi
else
  echo "    Mode:        default (simple forwarder)"
fi
status_show_process
show_ports
show_config
show_cache
echo
echo "  System:"
status_show_uptime
status_show_version
echo
echo "  DNS Tests:"
show_dns_tests

exit "$STATUS_OK"
