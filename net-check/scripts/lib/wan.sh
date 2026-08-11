# net-check: WAN interface discovery and type classification.
# Dependencies: is_tunnel_iface, detect_out_iface from lib/ip.sh
# Globals used: CHECK_INTERFACES, SCRIPT_DIR
# Globals set: _CACHED_WAN_IFACES
# shellcheck disable=SC3043

# Per-run cache for auto-detected WAN interfaces (avoids repeated wan-paths.sh fork).
_CACHED_WAN_IFACES=""

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
