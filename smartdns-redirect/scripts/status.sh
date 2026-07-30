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
if command -v ip6tables >/dev/null 2>&1; then
    ROUTER_IP6="$(detect_router_ip6)"
fi

# --- IPv6 auto-detection (same logic as dns-redirect.sh) ---

# Check if we can DNAT IPv6 DNS to SmartDNS.
can_dnat_ipv6() {
    command -v ip6tables >/dev/null 2>&1 || return 1
    [ -n "$ROUTER_IP6" ] || return 1
    grep -q 'bind \[' /opt/etc/smartdns/bind-addrs.conf 2>/dev/null || return 1
    return 0
}

# Detect current IPv6 mode: "dnat", "reject", or "none".
# stdout: mode string
detect_ipv6_mode() {
    if ! command -v ip6tables >/dev/null 2>&1; then
        printf 'none'
    elif can_dnat_ipv6; then
        printf 'dnat'
    else
        printf 'reject'
    fi
}

IPV6_MODE="$(detect_ipv6_mode)"

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
_ck_rules_json=""
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

# Verify iptables rules for all interfaces × protos.
# IPv6 rules checked based on auto-detected mode (dnat or reject).
# DoT blocking (:853) checked only in "force" mode.
# In "local" mode, DNAT rules include -d $ROUTER_IP / -d $ROUTER_IP6.
# Sets: _ck_rules_ok (0=all present, 1=some missing),
#        _ck_rules_json (JSON array of per-iface/proto results)
check_rules() {
  _ck_rules_ok=0
  _ck_rules_json=""
  local _iface _proto _ok _mode
  _mode="${REDIRECT_MODE:-force}"
  if [ -z "$INTERFACES" ]; then
    return
  fi
  # IPv4 DNAT rules
  for _iface in $INTERFACES; do
    for _proto in udp tcp; do
      _ok="true"
      if [ "$_mode" = "local" ]; then
        iptables -t nat -C PREROUTING -i "$_iface" -p "$_proto" -d "$ROUTER_IP" --dport 53 \
          -j DNAT --to-destination "${ROUTER_IP}:${UPSTREAM_PORT}" 2>/dev/null || { _ck_rules_ok=1; _ok="false"; }
      else
        iptables -t nat -C PREROUTING -i "$_iface" -p "$_proto" --dport 53 \
          -j DNAT --to-destination "${ROUTER_IP}:${UPSTREAM_PORT}" 2>/dev/null || { _ck_rules_ok=1; _ok="false"; }
      fi
      _ck_rules_json="${_ck_rules_json:+${_ck_rules_json},}{\"iface\":\"${_iface}\",\"family\":\"v4\",\"proto\":\"${_proto}\",\"ok\":${_ok}}"
    done
  done
  # IPv6 rules (based on detected mode)
  if [ "$IPV6_MODE" = "dnat" ]; then
    for _iface in $INTERFACES; do
      for _proto in udp tcp; do
        _ok="true"
        if [ "$_mode" = "local" ]; then
          ip6tables -t nat -C PREROUTING -i "$_iface" -p "$_proto" -d "$ROUTER_IP6" --dport 53 \
            -j DNAT --to-destination "[${ROUTER_IP6}]:${UPSTREAM_PORT}" 2>/dev/null || { _ck_rules_ok=1; _ok="false"; }
        else
          ip6tables -t nat -C PREROUTING -i "$_iface" -p "$_proto" --dport 53 \
            -j DNAT --to-destination "[${ROUTER_IP6}]:${UPSTREAM_PORT}" 2>/dev/null || { _ck_rules_ok=1; _ok="false"; }
        fi
        _ck_rules_json="${_ck_rules_json:+${_ck_rules_json},}{\"iface\":\"${_iface}\",\"family\":\"v6\",\"proto\":\"${_proto}\",\"type\":\"dnat\",\"ok\":${_ok}}"
      done
    done
  elif [ "$IPV6_MODE" = "reject" ]; then
    for _iface in $INTERFACES; do
      for _proto in udp tcp; do
        _ok="true"
        ip6tables -C INPUT -i "$_iface" -p "$_proto" --dport 53 \
          -j REJECT --reject-with icmp6-port-unreachable 2>/dev/null || { _ck_rules_ok=1; _ok="false"; }
        _ck_rules_json="${_ck_rules_json:+${_ck_rules_json},}{\"iface\":\"${_iface}\",\"family\":\"v6\",\"proto\":\"${_proto}\",\"type\":\"reject\",\"ok\":${_ok}}"
      done
    done
  fi
  # DoT blocking: FORWARD REJECT :853 rules (force mode only)
  if [ "$_mode" = "force" ]; then
    for _iface in $INTERFACES; do
      for _proto in tcp udp; do
        _ok="true"
        iptables -C FORWARD -i "$_iface" -p "$_proto" --dport 853 \
          -j REJECT --reject-with icmp-port-unreachable 2>/dev/null || { _ck_rules_ok=1; _ok="false"; }
        _ck_rules_json="${_ck_rules_json:+${_ck_rules_json},}{\"iface\":\"${_iface}\",\"family\":\"v4\",\"proto\":\"${_proto}\",\"type\":\"dot_block\",\"ok\":${_ok}}"
      done
    done
    if command -v ip6tables >/dev/null 2>&1; then
      for _iface in $INTERFACES; do
        for _proto in tcp udp; do
          _ok="true"
          ip6tables -C FORWARD -i "$_iface" -p "$_proto" --dport 853 \
            -j REJECT --reject-with icmp6-port-unreachable 2>/dev/null || { _ck_rules_ok=1; _ok="false"; }
          _ck_rules_json="${_ck_rules_json:+${_ck_rules_json},}{\"iface\":\"${_iface}\",\"family\":\"v6\",\"proto\":\"${_proto}\",\"type\":\"dot_block\",\"ok\":${_ok}}"
        done
      done
    fi
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
  # Redirect mode display
  case "${REDIRECT_MODE:-force}" in
    force)  status_line "Redirect" "force (intercept all DNS + block DoT)" ;;
    local)  status_line "Redirect" "local (only router-targeted DNS)" ;;
    *)      status_line "Redirect" "${REDIRECT_MODE:-force}" ;;
  esac
  # IPv6 mode display
  case "$IPV6_MODE" in
    dnat)   status_line "IPv6" "auto-dnat [${ROUTER_IP6}]:${UPSTREAM_PORT}" ;;
    reject) status_line "IPv6" "auto-reject (Happy Eyeballs → IPv4)" ;;
    none)   status_line "IPv6" "unavailable (no ip6tables)" ;;
  esac
  status_line "DNAT to" "${ROUTER_IP}:${UPSTREAM_PORT}"
  if [ "${REDIRECT_MODE:-force}" = "force" ]; then
    status_line "DoT block" ":853 → REJECT (force mode)" "ok"
  else
    status_line "DoT block" "off (local mode)" ""
  fi
}

