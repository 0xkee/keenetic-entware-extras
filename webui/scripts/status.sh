#!/opt/bin/sh
# Show nginx-webui diagnostic status.
# shellcheck disable=SC3043  # 'local' supported by ash/busybox sh
# shellcheck disable=SC1091
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../../lib/common.sh"

PIDFILE="/opt/var/run/nginx-webui.pid"
CONF="/opt/keenetic-entware-extras/webui/config/nginx.conf"
LISTEN_PORT="8080"
BASE_URL="http://127.0.0.1:${LISTEN_PORT}"

STATUS_OK=0

# Get nginx-webui PID (from pidfile or pidof fallback).
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
  __PID="$(pidof nginx 2>/dev/null || true)"
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

# Show config file presence.
show_config() {
  if [ -f "$CONF" ]; then
    echo "    Config:      $CONF ✓"
  else
    echo "    Config:      $CONF NOT FOUND ✗"; STATUS_OK=1
  fi
}

# Show Lua dynamic module presence.
show_lua_module() {
  local mod="/opt/lib/nginx/modules/ngx_http_lua_module.so"
  if [ -f "$mod" ]; then
    echo "    Lua module:  $mod ✓"
  else
    echo "    Lua module:  $mod NOT FOUND ✗"; STATUS_OK=1
  fi
}

# Show listening port status.
show_port() {
  local listening=""
  if command -v netstat >/dev/null 2>&1; then
    listening="$(netstat -tlnp 2>/dev/null | grep ":${LISTEN_PORT} " | head -1)" || true
  elif command -v ss >/dev/null 2>&1; then
    listening="$(ss -tlnp 2>/dev/null | grep ":${LISTEN_PORT} " | head -1)" || true
  fi
  if [ -n "$listening" ]; then
    echo "    Port:        :${LISTEN_PORT} listening ✓"
  else
    echo "    Port:        :${LISTEN_PORT} not listening ✗"; STATUS_OK=1
  fi
}

