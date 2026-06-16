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

# Check uptime from /proc/<pid>/stat (monotonic) or pidfile stored uptime.
# Uses boot-relative time to avoid clock-skew issues (NTP sync after boot
# can make wall-clock timestamps appear days off on routers without RTC battery).
# Args: $1 - pidfile path
# Sets: _st_uptime_seconds (0 if not available)
status_check_uptime() {
  local pidfile="$1"
  _st_uptime_seconds=0

  # Method 1: Real process — /proc/<pid>/stat field 22 (starttime in jiffies).
  # Monotonic, immune to wall-clock skew.
  if [ -n "${_st_pid:-}" ] && [ -f "/proc/$_st_pid/stat" ]; then
    local starttime uptime_sec
    starttime=$(awk '{print $22}' "/proc/$_st_pid/stat" 2>/dev/null) || starttime=""
    uptime_sec=$(awk '{printf "%d", $1}' /proc/uptime 2>/dev/null) || uptime_sec=""
    if [ -n "$starttime" ] && [ -n "$uptime_sec" ] && [ "$uptime_sec" -gt 0 ] 2>/dev/null; then
      _st_uptime_seconds=$((uptime_sec - starttime / 100))
      [ "$_st_uptime_seconds" -lt 0 ] && _st_uptime_seconds=0 || true
      return 0
    fi
  fi

  # Method 2: Marker pidfile with stored boot-relative uptime on line 2.
  # Written by update_pid_file() — immune to clock skew.
  if [ -f "$pidfile" ]; then
    local stored_uptime uptime_sec
    stored_uptime=$(sed -n '2p' "$pidfile" 2>/dev/null) || stored_uptime=""
    if [ -n "$stored_uptime" ] && [ "$stored_uptime" -gt 0 ] 2>/dev/null; then
      uptime_sec=$(awk '{printf "%d", $1}' /proc/uptime 2>/dev/null) || uptime_sec=""
      if [ -n "$uptime_sec" ]; then
        _st_uptime_seconds=$((uptime_sec - stored_uptime))
        [ "$_st_uptime_seconds" -lt 0 ] && _st_uptime_seconds=0 || true
        return 0
      fi
    fi
    # Method 3: Legacy fallback — pidfile mtime (subject to clock skew on
    # routers with bad RTC; kept for backward compat with old-format pidfiles).
    # Cap at system uptime: a service cannot run longer than the OS.
    local mtime sys_up
    mtime="$(file_mtime "$pidfile")" || mtime=""
    if [ -n "$mtime" ] && [ "$mtime" -gt 0 ] 2>/dev/null; then
      _st_uptime_seconds=$(( $(date +%s) - mtime ))
      [ "$_st_uptime_seconds" -lt 0 ] && _st_uptime_seconds=0 || true
      sys_up=$(awk '{printf "%d", $1}' /proc/uptime 2>/dev/null) || sys_up=""
      if [ -n "$sys_up" ] && [ "$_st_uptime_seconds" -gt "$sys_up" ]; then
        _st_uptime_seconds="$sys_up"
      fi
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

# --- Declarative text output API (accumulator + emit) ---
# Parallel to JSON accumulator: register lines, then flush with status_emit_text.
# Format: 4-space indent + 13-char label column + value + mark.

_text_buf=""

# Accumulate a section header.
# Args: $1 - title (without colon)
status_section() {
  _text_buf="${_text_buf}$(printf '  %s:\n' "$1")
"
}

# Accumulate a status line.
# Args: $1 - label (without colon), $2 - value, $3 - status: "ok"|"fail"|"warn"|"" (default: "")
status_line() {
  local label="$1" value="$2" status="${3:-}"
  local mark=""
  case "$status" in
    ok)   mark=" ✓" ;;
    fail) mark=" ✗" ;;
    warn) mark=" ⚠" ;;
    *)    mark="" ;;
  esac
  _text_buf="${_text_buf}$(printf '    %-13s%s%s\n' "${label}:" "$value" "$mark")
"
}

# Accumulate a continuation line (no label, aligned with value column).
# Args: $1 - value, $2 - status: "ok"|"fail"|"warn"|"" (default: "")
status_line_cont() {
  local value="$1" status="${2:-}"
  local mark=""
  case "$status" in
    ok)   mark=" ✓" ;;
    fail) mark=" ✗" ;;
    warn) mark=" ⚠" ;;
    *)    mark="" ;;
  esac
  _text_buf="${_text_buf}$(printf '                 %s%s\n' "$value" "$mark")
