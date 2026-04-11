#!/opt/bin/sh
# Load GEO subnets into ipset from cached files.
# Does NOT download data or resolve domains — only loads from files.
# shellcheck disable=SC3043  # 'local' supported by ash/busybox sh
# shellcheck disable=SC1091  # sourced files resolved at runtime on router
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../../lib/common.sh"
. "$SCRIPT_DIR/../../lib/lists.sh"
_CONFIG_DIR="$(cd "$SCRIPT_DIR/../config" && pwd)"
. "$_CONFIG_DIR/config.sh"

# Temp restore file path (global for cleanup trap)
_TMP_RESTORE_FILE=""

# PID lock file (prevents concurrent runs)
PID_FILE="/opt/tmp/geo-bypass-apply.pid"

# Acquire PID-based lock. Exit if another instance is running.
acquire_lock() {
  if [ -f "$PID_FILE" ]; then
    local old_pid
    old_pid=$(cat "$PID_FILE" 2>/dev/null || echo "")
    if [ -n "$old_pid" ] && [ -d "/proc/$old_pid" ]; then
      log "Another instance is already running (PID $old_pid), skipping"
      exit 0
    fi
    log "Removing stale PID file (PID $old_pid)"
    rm -f "$PID_FILE"
  fi
  echo $$ > "$PID_FILE"
}

# Release PID lock
release_lock() {
  rm -f "$PID_FILE"
}

# Ensure main ipset exists (create if missing)
setup_ipset() {
  require_cmd ipset

  if ! ipset list "$IPSET_NAME" >/dev/null 2>&1; then
    log "Creating ipset: $IPSET_NAME (hash:net)"
    ipset create "$IPSET_NAME" hash:net
  else
    log "Ipset $IPSET_NAME already exists"
  fi
}

# Cleanup temporary ipset, restore file, and PID lock on exit/error
cleanup_all() {
  if [ -n "$_TMP_RESTORE_FILE" ] && [ -f "$_TMP_RESTORE_FILE" ]; then
    rm -f "$_TMP_RESTORE_FILE"
  fi
  ipset destroy "${IPSET_NAME}-tmp" 2>/dev/null || true
  release_lock
}

# Load subnets from file into ipset via restore + atomic swap
load_subnets() {
  local tmp_set="${IPSET_NAME}-tmp"

  _TMP_RESTORE_FILE="$(mktemp /opt/tmp/ipset-restore.XXXXXX)"

  # Build restore file: create tmp set + add entries
  echo "create ${tmp_set} hash:net" > "$_TMP_RESTORE_FILE"
  list_strip < "$SUBNET_LIST_FILE" | while IFS= read -r subnet; do
    echo "add ${tmp_set} ${subnet}"
  done >> "$_TMP_RESTORE_FILE"

  local count
  count=$(($(wc -l < "$_TMP_RESTORE_FILE") - 1))

  # Batch load into tmp set (timed — this is the heavy operation)
  local t_start t_end t_elapsed
  t_start=$(date +%s)
  ipset restore < "$_TMP_RESTORE_FILE"
  t_end=$(date +%s)
  t_elapsed=$((t_end - t_start))
  log "Loaded $count subnets into tmp ipset ${tmp_set} (${t_elapsed}s)"

  # Atomic swap: zero-downtime replacement
  ipset swap "$tmp_set" "$IPSET_NAME"
  log "Swapped ${tmp_set} → $IPSET_NAME"

  # Cleanup tmp
  ipset destroy "$tmp_set"
  rm -f "$_TMP_RESTORE_FILE"
  _TMP_RESTORE_FILE=""

  log "Ipset $IPSET_NAME updated ($count subnets)"
}

# Add IPs from file to ipset (one IP per line).
# NOTE: not using list_strip pipe — ip_count must stay in current shell
# (pipe creates subshell). Domain cache is machine-generated, no @include needed.
load_domain_ips() {
  local src_file="$1"
  local ip_count=0

  while IFS= read -r ip; do
    case "$ip" in
      ""|\#*) continue ;;
    esac
    ipset add "$IPSET_NAME" "$ip" -exist 2>/dev/null || true
    ip_count=$((ip_count + 1))
  done < "$src_file"

  echo "$ip_count"
}

# --- main ---
acquire_lock
trap cleanup_all EXIT

setup_ipset

if [ -f "$SUBNET_LIST_FILE" ]; then
  load_subnets
else
  log "No subnet cache file, skipping (run update-subnets.sh first)"
fi

if [ -f "${DOMAINS_CACHE_FILE:-}" ]; then
  count=$(load_domain_ips "$DOMAINS_CACHE_FILE")
  log "Loaded $count domain IPs from cache"
fi
