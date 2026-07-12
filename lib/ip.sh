#!/opt/bin/sh
# lib/ip.sh - IP/CIDR library (aggregation, interface detection, route table fill)
# Source: . ./lib/ip.sh
# shellcheck disable=SC3043  # 'local' supported by ash/busybox sh
set -eu

# Check if string is a valid IPv4 address pattern.
# Args: $1 - string to check
# Returns: 0 if valid IPv4, 1 otherwise
is_ipv4() {
  echo "$1" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'
}

# Check if string is a plausible domain name.
# Args: $1 - string to check
# Returns: 0 if valid domain, 1 otherwise
is_domain() {
  echo "$1" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?$'
}

# Check if string is a valid CIDR notation (A.B.C.D/N, N=0-32).
# Validates format only — does not normalize host bits.
# Args: $1 - string to check
# Returns: 0 if valid CIDR, 1 otherwise
is_cidr() {
  echo "$1" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$' || return 1
  local prefix="${1##*/}"
  [ "$prefix" -ge 0 ] 2>/dev/null && [ "$prefix" -le 32 ]
}

# Count total IPs in a CIDR subnet.
# Args: $1 - CIDR (e.g. "10.0.0.0/24")
# stdout: integer (e.g. 256 for /24, 1 for /32)
cidr_total_ips() {
  local prefix="${1##*/}"
  awk "BEGIN { p=1; for(i=0;i<32-${prefix};i++) p*=2; print p }"
}

# Output 1-3 representative sample IPs from a CIDR for routing probes.
# /32 → 1 IP (the host); /31-/30 → 2 IPs; /29 and wider → 3 (first, mid, last host).
# Args: $1 - CIDR (e.g. "10.0.0.0/24")
# stdout: space-separated IPs (e.g. "10.0.0.1 10.0.0.128 10.0.0.254")
cidr_sample_ips() {
  awk -v cidr="$1" 'BEGIN {
    n = split(cidr, parts, "/")
    prefix = int(parts[2])
    split(parts[1], o, ".")
    ip = o[1]*16777216 + o[2]*65536 + o[3]*256 + o[4]
    sz = 1; for (i=0; i<32-prefix; i++) sz *= 2
    net = ip - (ip % sz)
    bcast = net + sz - 1
    if (sz == 1) {
      # /32: single host
      _ip(net)
    } else if (sz == 2) {
      # /31: point-to-point, both IPs usable
      _ip(net); printf " "; _ip(bcast)
    } else if (sz == 4) {
      # /30: 2 usable hosts (skip network + broadcast)
      _ip(net + 1); printf " "; _ip(bcast - 1)
    } else {
      # /29 and wider: first host, middle, last host
      _ip(net + 1); printf " "
      _ip(net + int(sz / 2)); printf " "
      _ip(bcast - 1)
    }
    printf "\n"
  }
  function _ip(n) {
    printf "%d.%d.%d.%d", int(n/16777216)%256, int(n/65536)%256, int(n/256)%256, n%256
  }'
}

# Find routes in a routing table that overlap with the given CIDR.
# For each overlapping route outputs: "prefix route_ips dev overlap_ips".
# Uses inline AWK for IP→int math (same arithmetic as cidr_sample_ips).
# Args: $1 - input CIDR, $2 - routing table number
# stdout: lines "prefix route_ips dev overlap_ips" for each overlapping route
cidr_overlap_routes() {
  local input_cidr="$1" table="$2"
  ip route show table "$table" 2>/dev/null | awk -v input="$input_cidr" '
    BEGIN {
      n = split(input, p, "/"); in_pfx = int(p[2])
      split(p[1], o, "."); in_ip = o[1]*16777216 + o[2]*65536 + o[3]*256 + o[4]
      in_sz = 1; for (i=0; i<32-in_pfx; i++) in_sz *= 2
      in_net = in_ip - (in_ip % in_sz); in_end = in_net + in_sz - 1
    }
    /^[0-9]/ {
      n = split($1, p, "/")
      if (n == 1) { pfx = 32 } else { pfx = int(p[2]) }
      split(p[1], o, ".")
      rip = o[1]*16777216 + o[2]*65536 + o[3]*256 + o[4]
      rsz = 1; for (i=0; i<32-pfx; i++) rsz *= 2
      rn = rip - (rip % rsz); re = rn + rsz - 1
      os = (rn > in_net) ? rn : in_net
      oe = (re < in_end) ? re : in_end
      if (os <= oe) {
        dev = ""
        for (i=1; i<=NF; i++) if ($i == "dev") { dev = $(i+1); break }
        print $1, rsz, dev, oe - os + 1
      }
    }'
}

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

