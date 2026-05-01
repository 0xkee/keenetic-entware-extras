#!/opt/bin/sh
# Shared check/show functions for status scripts.
# Prereq: lib/common.sh must be sourced before this file
#   (provides: file_mtime, format_age, format_size_kb, installed_pkg_version)
# Usage: . "$SCRIPT_DIR/../../lib/status.sh"
# shellcheck disable=SC3043  # 'local' supported by ash/busybox sh
set -eu

# --- Check functions (set _st_* globals, never touch STATUS_OK) ---

# Detect process PID from pidfile with pidof fallback.
# Args: $1 - pidfile path, $2 - process name for pidof fallback
# Sets: _st_pid (empty if not running), _st_pid_source ("pidfile"|"pidof"|"")
status_detect_pid() {
  local pidfile="$1" proc_name="$2"
  _st_pid=""
  _st_pid_source=""
  if [ -f "$pidfile" ]; then
    _st_pid="$(cat "$pidfile" 2>/dev/null)" || true
    if [ -n "$_st_pid" ] && kill -0 "$_st_pid" 2>/dev/null; then
      _st_pid_source="pidfile"
      return 0
    fi
    _st_pid=""
  fi
  _st_pid="$(pidof "$proc_name" 2>/dev/null || true)"
  [ -n "$_st_pid" ] && _st_pid_source="pidof" || true
}

# Check process running state and memory usage.
# Requires: _st_pid set (via status_detect_pid)
# Sets: _st_running ("true"|"false"), _st_mem_kb (integer, 0 if unknown)
status_check_process() {
  _st_running="false"
  _st_mem_kb="0"
  if [ -n "$_st_pid" ] && kill -0 "$_st_pid" 2>/dev/null; then
    _st_running="true"
    _st_mem_kb="$(awk '/VmRSS/{print $2}' "/proc/$_st_pid/status" 2>/dev/null || echo "0")"
  fi
}

# Check uptime from pidfile mtime.
# Args: $1 - pidfile path
# Sets: _st_uptime_seconds (0 if not available)
status_check_uptime() {
  local pidfile="$1" mtime
  _st_uptime_seconds=0
  if [ -f "$pidfile" ]; then
    mtime="$(file_mtime "$pidfile")"
    if [ -n "$mtime" ] && [ "$mtime" -gt 0 ] 2>/dev/null; then
      _st_uptime_seconds=$(( $(date +%s) - mtime ))
    fi
  fi
}

# Check if port is listening (TCP/UDP).
# Args: $1 - port number, $2 - protocol: "tcp" (default) | "udp" | "any"
#       $3 - (optional) grep filter for process name (e.g. "smartdns")
# Sets: _st_port_ok ("true"|"false"), _st_port_addrs (space-separated listen addrs)
status_check_port() {
  local port="$1" proto="${2:-tcp}" proc_grep="${3:-}"
  local flags="" output=""
  _st_port_ok="false"
  _st_port_addrs=""

  # Build netstat/ss flags
  case "$proto" in
    tcp) flags="-tlnp" ;;
    udp) flags="-lnup" ;;
    any) flags="-tlnup" ;;
    *)   flags="-tlnp" ;;
  esac

  # Build grep pattern: by port or by process
  local pattern
  if [ -n "$proc_grep" ]; then
    pattern="$proc_grep"
  else
    pattern=":${port} "
  fi

  if command -v netstat >/dev/null 2>&1; then
    output="$(netstat "$flags" 2>/dev/null | grep "$pattern" || true)"
  elif command -v ss >/dev/null 2>&1; then
    output="$(ss "$flags" 2>/dev/null | grep "$pattern" || true)"
  fi

  if [ -n "$output" ]; then
    _st_port_ok="true"
    _st_port_addrs="$(echo "$output" | awk '{print $4}' | sort -u | tr '\n' ' ' | sed 's/ $//')"
  fi
}

# Check installed package version.
# Args: $1 - package name
# Sets: _st_version (empty if not installed)
status_check_version() {
  _st_version="$(installed_pkg_version "$1")"
}

# --- Show functions (text output for CLI) ---

# Print process status line.
# Requires: _st_running, _st_pid, _st_mem_kb, _st_pid_source
status_show_process() {
  if [ "$_st_running" = "true" ]; then
    echo "    Process:     running (pid $_st_pid via $_st_pid_source, RSS ${_st_mem_kb}kB) ✓"
  else
    echo "    Process:     NOT running ✗"
  fi
}

# Print uptime line.
# Requires: _st_uptime_seconds, _st_running
status_show_uptime() {
  if [ "$_st_running" = "true" ] && [ "$_st_uptime_seconds" -gt 0 ] 2>/dev/null; then
    echo "    Uptime:      $(format_age "$_st_uptime_seconds") ✓"
  elif [ "$_st_running" = "true" ]; then
    echo "    Uptime:      unknown"
  else
    echo "    Uptime:      — (not running)"
  fi
}

# Print version line.
# Requires: _st_version
status_show_version() {
  if [ -n "$_st_version" ]; then
    echo "    Version:     $_st_version"
  else
    echo "    Version:     — (not installed via opkg)"
  fi
}

# Print listening port(s) line.
# Args: $1 - port number (for "not listening" message)
# Requires: _st_port_ok, _st_port_addrs
status_show_port() {
  local port="${1:-?}"
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
    echo "    Ports:       :${port} not listening ✗"
  fi
}
