#!/opt/bin/bash
# Apply routing rules: load subnets into ipset, configure ip rules.
# Run after update-domains.sh has fetched the subnet list.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../../lib/common.sh"
. "$SCRIPT_DIR/../config/config.sh"

# Create or flush the ipset
setup_ipset() {
  require_cmd ipset

  if ipset list "$IPSET_NAME" &>/dev/null; then
    log "Flushing existing ipset: $IPSET_NAME"
    ipset flush "$IPSET_NAME"
  else
    log "Creating ipset: $IPSET_NAME (hash:net)"
    ipset create "$IPSET_NAME" hash:net
  fi
}

# Load subnets from file into ipset
load_subnets() {
  if [[ ! -f "$SUBNET_LIST_FILE" ]]; then
    log_error "Subnet list not found: $SUBNET_LIST_FILE"
    log_error "Run update-domains.sh first"
    exit 1
  fi

  local count=0
  while IFS= read -r subnet; do
    # Skip empty lines and comments
    [[ -z "$subnet" || "$subnet" == \#* ]] && continue
    ipset add "$IPSET_NAME" "$subnet" 2>/dev/null || true
    (( count++ ))
  done < "$SUBNET_LIST_FILE"

  log "Loaded $count subnets into ipset $IPSET_NAME"
}

# Set up ip rule for direct routing
setup_ip_rules() {
  require_cmd ip

  # Get default gateway for ISP interface
  local gw
  gw=$(ip route show dev "$ISP_INTERFACE" | awk '/default/ {print $3}')

  if [[ -z "$gw" ]]; then
    log_error "Cannot find default gateway for $ISP_INTERFACE"
    exit 1
  fi

  # Add default route to custom table via ISP
  ip route replace default via "$gw" dev "$ISP_INTERFACE" table "$ROUTE_TABLE" 2>/dev/null || true
  log "Route table $ROUTE_TABLE: default via $gw dev $ISP_INTERFACE"

  # Add ip rule: if dst matches ipset → use custom table
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
  log "Applying geo-bypass rules..."
  setup_ipset
  load_subnets
  setup_ip_rules
  log "Done. Russian subnets routed directly via $ISP_INTERFACE"
}

main "$@"
