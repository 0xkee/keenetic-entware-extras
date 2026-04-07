#!/opt/bin/sh
# Detach GEO routing rules: remove ip rule + iptables mangle.
# shellcheck disable=SC3043  # 'local' supported by ash/busybox sh
# shellcheck disable=SC1091  # sourced files resolved at runtime on router
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../../lib/common.sh"
_CONFIG_DIR="$SCRIPT_DIR/../config"
. "$_CONFIG_DIR/config.sh"

# Remove ip rule, flush route table, and delete iptables mangle mark
main() {
  local fwmark="${FWMARK:-0x20000000}"
  local fwmask="${FWMARK_MASK:-0x20000000}"

  # Remove ip rules (legacy full-mark and bitwise variants)
  ip rule del fwmark "0x${ROUTE_TABLE}" table "$ROUTE_TABLE" 2>/dev/null || true
  ip rule del fwmark "$fwmark/$fwmask" table "$ROUTE_TABLE" 2>/dev/null || true
  ip route flush table "$ROUTE_TABLE" 2>/dev/null || true

  # Remove mangle marks (legacy and bitwise)
  iptables -t mangle -D PREROUTING \
    -m set --match-set "$IPSET_NAME" dst \
    -j MARK --set-mark "0x${ROUTE_TABLE}" 2>/dev/null || true
  iptables -t mangle -D PREROUTING \
    -m set --match-set "$IPSET_NAME" dst \
    -j MARK --set-xmark "$fwmark/$fwmask" 2>/dev/null || true

  log "Rules detached"
}

main
