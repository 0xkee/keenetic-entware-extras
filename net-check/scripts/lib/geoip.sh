#!/opt/bin/sh
# lib/geoip.sh — IP address to country code geolocation.
# Local library for net-check (no other packages need API-based IP geolocation).
#
# Usage: . "$SCRIPT_DIR/lib/geoip.sh"
# Requires: CURL_UA, DATA_DIR, CDN_GEO_CACHE_TTL, GEOIP_SERVICES, GEOIP_TIMEOUT from caller.
# Requires: is_cache_fresh() from lib/common.sh.
# shellcheck disable=SC3043

# Internal flag: set to 1 when ip-api.com returns 429 (skip further attempts).
# File-based coordination: ${_RUN_DIR}/.geoip-blocked shared across parallel subshells.
# Per-run: auto-cleaned with _RUN_DIR on exit (no stale flags between runs).
_GEOIP_PRIMARY_BLOCKED=0

# Check if ip-api.com is blocked (process-local flag OR cross-process file flag).
_geoip_is_blocked() {
  [ "$_GEOIP_PRIMARY_BLOCKED" = 1 ] && return 0
  [ -f "${_RUN_DIR}/.geoip-blocked" ] && { _GEOIP_PRIMARY_BLOCKED=1; return 0; }
  return 1
}

# Mark ip-api.com as blocked (both process-local and cross-process).
_geoip_mark_blocked() {
  _GEOIP_PRIMARY_BLOCKED=1
  touch "${_RUN_DIR}/.geoip-blocked" 2>/dev/null || true
}

# Geolocate an IP address to country code.
# Primary: ip-api.com (free, 45 req/min, no key, HTTP).
# Fallback: ipinfo.io (separate from cmd_geo to avoid shared rate-limit).
# File cache: ${DATA_DIR}/cdngeo-<ip> with TTL from CDN_GEO_CACHE_TTL.
# Cross-process 429 coordination: file flag ${DATA_DIR}/.geoip-blocked
# prevents parallel subshells from all hitting rate-limited API.
# Args: $1 - IPv4 address
# stdout: two-letter country code (e.g. "NL") or "??"
geolocate_ip() {
  local ip="$1"
  [ -z "$ip" ] || [ "$ip" = "—" ] && { printf '??'; return 0; }

  local cache_f="${DATA_DIR}/cdngeo-${ip}"
  if is_cache_fresh "$cache_f" "$CDN_GEO_CACHE_TTL"; then
    cat "$cache_f"
    return 0
  fi

  local cc="" http_code="" tmp_body="${_RUN_DIR}/geoip-resp-${ip}.tmp"

  # Try each GeoIP service in order
  for _svc in $GEOIP_SERVICES; do
    _url="${_svc%%|*}"
    # Replace {ip} placeholder with actual IP
    _url=$(printf '%s' "$_url" | sed "s/{ip}/${ip}/g")

    # Skip ip-api.com if rate-limited
    case "$_url" in *ip-api.com*)
      if _geoip_is_blocked; then continue; fi
    ;; esac

    http_code=$(curl -sS --max-time "$GEOIP_TIMEOUT" \
      -o "$tmp_body" -w '%{http_code}' \
      -H "User-Agent: ${CURL_UA:-net-check}" \
      "$_url" 2>/dev/null) || http_code="000"

    if [ "$http_code" = "429" ]; then
      case "$_url" in *ip-api.com*)
        _geoip_mark_blocked
        printf '⚠️  ip-api.com rate-limited (429) — switching to fallback\n' >&2
      ;; *)
        printf '⚠️  %s rate-limited (429)\n' "$_url" >&2
      ;; esac
    elif [ "$http_code" = "200" ]; then
      cc=$(cat "$tmp_body" 2>/dev/null) || cc=""
      case "$cc" in
        [A-Z][A-Z]) ;;
        *) cc="" ;;
      esac
    fi
    rm -f "$tmp_body" 2>/dev/null

    # Break on first successful result
    [ -n "$cc" ] && break
  done

  if [ -n "$cc" ]; then
    # Atomic write: temp+mv. In parallel subshells $$ is the parent PID,
    # so two subshells may race on the same temp file — suppress mv error
    # (loser is safe: winner already wrote the same correct data).
    printf '%s' "$cc" > "${cache_f}.$$"
    mv -f "${cache_f}.$$" "$cache_f" 2>/dev/null || true
  else
    # Stale cache fallback
    if [ -s "$cache_f" ]; then
      cat "$cache_f"
      return 0
    fi
    cc="??"
  fi
  printf '%s' "$cc"
}