# Check if an interface name is a VPN/tunnel device.
# Standard Keenetic: nwg*, awg*, ovpn*, l2tp*, pptp*, sstp*, ipsec*
# Kernel tunnel:     tun[0-9]*, tap*, gre*, vti*, sit*, ip6tnl*, xfrm*
# Third-party pkgs:  wg* (standalone WireGuard)
# Args: $1 - interface name
# Returns: 0 if tunnel, 1 otherwise
is_tunnel_iface() {
  case "$1" in
    nwg*|awg*|wg*|ovpn*|l2tp*|pptp*|sstp*|ipsec*) return 0 ;;
    tun[0-9]*|tap*|gre*|vti*|sit*|ip6tnl*|xfrm*) return 0 ;;
    *) return 1 ;;
  esac
}

# Detect outgoing ISP interface for geo-split routes.
# Priority: main table default route (most reliable, reflects actual connectivity).
# Fallback: scan all routing tables (handles "VPN = default policy" where ISP
# is only reachable via Keenetic policy tables 4096+).
# Excludes VPN interfaces (nwg*, ovpn*, l2tp*, etc.) and LAN bridges (br*).
detect_out_iface() {
  local iface

  # Primary: main table default route (actual system default)
  iface=$(ip route | grep "^default" | \
    grep -v "dev nwg\|dev awg\|dev ovpn\|dev l2tp\|dev pptp\|dev sstp\|dev ipsec\|dev tun\|dev tap" | \
    sed -n 's/.*dev \([^ ]*\).*/\1/p' | grep -v '^br' | head -1)

  # Fallback: all tables (VPN is default policy, ISP only in policy tables)
  if [ -z "$iface" ]; then
    iface=$(ip route show table all | grep "^default" | \
      grep -v "dev nwg\|dev awg\|dev ovpn\|dev l2tp\|dev pptp\|dev sstp\|dev ipsec\|dev tun\|dev tap" | \
      sed -n 's/.*dev \([^ ]*\).*/\1/p' | grep -v '^br' | head -1)
  fi

  echo "$iface"
}

# Detect gateway (nexthop) IP for a given interface.
# Searches default routes in main table first, then all tables.
# For point-to-point interfaces (LTE, PPP) there is typically no gateway —
# returns empty string in that case (caller should use dev-only routes).
# Args: $1 - interface name
# stdout: gateway IP or empty string
detect_gateway() {
  local dev="$1" gw

  # Primary: main table default route for this device
  gw=$(ip route show default dev "$dev" 2>/dev/null | \
    sed -n 's/.*via \([^ ]*\).*/\1/p' | head -1)

  # Fallback: all policy tables (Keenetic puts ISP routes in tables 4096+)
  if [ -z "$gw" ]; then
    gw=$(ip route show table all default dev "$dev" 2>/dev/null | \
      sed -n 's/.*via \([^ ]*\).*/\1/p' | head -1)
  fi

  echo "$gw"
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

# Resolve target gateway from ROUTE_GW config and target interface.
# ROUTE_GW=auto|"" → auto-detect via detect_gateway($dev).
# ROUTE_GW=<ip> → use directly.
# ROUTE_GW=none → force no gateway (dev-only routes).
# Args: $1 - target interface name
# stdout: gateway IP or empty string (empty = use dev-only routes)
resolve_target_gateway() {
  local dev="$1" gw

  case "${ROUTE_GW:-auto}" in
    none|"")
      gw=""
      ;;
    auto)
      gw=$(detect_gateway "$dev")
      ;;
    *)
      gw="$ROUTE_GW"
      ;;
  esac

  echo "$gw"
}

