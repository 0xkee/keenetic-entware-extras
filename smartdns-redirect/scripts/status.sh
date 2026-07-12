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

# Detect router LAN IP for DNAT rule check (must match dns-redirect.sh).
ROUTER_IP="$(detect_router_ip)"
ROUTER_IP6=""
if [ "${ENABLE_IPV6:-no}" = "yes" ] && command -v ip6tables >/dev/null 2>&1; then
    ROUTER_IP6=$(ip -6 addr show br0 2>/dev/null \
        | awk '/inet6.*global/ {split($2, a, "/"); print a[1]; exit}')
fi

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

# Verify iptables DNAT rules for all interfaces × protos.
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
        -j DNAT --to-destination "${ROUTER_IP}:${UPSTREAM_PORT}" 2>/dev/null || _ck_rules_ok=1
    done
  done
  if [ "$ENABLE_IPV6" = "yes" ] && command -v ip6tables >/dev/null 2>&1; then
    for _iface in $INTERFACES; do
      for _proto in udp tcp; do
        ip6tables -t nat -C PREROUTING -i "$_iface" -p "$_proto" --dport 53 \
          -j DNAT --to-destination "[${ROUTER_IP6}]:${UPSTREAM_PORT}" 2>/dev/null || _ck_rules_ok=1
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
  status_section "Mode"
  status_line "Config" "$CONFIG_FILE"
  status_line "Upstream" "127.0.0.1:$UPSTREAM_PORT (${_ck_upstream_name:-unknown})"
  if [ -n "$INTERFACES" ]; then
    status_line "Interfaces" "$INTERFACES"
  else
    status_line "Interfaces" "— (empty → disabled)"
  fi
  status_line "IPv6" "$ENABLE_IPV6"
}

# Check a single iptables DNAT rule for (family, iface, proto).
# Args: $1 - "v4"|"v6", $2 - iface, $3 - proto (udp|tcp)
check_rule() {
  local family="$1" iface="$2" proto="$3" bin target display_target
  case "$family" in
    v4) bin="iptables"; target="${ROUTER_IP}:${UPSTREAM_PORT}" ;;
    v6) bin="ip6tables"; target="[${ROUTER_IP6}]:${UPSTREAM_PORT}" ;;
    *)  return 1 ;;
  esac
  display_target="$target"
  if "$bin" -t nat -C PREROUTING -i "$iface" -p "$proto" --dport 53 \
      -j DNAT --to-destination "$target" 2>/dev/null; then
    _text_buf="${_text_buf}$(printf '    %-4s %-6s %s → %s ✓\n' "$family" "$proto" "$iface" "$display_target")
"
  else
    _text_buf="${_text_buf}$(printf '    %-4s %-6s %s → %s ✗\n' "$family" "$proto" "$iface" "$display_target")
"
    STATUS_OK=1
  fi
}

# Report expected rules (per configured iface × proto); mark missing as ✗.
show_rules() {
  status_section "Rules"
  if [ -z "$INTERFACES" ]; then
    status_line_cont "(disabled: INTERFACES is empty)"
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
      status_line "IPv6" "enabled but ip6tables not available" "fail"
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
  status_section "Upstream probe"
  if [ "$_ck_upstream_ok" = 0 ]; then
    status_line "UDP :$UPSTREAM_PORT" "listening ($_ck_upstream_listening)" "ok"
  else
    status_line "UDP :$UPSTREAM_PORT" "no listener" "fail"
    STATUS_OK=1
  fi
}

# Show NDM hook status.
show_ndm_hook() {
  local hook="/opt/etc/ndm/netfilter.d/smartdns-redirect-hook"
  if [ "$_ck_ndm_hook_ok" = 0 ]; then
    status_line "NDM hook" "$hook" "ok"
  elif [ -f "$hook" ]; then
    status_line "NDM hook" "$hook (not executable)" "fail"
    STATUS_OK=1
  else
    status_line "NDM hook" "(missing)" "fail"
    STATUS_OK=1
  fi
}

# Show init.d status.
show_init() {
  local init="/opt/etc/init.d/S39smartdns-redirect"
  if [ "$_ck_init_ok" = 0 ]; then
    status_line "Init" "$init" "ok"
  elif [ -f "$init" ]; then
    status_line "Init" "$init (not executable)" "fail"
    STATUS_OK=1
  else
    status_line "Init" "(missing)" "fail"
    STATUS_OK=1
  fi
}

# Show uptime using lib/status.sh.
show_uptime() {
  if [ "$_st_running" = "true" ]; then
    status_show_uptime
  else
    status_line "Uptime" "— (not running)" "fail"
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

  # Details
  status_detail "interfaces" "$INTERFACES"
  status_detail "ipv6" "$ENABLE_IPV6"
  status_detail "ndm_hook" "$_ck_ndm_hook_ok" "bool"
  status_detail "upstream" "127.0.0.1:${UPSTREAM_PORT}"
  status_detail "name" "$_ck_upstream_name"
  status_detail "status" "$_ck_upstream_ok" "bool"
  status_detail "init" "$_ck_init_ok" "bool"
  status_detail "rules" "$_ck_rules_ok" "bool"
  status_detail "uptime" "$uptime_seconds_val" "num"
  status_detail "version" "${_st_version:-unknown}"

  # Checks
  status_check_result "running" "$(if [ "$running" = "true" ]; then printf ok; else printf fail; fi)"
  status_check_result "upstream" "$(if [ "$_ck_upstream_ok" = 0 ]; then printf ok; else printf fail; fi)"
  status_check_result "ndm_hook" "$(if [ "$_ck_ndm_hook_ok" = 0 ]; then printf ok; else printf fail; fi)"
  status_check_result "init" "$(if [ "$_ck_init_ok" = 0 ]; then printf ok; else printf fail; fi)"
  status_check_result "rules" "$(if [ "$_ck_rules_ok" = 0 ]; then printf ok; else printf fail; fi)"

  # Emit
  status_emit_json "$enabled_val" "$([ "$running" = "true" ] && echo 0 || echo 1)" "$STATUS_OK"
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

# --- Text output (declarative, parallel to json_output) ---

text_output() {
  local _status_word="✓ Alive"
  if ! is_service_enabled "S39smartdns-redirect"; then
    _status_word="⚠ Disabled"
  elif [ "$STATUS_OK" -ne 0 ]; then
    _status_word="✗ Fail"
  fi

  _text_buf="smartdns-redirect status: ${_status_word}
"
  show_mode
  status_blank
  show_rules
  status_blank
  show_upstream
  status_blank
  status_section "System"
  show_uptime
  show_init
  show_ndm_hook
  show_version

  status_emit_text
}

# --- main ---

if [ "${1:-}" = "--json" ]; then
  json_output
  exit "$STATUS_OK"
fi

text_output
exit "$STATUS_OK"
