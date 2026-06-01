#!/opt/bin/sh
# Show smartdns-redirect diagnostic status.
# shellcheck disable=SC3043
# shellcheck disable=SC1091
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../../lib/common.sh"
. "$SCRIPT_DIR/../../lib/status.sh"
_CONFIG_DIR="$(cd "$SCRIPT_DIR/../config" && pwd)"
CONFIG_FILE="$_CONFIG_DIR/defaults.conf"
# shellcheck source=/dev/null
. "$CONFIG_FILE"
[ -f "$_CONFIG_DIR/config.conf" ] && . "$_CONFIG_DIR/config.conf"

STATUS_OK=0

# Globals set by check functions / lib/status.sh
_st_uptime_seconds=0
_st_version=""
_st_port_ok="false"
_st_port_addrs=""
_st_running="false"
_ck_upstream_ok=1
_ck_upstream_name="unknown"
_ck_upstream_listening=""
_ck_rules_ok=0
_ck_ndm_hook_ok=1
_ck_init_ok=1

# --- Check functions (set _ck_* globals, never print) ---

# Check upstream resolver listening on UPSTREAM_PORT (UDP) + detect name.
# Sets: _ck_upstream_ok (0|1), _ck_upstream_name, _ck_upstream_listening
check_upstream() {
  _ck_upstream_ok=1
  _ck_upstream_name="unknown"
  _ck_upstream_listening=""

  status_check_port "$UPSTREAM_PORT" "udp"
  if [ "$_st_port_ok" = "true" ]; then
    _ck_upstream_ok=0
    _ck_upstream_listening="$_st_port_addrs"
  fi

  _ck_upstream_name=$(netstat -tlnup 2>/dev/null | grep ":${UPSTREAM_PORT} " | head -1 \
    | sed -n 's|.*/\([^ ]*\)$|\1|p') || true
  [ -z "$_ck_upstream_name" ] && _ck_upstream_name="unknown" || true
}

# Verify iptables REDIRECT rules for all interfaces × protos.
# Sets: _ck_rules_ok (0=all present, 1=some missing)
check_rules() {
  _ck_rules_ok=0
  local _iface _proto
  if [ -z "$INTERFACES" ]; then
    return
  fi
  for _iface in $INTERFACES; do
    for _proto in udp tcp; do
      iptables -t nat -C PREROUTING -i "$_iface" -p "$_proto" --dport 53 \
        -j REDIRECT --to-ports "$UPSTREAM_PORT" 2>/dev/null || _ck_rules_ok=1
    done
  done
  if [ "$ENABLE_IPV6" = "yes" ] && command -v ip6tables >/dev/null 2>&1; then
    for _iface in $INTERFACES; do
      for _proto in udp tcp; do
        ip6tables -t nat -C PREROUTING -i "$_iface" -p "$_proto" --dport 53 \
          -j REDIRECT --to-ports "$UPSTREAM_PORT" 2>/dev/null || _ck_rules_ok=1
      done
    done
  fi
}

# Check NDM netfilter.d hook presence.
# Sets: _ck_ndm_hook_ok (0=executable, 1=missing/broken)
check_ndm_hook() {
  if [ -x "/opt/etc/ndm/netfilter.d/smartdns-redirect-hook" ]; then
    _ck_ndm_hook_ok=0
  else
    _ck_ndm_hook_ok=1
  fi
}

# Check init.d wrapper presence.
# Sets: _ck_init_ok (0=executable, 1=missing/broken)
check_init() {
  if [ -x "/opt/etc/init.d/S39smartdns-redirect" ]; then
    _ck_init_ok=0
  else
    _ck_init_ok=1
  fi
}

# --- Show functions (text output for CLI) ---

# Show configuration: source file and resolver parameters.
show_mode() {
  echo "  Mode:"
  echo "    Config:      $CONFIG_FILE"
  echo "    Upstream:    127.0.0.1:$UPSTREAM_PORT (${_ck_upstream_name:-unknown})"
  if [ -n "$INTERFACES" ]; then
    echo "    Interfaces:  $INTERFACES"
  else
    echo "    Interfaces:  — (empty → disabled)"
  fi
  echo "    IPv6:        $ENABLE_IPV6"
}

# Check a single iptables REDIRECT rule for (family, iface, proto).
# Args: $1 - "v4"|"v6", $2 - iface, $3 - proto (udp|tcp)
check_rule() {
  local family="$1" iface="$2" proto="$3" bin
  case "$family" in
    v4) bin="iptables" ;;
    v6) bin="ip6tables" ;;
    *)  return 1 ;;
  esac
  if "$bin" -t nat -C PREROUTING -i "$iface" -p "$proto" --dport 53 \
      -j REDIRECT --to-ports "$UPSTREAM_PORT" 2>/dev/null; then
    printf "    %-4s %-6s %s → :%s ✓\n" "$family" "$proto" "$iface" "$UPSTREAM_PORT"
  else
    printf "    %-4s %-6s %s → :%s ✗\n" "$family" "$proto" "$iface" "$UPSTREAM_PORT"
    STATUS_OK=1
  fi
}

