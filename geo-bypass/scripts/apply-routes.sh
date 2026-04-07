#!/opt/bin/sh
# Apply GEO routing rules: load subnets into ipset, configure ip rules.
# Run after update-domains.sh has fetched the GEO subnet list.
# shellcheck disable=SC3043  # 'local' supported by ash/busybox sh
# shellcheck disable=SC1091  # sourced files resolved at runtime on router
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../../lib/common.sh"
_CONFIG_DIR="$SCRIPT_DIR/../config"
. "$_CONFIG_DIR/config.sh"

# Resolved target interface (set by resolve_target_interface)
TARGET_INTERFACE=""

# Temp restore file path (global for cleanup trap)
_TMP_RESTORE_FILE=""

# PID lock file (prevents concurrent runs)
PID_FILE="/tmp/geo-bypass-apply.pid"

# Acquire PID-based lock. Exit if another instance is running.
acquire_lock() {
  if [ -f "$PID_FILE" ]; then
    local old_pid
    old_pid=$(cat "$PID_FILE" 2>/dev/null || echo "")
    if [ -n "$old_pid" ] && [ -d "/proc/$old_pid" ]; then
      log "Another instance is already running (PID $old_pid), skipping"
      exit 0
    fi
    # Stale PID file — previous run crashed
    log "Removing stale PID file (PID $old_pid)"
    rm -f "$PID_FILE"
  fi
  echo $$ > "$PID_FILE"
}

# Release PID lock (called via trap)
release_lock() {
  rm -f "$PID_FILE"
}

# Detect ISP interface from default route
detect_isp_interface() {
  ip route show default | awk '{print $5; exit}'
}

# Resolve target interface based on ROUTE_MODE
resolve_target_interface() {
  case "$ROUTE_MODE" in
    bypass)
      if [ -n "$ISP_INTERFACE" ]; then
        TARGET_INTERFACE="$ISP_INTERFACE"
      else
        TARGET_INTERFACE="$(detect_isp_interface)"
      fi
      log "Mode: bypass → target interface: $TARGET_INTERFACE"
      ;;
    vpn)
      TARGET_INTERFACE="$VPN_INTERFACE"
      log "Mode: vpn → target interface: $TARGET_INTERFACE"
      ;;
    auto)
      TARGET_INTERFACE="$(detect_isp_interface)"
      log "Mode: auto → detected ISP interface: $TARGET_INTERFACE"
      ;;
    *)
      log_error "Unknown ROUTE_MODE: $ROUTE_MODE (expected: bypass, vpn, auto)"
      exit 1
      ;;
  esac

  if [ -z "$TARGET_INTERFACE" ]; then
    log_error "Failed to resolve target interface (mode=$ROUTE_MODE)"
    exit 1
  fi
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
  if [ ! -f "$SUBNET_LIST_FILE" ]; then
    log_error "Subnet list not found: $SUBNET_LIST_FILE"
    log_error "Run update-domains.sh first"
    exit 1
  fi

  local tmp_set="${IPSET_NAME}-tmp"

  # Temp file for ipset restore batch
  _TMP_RESTORE_FILE="$(mktemp /tmp/ipset-restore.XXXXXX)"

  # Build restore file: create tmp set + add entries
  echo "create ${tmp_set} hash:net" > "$_TMP_RESTORE_FILE"
  while IFS= read -r subnet; do
    # Skip empty lines and comments
    case "$subnet" in
      ""|\#*) continue ;;
    esac
    echo "add ${tmp_set} ${subnet}"
  done < "$SUBNET_LIST_FILE" >> "$_TMP_RESTORE_FILE"

  # Count entries (exclude 'create' line)
  local count
  count=$(($(wc -l < "$_TMP_RESTORE_FILE") - 1))

  # Batch load into tmp set
  ipset restore < "$_TMP_RESTORE_FILE"
  log "Loaded $count subnets into tmp ipset ${tmp_set}"

  # Atomic swap: zero-downtime replacement
  ipset swap "$tmp_set" "$IPSET_NAME"
  log "Swapped ${tmp_set} → $IPSET_NAME"

  # Cleanup
  ipset destroy "$tmp_set"
  rm -f "$_TMP_RESTORE_FILE"
  _TMP_RESTORE_FILE=""

  log "Ipset $IPSET_NAME updated ($count subnets)"
}

# Filter out private/special IPs from stdin
# Passes through only routable public IPv4 addresses
filter_private_ips() {
  grep -vE \
    -e '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)' \
    -e '^(0\.|127\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.|255\.255\.255\.255)'
}

# Check if domain IP cache is still fresh
is_domains_cache_fresh() {
  if [ ! -f "$DOMAINS_CACHE_FILE" ]; then
    return 1
  fi

  local file_age
  file_age=$(( $(date +%s) - $(stat -c %Y "$DOMAINS_CACHE_FILE") ))

  if [ "$file_age" -gt "$DOMAINS_CACHE_AGE" ]; then
    return 1
  fi

  log "Domain IP cache is fresh (${file_age}s old, max ${DOMAINS_CACHE_AGE}s)"
  return 0
}

