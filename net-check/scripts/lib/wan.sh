# net-check: WAN interface discovery, type classification, geo-zone context.
# Dependencies: is_tunnel_iface, detect_out_iface from lib/ip.sh,
#   geo_read_cache, geo_read_stale from lib/geo-cache.sh,
#   resolve_geo_zone from lib/geo.sh (optional, loaded on demand)
# Globals used: CHECK_INTERFACES, SCRIPT_DIR, _GEO_EXT_IPS, DATA_DIR, GEO_CACHE_TTL
# Globals set: _ZONE_LABEL, _ZONE_CC_LIST, _ZONE_ROUTE_DEV, _ZONE_ROUTE_TYPE,
#   _DEFAULT_ROUTE_DEV, _DEFAULT_ROUTE_TYPE
# shellcheck disable=SC3043

# Per-run cache for auto-detected WAN interfaces (avoids repeated wan-paths.sh fork).
_CACHED_WAN_IFACES=""

# Per-run cache for zone context (avoids repeated config reads).
_ZONE_CTX_LOADED=0
# Guard for one-time zone header printing.
_ZONE_HEADER_PRINTED=0
_ZONE_LABEL=""
_ZONE_CC_LIST=""
_ZONE_ROUTE_DEV=""
_ZONE_ROUTE_TYPE=""
_DEFAULT_ROUTE_DEV=""
_DEFAULT_ROUTE_TYPE=""

# Get interface type label.
# Args: $1 - interface name
# stdout: "tunnel" or "isp"
iface_type() {
  if is_tunnel_iface "$1"; then
    printf 'tunnel'
  else
    printf 'isp'
  fi
}

# ─── WAN Interface Discovery ─────────────────────────────────────────────────

# Get list of WAN interfaces (space-separated, ISP first then tunnels).
# Uses CHECK_INTERFACES if set, otherwise auto-detects via wan-paths.sh / fallback.
# stdout: space-separated interface names
get_wan_interfaces() {
  if [ -n "$CHECK_INTERFACES" ]; then
    printf '%s' "$CHECK_INTERFACES"
    return 0
  fi

  # Per-run cache: avoid repeated wan-paths.sh fork during cmd_all (8 sections)
  if [ -n "$_CACHED_WAN_IFACES" ]; then
    printf '%s' "$_CACHED_WAN_IFACES"
    return 0
  fi

  local wan_paths_script="$SCRIPT_DIR/../../geo-split/scripts/wan-paths.sh"
  local ifaces=""

  # Method 1: wan-paths.sh (best, gives all WAN+tunnel interfaces)
  if [ -x "$wan_paths_script" ]; then
    ifaces=$("$wan_paths_script" 2>/dev/null | \
      sed 's/[{}]//g' | tr ',' '\n' | \
      sed -n 's/.*"dev":"\([^"]*\)".*/\1/p' | \
      tr '\n' ' ' | sed 's/ $//')
  fi

  # Method 2: fallback — ISP iface + tunnel ifaces from routing tables
  if [ -z "$ifaces" ]; then
    local isp_iface
    isp_iface=$(detect_out_iface)
    [ -n "$isp_iface" ] && ifaces="$isp_iface"

    local tun_ifaces
    tun_ifaces=$(ip route show table all 2>/dev/null | \
      sed -n 's/.*dev \([^ ]*\).*/\1/p' | sort -u | while read -r dev; do
        if is_tunnel_iface "$dev"; then
          printf '%s ' "$dev"
        fi
      done | sed 's/ $//')

    if [ -n "$tun_ifaces" ]; then
      ifaces="${ifaces:+${ifaces} }${tun_ifaces}"
    fi
  fi

  # Sort: ISP (non-tunnel) first, then tunnels
  local isp_list="" tun_list="" dev
  for dev in $ifaces; do
    if is_tunnel_iface "$dev"; then
      tun_list="${tun_list:+${tun_list} }${dev}"
    else
      isp_list="${isp_list:+${isp_list} }${dev}"
    fi
  done
  local _result="${isp_list:+${isp_list}}${tun_list:+ ${tun_list}}"
  _CACHED_WAN_IFACES="$_result"
  printf '%s' "$_result"
}

# Get WAN interfaces or emit error and return 1.
# Convenience wrapper around get_wan_interfaces() for commands that
# require at least one WAN interface to proceed.
# stdout: space-separated interface names
# Returns: 0 if interfaces found, 1 if none
require_wan_ifaces() {
  local _ifaces
  _ifaces=$(get_wan_interfaces)
  if [ -z "$_ifaces" ]; then
    emit_error "No WAN interfaces detected"
    return 1
  fi
  printf '%s' "$_ifaces"
}

