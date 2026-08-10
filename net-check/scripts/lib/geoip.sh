#!/opt/bin/sh
# lib/geoip.sh — Unified IP geolocation: country code, city, ASN, org.
# Local library for net-check (no other packages need API-based IP geolocation).
#
# Unified per-IP cache: ${DATA_DIR}/ipgeo-<ip>.json
#   Format: {"cc":"CY","city":"Nicosia","asn":"AS6866","org":"Cyprus Telecom"}
#   TTL: IPGEO_CACHE_TTL (default 24h) — geo data for a given IP rarely changes.
#
# Usage: . "$SCRIPT_DIR/lib/geoip.sh"
# Requires: CURL_UA, DATA_DIR, IPGEO_CACHE_TTL, GEOIP_SERVICES, GEOIP_TIMEOUT from caller.
# Requires: is_cache_fresh() from lib/common.sh.
# shellcheck disable=SC3043

# ── Rate-limit tracking (cross-process via file flags) ────────────────────────
# File flags: ${_RUN_DIR}/.api-blocked-<provider>
# Process-local flags avoid repeated stat() calls in tight loops.
_BLOCKED_ipapi=0
_BLOCKED_ipinfo=0

# Check if a provider is rate-limited.
# Args: $1 - provider key ("ipapi" or "ipinfo")
# Returns: 0 if blocked, 1 if OK
_geoip_is_blocked() {
  local _prov="$1"
  case "$_prov" in
    ipapi)  [ "$_BLOCKED_ipapi"  = 1 ] && return 0 ;;
    ipinfo) [ "$_BLOCKED_ipinfo" = 1 ] && return 0 ;;
  esac
  if [ -f "${_RUN_DIR}/.api-blocked-${_prov}" ]; then
    case "$_prov" in
      ipapi)  _BLOCKED_ipapi=1 ;;
      ipinfo) _BLOCKED_ipinfo=1 ;;
    esac
    return 0
  fi
  return 1
}

# Mark a provider as rate-limited (process-local + cross-process file flag).
# Args: $1 - provider key
_geoip_mark_blocked() {
  local _prov="$1"
  case "$_prov" in
    ipapi)  _BLOCKED_ipapi=1 ;;
    ipinfo) _BLOCKED_ipinfo=1 ;;
  esac
  touch "${_RUN_DIR}/.api-blocked-${_prov}" 2>/dev/null || true
}

# Detect provider key from URL for rate-limit tracking.
# Args: $1 - URL
# stdout: provider key or empty
_geoip_provider() {
  case "$1" in
    *ip-api.com*) printf 'ipapi' ;;
    *ipinfo.io*)  printf 'ipinfo' ;;
  esac
}

# ── Unified per-IP cache ──────────────────────────────────────────────────────

# Get unified cache file path for an IP.
# Args: $1 - IP address
# stdout: file path
ipgeo_cache_file() {
  printf '%s/ipgeo-%s.json' "$DATA_DIR" "$1"
}

# Read full geo data from unified per-IP cache (any age, for enrichment).
# Args: $1 - IP address
# Sets: _enrich_cc, _enrich_city, _enrich_asn, _enrich_org
# Returns: 0 if cache has data, 1 if miss
geoip_read_full() {
  local _cf
  _cf=$(ipgeo_cache_file "$1")
  [ ! -s "$_cf" ] && return 1
  local _j
  _j=$(cat "$_cf" 2>/dev/null) || return 1
  _enrich_cc=$(printf '%s' "$_j" | sed -n 's/.*"cc":"\([^"]*\)".*/\1/p')
  _enrich_city=$(printf '%s' "$_j" | sed -n 's/.*"city":"\([^"]*\)".*/\1/p')
  _enrich_asn=$(printf '%s' "$_j" | sed -n 's/.*"asn":"\([^"]*\)".*/\1/p')
  _enrich_org=$(printf '%s' "$_j" | sed 's/\\"/§/g' | sed -n 's/.*"org":"\([^"]*\)".*/\1/p' | sed 's/§/"/g')
  [ -n "$_enrich_cc" ]
}

# Write full geo data to unified per-IP cache (atomic write).
# Args: $1 - IP, $2 - cc, $3 - city, $4 - asn, $5 - org
_ipgeo_write_cache() {
  local _ip="$1" _cc="$2" _city="${3:-}" _asn="${4:-}" _org="${5:-}"
  [ -z "$_cc" ] && return 0
  local _cf
  _cf=$(ipgeo_cache_file "$_ip")
  printf '{"cc":"%s","city":"%s","asn":"%s","org":"%s"}' \
    "$_cc" "$_city" "$_asn" \
    "$(printf '%s' "$_org" | sed 's/"/\\"/g')" \
    > "${_cf}.$$"
  mv -f "${_cf}.$$" "$_cf" 2>/dev/null || true
}

# ── Main: geolocate IP → CC (with full enrichment side-cache) ────────────────

