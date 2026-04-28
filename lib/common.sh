#!/opt/bin/sh
# Common shared functions for keenetic-entware-extras scripts.
# Usage: source this file from other scripts:
#   SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
#   . "$SCRIPT_DIR/../lib/common.sh"
# shellcheck disable=SC3043  # 'local' supported by ash/busybox sh

# Log message with script name tag
# Args: $1 - message
log() {
  local tag
  tag="$(basename "$0" .sh)"
  logger -t "$tag" "$1"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$tag] $1"
}

# Log error to stderr and syslog
# Args: $1 - error message
log_error() {
  local tag
  tag="$(basename "$0" .sh)"
  logger -t "$tag" -p user.err "$1"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$tag] ERROR: $1" >&2
}

# Check if command exists
# Args: $1 - command name
require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    log_error "Required command not found: $1"
    exit 1
  fi
}

# Check if running on Entware (router)
is_entware() {
  [ -d /opt/etc ]
}

# Detect router LAN IP address (Keenetic br0 bridge).
# Method: br0 is the standard LAN bridge on Keenetic routers.
# Fallback: ip route get → source IP (may return VPN/WAN on tunneled setups).
# stdout: IP address or empty string
detect_router_ip() {
  local ip=""
  ip=$(ip -4 addr show br0 2>/dev/null | awk '/inet / {split($2, a, "/"); print a[1]; exit}')
  if [ -z "$ip" ]; then
    ip=$(ip route get 1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
  fi
  printf '%s' "$ip"
}

# Get file modification time as epoch seconds (BusyBox compatible).
# BusyBox stat does not support GNU -c format.
# Args: $1 - file path
file_mtime() {
  stat -t "$1" | awk '{print $13}'
}

# Check if file is fresh (younger than max_age seconds).
# Uses file_mtime() to get modification time.
# Args: $1 - file path, $2 - max age in seconds
# Returns: 0 if file exists and is younger than max_age, 1 otherwise
is_cache_fresh() {
  local file="$1" max_age="$2"
  [ -f "$file" ] || return 1
  local file_age
  file_age=$(( $(date +%s) - $(file_mtime "$file") ))
  [ "$file_age" -lt "$max_age" ]
}

# Format seconds as human-readable age.
# Examples: "2d 5h 30m", "1h 15m 3s", "8m 42s", "5s"
# Args: $1 - age in seconds (non-negative integer)
# stdout: formatted string
format_age() {
  local seconds="$1"
  local days hours mins secs result=""
  days=$((seconds / 86400))
  hours=$(( (seconds % 86400) / 3600 ))
  mins=$(( (seconds % 3600) / 60 ))
  secs=$((seconds % 60))
  [ "$days" -gt 0 ] && result="${days}d ${hours}h ${mins}m"
  [ -z "$result" ] && [ "$hours" -gt 0 ] && result="${hours}h ${mins}m ${secs}s"
  [ -z "$result" ] && [ "$mins" -gt 0 ] && result="${mins}m ${secs}s"
  [ -z "$result" ] && result="${secs}s"
  echo "$result"
}

# Format kilobytes as human-readable size with adaptive unit (KB/MB/GB).
# Uses best-fit unit: <1024 → "X KB", <1M → "X.X MB", else → "X.X GB".
# Args: $1 - size in kilobytes
# stdout: formatted string, e.g. "432 KB", "11.1 MB", "1.2 GB"
format_size_kb() {
  local kb="$1"
  awk "BEGIN{
    if ($kb < 1024) printf \"%d KB\", $kb
    else if ($kb < 1048576) printf \"%.1f MB\", $kb/1024
    else printf \"%.1f GB\", $kb/1048576
  }"
}

# Read installed package version via opkg.
# Uses 'opkg list-installed' (fast, reliable on Entware) instead of
# 'opkg info' which may return empty or stale data.
# Output format: "pkg - version" → extract version field.
# Args: $1 - package name
# stdout: version string, or empty if not installed
installed_pkg_version() {
  opkg list-installed "$1" 2>/dev/null | awk -F ' - ' '{print $2}'
}

# Escape a string for safe JSON value embedding (no surrounding quotes).
# Handles: backslash, double-quote, newline, tab.
# POSIX-compatible via awk.
# Args: $1 - string to escape
# stdout: escaped string
json_escape_val() {
  printf '%s' "$1" | awk '
    BEGIN { ORS="" }
    {
      gsub(/\\/, "\\\\")
      gsub(/"/, "\\\"")
      gsub(/\t/, "\\t")
      if (NR > 1) printf "\\n"
      printf "%s", $0
    }
  '
}

# Emit a JSON key-value pair: "key":"value" (value is escaped).
# Args: $1 - key, $2 - value
# stdout: "key":"escaped_value"
json_kv() {
  printf '"%s":"%s"' "$1" "$(json_escape_val "$2")"
}

# Emit a JSON key with numeric value: "key":number
# Args: $1 - key, $2 - numeric value
# stdout: "key":number
json_kv_num() {
  printf '"%s":%s' "$1" "${2:-0}"
}

# Emit a JSON key with boolean value: "key":true/false
# Args: $1 - key, $2 - 0 for true, non-0 for false
# stdout: "key":true or "key":false
json_kv_bool() {
  if [ "${2:-1}" = "0" ]; then
    printf '"%s":true' "$1"
  else
    printf '"%s":false' "$1"
  fi
}