# Lookup cached ext_ip for an interface from _GEO_EXT_IPS.
# Args: $1 - interface name
# stdout: ext_ip or empty string
geo_cached_ip() {
  [ -z "$_GEO_EXT_IPS" ] && return 0
  printf '%s\n' "$_GEO_EXT_IPS" | sed -n "s/^${1}://p" | head -1
}

# Lookup cached country code for an interface from geo cache file.
# Returns fresh cache if available, otherwise stale. Empty if no cache exists.
# Args: $1 - interface name
# stdout: 2-letter country code or empty string
geo_cached_cc() {
  local _gc_json=""
  _gc_json=$(geo_read_cache "$1" 2>/dev/null) || \
    _gc_json=$(geo_read_stale "$1" 2>/dev/null) || return 0
  printf '%s' "$_gc_json" | sed -n 's/.*"country"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

# ─── Geo-Zone Context ─────────────────────────────────────────────────────────

# Load geo-zone context from smartdns-geo-conf and geo-split configs.
# Detects: DNS zone label + CC list, zone route output device + type,
# default route device + type.
# Cached per-run: safe to call from every cmd_* function.
# Sets globals: _ZONE_LABEL, _ZONE_CC_LIST, _ZONE_ROUTE_DEV, _ZONE_ROUTE_TYPE,
#   _DEFAULT_ROUTE_DEV, _DEFAULT_ROUTE_TYPE, _ZONE_CTX_LOADED
load_zone_context() {
  [ "$_ZONE_CTX_LOADED" = 1 ] && return 0

  local _sg_dir="$SCRIPT_DIR/../../smartdns-geo-conf/config"
  local _gs_dir="$SCRIPT_DIR/../../geo-split/config"

  # ── 1. DNS zone label + CC list ──
  if [ -f "$SCRIPT_DIR/../../lib/geo.sh" ] && [ -f "$_sg_dir/defaults.conf" ]; then
    # shellcheck source=../../../lib/geo.sh
    . "$SCRIPT_DIR/../../lib/geo.sh"
    _ZONE_LABEL=$(grep '^DNS_ZONE=' "$_sg_dir/defaults.conf" 2>/dev/null \
      | tail -1 | sed "s/^DNS_ZONE=//;s/[\"']//g")
    if [ -f "$_sg_dir/config.conf" ]; then
      local _override
      _override=$(grep '^DNS_ZONE=' "$_sg_dir/config.conf" 2>/dev/null \
        | tail -1 | sed "s/^DNS_ZONE=//;s/[\"']//g") || true
      [ -n "$_override" ] && _ZONE_LABEL="$_override"
    fi
    [ -n "$_ZONE_LABEL" ] && _ZONE_CC_LIST=$(resolve_geo_zone "$_ZONE_LABEL")
  fi

  # ── 2. Geo-split ROUTE_OUT → zone route device + type ──
  local _gs_route_out=""
  if [ -f "$_gs_dir/defaults.conf" ]; then
    _gs_route_out=$(grep '^ROUTE_OUT=' "$_gs_dir/defaults.conf" 2>/dev/null \
      | tail -1 | sed "s/^ROUTE_OUT=//;s/[\"']//g")
    if [ -f "$_gs_dir/config.conf" ]; then
      local _gs_override
      _gs_override=$(grep '^ROUTE_OUT=' "$_gs_dir/config.conf" 2>/dev/null \
        | tail -1 | sed "s/^ROUTE_OUT=//;s/[\"']//g") || true
      [ -n "$_gs_override" ] && _gs_route_out="$_gs_override"
    fi
  fi

  # Resolve ROUTE_OUT="auto" → actual device from geo-split routing tables
  if [ -z "$_gs_route_out" ] || [ "$_gs_route_out" = "auto" ]; then
    # Read geo-split table numbers
    local _gs_subnet_table=""
    _gs_subnet_table=$(grep '^SUBNET_ROUTE_TABLE=' "$_gs_dir/defaults.conf" 2>/dev/null \
      | tail -1 | sed "s/^SUBNET_ROUTE_TABLE=//;s/[\"']//g") || true
    if [ -f "$_gs_dir/config.conf" ]; then
      local _st_override
      _st_override=$(grep '^SUBNET_ROUTE_TABLE=' "$_gs_dir/config.conf" 2>/dev/null \
        | tail -1 | sed "s/^SUBNET_ROUTE_TABLE=//;s/[\"']//g") || true
      [ -n "$_st_override" ] && _gs_subnet_table="$_st_override"
    fi
    [ -z "$_gs_subnet_table" ] && _gs_subnet_table="1001"
    # Extract device from active routes in geo-split table
    _ZONE_ROUTE_DEV=$(ip route show table "$_gs_subnet_table" 2>/dev/null \
      | head -3 | sed -n 's/.*dev \([^ ]*\).*/\1/p' | sort -u | head -1)
  else
    _ZONE_ROUTE_DEV="$_gs_route_out"
  fi

  if [ -n "$_ZONE_ROUTE_DEV" ]; then
    _ZONE_ROUTE_TYPE=$(iface_type "$_ZONE_ROUTE_DEV")
  fi

  # ── 3. Default route → non-zone traffic ──
  _DEFAULT_ROUTE_DEV=$(ip route show default 2>/dev/null \
    | head -1 | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
  if [ -n "$_DEFAULT_ROUTE_DEV" ]; then
    _DEFAULT_ROUTE_TYPE=$(iface_type "$_DEFAULT_ROUTE_DEV")
  fi

  _ZONE_CTX_LOADED=1
}

# Check if a country code belongs to the active geo zone.
# Args: $1 - 2-letter country code (lowercase)
# Returns: 0 if in zone, 1 if not
is_cc_in_zone() {
  local _cc
  _cc=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
  [ -z "$_cc" ] && return 1
  [ -z "$_ZONE_CC_LIST" ] && return 1
  case " $_ZONE_CC_LIST " in
    *" $_cc "*) return 0 ;;
    *) return 1 ;;
  esac
}