# Geolocate an IP address to country code.
# Primary: ip-api.com/json (free, 45 req/min, HTTP, returns full data).
# Fallback: ipinfo.io/{ip}/json (full) or ipinfo.io/{ip}/country (CC only).
# Unified file cache: ${DATA_DIR}/ipgeo-<ip>.json with all geo fields.
# Cross-process 429 coordination via provider-specific rate-limit tracking.
# Args: $1 - IPv4 address
# stdout: two-letter country code (e.g. "NL") or "??"
geolocate_ip() {
  local ip="$1"
  [ -z "$ip" ] || [ "$ip" = "—" ] || [ "$ip" = "-" ] && { printf '??'; return 0; }

  # Check unified cache (fresh)
  local cache_f
  cache_f=$(ipgeo_cache_file "$ip")
  if is_cache_fresh "$cache_f" "$IPGEO_CACHE_TTL"; then
    sed -n 's/.*"cc":"\([^"]*\)".*/\1/p' "$cache_f"
    return 0
  fi

  local cc="" city="" asn="" org=""
  local http_code="" tmp_body="${_RUN_DIR}/geoip-resp-${ip}.tmp"

  # Try each GeoIP service in order
  for _svc in $GEOIP_SERVICES; do
    _url="${_svc%%|*}"
    _type="${_svc##*|}"
    _url=$(printf '%s' "$_url" | sed "s/{ip}/${ip}/g")

    # Skip rate-limited providers
    local _prov
    _prov=$(_geoip_provider "$_url")
    if [ -n "$_prov" ] && _geoip_is_blocked "$_prov"; then continue; fi

    http_code=$(curl -sS --max-time "$GEOIP_TIMEOUT" \
      -o "$tmp_body" -w '%{http_code}' \
      -H "User-Agent: ${CURL_UA:-net-check}" \
      "$_url" 2>/dev/null) || http_code="000"

    if [ "$http_code" = "429" ]; then
      if [ -n "$_prov" ]; then
        # Only warn if we are the first process to discover the rate limit;
        # parallel subshells may all hit 429 simultaneously — suppress dupes.
        if [ ! -f "${_RUN_DIR}/.api-blocked-${_prov}" ]; then
          case "$_prov" in
            ipapi)  printf '⚠️  ip-api.com rate-limited (429) — switching to fallback\n' >&2 ;;
            ipinfo) printf '⚠️  ipinfo.io rate-limited (429)\n' >&2 ;;
          esac
        fi
        _geoip_mark_blocked "$_prov"
      fi
      rm -f "$tmp_body" 2>/dev/null
      continue
    fi

    if [ "$http_code" != "200" ]; then rm -f "$tmp_body" 2>/dev/null; continue; fi

    local _resp
    _resp=$(cat "$tmp_body" 2>/dev/null | tr -d '\n\r') || _resp=""
    rm -f "$tmp_body" 2>/dev/null
    [ -z "$_resp" ] && continue

    case "$_type" in
      ipapi_json)
        # ip-api.com/json: {"countryCode":"CY","city":"Nicosia","as":"AS6866 Name"}
        cc=$(printf '%s' "$_resp" | sed -n 's/.*"countryCode"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
        city=$(printf '%s' "$_resp" | sed -n 's/.*"city"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
        local _raw_as
        _raw_as=$(printf '%s' "$_resp" | sed -n 's/.*"as"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
        asn=$(printf '%s' "$_raw_as" | sed -n 's/^\(AS[0-9]*\).*/\1/p')
        org=$(printf '%s' "$_raw_as" | sed 's/^AS[0-9]* *//')
        ;;
      ipinfo_json)
        # ipinfo.io/{ip}/json: {"country":"CY","city":"Nicosia","org":"AS6866 Name"}
        cc=$(printf '%s' "$_resp" | sed -n 's/.*"country"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
        city=$(printf '%s' "$_resp" | sed -n 's/.*"city"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
        local _raw_org
        _raw_org=$(printf '%s' "$_resp" | sed 's/\\"/§/g' | sed -n 's/.*"org"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | sed 's/§/"/g')
        asn=$(printf '%s' "$_raw_org" | sed -n 's/^\(AS[0-9]*\).*/\1/p')
        org=$(printf '%s' "$_raw_org" | sed 's/^AS[0-9]* *//')
        ;;
      plain)
        cc=$(printf '%s' "$_resp")
        case "$cc" in [A-Z][A-Z]) ;; *) cc="" ;; esac
        ;;
    esac

    # Break on first successful result
    [ -n "$cc" ] && break
  done

  if [ -n "$cc" ]; then
    # Atomic write: temp+mv. In parallel subshells $$ is the parent PID,
    # so two subshells may race on the same temp file — suppress mv error
    # (loser is safe: winner already wrote the same correct data).
    _ipgeo_write_cache "$ip" "$cc" "$city" "$asn" "$org"
  else
    # Stale cache fallback
    if [ -s "$cache_f" ]; then
      sed -n 's/.*"cc":"\([^"]*\)".*/\1/p' "$cache_f"
      return 0
    fi
    cc="??"
  fi
  printf '%s' "$cc"
}

# Pre-warm GeoIP cache for a list of IPs (sequential, deduplicated).
# Skips IPs already in fresh cache. Respects rate limits.
# Used by cmd_dns/cmd_cdn after Phase 2 to ensure Phase 3 is cache-only.
# Args: $1 - space-separated IP list (may contain duplicates and "-")
geoip_batch_prewarm() {
  local _seen="" _ip
  for _ip in $1; do
    # Skip blanks, dashes, already-seen
    case "$_ip" in ""|"-"|"—") continue ;; esac
    case " $_seen " in *" $_ip "*) continue ;; esac
    _seen="${_seen} ${_ip}"
    # Skip if cache is fresh
    is_cache_fresh "$(ipgeo_cache_file "$_ip")" "$IPGEO_CACHE_TTL" && continue
    # Sequential call (respects rate limits automatically via _geoip_is_blocked)
    geolocate_ip "$_ip" > /dev/null 2>&1 || true
  done
}
