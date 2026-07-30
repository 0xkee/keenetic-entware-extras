#!/opt/bin/sh
# Show SmartDNS diagnostic status.
# shellcheck disable=SC1091
# shellcheck disable=SC3043  # 'local' supported by ash/busybox sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../../lib/common.sh"
. "$SCRIPT_DIR/../../lib/ip.sh"
. "$SCRIPT_DIR/../../lib/status.sh"
. "$SCRIPT_DIR/../../lib/geo.sh"

_CONFIG_DIR="${SCRIPT_DIR%/*}/config"
# shellcheck source=/dev/null
. "$_CONFIG_DIR/defaults.conf"
[ -f "$_CONFIG_DIR/config.conf" ] && . "$_CONFIG_DIR/config.conf"

# Enable colors for text output (auto = TTY-aware, --color/--no-color override)
status_setup_colors "$(_status_parse_color_arg "$@")"

# SMARTDNS_PORT=0 or empty → auto-detect via /proc/net/tcp → fallback 6053.
if [ -z "${SMARTDNS_PORT:-}" ] || [ "$SMARTDNS_PORT" = "0" ]; then
  _port_detect=$(detect_dns_port main)
  SMARTDNS_PORT="${_port_detect%% *}"
  [ "$SMARTDNS_PORT" = "0" ] && SMARTDNS_PORT=6053
  unset _port_detect
fi

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
# Sets: _ck_enabled ("true"|"false"), _ck_disabled ("true"|"false"),
#        _ck_zone, _ck_active_zones, _ck_other_ifaces
check_enabled() {
  _ck_enabled="false"
  _ck_disabled="false"
  _ck_zone="${DNS_ZONE:-ru}"
  _ck_active_zones=""
  _ck_other_ifaces="${OTHER_DNS_INTERFACES:-}"
  _ck_other_provider="${OTHER_DNS_PROVIDER:-google cloudflare}"
  _ck_zone_provider="${ZONE_DNS_PROVIDER:-yandex adguard}"
  if [ -f "$STATE_FILE" ]; then
    _ck_enabled="true"
  elif [ -f "${S38}.disabled" ] && [ ! -x "$S38" ]; then
    # Fully disabled: S38 renamed by S37smartdns-conf disable
    _ck_disabled="true"
  fi
  _ck_active_zones="$(resolve_geo_zone "$_ck_zone")"
}

# Check custom DNS providers file.
# Sets: _ck_custom_providers (count of uncommented LABEL= lines, 0 if absent)
check_custom_providers() {
  _ck_custom_providers=0
  local _f="$_CONFIG_DIR/dns-providers-custom.conf"
  if [ -f "$_f" ]; then
    _ck_custom_providers=$(grep -v '^[[:space:]]*#' "$_f" | grep -c '_LABEL=' 2>/dev/null) || _ck_custom_providers=0
  fi
}

# --- Show functions (text, use lib + local checks) ---

show_config() {
  local _extra=""
  [ "$_ck_custom_providers" -gt 0 ] && _extra=", $_ck_custom_providers custom"
  if [ "$_ck_config_ok" = "true" ]; then
    status_line "Config" "$CONF ($_ck_servers servers, $_ck_rules rules${_extra})" "ok"
  else
    status_line "Config" "NOT found" "fail"; STATUS_OK=1
  fi
}

show_cache() {
  if [ -n "$_ck_cache_size" ]; then
    status_line "Cache" "$_ck_cache_size ($CACHE_FILE)" "ok"
  else
    status_line "Cache" "not found"
  fi
}

# Show listening ports (delegates to lib/status.sh).
# STATUS_OK is set in main section based on _st_port_ok, not here.
show_ports() {
  status_show_port "$SMARTDNS_PORT"
}

