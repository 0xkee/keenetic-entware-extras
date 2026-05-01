#!/opt/bin/sh
# Attach ip rules: connect LAN interfaces to geo-split routing tables.
# Does NOT load routes — that is done by update-subnets.sh / update-domains.sh.
# shellcheck disable=SC3043  # 'local' supported by ash/busybox sh
# shellcheck disable=SC1091  # sourced files resolved at runtime on router
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../../lib/common.sh"
_CONFIG_DIR="$(cd "$SCRIPT_DIR/../config" && pwd)"
. "$_CONFIG_DIR/defaults.conf"
[ -f "$_CONFIG_DIR/config.conf" ] && . "$_CONFIG_DIR/config.conf"

# Add ip rules: LAN traffic (iif) → routing tables.
# Creates rules for both domain and subnet tables per interface in ROUTE_IN.
main() {
  local iface
  for iface in $ROUTE_IN; do
    # Domain table (higher priority — checked first)
    ip rule del iif "$iface" table "$DOMAIN_ROUTE_TABLE" 2>/dev/null || true
    ip rule add iif "$iface" table "$DOMAIN_ROUTE_TABLE" priority "$DOMAIN_RULE_PRIORITY"
    log "IP rule: iif $iface → table $DOMAIN_ROUTE_TABLE (priority $DOMAIN_RULE_PRIORITY)"

    # Subnet table (lower priority — checked after domains)
    ip rule del iif "$iface" table "$SUBNET_ROUTE_TABLE" 2>/dev/null || true
    ip rule add iif "$iface" table "$SUBNET_ROUTE_TABLE" priority "$SUBNET_RULE_PRIORITY"
    log "IP rule: iif $iface → table $SUBNET_ROUTE_TABLE (priority $SUBNET_RULE_PRIORITY)"
  done
  log "Rules attached: tables $DOMAIN_ROUTE_TABLE,$SUBNET_ROUTE_TABLE, iif: $ROUTE_IN"
}

main
