# net-check: Geo-zone context, routing/FIB lookup, zone header UI.
# Dependencies: iface_type from lib/wan.sh,
#   geo_read_cache, geo_read_stale from lib/geo-cache.sh,
#   resolve_geo_zone from lib/geo.sh (optional, loaded on demand),
#   is_tunnel_iface from lib/ip.sh,
#   is_quiet from lib/sections.sh,
#   C_CYAN, C_RST, C_BOLD, C_DIM from lib/colors.sh
# Globals used: CHECK_ZONE, SCRIPT_DIR, LAN_BRIDGE, OUTPUT_JSON, VERBOSITY
# Globals set: _ZONE_LABEL, _ZONE_CC_LIST, _ZONE_ROUTE_DEV, _ZONE_ROUTE_TYPE,
#   _DEFAULT_ROUTE_DEV, _DEFAULT_ROUTE_TYPE,
#   _NON_GEO_SEGMENTS, _NON_GEO_SINGLE, _NON_GEO_COUNT,
#   _AUTO_FWMARK, _ZONE_CTX_LOADED, _ZONE_HEADER_PRINTED
# shellcheck disable=SC1091,SC3043

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
# Non-geo routing segments (tunnel/routing policies + main default).
# Populated by load_zone_context() section 4.
_NON_GEO_SEGMENTS=""
_NON_GEO_SINGLE=""
_NON_GEO_COUNT=0

# Per-run cache for auto-detected VPN fwmark.
# "" = unchecked, "none" = no VPN fwmark found, "0xNN..." = fwmark value.
_AUTO_FWMARK=""

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
  # Priority: CHECK_ZONE (net-check config) > DNS_ZONE (smartdns-geo-conf)
  local _check_zone="${CHECK_ZONE:-auto}"

  if [ "$_check_zone" != "auto" ]; then
    # Explicit zone from net-check config (or empty = no zone targets)
    if [ -n "$_check_zone" ] && [ -f "$SCRIPT_DIR/../../lib/geo.sh" ]; then
      # shellcheck source=../../../lib/geo.sh
      . "$SCRIPT_DIR/../../lib/geo.sh"
      _ZONE_LABEL="$_check_zone"
      _ZONE_CC_LIST=$(resolve_geo_zone "$_ZONE_LABEL")
    fi
    # If _check_zone="" → _ZONE_LABEL="" and _ZONE_CC_LIST="" (no zone targets)
  elif [ -f "$SCRIPT_DIR/../../lib/geo.sh" ] && [ -f "$_sg_dir/defaults.conf" ]; then
    # Auto: read DNS_ZONE from smartdns-geo-conf (existing logic)
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

  # ── 4. Non-geo routing segments (tunnel policies + main default) ──
  # Enumerate unique egress devices for non-geo traffic across all Keenetic
  # per-client routing policies. Geo-split rules (prio 50-51) are checked BEFORE
  # fwmark rules (prio 100+), so geo resources always route the same way
  # regardless of client policy. Non-geo traffic depends on client fwmark.
  _NON_GEO_SEGMENTS=""
  _NON_GEO_SINGLE=""
  _NON_GEO_COUNT=0
  local _ngs_seen=""
  # Start with main table default (clients without tunnel policy)
  if [ -n "$_DEFAULT_ROUTE_DEV" ]; then
    _ngs_seen="|${_DEFAULT_ROUTE_DEV}|"
    _NON_GEO_SEGMENTS="$_DEFAULT_ROUTE_DEV"
  fi
  # Collect fwmark→table→dev for each routing policy (from ip rule)
  local _ngs_table _ngs_dev
  for _ngs_table in $(ip rule show 2>/dev/null \
      | sed -n 's/.*fwmark 0x[0-9a-f]* lookup \([0-9]*\).*/\1/p' | sort -u); do
    _ngs_dev=$(ip route show table "$_ngs_table" 2>/dev/null \
      | awk '/^default/{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    [ -z "$_ngs_dev" ] && continue
    case "$_ngs_seen" in *"|${_ngs_dev}|"*) continue ;; esac
    _ngs_seen="${_ngs_seen}|${_ngs_dev}|"
    _NON_GEO_SEGMENTS="${_NON_GEO_SEGMENTS:+${_NON_GEO_SEGMENTS} }${_ngs_dev}"
  done
  # Also scan source-based routing rules (standby tunnels: prio >= 1000).
  # These tunnels are UP but only have default routes in their own source tables.
  local _src_table _src_dev
  for _src_table in $(ip rule show 2>/dev/null | grep -v 'fwmark' | \
      sed -n 's/.*from [0-9][0-9]*\.[0-9].*lookup \([0-9]*\).*/\1/p' | \
      awk '$1 >= 10000' | sort -u); do
    _src_dev=$(ip route show table "$_src_table" 2>/dev/null \
      | awk '/^default/{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    [ -z "$_src_dev" ] && continue
    is_tunnel_iface "$_src_dev" || continue
    case "$_ngs_seen" in *"|${_src_dev}|"*) continue ;; esac
    _ngs_seen="${_ngs_seen}|${_src_dev}|"
    _NON_GEO_SEGMENTS="${_NON_GEO_SEGMENTS:+${_NON_GEO_SEGMENTS} }${_src_dev}"
  done
  _NON_GEO_COUNT=$(printf '%s' "$_NON_GEO_SEGMENTS" | wc -w | tr -d ' ')
  [ "$_NON_GEO_COUNT" -eq 1 ] && _NON_GEO_SINGLE="$_NON_GEO_SEGMENTS"

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
      # Multiple non-geo segments → can't assert a single expected type
      if [ "$_NON_GEO_COUNT" -gt 1 ]; then
        printf 'any'
      else
        printf '%s' "${_DEFAULT_ROUTE_TYPE:-any}"
      fi ;;
    *)
      printf 'any' ;;
  esac
}

