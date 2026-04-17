#!/opt/bin/sh
# Show SmartDNS diagnostic status.
# shellcheck disable=SC3043  # 'local' supported by ash/busybox sh
# shellcheck disable=SC1091
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../../lib/common.sh"

PIDFILE="/opt/var/run/smartdns.pid"
CONF="/opt/etc/smartdns/smartdns.conf"
CACHE_FILE="/opt/var/cache/smartdns.cache"

STATUS_OK=0

# Get SmartDNS PID (from pidfile or pidof fallback).
# Sets global __PID (empty if not running).
detect_pid() {
  __PID=""
  if [ -f "$PIDFILE" ]; then
    __PID="$(cat "$PIDFILE" 2>/dev/null)" || true
    if [ -n "$__PID" ] && kill -0 "$__PID" 2>/dev/null; then
      return 0
    fi
    __PID=""
  fi
  __PID="$(pidof smartdns 2>/dev/null || true)"
}

# Show process info: running/stopped, PID, RSS.
show_process() {
  if [ -n "$__PID" ] && kill -0 "$__PID" 2>/dev/null; then
    local mem src="pidfile"
    mem="$(awk '/VmRSS/{print $2}' "/proc/$__PID/status" 2>/dev/null || echo "?")"
    [ ! -f "$PIDFILE" ] && src="pidof"
    echo "    Process:     running (pid $__PID via $src, RSS ${mem}kB) ✓"
  else
    echo "    Process:     NOT running ✗"; STATUS_OK=1
  fi
}

# Show service uptime from pidfile mtime.
show_uptime() {
  if [ -f "$PIDFILE" ]; then
    local mtime age age_label
    mtime="$(file_mtime "$PIDFILE")"
    if [ -n "$mtime" ] && [ "$mtime" -gt 0 ] 2>/dev/null; then
      age=$(( $(date +%s) - mtime ))
      age_label="$(format_age "$age")"
      echo "    Uptime:      $age_label ✓"
    else
      echo "    Uptime:      unknown"
    fi
  else
    echo "    Uptime:      — (not running)"
  fi
}

# Show listening ports for SmartDNS process.
show_ports() {
  local lines first=1
  lines="$(netstat -tlnup 2>/dev/null | grep smartdns | awk '{print $4}' | sort -u)"
  if [ -n "$lines" ]; then
    echo "$lines" | while IFS= read -r addr; do
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

# Show config file info: server count, routing rules.
show_config() {
  if [ -f "$CONF" ]; then
    local servers rules
    servers="$(grep -c '^server' "$CONF" 2>/dev/null || echo 0)"
    rules="$(grep -c '^nameserver' "$CONF" 2>/dev/null || echo 0)"
    echo "    Config:      $CONF ($servers servers, $rules rules) ✓"
  else
    echo "    Config:      NOT found ✗"; STATUS_OK=1
  fi
}

# Show persistent cache status and size.
show_cache() {
  if [ -f "$CACHE_FILE" ]; then
    local size
    size="$(du -h "$CACHE_FILE" 2>/dev/null | awk '{print $1}')"
    echo "    Cache:       $size ($CACHE_FILE) ✓"
  else
    echo "    Cache:       not found"
  fi
}

# Show installed package version.
show_version() {
  local ver
  ver="$(installed_pkg_version smartdns-ru)"
  if [ -n "$ver" ]; then
    echo "    Version:     $ver"
  else
    echo "    Version:     — (not installed via opkg)"
  fi
}

# Run a single DNS test via main port 6053.
# Usage: dns_test <domain> <group_label>
dns_test() {
  local domain="$1" label="$2"
  local result ip_line
  result="$(dig +short +time=3 "$domain" @127.0.0.1 -p 6053 2>/dev/null || echo "FAILED")"
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

# --- main ---
detect_pid

echo "smartdns-ru status:"
echo "  Service:"
show_process
show_ports
show_config
show_cache
echo
echo "  System:"
show_uptime
show_version
echo
echo "  DNS Tests:"
show_dns_tests

exit "$STATUS_OK"
