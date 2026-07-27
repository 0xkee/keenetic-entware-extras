# net-check: File-based geo-location cache (read/write/stale).
# Per-interface cache: geo-<iface>.json with GEO_CACHE_TTL — full result per WAN path.
# Per-IP unified cache moved to lib/geoip.sh (ipgeo-<ip>.json).
# Dependencies: is_cache_fresh from lib/common.sh
# Globals used: DATA_DIR, GEO_CACHE_TTL
# shellcheck disable=SC3043

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
