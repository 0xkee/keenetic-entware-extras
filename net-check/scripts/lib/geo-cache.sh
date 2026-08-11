# net-check: File-based geo-location cache (read/write/stale) + geo cache lookups.
# Per-interface cache: geo-<iface>.json with GEO_CACHE_TTL — full result per WAN path.
# Per-IP unified cache moved to lib/geoip.sh (ipgeo-<ip>.json).
# Dependencies: is_cache_fresh from lib/common.sh,
#   get_wan_interfaces from lib/wan.sh (for precache_geo_cc)
# Runtime dependencies: cmd_geo from lib/cmd-geo.sh (for ensure_geo_cache,
#   loaded after libs but called only at runtime)
# Globals used: DATA_DIR, GEO_CACHE_TTL, _GEO_EXT_IPS, _EXIT_CODE
# shellcheck disable=SC3043

# ─── File Cache Operations ────────────────────────────────────────────────────

# Get geo cache file path for an interface.
# Args: $1 - interface name
# stdout: file path
geo_cache_file() {
  printf '%s/geo-%s.json' "$DATA_DIR" "$1"
}

# Read geo data from file cache if fresh.
# Args: $1 - interface name
# stdout: cached JSON if fresh, empty otherwise
# Returns: 0 if hit, 1 if miss
geo_read_cache() {
  local cache_f
  cache_f=$(geo_cache_file "$1")
  if is_cache_fresh "$cache_f" "$GEO_CACHE_TTL"; then
    cat "$cache_f"
    return 0
  fi
  return 1
}

# Write geo data to file cache (atomic write for parallel safety).
# Args: $1 - interface name, $2 - JSON data
geo_write_cache() {
  local cache_f
  cache_f=$(geo_cache_file "$1")
  printf '%s' "$2" > "${cache_f}.$$"
  mv -f "${cache_f}.$$" "$cache_f" 2>/dev/null || true
}

# Read geo data from stale (expired) file cache.
# Args: $1 - interface name
# stdout: stale JSON if file exists, empty otherwise
# Returns: 0 if file exists, 1 otherwise
geo_read_stale() {
  local cache_f
  cache_f=$(geo_cache_file "$1")
  if [ -s "$cache_f" ]; then
    cat "$cache_f"
    return 0
  fi
  return 1
}

# Parse geo JSON fields into variables.
# Handles escaped quotes in "org" field via § placeholder.
# Args: $1 - JSON string
# Sets: _geo_ip, _geo_country, _geo_city, _geo_asn, _geo_org
parse_geo_json() {
  local _j="$1"
  _geo_ip=$(printf '%s' "$_j" | sed -n 's/.*"ip"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  _geo_country=$(printf '%s' "$_j" | sed -n 's/.*"country"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  _geo_city=$(printf '%s' "$_j" | sed -n 's/.*"city"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  _geo_asn=$(printf '%s' "$_j" | sed -n 's/.*"asn"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  _geo_org=$(printf '%s' "$_j" | sed 's/\\"/§/g' | sed -n 's/.*"org"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | sed 's/§/"/g')
}

# ─── Geo Cache Lookups ────────────────────────────────────────────────────────

# Ensure geo ext_ip cache is populated (runs cmd_geo silently if empty).
# Preserves _EXIT_CODE from caller.
# Depends: cmd_geo (from lib/cmd-geo.sh, loaded before this is called)
ensure_geo_cache() {
  [ -n "$_GEO_EXT_IPS" ] && return 0
  local _saved_exit="$_EXIT_CODE"
  cmd_geo > /dev/null 2>&1 || true
  _EXIT_CODE="$_saved_exit"
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

# Pre-cache geo CC for all WAN interfaces into _GEO_CC_* globals (0 forks per lookup).
# Call once after ensure_geo_cache() before rendering loops.
precache_geo_cc() {
  local _iface _cc
  for _iface in $(get_wan_interfaces); do
    _cc=$(geo_cached_cc "$_iface")
    eval "_GEO_CC_$(printf '%s' "$_iface" | tr '.-' '__')=\"$_cc\""
  done
}

# Fast CC lookup from pre-cached globals (0 forks).
# Args: $1 - interface name
# stdout: 2-letter CC or empty
geo_cc_fast() {
  eval "printf '%s' \"\${_GEO_CC_$(printf '%s' "$1" | tr '.-' '__'):-}\""
}