# ─── Routing / FIB Lookup ─────────────────────────────────────────────────────

# Auto-detect first VPN tunnel fwmark from ip rules.
# Scans fwmark-based policy rules, finds the first whose routing table
# has a default route through a tunnel device.
# Same logic as route-check.sh legacy auto-detect.
# Cached per run. stdout: fwmark hex (e.g. "0xff0100") or empty.
_detect_auto_fwmark() {
  if [ -n "$_AUTO_FWMARK" ]; then
    [ "$_AUTO_FWMARK" = "none" ] && return 0
    printf '%s' "$_AUTO_FWMARK"
    return 0
  fi

  local _result
  _result=$(ip rule show 2>/dev/null \
    | sed -n 's/.*fwmark \(0x[0-9a-f]*\) lookup \([0-9]*\).*/\1 \2/p' \
    | while read -r _m _t; do
        _dev=$(ip route show table "$_t" 2>/dev/null \
          | awk '/^default/{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
        [ -z "$_dev" ] && continue
        is_tunnel_iface "$_dev" && { printf '%s' "$_m"; break; }
      done)

  if [ -n "$_result" ]; then
    _AUTO_FWMARK="$_result"
    printf '%s' "$_result"
  else
    _AUTO_FWMARK="none"
  fi
}

# Determine active route device via kernel FIB with auto-detected VPN fwmark.
# Simulates a VPN-policy LAN client: ip route get with fwmark + iif br0.
# Correctly returns:
#   - geo-split dev for zone IPs (prio 50/51 checked before fwmark rules)
#   - tunnel dev for intl IPs (fwmark rule at prio 100+ after geo-split miss)
#   - default route dev when no fwmark policies exist
# Args: $1 - target IP
# stdout: device name or empty
fib_active_dev() {
  local _fib_ip="$1" _route_out=""
  [ -z "$_fib_ip" ] || [ "$_fib_ip" = "—" ] && return 0

  local _lan="${LAN_BRIDGE:-br0}"
  local _fake_src
  _fake_src=$(ip -4 addr show "$_lan" 2>/dev/null | \
    awk '/inet /{split($2,a,"/"); split(a[1],b,"."); printf "%s.%s.%s.%d", b[1],b[2],b[3],(b[4]%254)+1; exit}')
  [ -z "$_fake_src" ] && return 0

  # Try with auto-detected VPN fwmark first (simulates VPN-policy client)
  local _fwmark
  _fwmark=$(_detect_auto_fwmark)
  if [ -n "$_fwmark" ]; then
    _route_out=$(ip route get "$_fib_ip" mark "$_fwmark" from "$_fake_src" iif "$_lan" 2>/dev/null) || _route_out=""
  fi

  # Fallback: without fwmark (default-policy client)
  [ -z "$_route_out" ] && \
    _route_out=$(ip route get "$_fib_ip" from "$_fake_src" iif "$_lan" 2>/dev/null) || true

  printf '%s' "$_route_out" | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1
}

# Determine active route device for a target.
# Category-aware fast path: uses geo-split config for zone resources.
# FIB fallback with auto-fwmark: simulates VPN-policy LAN client routing
# (geo-split tables checked at prio 50/51, fwmark at prio 100+).
# Args: $1 - resolved IP (for FIB lookup)
#        $2 - category from check-targets.conf (optional)
# stdout: device name or empty
active_dev_for_target() {
  local _ip="${1:-}" _cat="${2:-}"

  # Category-based fast path (avoids ip route get fork per target)
  if [ -n "$_cat" ] && [ "$_ZONE_CTX_LOADED" = 1 ]; then
    case "$_cat" in
      zone-*)
        local _cc="${_cat#zone-}"
        if is_cc_in_zone "$_cc" && [ -n "$_ZONE_ROUTE_DEV" ]; then
          printf '%s' "$_ZONE_ROUTE_DEV"
          return 0
        fi ;;
    esac
  fi

  # FIB with auto-fwmark: correct for both zone (geo-split) and intl (tunnel)
  if [ -n "$_ip" ]; then fib_active_dev "$_ip"; fi
}

