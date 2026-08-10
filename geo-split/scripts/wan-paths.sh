#!/opt/bin/sh
# List all WAN egress paths (ISP + VPN tunnels) as JSON array.
# Used by WebUI diagram to show all available routes.
# Usage: wan-paths.sh [--json]
# Output: JSON array of {dev, via, type} objects.
# shellcheck disable=SC1091
# shellcheck disable=SC3043
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../../lib/common.sh"
. "$SCRIPT_DIR/../../lib/ip.sh"
_CONFIG_DIR="${SCRIPT_DIR%/*}/config"
. "$_CONFIG_DIR/defaults.conf"
[ -f "$_CONFIG_DIR/config.conf" ] && . "$_CONFIG_DIR/config.conf"

# --- Collect all WAN paths ---
ALL_PATHS_JSON=""
_seen_devs=""

# Helper: add path if device not yet seen.
# Args: $1=dev, $2=via, $3=type(isp|tunnel)
_add_path() {
  local _dev="$1" _via="$2" _type="$3"
  [ -z "$_dev" ] && return 0
  case "$_seen_devs" in *"|${_dev}|"*) return 0 ;; esac
  _seen_devs="${_seen_devs}|${_dev}|"
  local _entry
  _entry=$(printf '{%s,%s,%s}' \
    "$(json_kv "dev" "$_dev")" \
    "$(json_kv "via" "$_via")" \
    "$(json_kv "type" "$_type")")
  ALL_PATHS_JSON="${ALL_PATHS_JSON:+${ALL_PATHS_JSON},}${_entry}"
}

# Default route (main table)
dr_output=$(ip route show default 2>/dev/null | head -1) || dr_output=""
dr_dev=$(echo "$dr_output" | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
dr_via=$(echo "$dr_output" | awk '{for(i=1;i<=NF;i++) if($i=="via") {print $(i+1); exit}}')

# 1) ISP interface from geo-split config (ROUTE_OUT)
_geo_out_dev=""
if [ "${ROUTE_OUT:-auto}" = "auto" ] || [ -z "${ROUTE_OUT:-}" ]; then
  if ! is_tunnel_iface "${dr_dev:-}"; then
    _geo_out_dev="$dr_dev"
  fi
  if [ -z "$_geo_out_dev" ]; then
    _geo_out_dev=$(ip route show 2>/dev/null | awk '/^default/{for(i=1;i<=NF;i++) if($i=="dev"){d=$(i+1)}} END{print d}')
    if [ -n "$_geo_out_dev" ] && is_tunnel_iface "$_geo_out_dev"; then
      _geo_out_dev=""
    fi
  fi
else
  _geo_out_dev="$ROUTE_OUT"
fi
if [ -n "$_geo_out_dev" ]; then
  _geo_out_via=$(ip route show dev "$_geo_out_dev" 2>/dev/null | awk '/^default/{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}')
  if is_tunnel_iface "$_geo_out_dev"; then
    _add_path "$_geo_out_dev" "${_geo_out_via:-}" "tunnel"
  else
    _add_path "$_geo_out_dev" "${_geo_out_via:-}" "isp"
  fi
fi

# 2) VPN tunnel interfaces from fwmark policy tables (deduplicated, 1 fork per table)
_vpn_tables=$(ip rule show 2>/dev/null | sed -n 's/.*fwmark \(0x[0-9a-f]*\) lookup \([0-9]*\).*/\2/p' | sort -u)
for _t in $_vpn_tables; do
  _route_info=$(ip route show table "$_t" 2>/dev/null | awk '/^default/{for(i=1;i<=NF;i++){if($i=="dev")d=$(i+1);if($i=="via")v=$(i+1)};print d" "v;exit}')
  _tdev="${_route_info%% *}"
  _tvia="${_route_info#* }"
  [ "$_tvia" = "$_tdev" ] && _tvia=""
  [ -z "$_tdev" ] && continue
  if is_tunnel_iface "$_tdev"; then
    _add_path "$_tdev" "${_tvia:-}" "tunnel"
  fi
done

# 2b) Standby tunnel interfaces from source-based routing rules (prio >= 1000).
# Keenetic assigns "from <tunnel_ip> lookup <table>" for each tunnel's own traffic.
# Standby tunnels only have default routes in these tables, not in fwmark tables.
_src_tables=$(ip rule show 2>/dev/null | grep -v 'fwmark' | \
  sed -n 's/.*from [0-9][0-9]*\.[0-9].*lookup \([0-9]*\).*/\1/p' | \
  awk '$1 >= 10000' | sort -u)
for _t in $_src_tables; do
  _route_info=$(ip route show table "$_t" 2>/dev/null | awk '/^default/{for(i=1;i<=NF;i++){if($i=="dev")d=$(i+1);if($i=="via")v=$(i+1)};print d" "v;exit}')
  _tdev="${_route_info%% *}"
  _tvia="${_route_info#* }"
  [ "$_tvia" = "$_tdev" ] && _tvia=""
  [ -z "$_tdev" ] && continue
  if is_tunnel_iface "$_tdev"; then
    _add_path "$_tdev" "${_tvia:-}" "tunnel"
  fi
done

# 3) Main default route (if not already added)
if [ -n "${dr_dev:-}" ]; then
  if ! is_tunnel_iface "$dr_dev"; then
    _add_path "$dr_dev" "${dr_via:-}" "isp"
  else
    _add_path "$dr_dev" "${dr_via:-}" "tunnel"
  fi
fi

# --- Output ---
printf '[%s]\n' "$ALL_PATHS_JSON"