# Add IPs from file to ipset (one IP per line)
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

# Resolve domains from DOMAINS_LIST_FILE and add IPs to ipset
# Uses cache file to avoid re-resolving on every run
resolve_domains() {
  # Skip if DOMAINS_LIST_FILE not configured
  if [ -z "${DOMAINS_LIST_FILE:-}" ]; then
    log "Domain resolution: skipped (DOMAINS_LIST_FILE not set)"
    return 0
  fi

  # Skip if file doesn't exist
  if [ ! -f "$DOMAINS_LIST_FILE" ]; then
    log "Domain resolution: skipped (file not found: $DOMAINS_LIST_FILE)"
    return 0
  fi

  # Skip if dig not installed
  if ! command -v dig >/dev/null 2>&1; then
    log "Domain resolution: skipped (dig not installed, run: opkg install bind-dig)"
    return 0
  fi

  # Use cache if fresh
  if is_domains_cache_fresh; then
    local cached_count
    cached_count=$(load_domain_ips "$DOMAINS_CACHE_FILE")
    log "Domain resolution: loaded $cached_count IPs from cache"
    return 0
  fi

  local domain_count=0
  local ip_count=0
  local skip_count=0
  local tmp_cache
  tmp_cache="${DOMAINS_CACHE_FILE}.tmp"

  : > "$tmp_cache"

  while IFS= read -r domain; do
    # Skip empty lines and comments
    case "$domain" in
      ""|\#*) continue ;;
    esac

    # Trim whitespace
    domain=$(echo "$domain" | tr -d ' \t')
    [ -z "$domain" ] && continue

    domain_count=$((domain_count + 1))

    # Resolve domain via local DNS
    local dig_out
    dig_out=$(dig +short "$domain" @localhost 2>/dev/null) || continue

    # Process each line of dig output
    # shellcheck disable=SC2086  # intentional word splitting on dig output
    for ip in $dig_out; do
      # Skip non-IPv4 (CNAMEs, AAAA, etc.)
      case "$ip" in
        *[!0-9.]*) continue ;;
      esac

      # Filter private/special IPs
      if ! echo "$ip" | filter_private_ips | grep -q .; then
        skip_count=$((skip_count + 1))
        continue
      fi

      echo "$ip" >> "$tmp_cache"
      ipset add "$IPSET_NAME" "$ip" -exist 2>/dev/null || true
      ip_count=$((ip_count + 1))
    done
  done < "$DOMAINS_LIST_FILE"

  # Save cache
  mv "$tmp_cache" "$DOMAINS_CACHE_FILE"

  log "Domain resolution: $domain_count domains, $ip_count IPs added, $skip_count private IPs skipped"
}

# Set up ip rule + iptables for routing via resolved TARGET_INTERFACE
setup_ip_rules() {
  require_cmd ip

  # Get default gateway for target interface
  local gw
  gw=$(ip route show dev "$TARGET_INTERFACE" | awk '/default/ {print $3}')

  if [ -z "$gw" ]; then
    log_error "Cannot find default gateway for $TARGET_INTERFACE"
    exit 1
  fi

  # Add default route to custom table via target interface
  ip route replace default via "$gw" dev "$TARGET_INTERFACE" table "$ROUTE_TABLE" 2>/dev/null || true
  log "Route table $ROUTE_TABLE: default via $gw dev $TARGET_INTERFACE"

  # Using fwmark approach: iptables marks packets, ip rule routes by mark
  local fwmark="0x${ROUTE_TABLE}"

  # Remove old rule if exists
  ip rule del fwmark "$fwmark" table "$ROUTE_TABLE" 2>/dev/null || true

  # Add rule
  ip rule add fwmark "$fwmark" table "$ROUTE_TABLE" priority "$RULE_PRIORITY"
  log "IP rule: fwmark $fwmark → table $ROUTE_TABLE (priority $RULE_PRIORITY)"

  # iptables: mark packets destined for ipset subnets
  iptables -t mangle -D PREROUTING -m set --match-set "$IPSET_NAME" dst -j MARK --set-mark "$fwmark" 2>/dev/null || true
  iptables -t mangle -A PREROUTING -m set --match-set "$IPSET_NAME" dst -j MARK --set-mark "$fwmark"
  log "iptables mangle: mark $IPSET_NAME dst → $fwmark"
}

# --- main ---
main() {
  acquire_lock
  trap cleanup_all EXIT
  log "Applying geo-bypass rules (mode=$ROUTE_MODE)..."
  resolve_target_interface
  setup_ipset
  load_subnets
  resolve_domains
  setup_ip_rules
  log "Done. Subnets routed via $TARGET_INTERFACE (mode=$ROUTE_MODE)"
}

main "$@"
