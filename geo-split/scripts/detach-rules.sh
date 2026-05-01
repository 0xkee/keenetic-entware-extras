#!/opt/bin/sh
# Detach GEO routing rules: remove ip rule iif br0 + flush route table.
# Route-based approach — no iptables mangle/fwmark.
# shellcheck disable=SC3043  # 'local' supported by ash/busybox sh
# shellcheck disable=SC1091  # sourced files resolved at runtime on router
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../../lib/common.sh"
_CONFIG_DIR="$(cd "$SCRIPT_DIR/../config" && pwd)"
. "$_CONFIG_DIR/defaults.conf"
[ -f "$_CONFIG_DIR/config.conf" ] && . "$_CONFIG_DIR/config.conf"

# Remove ip rules and flush route tables
main() {
  # Remove iif rules for all configured LAN interfaces
  local iface
  for iface in $ROUTE_IN; do
    ip rule del iif "$iface" table "$DOMAIN_ROUTE_TABLE" 2>/dev/null || true
    ip rule del iif "$iface" table "$SUBNET_ROUTE_TABLE" 2>/dev/null || true
  done

  # Flush all routes in custom tables
  ip route flush table "$DOMAIN_ROUTE_TABLE" 2>/dev/null || true
  ip route flush table "$SUBNET_ROUTE_TABLE" 2>/dev/null || true

  # Remove table fill stamp files (freshness tracking)
  rm -f "${TABLE_STAMP_PREFIX}${DOMAIN_ROUTE_TABLE}.filled"
  rm -f "${TABLE_STAMP_PREFIX}${SUBNET_ROUTE_TABLE}.filled"

  log "Rules detached (tables $DOMAIN_ROUTE_TABLE,$SUBNET_ROUTE_TABLE flushed, iif: $ROUTE_IN)"
}

main