"
}

# Accumulate a blank separator line.
status_blank() {
  _text_buf="${_text_buf}
"
}

# Emit accumulated text to stdout and reset buffer.
status_emit_text() {
  printf '%s' "$_text_buf"
  _text_buf=""
}

# --- Show functions (text output helpers, use accumulator) ---

# Register process status line.
# Requires: _st_running, _st_pid, _st_mem_kb, _st_pid_source
status_show_process() {
  if [ "$_st_running" = "true" ]; then
    status_line "Process" "running (pid $_st_pid via $_st_pid_source, RSS ${_st_mem_kb}kB)" "ok"
  else
    status_line "Process" "NOT running" "fail"
  fi
}

# Register uptime line.
# Requires: _st_uptime_seconds, _st_running
status_show_uptime() {
  if [ "$_st_running" = "true" ] && [ "$_st_uptime_seconds" -gt 0 ] 2>/dev/null; then
    status_line "Uptime" "$(format_age "$_st_uptime_seconds")" "ok"
  elif [ "$_st_running" = "true" ]; then
    status_line "Uptime" "unknown"
  else
    status_line "Uptime" "— (not running)"
  fi
}

# Register version line.
# Requires: _st_version
status_show_version() {
  if [ -n "$_st_version" ]; then
    status_line "Version" "$_st_version"
  else
    status_line "Version" "— (not installed via opkg)"
  fi
}

# Register listening port(s) line.
# Args: $1 - port number (for "not listening" message)
# Requires: _st_port_ok, _st_port_addrs
status_show_port() {
  local port="${1:-?}"
  if [ "$_st_port_ok" = "true" ]; then
    local first=1 addr=""
    local _old_ifs="$IFS"
    IFS=' '
    for addr in $_st_port_addrs; do
      [ -z "$addr" ] && continue
      if [ "$first" = 1 ]; then
        status_line "Ports" "$addr" "ok"
        first=0
      else
        status_line_cont "$addr" "ok"
      fi
    done
    IFS="$_old_ifs"
  else
    status_line "Ports" ":${port} not listening" "fail"
  fi
}

# --- Declarative JSON accumulation API ---
# Accumulators for building structured JSON output without manual printf.
# Usage: call status_detail/status_check/status_extra, then status_emit_json.

_json_details=""
_json_checks=""
_json_extras=""

# Register a detail key-value pair for the "details" object.
# Args: $1 - key, $2 - value, $3 - type: "str" (default) | "num" | "bool"
# For bool: value is 0 (true) or non-0 (false), same convention as json_kv_bool.
status_detail() {
  local key="$1" val="$2" typ="${3:-str}"
  [ -n "$_json_details" ] && _json_details="${_json_details},"
  case "$typ" in
    num)  _json_details="${_json_details}$(json_kv_num "$key" "$val")" ;;
    bool) _json_details="${_json_details}$(json_kv_bool "$key" "$val")" ;;
    *)    _json_details="${_json_details}$(json_kv "$key" "$val")" ;;
  esac
}

# Register a check result for the "checks" object.
# Args: $1 - check name, $2 - "ok"|"warn"|"fail"
status_check_result() {
  [ -n "$_json_checks" ] && _json_checks="${_json_checks},"
  _json_checks="${_json_checks}$(json_check "$1" "$2")"
}

# Register an extra top-level key with pre-serialized JSON value.
# Use for arrays or nested objects that are already JSON strings.
# Args: $1 - key, $2 - raw JSON value (array/object, already serialized)
status_extra() {
  [ -n "$_json_extras" ] && _json_extras="${_json_extras},"
  _json_extras="${_json_extras}\"$1\":$2"
}

# Emit the full JSON object to stdout.
# Structure: {enabled, running, ok, details:{...}, [extras...], checks:{...}}
# Args: $1 - enabled (0=true|1=false), $2 - running (0|1), $3 - ok (0|1)
status_emit_json() {
  local enabled="$1" running="$2" ok="$3"
  printf '{'
  json_kv_bool "enabled" "$enabled"
  printf ','
  json_kv_bool "running" "$running"
  printf ','
  json_kv_bool "ok" "$ok"
  printf ',"details":{%s}' "$_json_details"
  [ -n "$_json_extras" ] && printf ',%s' "$_json_extras"
  printf ',"checks":{%s}' "$_json_checks"
  printf '}\n'
}