# Check a single iptables/ip6tables rule for display.
# Args: $1 - "v4"|"v6_dnat"|"v6_reject", $2 - iface, $3 - proto (udp|tcp)
check_rule() {
  local rtype="$1" iface="$2" proto="$3" label target _check_ok
  case "$rtype" in
    v4)
      label="v4"
      target="${ROUTER_IP}:${UPSTREAM_PORT}"
      _check_ok="false"
      if [ "${REDIRECT_MODE:-force}" = "local" ]; then
        iptables -t nat -C PREROUTING -i "$iface" -p "$proto" -d "$ROUTER_IP" --dport 53 \
            -j DNAT --to-destination "$target" 2>/dev/null && _check_ok="true"
      else
        iptables -t nat -C PREROUTING -i "$iface" -p "$proto" --dport 53 \
            -j DNAT --to-destination "$target" 2>/dev/null && _check_ok="true"
      fi
      if [ "$_check_ok" = "true" ]; then
        _text_buf="${_text_buf}$(printf '    %-10s %-6s %s → DNAT %s ✓\n' "$label" "$proto" "$iface" "$target")
"
      else
        _text_buf="${_text_buf}$(printf '    %-10s %-6s %s → DNAT %s ✗\n' "$label" "$proto" "$iface" "$target")
