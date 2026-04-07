#!/opt/bin/sh
# Common shared functions for keenetic-entware scripts.
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

# Get file modification time as epoch seconds (BusyBox compatible).
# BusyBox stat does not support GNU -c format.
# Args: $1 - file path
file_mtime() {
  stat -t "$1" | awk '{print $13}'
}
