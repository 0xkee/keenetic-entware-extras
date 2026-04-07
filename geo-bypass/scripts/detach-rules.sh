#!/opt/bin/sh
# Detach GEO routing rules: remove ip rule iif br0 + flush route table.
# Route-based approach — no iptables mangle/fwmark.
# shellcheck disable=SC3043  # 'local' supported by ash/busybox sh
# shellcheck disable=SC1091  # sourced files resolved at runtime on router
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../../lib/common.sh"
_CONFIG_DIR="$SCRIPT_DIR/../config"
. "$_CONFIG_DIR/config.sh"

# Remove ip rules and flush route table
main() {
  # Remove iif rules for all configured LAN interfaces
  local iface
  for iface in $LAN_INTERFACES; do
    ip rule del iif "$iface" table "$ROUTE_TABLE" 2>/dev/null || true
  done

  # Flush all routes in the custom table
  ip route flush table "$ROUTE_TABLE" 2>/dev/null || true

  log "Rules detached (table $ROUTE_TABLE flushed, iif: $LAN_INTERFACES)"
}

main