# Report expected rules (per configured iface × proto); mark missing as ✗.
show_rules() {
  echo "  Rules:"
  if [ -z "$INTERFACES" ]; then
    echo "    (disabled: INTERFACES is empty)"
    return
  fi
  local iface proto
  for iface in $INTERFACES; do
    for proto in udp tcp; do
      check_rule "v4" "$iface" "$proto"
    done
  done
  if [ "$ENABLE_IPV6" = "yes" ]; then
    if ! command -v ip6tables >/dev/null 2>&1; then
      echo "    IPv6 enabled but ip6tables not available ✗"
      STATUS_OK=1
    else
      for iface in $INTERFACES; do
        for proto in udp tcp; do
          check_rule "v6" "$iface" "$proto"
        done
      done
    fi
  fi
}

# Display upstream probe result.
show_upstream() {
  echo "  Upstream probe:"
  if [ "$_ck_upstream_ok" = 0 ]; then
    echo "    UDP :$UPSTREAM_PORT: listening ($_ck_upstream_listening) ✓"
  else
    echo "    UDP :$UPSTREAM_PORT: no listener ✗"
    STATUS_OK=1
  fi
}

# Show NDM hook status.
show_ndm_hook() {
  local hook="/opt/etc/ndm/netfilter.d/smartdns-redirect-hook"
  if [ "$_ck_ndm_hook_ok" = 0 ]; then
    echo "    NDM hook:    $hook ✓"
  elif [ -f "$hook" ]; then
    echo "    NDM hook:    $hook (not executable) ✗"
    STATUS_OK=1
  else
    echo "    NDM hook:    ✗ (missing)"
    STATUS_OK=1
  fi
}

# Show init.d status.
show_init() {
  local init="/opt/etc/init.d/S39smartdns-redirect"
  if [ "$_ck_init_ok" = 0 ]; then
    echo "    Init:        $init ✓"
  elif [ -f "$init" ]; then
    echo "    Init:        $init (not executable) ✗"
    STATUS_OK=1
  else
    echo "    Init:        ✗ (missing)"
    STATUS_OK=1
  fi
}

# Show uptime using lib/status.sh.
show_uptime() {
  if [ "$_st_running" = "true" ]; then
    status_show_uptime
  else
    echo "    Uptime:      — (not running)"
    STATUS_OK=1
  fi
}

# Show version using lib/status.sh.
show_version() {
  status_show_version
}

# --- JSON output ---

# Collect structured data and emit JSON for webui.
json_output() {
  local running="false" uptime_seconds_val=0

  # Running: PIDFILE exists = rules attached
  if [ "$_st_running" = "true" ]; then
    running="true"
    uptime_seconds_val="$_st_uptime_seconds"
  fi

  # Enabled: symlink exists in /opt/etc/init.d/
  local enabled_val=1
  is_service_enabled "S39smartdns-redirect" && enabled_val=0

  printf '{'
  json_kv_bool "enabled" "$enabled_val"
  printf ','
  json_kv_bool "running" "$([ "$running" = "true" ] && echo 0 || echo 1)"
  printf ','
  json_kv_bool "ok" "$STATUS_OK"
  printf ',"details":{'
  json_kv "interfaces" "$INTERFACES"
  printf ','
  json_kv "ipv6" "$ENABLE_IPV6"
  printf ','
  json_kv_bool "ndm_hook" "$_ck_ndm_hook_ok"
  printf ','
  json_kv "upstream" "127.0.0.1:${UPSTREAM_PORT}"
  printf ','
  json_kv "name" "$_ck_upstream_name"
  printf ','
  json_kv_bool "status" "$_ck_upstream_ok"
  printf ','
  json_kv_bool "init" "$_ck_init_ok"
  printf ','
  json_kv_bool "rules" "$_ck_rules_ok"
  printf ','
  json_kv_num "uptime" "$uptime_seconds_val"
  printf ','
  json_kv "version" "${_st_version:-unknown}"
  printf '},'

  # Checks section: "ok"|"warn"|"fail" per field
  printf '"checks":{'
  json_check "running" "$(if [ "$running" = "true" ]; then printf ok; else printf fail; fi)"
  printf ','
  json_check "upstream" "$(if [ "$_ck_upstream_ok" = 0 ]; then printf ok; else printf fail; fi)"
  printf ','
  json_check "ndm_hook" "$(if [ "$_ck_ndm_hook_ok" = 0 ]; then printf ok; else printf fail; fi)"
  printf ','
  json_check "init" "$(if [ "$_ck_init_ok" = 0 ]; then printf ok; else printf fail; fi)"
  printf ','
  json_check "rules" "$(if [ "$_ck_rules_ok" = 0 ]; then printf ok; else printf fail; fi)"
  printf '}}\n'
}

# --- main ---

# Run all checks upfront (sets _st_* and _ck_* globals)
check_upstream
check_rules
check_ndm_hook
check_init
status_check_uptime "$PIDFILE"
status_check_version "smartdns-redirect"

# PIDFILE is a marker "rules attached" (no daemon process)
_st_running="false"
[ -f "$PIDFILE" ] && _st_running="true" || true
[ "$_st_running" = "false" ] && STATUS_OK=1 || true

if [ "${1:-}" = "--json" ]; then
  json_output
  exit "$STATUS_OK"
fi

echo "smartdns-redirect status:"
if ! is_service_enabled "S39smartdns-redirect"; then
  echo "  Service:     ⚠ Disabled (not auto-starting)"
  echo
fi
show_mode
echo
show_rules
echo
show_upstream
echo
echo "  System:"
show_uptime
show_init
show_ndm_hook
show_version

exit "$STATUS_OK"
