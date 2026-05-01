#!/opt/bin/sh
# Show SmartDNS diagnostic status.
# shellcheck disable=SC1091
# shellcheck disable=SC3043  # 'local' supported by ash/busybox sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../../lib/common.sh"
. "$SCRIPT_DIR/../../lib/status.sh"

_CONFIG_DIR="${SCRIPT_DIR%/*}/config"
# shellcheck source=/dev/null
. "$_CONFIG_DIR/config.sh"

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
    _ck_servers="$(grep -c '^server' "$CONF" 2>/dev/null || true)"
    _ck_rules="$(grep -c '^nameserver' "$CONF" 2>/dev/null || true)"
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
# Sets: _ck_enabled ("true"|"false")
check_enabled() {
  _ck_enabled="false"
  if [ -f "$STATE_FILE" ]; then
    _ck_enabled="true"
  fi
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
show_dns_tests() {
  if ! command -v dig >/dev/null 2>&1; then
    echo "    DNS test:    skipped (dig not available)"
    return
  fi
  # RU domains → routed to ru-group via nameserver rules
  dns_test "ya.ru"       "ru-group"
  dns_test "vk.com"      "ru-group (.com→ru)"
  # International domains → default group (foreign DoH)
  dns_test "google.com"  "default-group"
  dns_test "github.com"  "default-group"
}

# --- JSON output ---

json_output() {
  printf '{'
  json_kv_bool "running" "$([ "$_st_running" = "true" ] && echo 0 || echo 1)"
  printf ','
  json_kv_bool "enabled" "$([ "$_ck_enabled" = "true" ] && echo 0 || echo 1)"
  printf ','
  json_kv_bool "ok" "$STATUS_OK"
  printf ',"details":{'
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
status_check_version "smartdns-conf-ru-split"
check_config
check_cache
check_enabled

# Set STATUS_OK based on critical checks
[ "$_st_running" = "false" ] && STATUS_OK=1
[ "$_st_port_ok" = "false" ] && STATUS_OK=1
[ "$_ck_config_ok" = "false" ] && STATUS_OK=1

if [ "${1:-}" = "--json" ]; then
  # DNS tests also affect STATUS_OK
  show_dns_tests >/dev/null 2>&1 || true
  json_output
  exit "$STATUS_OK"
fi

echo "smartdns-conf-ru-split status:"
echo "  Service:"
if [ "$_ck_enabled" = "true" ]; then
  echo "    Mode:        split-DNS (enabled) ✓"
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
