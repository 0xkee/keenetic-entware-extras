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
  echo "    Upstream:    127.0.0.1:$UPSTREAM_PORT"
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

# --- main ---
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