# Count routes in a routing table.
# Uses /proc/net/fib_triestat (instant, no route dump) with fallback to wc -l.
# Args: $1 - table number
# stdout: route count (integer)
table_route_count() {
  local table="$1" count
  # Fast path: kernel FIB trie stats (reads ~2KB file vs dumping 11K routes)
  if [ -f /proc/net/fib_triestat ]; then
    count=$(awk "/^Id ${table}:/{f=1} f&&/Prefixes:/{print \$2;exit}" /proc/net/fib_triestat)
    if [ -n "$count" ]; then
      echo "$count"
      return
    fi
  fi
  # Fallback: enumerate routes (works everywhere)
  ip route show table "$table" 2>/dev/null | wc -l
}

# Check if a routing table already has routes loaded.
# Returns: 0 if table has at least one route, 1 if empty.
# Args: $1 - table number
is_table_filled() {
  local table="$1"
  [ "$(table_route_count "$table")" -gt 0 ]
}

# Flush and fill a routing table from a list file via ip-full -batch.
# Falls back to BusyBox ip loop if ip-full is not available.
# Touches stamp file ${TABLE_STAMP_PREFIX}${table}.filled on success
# (mtime used by status.sh for table freshness display).
# Args: $1 - table number, $2 - list file path, $3 - target device
#        $4 - mode: "cidr" (default, each line is a CIDR) or "host" (first field + /32)
#        $5 - gateway IP (optional; empty = dev-only route, scope link)
# Requires: IP_FULL, TABLE_STAMP_PREFIX from config.conf; list_strip, list_count from lib/lists.sh; log from lib/common.sh
# Optional: BATCH_FILE (base path, default /tmp/geo-routes); .${table}.batch is appended
fill_routes_batch() {
  local table="$1" file="$2" dev="$3" mode="${4:-cidr}" gw="${5:-}"
  local batch_file="${BATCH_FILE:-/tmp/geo-routes}.${table}.batch"

  if [ ! -f "$file" ]; then
    log "fill_routes_batch: no file $file, skipping table $table"
    return 0
  fi

  # Build route target: "via <gw> dev <dev>" or just "dev <dev>" (point-to-point)
  local route_target
  if [ -n "$gw" ]; then
    route_target="via $gw dev $dev"
  else
    route_target="dev $dev"
  fi

  local count
  count=$(list_count "$file")
  log "Loading $count routes into table $table ($route_target, mode=$mode)..."

  local t_start t_end elapsed

  if [ -x "${IP_FULL:-/opt/sbin/ip}" ]; then
    {
      echo "route flush table $table"
      if [ "$mode" = "host" ]; then
        list_strip < "$file" | while read -r ip _rest; do
          echo "route add $ip/32 $route_target table $table"
        done
      else
        list_strip < "$file" | while read -r cidr; do
          echo "route add $cidr $route_target table $table"
        done
      fi
    } > "$batch_file"

    t_start=$(date +%s)
    "${IP_FULL:-/opt/sbin/ip}" -batch "$batch_file"
    t_end=$(date +%s)
    elapsed=$((t_end - t_start))

    rm -f "$batch_file"
    echo "$dev" > "${TABLE_STAMP_PREFIX}${table}.filled"
    log "Routes loaded via ip-full -batch (table $table: $count entries in ${elapsed}s)"
  else
    log "ip-full not found, using BusyBox loop (slow)"
    ip route flush table "$table" 2>/dev/null || true

    t_start=$(date +%s)
    if [ "$mode" = "host" ]; then
      list_strip < "$file" | while read -r ip _rest; do
        # shellcheck disable=SC2086  # route_target must word-split
        ip route add "$ip/32" $route_target table "$table" 2>/dev/null || true
      done
    else
      list_strip < "$file" | while read -r cidr; do
        # shellcheck disable=SC2086  # route_target must word-split
        ip route add "$cidr" $route_target table "$table" 2>/dev/null || true
      done
    fi
    t_end=$(date +%s)
    elapsed=$((t_end - t_start))

    echo "$dev" > "${TABLE_STAMP_PREFIX}${table}.filled"
    log "Routes loaded via BusyBox loop (table $table: $count entries in ${elapsed}s)"
  fi
}