# Determine expected route type for a check-targets category.
# Args: $1 - category from check-targets.conf (global, zone-ru, intl-streaming, etc.)
# stdout: "isp", "tunnel", or "any"
expected_route_type() {
  local _cat="${1:-}"
  case "$_cat" in
    global) printf 'any' ;;
    zone-*)
      # Extract CC from category (zone-ru → ru)
      local _cc="${_cat#zone-}"
      if is_cc_in_zone "$_cc"; then
        printf '%s' "${_ZONE_ROUTE_TYPE:-any}"
      else
        printf '%s' "${_DEFAULT_ROUTE_TYPE:-any}"
      fi ;;
    intl-*|intl)
      printf '%s' "${_DEFAULT_ROUTE_TYPE:-any}" ;;
    *)
      printf 'any' ;;
  esac
}

# Check where traffic to a given IP actually routes from LAN perspective.
# Uses ip route get with iif br0 (same as geo-split/route-check.sh).
# Args: $1 - destination IP
# stdout: device name (e.g. "eth3", "nwg0") or empty
route_dev_for_ip() {
  local _ip="$1" _route_out=""
  [ -z "$_ip" ] || [ "$_ip" = "—" ] && return 0
  local _lan="${LAN_BRIDGE:-br0}"
  local _fake_src
  _fake_src=$(ip -4 addr show "$_lan" 2>/dev/null | \
    awk '/inet /{split($2,a,"/"); split(a[1],b,"."); printf "%s.%s.%s.%d", b[1],b[2],b[3],(b[4]%254)+1; exit}')
  if [ -n "$_fake_src" ]; then
    _route_out=$(ip route get "$_ip" from "$_fake_src" iif "$_lan" 2>/dev/null) || _route_out=""
  fi
  [ -z "$_route_out" ] && _route_out=$(ip route get "$_ip" 2>/dev/null) || true
  printf '%s' "$_route_out" | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1
}

# Format zone context header line for output.
# Prints zone label, CC list, and routing direction.
# stdout: formatted line or empty (if no zone detected)
format_zone_header() {
  [ -z "$_ZONE_LABEL" ] && return 0
  local _zone_dir=""
  [ -n "$_ZONE_ROUTE_DEV" ] && _zone_dir=" → ${_ZONE_ROUTE_DEV} (${_ZONE_ROUTE_TYPE:-?})"
  printf 'Geo zone: %s%s%s (%s)%s' "$C_CYAN" "$_ZONE_LABEL" "$C_RST" "$_ZONE_CC_LIST" "$_zone_dir"
}

# Print zone context header once (geo zone + resolver info).
# Safe to call from multiple cmd_* functions — prints only on first invocation.
# Skipped in JSON or quiet mode.
# Depends: load_zone_context(), format_zone_header(), detect_dns_port() from lib/ip.sh,
#   OUTPUT_JSON, VERBOSITY (is_quiet), C_BOLD, C_RST
print_zone_header_once() {
  [ "$OUTPUT_JSON" = 1 ] && return 0
  is_quiet && return 0
  [ "$_ZONE_HEADER_PRINTED" = 1 ] && return 0

  load_zone_context

  local _zh
  _zh=$(format_zone_header)
  if [ -n "$_zh" ]; then
    printf '%s══════════════════════════════════════════════════════════%s\n' "$C_CYAN" "$C_RST"
    printf '  %sGeo Config%s\n' "$C_BOLD" "$C_RST"
    printf '%s══════════════════════════════════════════════════════════%s\n' "$C_CYAN" "$C_RST"
    printf '%s\n' "$_zh"
    printf 'DNS zone: %s%s%s (%s)\n\n' "$C_CYAN" "$_ZONE_LABEL" "$C_RST" "$_ZONE_CC_LIST"
  fi

  _ZONE_HEADER_PRINTED=1
}
