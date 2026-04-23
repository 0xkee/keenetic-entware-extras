#!/opt/bin/sh
# Show smartdns-redirect diagnostic status.
# shellcheck disable=SC3043
# shellcheck disable=SC1091
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../../lib/common.sh"
_CONFIG_DIR="$(cd "$SCRIPT_DIR/../config" && pwd)"
CONFIG_FILE="$_CONFIG_DIR/smartdns-redirect.conf"
# shellcheck source=/dev/null
. "$CONFIG_FILE"

STATUS_OK=0

# Show configuration: source file and resolver parameters.
show_mode() {
  echo "  Mode:"
  echo "    Config:      $CONFIG_FILE"
  local _uname
  _uname=$(netstat -tlnup 2>/dev/null | grep ":${UPSTREAM_PORT} " | head -1 \
    | sed -n 's|.*/\([^ ]*\)$|\1|p') || true
  echo "    Upstream:    127.0.0.1:$UPSTREAM_PORT (${_uname:-unknown})"
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

# Probe that the upstream resolver actually listens on UPSTREAM_PORT (UDP).
show_upstream() {
  echo "  Upstream probe:"
  local listening=""
  if command -v netstat >/dev/null 2>&1; then
    listening=$(netstat -lnu 2>/dev/null | awk '{print $4}' \
      | grep -E "(^|:)${UPSTREAM_PORT}\$" | head -1)
  elif command -v ss >/dev/null 2>&1; then
    listening=$(ss -lnu 2>/dev/null | awk '{print $5}' \
      | grep -E "(^|:)${UPSTREAM_PORT}\$" | head -1)
  fi
  if [ -n "$listening" ]; then
    echo "    UDP :$UPSTREAM_PORT: listening ($listening) ✓"
  else
    echo "    UDP :$UPSTREAM_PORT: no listener ✗"
    STATUS_OK=1
  fi
}

# Check NDM netfilter.d hook presence.
show_ndm_hook() {
  local hook="/opt/etc/ndm/netfilter.d/smartdns-redirect-hook"
  if [ -x "$hook" ]; then
    echo "    NDM hook:    $hook ✓"
  elif [ -f "$hook" ]; then
    echo "    NDM hook:    $hook (not executable) ✗"
    STATUS_OK=1
  else
    echo "    NDM hook:    ✗ (missing)"
    STATUS_OK=1
  fi
}

# Check init.d wrapper presence.
show_init() {
  local init="/opt/etc/init.d/S39smartdns-redirect"
  if [ -x "$init" ]; then
    echo "    Init:        $init ✓"
  elif [ -f "$init" ]; then
    echo "    Init:        $init (not executable) ✗"
    STATUS_OK=1
  else
    echo "    Init:        ✗ (missing)"
    STATUS_OK=1
  fi
}

# Show service uptime from PID file written by S39smartdns-redirect start.
show_uptime() {
  if [ -f "$PIDFILE" ]; then
    local age age_label
    age=$(( $(date +%s) - $(file_mtime "$PIDFILE") ))
    age_label="$(format_age "$age")"
    echo "    Uptime:      $age_label ✓"
  else
    echo "    Uptime:      — (not running)"
    STATUS_OK=1
  fi
}

# Show installed package version (if registered in opkg).
show_version() {
  local ver
  ver=$(installed_pkg_version smartdns-redirect)
  if [ -n "$ver" ]; then
    echo "    Version:     $ver"
  else
    echo "    Version:     — (not installed via opkg)"
  fi
}

# Collect structured data and emit JSON for webui.
json_output() {
  local running="false" version_val=""
  local upstream_ok="false" upstream_name=""

  # Running: PIDFILE exists = service is attached
  if [ -f "$PIDFILE" ]; then
    running="true"
    local age
    age=$(( $(date +%s) - $(file_mtime "$PIDFILE") ))
    uptime_seconds_val="$age"
  fi

  # Upstream listening?
  local listening=""
  if command -v netstat >/dev/null 2>&1; then
    listening=$(netstat -lnu 2>/dev/null | awk '{print $4}' \
      | grep -E "(^|:)${UPSTREAM_PORT}\$" | head -1)
  elif command -v ss >/dev/null 2>&1; then
    listening=$(ss -lnu 2>/dev/null | awk '{print $5}' \
      | grep -E "(^|:)${UPSTREAM_PORT}\$" | head -1)
  fi
  [ -n "$listening" ] && upstream_ok="true"

  # Detect upstream DNS name by process on UPSTREAM_PORT
  upstream_name=$(netstat -tlnup 2>/dev/null | grep ":${UPSTREAM_PORT} " | head -1 \
    | sed -n 's|.*/\([^ ]*\)$|\1|p') || true
  [ -z "$upstream_name" ] && upstream_name="unknown"

  # Version
  version_val=$(installed_pkg_version smartdns-redirect)

  # Rules check: verify iptables REDIRECT rules for all interfaces × protos
  local rules_ok_val=0 _iface _proto
  if [ -n "$INTERFACES" ]; then
    for _iface in $INTERFACES; do
      for _proto in udp tcp; do
        iptables -t nat -C PREROUTING -i "$_iface" -p "$_proto" --dport 53 \
          -j REDIRECT --to-ports "$UPSTREAM_PORT" 2>/dev/null || rules_ok_val=1
      done
    done
    if [ "$ENABLE_IPV6" = "yes" ] && command -v ip6tables >/dev/null 2>&1; then
      for _iface in $INTERFACES; do
        for _proto in udp tcp; do
          ip6tables -t nat -C PREROUTING -i "$_iface" -p "$_proto" --dport 53 \
            -j REDIRECT --to-ports "$UPSTREAM_PORT" 2>/dev/null || rules_ok_val=1
        done
      done
    fi
  fi

  # NDM hook presence
  local ndm_hook_ok_val=1
  [ -x "/opt/etc/ndm/netfilter.d/smartdns-redirect-hook" ] && ndm_hook_ok_val=0

  # Init script presence
  local init_ok_val=1
  [ -x "/opt/etc/init.d/S39smartdns-redirect" ] && init_ok_val=0

  printf '{'
  json_kv_bool "running" "$([ "$running" = "true" ] && echo 0 || echo 1)"
  printf ','
  json_kv_bool "ok" "$STATUS_OK"
  printf ',"details":{'
  json_kv "interfaces" "$INTERFACES"
  printf ','
  json_kv "ipv6" "$ENABLE_IPV6"
  printf ','
  json_kv_bool "ndm_hook" "$ndm_hook_ok_val"
  printf ','
  json_kv "upstream" "127.0.0.1:${UPSTREAM_PORT}"
  printf ','
  json_kv "name" "$upstream_name"
  printf ','
  json_kv_bool "status" "$([ "$upstream_ok" = "true" ] && echo 0 || echo 1)"
  printf ','
  json_kv_bool "init" "$init_ok_val"
  printf ','
  json_kv_bool "rules" "$rules_ok_val"
  printf ','
  json_kv_num "uptime" "${uptime_seconds_val:-0}"
  printf ','
  json_kv "version" "${version_val:-unknown}"
  printf '}}\n'
}

# --- main ---
if [ "${1:-}" = "--json" ]; then
  # Run checks silently to set STATUS_OK
  show_rules >/dev/null 2>&1 || true
  show_upstream >/dev/null 2>&1 || true
  json_output
  exit "$STATUS_OK"
fi

echo "smartdns-redirect status:"
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