# Show HTTP endpoint checks (static page + API).
show_http() {
  if ! command -v curl >/dev/null 2>&1; then
    echo "    HTTP:        curl not available, skipping"
    return
  fi

  local http_code
  http_code="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 5 "${BASE_URL}/" 2>/dev/null)" || true
  if [ "$http_code" = "200" ]; then
    echo "    Static:      GET / → $http_code ✓"
  else
    echo "    Static:      GET / → ${http_code:-timeout} ✗"; STATUS_OK=1
  fi

  http_code="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 5 "${BASE_URL}/api/system/info" 2>/dev/null)" || true
  if [ "$http_code" = "200" ]; then
    echo "    API:         GET /api/system/info → $http_code ✓"
  else
    echo "    API:         GET /api/system/info → ${http_code:-timeout} ✗"; STATUS_OK=1
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

# Show logrotate status for nginx-webui logs.
show_logrotate() {
  local all_ok=true

  if [ -x "/opt/sbin/logrotate" ]; then
    echo "    Binary:      /opt/sbin/logrotate ✓"
  else
    echo "    Binary:      /opt/sbin/logrotate NOT FOUND ✗"; all_ok=false
  fi

  if [ -f "/opt/etc/logrotate.d/nginx-webui" ]; then
    echo "    Config:      /opt/etc/logrotate.d/nginx-webui ✓"
  else
    echo "    Config:      /opt/etc/logrotate.d/nginx-webui NOT FOUND ✗"; all_ok=false
  fi

  if [ -x "/opt/etc/cron.daily/logrotate" ]; then
    echo "    Cron daily:  /opt/etc/cron.daily/logrotate ✓"
  else
    echo "    Cron daily:  /opt/etc/cron.daily/logrotate NOT FOUND ✗"; all_ok=false
  fi

  if ! "$all_ok"; then STATUS_OK=1; fi
}

# Show installed package version.
show_version() {
  local ver
  ver="$(installed_pkg_version nginx-webui)"
  if [ -n "$ver" ]; then
    echo "    Version:     $ver"
  else
    echo "    Version:     — (not installed via opkg)"
  fi
}

# Collect structured data and emit JSON for webui.
json_output() {
  local running="false" pid_val="" mem_val="" version_val=""
  local port_ok="false"

  # Process
  if [ -n "$__PID" ] && kill -0 "$__PID" 2>/dev/null; then
    running="true"
    pid_val="$__PID"
    mem_val="$(awk '/VmRSS/{print $2}' "/proc/$__PID/status" 2>/dev/null || echo "0")"
  fi

  # Uptime
  if [ -f "$PIDFILE" ]; then
    local mtime age
    mtime="$(file_mtime "$PIDFILE")"
    if [ -n "$mtime" ] && [ "$mtime" -gt 0 ] 2>/dev/null; then
      age=$(( $(date +%s) - mtime ))
      uptime_seconds_val="$age"
    fi
  fi

  # Port
  local listening=""
  if command -v netstat >/dev/null 2>&1; then
    listening="$(netstat -tlnp 2>/dev/null | grep ":${LISTEN_PORT} " | head -1)" || true
  elif command -v ss >/dev/null 2>&1; then
    listening="$(ss -tlnp 2>/dev/null | grep ":${LISTEN_PORT} " | head -1)" || true
  fi
  [ -n "$listening" ] && port_ok="true"

  # Version
  version_val="$(installed_pkg_version nginx-webui)"

  # Config file presence
  local config_ok_val=1
  [ -f "$CONF" ] && config_ok_val=0

  # Lua module presence
  local lua_module_ok_val=1
  [ -f "/opt/lib/nginx/modules/ngx_http_lua_module.so" ] && lua_module_ok_val=0

  # HTTP ok: use port_listening as proxy (avoids curl recursion via nginx lua)
  local http_ok_val=1
  [ "$port_ok" = "true" ] && http_ok_val=0

  # Logrotate: binary + config + cron wrapper all present
  local logrotate_ok_val=1
  if [ -x "/opt/sbin/logrotate" ] \
     && [ -f "/opt/etc/logrotate.d/nginx-webui" ] \
     && [ -x "/opt/etc/cron.daily/logrotate" ]; then
    logrotate_ok_val=0
  fi

  printf '{'
  json_kv_bool "running" "$([ "$running" = "true" ] && echo 0 || echo 1)"
  printf ','
  json_kv_bool "ok" "$STATUS_OK"
  printf ',"details":{'
  json_kv "port" "$LISTEN_PORT"
  printf ','
  json_kv_bool "status" "$([ "$port_ok" = "true" ] && echo 0 || echo 1)"
  printf ','
  json_kv_bool "config" "$config_ok_val"
  printf ','
  json_kv_bool "lua_module" "$lua_module_ok_val"
  printf ','
  json_kv_bool "http" "$http_ok_val"
  printf ','
  json_kv "pid" "$pid_val"
  printf ','
  json_kv "memory" "$([ -n "$mem_val" ] && [ "$mem_val" != "0" ] && format_size_kb "$mem_val" || printf '')"
  printf ','
  json_kv_bool "logrotate" "$logrotate_ok_val"
  printf ','
  json_kv_num "uptime" "${uptime_seconds_val:-0}"
  printf ','
  json_kv "version" "${version_val:-unknown}"
  printf '}}\n'
}

# --- main ---
detect_pid

if [ "${1:-}" = "--json" ]; then
  # Run checks silently to set STATUS_OK
  show_process >/dev/null 2>&1 || true
  show_port >/dev/null 2>&1 || true
  show_config >/dev/null 2>&1 || true
  json_output
  exit "$STATUS_OK"
fi

echo "nginx-webui status:"
echo "  Service:"
show_process
show_config
show_lua_module
show_port
echo
echo "  HTTP:"
show_http
echo
echo "  Logrotate:"
show_logrotate
echo
echo "  System:"
show_uptime
show_version

exit "$STATUS_OK"
