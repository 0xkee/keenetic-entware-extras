#!/opt/bin/sh
# lib/ip.sh - IP/CIDR library (aggregation, interface detection, route table fill)
# Source: . ./lib/ip.sh
# shellcheck disable=SC3043  # 'local' supported by ash/busybox sh
set -eu

# Pipe filter: aggregate (merge overlapping/adjacent) CIDR subnets.
# Uses ISC aggregate (opkg install aggregate). IPv4 only.
# Future: fork aggregate6 for IPv6 support.
# stdin: CIDR lines (one per line)
# stdout: minimal set of CIDRs covering the same IP space
list_aggregate_cidrs() {
  aggregate 2>/dev/null
}

# Detect best DNS resolver port for full A-record resolution.
# Probes SmartDNS no-speed-check (6153), then main (6053), then system.
# Uses DNS_FULL_RESOLVER_PORT if set in config.
# Outputs: "PORT LABEL" (e.g. "6153 SmartDNS no-speed-check") or "0 system resolver"
detect_dns_port() {
  if [ -n "${DNS_FULL_RESOLVER_PORT:-}" ]; then
    echo "$DNS_FULL_RESOLVER_PORT configured"
    return
  fi
  if dig +short +time=1 +tries=1 localhost @localhost -p 6153 >/dev/null 2>&1; then
    echo "6153 SmartDNS no-speed-check"
    return
  fi
  if dig +short +time=1 +tries=1 localhost @localhost -p 6053 >/dev/null 2>&1; then
    echo "6053 SmartDNS"
    return
  fi
  echo "0 system resolver"
}

# Detect outgoing ISP interface from default routes across all routing tables.
# Excludes VPN interfaces (nwg*, ovpn*, l2tp*, etc.) and LAN bridges (br*).
# Works when "Политика по умолчанию" = VPN (ISP only in Keenetic policy tables 4096+).
# Fallback: if no non-VPN route found, uses main table default (original behavior).
detect_out_iface() {
  local iface
  iface=$(ip route show table all | grep "^default" | \
    grep -v "dev nwg\|dev ovpn\|dev l2tp\|dev pptp\|dev sstp\|dev ipsec\|dev tun\|dev tap" | \
    sed -n 's/.*dev \([^ ]*\).*/\1/p' | grep -v '^br' | head -1)

  # Fallback: main table default route (ISP down, unusual interface names)
  if [ -z "$iface" ]; then
    iface=$(ip route | grep "^default" | sed -n 's/.*dev \([^ ]*\).*/\1/p' | grep -v '^br' | head -1)
  fi

  echo "$iface"
}

# Resolve target outgoing interface from ROUTE_OUT config.
# ROUTE_OUT=auto|"" → auto-detect via detect_out_iface().
# ROUTE_OUT=<name> → use directly.
# stdout: interface name
# Returns: 0 = OK, 1 = no interface found
resolve_target_interface() {
  local iface
  if [ "${ROUTE_OUT:-auto}" = "auto" ] || [ -z "${ROUTE_OUT:-}" ]; then
    iface="$(detect_out_iface)"
  else
    iface="$ROUTE_OUT"
  fi
  if [ -z "$iface" ]; then
    return 1
  fi
  echo "$iface"
}

# Check if a routing table already has routes loaded.
# Returns: 0 if table has at least one route, 1 if empty.
# Args: $1 - table number
is_table_filled() {
  local table="$1"
  ip route show table "$table" 2>/dev/null | grep -q .
}

# Flush and fill a routing table from a list file via ip-full -batch.
# Falls back to BusyBox ip loop if ip-full is not available.
# Touches stamp file ${TABLE_STAMP_PREFIX}${table}.filled on success
# (mtime used by status.sh for table freshness display).
# Args: $1 - table number, $2 - list file path, $3 - target device
#        $4 - mode: "cidr" (default, each line is a CIDR) or "host" (first field + /32)
# Requires: IP_FULL, TABLE_STAMP_PREFIX from config.conf; list_strip, list_count from lib/lists.sh; log from lib/common.sh
# Optional: BATCH_FILE (base path, default /tmp/geo-routes); .${table}.batch is appended
fill_routes_batch() {
  local table="$1" file="$2" dev="$3" mode="${4:-cidr}"
  local batch_file="${BATCH_FILE:-/tmp/geo-routes}.${table}.batch"

  if [ ! -f "$file" ]; then
    log "fill_routes_batch: no file $file, skipping table $table"
    return 0
  fi

  local count
  count=$(list_count "$file")
  log "Loading $count routes into table $table via $dev (mode=$mode)..."

  local t_start t_end elapsed

  if [ -x "${IP_FULL:-/opt/sbin/ip}" ]; then
    {
      echo "route flush table $table"
      if [ "$mode" = "host" ]; then
        list_strip < "$file" | while read -r ip _rest; do
          echo "route add $ip/32 dev $dev table $table"
        done
      else
        list_strip < "$file" | while read -r cidr; do
          echo "route add $cidr dev $dev table $table"
        done
      fi
    } > "$batch_file"

    t_start=$(date +%s)
    "${IP_FULL:-/opt/sbin/ip}" -batch "$batch_file"
    t_end=$(date +%s)
    elapsed=$((t_end - t_start))

    rm -f "$batch_file"
    touch "${TABLE_STAMP_PREFIX}${table}.filled"
    log "Routes loaded via ip-full -batch (table $table: $count entries in ${elapsed}s)"
  else
    log "ip-full not found, using BusyBox loop (slow)"
    ip route flush table "$table" 2>/dev/null || true

    t_start=$(date +%s)
    if [ "$mode" = "host" ]; then
      list_strip < "$file" | while read -r ip _rest; do
        ip route add "$ip/32" dev "$dev" table "$table" 2>/dev/null || true
      done
    else
      list_strip < "$file" | while read -r cidr; do
        ip route add "$cidr" dev "$dev" table "$table" 2>/dev/null || true
      done
    fi
    t_end=$(date +%s)
    elapsed=$((t_end - t_start))

    touch "${TABLE_STAMP_PREFIX}${table}.filled"
    log "Routes loaded via BusyBox loop (table $table: $count entries in ${elapsed}s)"
  fi
}
