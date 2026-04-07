#!/opt/bin/sh
# Attach GEO routing rules: ip rule + iptables mangle.
# Requires ipset to be already loaded (see load-ipset.sh).
# shellcheck disable=SC3043  # 'local' supported by ash/busybox sh
# shellcheck disable=SC1091  # sourced files resolved at runtime on router
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../../lib/common.sh"
_CONFIG_DIR="$SCRIPT_DIR/../config"
. "$_CONFIG_DIR/config.sh"

# Resolved target interface (set by resolve_target_interface)
TARGET_INTERFACE=""

# Detect ISP interface from default route
detect_isp_interface() {
  ip route show default | sed -n 's/.*dev \([^ ]*\).*/\1/p' | head -1
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

# Set up ip rule + iptables for routing via resolved TARGET_INTERFACE
setup_ip_rules() {
  require_cmd ip

  # Extract gateway if present (some routes are "scope link" without via)
  local gw
  gw=$(ip route show default dev "$TARGET_INTERFACE" 2>/dev/null \
    | sed -n 's/.*via \([^ ]*\).*/\1/p' | head -1)

  if [ -n "$gw" ]; then
    ip route replace default via "$gw" dev "$TARGET_INTERFACE" table "$ROUTE_TABLE" 2>/dev/null || true
    log "Route table $ROUTE_TABLE: default via $gw dev $TARGET_INTERFACE"
  else
    # Direct link route (no gateway — e.g. LTE, scope link)
    ip route replace default dev "$TARGET_INTERFACE" table "$ROUTE_TABLE" 2>/dev/null || true
    log "Route table $ROUTE_TABLE: default dev $TARGET_INTERFACE (scope link)"
  fi

  local fwmark="${FWMARK:-0x20000000}"
  local fwmask="${FWMARK_MASK:-0x20000000}"

  # Remove old rules (legacy full-mark and bitwise variants)
  ip rule del fwmark "0x${ROUTE_TABLE}" table "$ROUTE_TABLE" 2>/dev/null || true
  ip rule del fwmark "$fwmark/$fwmask" table "$ROUTE_TABLE" 2>/dev/null || true

  # Add rule with bitwise mask: match ONLY our bit, ignore Keenetic marks
  ip rule add fwmark "$fwmark/$fwmask" table "$ROUTE_TABLE" priority "$RULE_PRIORITY"
  log "IP rule: fwmark $fwmark/$fwmask → table $ROUTE_TABLE (priority $RULE_PRIORITY)"

  # iptables mangle: set our bit via xmark (preserves Keenetic's bits 0-27).
  # --set-xmark value/mask: newmark = (oldmark & ~mask) | (value & mask)
  iptables -t mangle -D PREROUTING -m set --match-set "$IPSET_NAME" dst -j MARK --set-mark "0x${ROUTE_TABLE}" 2>/dev/null || true
  iptables -t mangle -D PREROUTING -m set --match-set "$IPSET_NAME" dst -j MARK --set-xmark "$fwmark/$fwmask" 2>/dev/null || true
  iptables -t mangle -A PREROUTING -m set --match-set "$IPSET_NAME" dst -j MARK --set-xmark "$fwmark/$fwmask"
  log "iptables mangle: xmark $IPSET_NAME dst → $fwmark/$fwmask (bit 29)"
}

# --- main ---
resolve_target_interface
setup_ip_rules
log "Rules attached via $TARGET_INTERFACE"