# ─── Zone Header UI ──────────────────────────────────────────────────────────

# Format zone context header line for output.
# Prints zone label, CC list, routing direction, and non-geo segment info.
# stdout: formatted line or empty (if no zone detected)
format_zone_header() {
  [ -z "$_ZONE_LABEL" ] && return 0
  local _zone_dir=""
  [ -n "$_ZONE_ROUTE_DEV" ] && _zone_dir=" → ${_ZONE_ROUTE_DEV} (${_ZONE_ROUTE_TYPE:-?})"
  printf 'Geo zone: %s%s%s (%s)%s' "$C_CYAN" "$_ZONE_LABEL" "$C_RST" "$_ZONE_CC_LIST" "$_zone_dir"
}

# Format non-geo routing segment info for output.
# Shows where non-geo (intl/global) traffic routes, including multi-policy note.
# stdout: formatted line or empty (if default route unknown)
format_nongeo_header() {
  [ -z "$_DEFAULT_ROUTE_DEV" ] && return 0
  if [ "$_NON_GEO_COUNT" -le 1 ]; then
    printf 'Non-geo:  %s%s%s (%s)' \
      "$C_CYAN" "$_DEFAULT_ROUTE_DEV" "$C_RST" "${_DEFAULT_ROUTE_TYPE:-?}"
  else
    local _seg_list="" _s _st
    for _s in $_NON_GEO_SEGMENTS; do
      _st=$(iface_type "$_s")
      _seg_list="${_seg_list:+${_seg_list}, }${_s}(${_st})"
    done
    printf 'Non-geo:  %s%s%s (%s) %s[+%d routing policies: %s]%s' \
      "$C_CYAN" "$_DEFAULT_ROUTE_DEV" "$C_RST" "${_DEFAULT_ROUTE_TYPE:-?}" \
      "$C_DIM" "$((_NON_GEO_COUNT - 1))" "$_seg_list" "$C_RST"
  fi
}

# Print zone context header once (geo zone + resolver info + non-geo segments).
# Safe to call from multiple cmd_* functions — prints only on first invocation.
# Skipped in JSON or quiet mode.
# Depends: load_zone_context(), format_zone_header(), format_nongeo_header(),
#   detect_dns_port() from lib/ip.sh,
#   OUTPUT_JSON, VERBOSITY (is_quiet), C_BOLD, C_RST
print_zone_header_once() {
  [ "$OUTPUT_JSON" = 1 ] && return 0
  is_quiet && return 0
  [ "$_ZONE_HEADER_PRINTED" = 1 ] && return 0

  load_zone_context

  local _zh _ngh
  _zh=$(format_zone_header)
  _ngh=$(format_nongeo_header)
  if [ -n "$_zh" ] || [ -n "$_ngh" ]; then
    printf '%s══════════════════════════════════════════════════════════%s\n' "$C_CYAN" "$C_RST"
    printf '  %sGeo Config%s\n' "$C_BOLD" "$C_RST"
    printf '%s══════════════════════════════════════════════════════════%s\n' "$C_CYAN" "$C_RST"
    [ -n "$_zh" ] && printf '%s\n' "$_zh"
    [ -n "$_ngh" ] && printf '%s\n' "$_ngh"
    if [ -n "$_ZONE_LABEL" ]; then
      printf 'DNS zone: %s%s%s (%s)\n' "$C_CYAN" "$_ZONE_LABEL" "$C_RST" "$_ZONE_CC_LIST"
    fi
    printf '\n'
  fi

  _ZONE_HEADER_PRINTED=1
}