"
        STATUS_OK=1
      fi
      ;;
    v6_dnat)
      label="v6-dnat"
      target="[${ROUTER_IP6}]:${UPSTREAM_PORT}"
      _check_ok="false"
      if [ "${REDIRECT_MODE:-force}" = "local" ]; then
        ip6tables -t nat -C PREROUTING -i "$iface" -p "$proto" -d "$ROUTER_IP6" --dport 53 \
            -j DNAT --to-destination "$target" 2>/dev/null && _check_ok="true"
      else
        ip6tables -t nat -C PREROUTING -i "$iface" -p "$proto" --dport 53 \
            -j DNAT --to-destination "$target" 2>/dev/null && _check_ok="true"
      fi
      if [ "$_check_ok" = "true" ]; then
        _text_buf="${_text_buf}$(printf '    %-10s %-6s %s → DNAT %s ✓\n' "$label" "$proto" "$iface" "$target")
"
      else
        _text_buf="${_text_buf}$(printf '    %-10s %-6s %s → DNAT %s ✗\n' "$label" "$proto" "$iface" "$target")
"
        STATUS_OK=1
      fi
      ;;
    v6_reject)
      label="v6-reject"
      if ip6tables -C INPUT -i "$iface" -p "$proto" --dport 53 \
          -j REJECT --reject-with icmp6-port-unreachable 2>/dev/null; then
        _text_buf="${_text_buf}$(printf '    %-10s %-6s %s → REJECT ✓\n' "$label" "$proto" "$iface")
"
      else
        _text_buf="${_text_buf}$(printf '    %-10s %-6s %s → REJECT ✗\n' "$label" "$proto" "$iface")
"
        STATUS_OK=1
      fi
      ;;
    dot_block)
      label="dot-block"
      if iptables -C FORWARD -i "$iface" -p "$proto" --dport 853 \
          -j REJECT --reject-with icmp-port-unreachable 2>/dev/null; then
        _text_buf="${_text_buf}$(printf '    %-10s %-6s %s :853 → REJECT ✓\n' "$label" "$proto" "$iface")
"
      else
        _text_buf="${_text_buf}$(printf '    %-10s %-6s %s :853 → REJECT ✗\n' "$label" "$proto" "$iface")