# Run a single DNS test via main SmartDNS port.
# Usage: dns_test <domain> <group_label>
dns_test() {
  local domain="$1" label="$2"
  local result ip_line
  # Filter ";;" comment/error lines: Entware dig +short outputs
  # ";; communications error..." to stdout (not stderr) on connection refused.
  result="$(dig +short +time=2 +tries=1 "$domain" @127.0.0.1 -p "$SMARTDNS_PORT" 2>/dev/null | grep -v '^;;' || echo "FAILED")"
  # dig +short may return multiple lines; take first A-record
  ip_line="$(echo "$result" | head -1)"
  if [ -n "$ip_line" ] && [ "$ip_line" != "FAILED" ] && is_ipv4 "$ip_line"; then
    status_line "$domain" "$ip_line ($label)" "ok"
  else
    status_line "$domain" "FAILED ($label)" "fail"
    STATUS_OK=1
  fi
}

# Run DNS resolution tests (requires dig).
# Dynamic: tests first domain from each active zone + international.
show_dns_tests() {
  if [ "$_st_running" = "false" ]; then
    status_line "DNS test" "skipped (process not running)"
    return
  fi
  if ! command -v dig >/dev/null 2>&1; then
    status_line "DNS test" "skipped (dig not available)"
    return
  fi
  # Source test domains
  local test_domains_file="$_CONFIG_DIR/test-domains.conf"
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
# Sets: _dns_zone_ok, _dns_other_ok — group health for dns_server_checks
collect_dns_tests_json() {
  _dns_zone_ok="false"
  _dns_other_ok="false"
  # Skip DNS tests when service is disabled or not running — no port to query
  if [ "$_ck_disabled" = "true" ] || [ "$_st_running" = "false" ]; then
    _json_dns_tests="[]"
    return
  fi
  _json_dns_tests="["
  local first=1
  local _dns_failed=0
  if ! command -v dig >/dev/null 2>&1; then
    _json_dns_tests="[]"
    return
  fi
  # Source test domains
  local test_domains_file="$_CONFIG_DIR/test-domains.conf"
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
        # Early-exit: if previous test timed out, skip remaining (CPU-safe)
        if [ "$_dns_failed" -ge 2 ]; then
          r="SKIPPED"
        else
          r="$(dig +short +time=3 +tries=1 "$d" @127.0.0.1 -p "$SMARTDNS_PORT" 2>/dev/null | grep -v '^;;' | head -1 || true)"
          [ -z "$r" ] && _dns_failed=$((_dns_failed + 1))
        fi
        # Track zone group health: any successful resolve = zone providers reachable
        [ -n "$r" ] && [ "$r" != "FAILED" ] && [ "$r" != "SKIPPED" ] && _dns_zone_ok="true"
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
  if [ "$_dns_failed" -ge 2 ]; then
    intl_r="SKIPPED"
  else
    intl_r="$(dig +short +time=3 +tries=1 "$intl_d" @127.0.0.1 -p "$SMARTDNS_PORT" 2>/dev/null | grep -v '^;;' | head -1 || true)"
  fi
  # Track other group health
  [ -n "$intl_r" ] && [ "$intl_r" != "SKIPPED" ] && _dns_other_ok="true"
  [ "$first" -eq 0 ] && _json_dns_tests="${_json_dns_tests},"
  _json_dns_tests="${_json_dns_tests}{\"domain\":\"$intl_d\",\"group\":\"other\",\"result\":\"${intl_r:-FAILED}\"}"
  _json_dns_tests="${_json_dns_tests}]"
}

# Get first ISP DNS IP from /tmp/ndnproxymain.conf (Keenetic).
# Filters: SmartDNS (:6053), loopback. Returns single IP or empty.
_status_get_first_isp_ip() {
  local _ip=""
  if [ -f /tmp/ndnproxymain.conf ]; then
    _ip="$(grep '^dns_server' /tmp/ndnproxymain.conf | awk '{print $3}' | grep -v ':6053' | sed 's/:.*//' | grep -v '^127\.' | head -1)"
  fi
  printf '%s' "$_ip"
}

# Derive upstream provider health from DNS test results (collected by collect_dns_tests_json).
# Tests resolution through SmartDNS port — the actual path providers are reached,
# regardless of tunnel binding or direct routing. No separate dig probes needed.
# Requires: _dns_zone_ok, _dns_other_ok (set by collect_dns_tests_json)
# Sets: _json_dns_server_checks (JSON array string)
collect_dns_server_checks_json() {
  # Skip when service is disabled (no SmartDNS running)
  if [ "$_ck_disabled" = "true" ]; then
    _json_dns_server_checks="[]"
    return
  fi
  _json_dns_server_checks="["
  local first=1

  # Source provider catalog for host/label lookups
  local providers_file="$_CONFIG_DIR/dns-providers.conf"
  if [ -f "$providers_file" ]; then
    # shellcheck source=/dev/null
    . "$providers_file"
  fi

  # Zone providers — health derived from zone DNS tests
  for p in $_ck_zone_provider; do
    local host_var="ZONE_${p}_TLS_HOST"
    local ip_var="ZONE_${p}_IP1"
    eval "local host=\"\${${host_var}:-}\""
    eval "local ip=\"\${${ip_var}:-}\""
    # Dynamic provider (System/Keenetic): show ISP IP as host
    if [ -z "$host" ] && [ -z "$ip" ]; then
      eval "local _dyn=\"\${ZONE_${p}_DYNAMIC:-}\""
      # shellcheck disable=SC2154  # _dyn assigned via eval
      [ "$_dyn" = "resolv" ] && host="$(_status_get_first_isp_ip)"
    fi
    [ -z "$host" ] && host="${ip:-$p}"
    [ "$first" -eq 0 ] && _json_dns_server_checks="${_json_dns_server_checks},"
    _json_dns_server_checks="${_json_dns_server_checks}{\"provider\":\"$p\",\"group\":\"zone\",\"host\":\"${host}\",\"ok\":$_dns_zone_ok}"
    first=0
  done

  # Other (international) providers — health derived from international DNS test
  for p in $_ck_other_provider; do
    local host_var="OTHER_${p}_TLS_HOST"
    local ip_var="OTHER_${p}_IP1"
    eval "local host=\"\${${host_var}:-}\""
    eval "local ip=\"\${${ip_var}:-}\""
    # Dynamic provider (System/Keenetic): show ISP IP as host
    if [ -z "$host" ] && [ -z "$ip" ]; then
      eval "local _dyn=\"\${OTHER_${p}_DYNAMIC:-}\""
      # shellcheck disable=SC2154  # _dyn assigned via eval
      [ "$_dyn" = "resolv" ] && host="$(_status_get_first_isp_ip)"
    fi
    [ -z "$host" ] && host="${ip:-$p}"
    [ "$first" -eq 0 ] && _json_dns_server_checks="${_json_dns_server_checks},"
    _json_dns_server_checks="${_json_dns_server_checks}{\"provider\":\"$p\",\"group\":\"other\",\"host\":\"${host}\",\"ok\":$_dns_other_ok}"
    first=0
  done

  _json_dns_server_checks="${_json_dns_server_checks}]"
}

json_output() {
  local enabled_val=1
  [ "$_ck_enabled" = "true" ] && enabled_val=0

  # When disabled: reset runtime values per spec §4.2
  # Prevents stale pidfile → phantom uptime/pid/memory
  if [ "$_ck_disabled" = "true" ]; then
    _st_uptime_seconds=0
    _st_pid=""
    _st_mem_kb="0"
    _st_port_addrs=""
  fi

  # Details
  status_detail "dns_zone" "$_ck_zone"
  status_detail "active_zones" "$_ck_active_zones"
  status_detail "zone_dns_providers" "$_ck_zone_provider"
  status_detail "other_dns_providers" "$_ck_other_provider"
  status_detail "other_interfaces" "$_ck_other_ifaces"
  status_detail "ports" "$_st_port_addrs"
  status_detail "servers" "$_ck_servers" "num"
  status_detail "rules" "$_ck_rules" "num"
  [ "$_ck_custom_providers" -gt 0 ] && status_detail "custom_providers" "$_ck_custom_providers" "num"
  status_detail "cache" "$([ -n "$_ck_cache_kb" ] && format_size_kb "$_ck_cache_kb" || printf 'none')"
  status_detail "memory" "$([ "$_st_running" = "true" ] && [ "$_st_mem_kb" != "0" ] && format_size_kb "$_st_mem_kb" || printf '')"
  status_detail "pid" "$_st_pid"
  status_detail "uptime" "$_st_uptime_seconds" "num"
  status_detail "version" "${_st_version:-unknown}"

  # Extras (pre-serialized arrays)
  status_extra "dns_tests" "$_json_dns_tests"
  status_extra "dns_server_checks" "$_json_dns_server_checks"

  # Checks — runtime checks → "skip" when disabled (spec §4.2)
  if [ "$_ck_disabled" = "true" ]; then
    status_check_result "process" "skip"
    status_check_result "ports" "skip"
  else
    status_check_result "process" "$(if [ "$_st_running" = "true" ]; then printf ok; else printf fail; fi)"
    status_check_result "ports" "$(if [ "$_st_port_ok" = "true" ]; then printf ok; else printf fail; fi)"
  fi
  status_check_result "config" "$(if [ "$_ck_config_ok" = "true" ]; then printf ok; else printf fail; fi)"

  # Emit
  status_emit_json "$enabled_val" "$([ "$_st_running" = "true" ] && echo 0 || echo 1)" "$STATUS_OK"
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
check_custom_providers

# Set STATUS_OK based on critical checks (disabled state is not a failure)
if [ "$_ck_disabled" != "true" ]; then
  [ "$_st_running" = "false" ] && STATUS_OK=1
  [ "$_st_port_ok" = "false" ] && STATUS_OK=1
  [ "$_ck_config_ok" = "false" ] && STATUS_OK=1
fi

# --- Text output (declarative, parallel to json_output) ---

text_output() {
  local _status_word="✓ Alive"
  if [ "$_ck_disabled" = "true" ]; then
    _status_word="⚠ Disabled"
  elif [ "$STATUS_OK" -ne 0 ]; then
    _status_word="✗ Fail"
  fi

  _text_buf="smartdns-geo-conf status: ${_status_word}
"
  status_section "Service"
  if [ "$_ck_disabled" = "true" ]; then
    status_line "Mode" "disabled (fully stopped, system DNS via ndnproxy)"
    status_line "SmartDNS" "S38 init renamed → not running"
    show_cache
    status_blank
    status_section "System"
    status_show_version
  elif [ "$_ck_enabled" = "true" ]; then
    status_line "Mode" "split-DNS (enabled)" "ok"
    status_line "Zone" "$_ck_zone → [$_ck_active_zones]"
    status_line "Zone DNS" "$_ck_zone_provider"
    status_line "Other DNS" "$_ck_other_provider"
    if [ -n "$_ck_other_ifaces" ]; then
      status_line "Other tunnels" "$_ck_other_ifaces"
    fi
    status_show_process
    show_ports
    show_config
    show_cache
    status_blank
    status_section "System"
    status_show_uptime
    status_show_version
    status_blank
    status_section "DNS Tests"
    show_dns_tests
  else
    status_line "Mode" "default (simple forwarder)"
    status_show_process
    show_ports
    show_config
    show_cache
    status_blank
    status_section "System"
    status_show_uptime
    status_show_version
    status_blank
    status_section "DNS Tests"
    show_dns_tests
  fi

  status_emit_text
}

# --- main ---

if [ "${1:-}" = "--json" ]; then
  # Collect DNS test results and server reachability for JSON
  collect_dns_tests_json
  collect_dns_server_checks_json
  json_output
  exit "$STATUS_OK"
fi

text_output
exit "$STATUS_OK"
