#!/opt/bin/sh
# Attach GEO routing rules: ip rule iif br0 + per-subnet routes via ip-batch.
# Route-based approach — no iptables mangle/fwmark (compatible with Keenetic NDM).
# Requires subnet list file (see update-subnets.sh).
# shellcheck disable=SC3043  # 'local' supported by ash/busybox sh
# shellcheck disable=SC1091  # sourced files resolved at runtime on router
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../../lib/common.sh"
_CONFIG_DIR="$SCRIPT_DIR/../config"
. "$_CONFIG_DIR/config.sh"

# Resolved target interface (set by resolve_target_interface)
TARGET_INTERFACE=""

# Detect ISP interface from default route.
# Excludes LAN bridges (br*) — those are NOT ISP interfaces.
detect_isp_interface() {
  ip route show default | sed -n 's/.*dev \([^ ]*\).*/\1/p' | grep -v '^br' | head -1
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

# Add ip rules: LAN traffic (iif) → custom route table.
# Creates one rule per interface in LAN_INTERFACES.
setup_ip_rules() {
  local iface
  for iface in $LAN_INTERFACES; do
    # Remove stale rule if present
    ip rule del iif "$iface" table "$ROUTE_TABLE" 2>/dev/null || true

    ip rule add iif "$iface" table "$ROUTE_TABLE" priority "$RULE_PRIORITY"
    log "IP rule: iif $iface → table $ROUTE_TABLE (priority $RULE_PRIORITY)"
  done
}

# Load per-subnet routes into the custom route table via ip-full -batch.
# Falls back to BusyBox ip loop if ip-full is not available.
load_routes_batch() {
  if [ ! -f "$SUBNET_LIST_FILE" ]; then
    log_error "Subnet list not found: $SUBNET_LIST_FILE"
    exit 1
  fi

  local count domain_count
  count=$(grep -cvE '^#|^$' "$SUBNET_LIST_FILE" || true)
  domain_count=0
  if [ -f "${DOMAINS_CACHE_FILE:-}" ]; then
    domain_count=$(grep -cvE '^#|^$' "$DOMAINS_CACHE_FILE" || true)
  fi
  log "Loading $count subnet + $domain_count domain routes into table $ROUTE_TABLE via $TARGET_INTERFACE..."

  local t_start t_end elapsed

  if [ -x "$IP_FULL" ]; then
    # Fast path: ip-full -batch (handles 13K+ routes in ~1s)
    {
      echo "route flush table $ROUTE_TABLE"
      grep -vE '^#|^$' "$SUBNET_LIST_FILE" | while read -r subnet; do
        echo "route add $subnet dev $TARGET_INTERFACE table $ROUTE_TABLE"
      done
      # Domain IPs (from resolved cache) — route replace to handle overlap safely
      if [ -f "${DOMAINS_CACHE_FILE:-}" ]; then
        grep -vE '^#|^$' "$DOMAINS_CACHE_FILE" | while read -r ip _rest; do
          echo "route replace $ip/32 dev $TARGET_INTERFACE table $ROUTE_TABLE"
        done
      fi
    } > "$BATCH_FILE"

    t_start=$(date +%s)
    "$IP_FULL" -batch "$BATCH_FILE"
    t_end=$(date +%s)
    elapsed=$((t_end - t_start))

    rm -f "$BATCH_FILE"
    log "Routes loaded via ip-full -batch ($count subnet + $domain_count domain in ${elapsed}s)"
  else
    # Slow fallback: BusyBox ip loop
    log "ip-full not found at $IP_FULL, using BusyBox loop (slow)"
    ip route flush table "$ROUTE_TABLE" 2>/dev/null || true

    t_start=$(date +%s)
    grep -vE '^#|^$' "$SUBNET_LIST_FILE" | while read -r subnet; do
      ip route add "$subnet" dev "$TARGET_INTERFACE" table "$ROUTE_TABLE" 2>/dev/null || true
    done
    # Domain IPs (from resolved cache)
    if [ -f "${DOMAINS_CACHE_FILE:-}" ]; then
      grep -vE '^#|^$' "$DOMAINS_CACHE_FILE" | while read -r ip _rest; do
        ip route replace "$ip/32" dev "$TARGET_INTERFACE" table "$ROUTE_TABLE" 2>/dev/null || true
      done
    fi
    t_end=$(date +%s)
    elapsed=$((t_end - t_start))

    log "Routes loaded via BusyBox loop ($count subnet + $domain_count domain in ${elapsed}s)"
  fi
}

# --- main ---
resolve_target_interface
setup_ip_rules
load_routes_batch
log "Rules attached: $TARGET_INTERFACE, table $ROUTE_TABLE, iif: $LAN_INTERFACES"