"
        STATUS_OK=1
      fi
      ;;
  esac
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
  # IPv6 rules based on detected mode
  case "$IPV6_MODE" in
    dnat)
      for iface in $INTERFACES; do
        for proto in udp tcp; do
          check_rule "v6_dnat" "$iface" "$proto"
        done
      done
      ;;
    reject)
      for iface in $INTERFACES; do
        for proto in udp tcp; do
          check_rule "v6_reject" "$iface" "$proto"
        done
      done
      ;;
  esac
  # DoT blocking: FORWARD REJECT :853 (force mode only)
  if [ "${REDIRECT_MODE:-force}" = "force" ]; then
    for iface in $INTERFACES; do
      for proto in tcp udp; do
        check_rule "dot_block" "$iface" "$proto"
      done
    done
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

  # Detect parent disabled (spec §4.3) — same logic as text_output
  local _parent_disabled="false"
  [ ! -x /opt/etc/init.d/S38smartdns ] && [ -f /opt/etc/init.d/S38smartdns.disabled ] && _parent_disabled="true"

  # Running: PIDFILE exists = rules attached
  if [ "$_st_running" = "true" ]; then
    running="true"
    uptime_seconds_val="$_st_uptime_seconds"
  fi

  # Enabled: symlink exists in /opt/etc/init.d/
  local enabled_val=1
  is_service_enabled "S39smartdns-redirect" && enabled_val=0

  # Parent disabled overrides enabled → false (spec §4.3)
  # Prevents webui showing 🔴 "Failed" for a non-failure state
  if [ "$_parent_disabled" = "true" ]; then
    enabled_val=1
    STATUS_OK=0
  fi

  # Determine if service is effectively disabled (self or parent)
  local _disabled="false"
  [ "$enabled_val" -ne 0 ] && _disabled="true"

  # Details — Redirect chain
  status_detail "redirect_mode" "${REDIRECT_MODE:-force}"
  status_detail "interfaces" "$INTERFACES"
  if [ "${REDIRECT_MODE:-force}" = "force" ]; then
    status_detail "dot_block" "on"
  else
    status_detail "dot_block" "off"
  fi
  status_detail "ipv6" "$IPV6_MODE"
  status_detail "dnat_target" "${ROUTER_IP}:${UPSTREAM_PORT}"
  if [ "$IPV6_MODE" = "dnat" ]; then
    status_detail "dnat_target_v6" "[${ROUTER_IP6}]:${UPSTREAM_PORT}"
  fi
  # Runtime details — skip when disabled (no red ✗ noise)
  if [ "$_disabled" = "false" ]; then
    status_detail "rules" "$_ck_rules_ok" "bool"
  fi
  # Details — Upstream resolver
  status_detail "upstream" "127.0.0.1:${UPSTREAM_PORT}"
  status_detail "name" "$_ck_upstream_name"
  if [ "$_disabled" = "false" ]; then
    status_detail "status" "$_ck_upstream_ok" "bool"
    # Details — Infrastructure (only shown when enabled — no ✓ noise when off)
    status_detail "ndm_hook" "$_ck_ndm_hook_ok" "bool"
    status_detail "init" "$_ck_init_ok" "bool"
  fi
  # Details — System
  status_detail "uptime" "$uptime_seconds_val" "num"
  status_detail "version" "${_st_version:-unknown}"
  # Parent-disabled hint (spec §4.3) — human-readable values for webui
  if [ "$_parent_disabled" = "true" ]; then
    status_detail "depends_on" "SmartDNS Geo-Config (disabled)"
    status_detail "action" "Enable SmartDNS Geo-Config"
  fi

  # Per-interface rule detail — empty when disabled (no noise)
  if [ "$_disabled" = "true" ]; then
    status_extra "rules_detail" "[]"
  else
    status_extra "rules_detail" "[${_ck_rules_json}]"
  fi

  # Checks — runtime checks → "skip" when disabled (spec §4.2/4.3)
  if [ "$_disabled" = "true" ]; then
    status_check_result "running" "skip"
    status_check_result "upstream" "skip"
  else
    status_check_result "running" "$(if [ "$running" = "true" ]; then printf ok; else printf fail; fi)"
    status_check_result "upstream" "$(if [ "$_ck_upstream_ok" = 0 ]; then printf ok; else printf fail; fi)"
  fi
  status_check_result "ndm_hook" "$(if [ "$_ck_ndm_hook_ok" = 0 ]; then printf ok; else printf fail; fi)"
  status_check_result "init" "$(if [ "$_ck_init_ok" = 0 ]; then printf ok; else printf fail; fi)"
  if [ "$_disabled" = "true" ]; then
    status_check_result "rules" "skip"
  else
    status_check_result "rules" "$(if [ "$_ck_rules_ok" = 0 ]; then printf ok; else printf fail; fi)"
  fi

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
  local _parent_disabled="false"
  # Check if parent service (SmartDNS) is intentionally disabled
  [ ! -x /opt/etc/init.d/S38smartdns ] && [ -f /opt/etc/init.d/S38smartdns.disabled ] && _parent_disabled="true"
  if [ "$_parent_disabled" = "true" ]; then
    _status_word="⏸ Pending (smartdns-geo-conf disabled)"
  elif ! is_service_enabled "S39smartdns-redirect"; then
    _status_word="⚠ Disabled"
  elif [ "$STATUS_OK" -ne 0 ]; then
    _status_word="✗ Fail"
  fi

  _text_buf="smartdns-redirect status: ${_status_word}
"

  if [ "$_parent_disabled" = "true" ]; then
    # Simplified output: parent disabled, no point showing failed rules/upstream
    status_section "Service"
    status_line "Upstream" "SmartDNS (stopped by smartdns-geo-conf disable)"
    status_line "Action" "run: /opt/etc/init.d/S37smartdns-conf enable"
    status_blank
    status_section "System"
    show_init
    show_ndm_hook
    show_version
  else
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
  fi

  status_emit_text
}

# --- main ---

if [ "${1:-}" = "--json" ]; then
  json_output
  exit "$STATUS_OK"
fi

text_output
exit "$STATUS_OK"
