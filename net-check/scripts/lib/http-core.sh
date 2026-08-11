# net-check: HTTP check core — content verification, curl wrapper, metrics parsing, utilities.
# Dependencies: none (self-contained)
# Globals used: ANOMALY_MARKERS_FILE, KNOWN_CAS_FILE, CONNECT_TIMEOUT, HTTP_TIMEOUT, MAX_REDIRS,
#   CURL_UA
# shellcheck disable=SC3043

# ─── Content Verification ────────────────────────────────────────────────────

# Check body against anomaly markers from config file.
# Args: $1 - body file path
# stdout: matched marker string, or empty
# Returns: 0 if anomaly found, 1 if clean
check_anomaly_markers() {
  local body_file="$1"
  [ ! -f "$ANOMALY_MARKERS_FILE" ] && return 1
  [ ! -s "$body_file" ] && return 1
  local marker
  while IFS= read -r marker; do
    case "$marker" in
      "#"*|"") continue ;;
    esac
    if grep -qiF "$marker" "$body_file" 2>/dev/null; then
      printf '%s' "$marker"
      return 0
    fi
  done < "$ANOMALY_MARKERS_FILE"
  return 1
}

# Check body against expected fingerprint string.
# Args: $1 - body file, $2 - expected string
# Returns: 0 if match, 1 if mismatch
check_fingerprint() {
  local body_file="$1" expected="$2"
  [ -z "$expected" ] && return 0
  [ ! -s "$body_file" ] && return 1
  grep -qF "$expected" "$body_file" 2>/dev/null
}

# ─── HTTP Check Core ─────────────────────────────────────────────────────────

# Check a URL via a specific interface using curl.
# Extended format includes namelookup time for verbose waterfall.
# Args: $1 - url, $2 - interface name, $3 - body output file (optional, default /dev/null)
# stdout: JSON metrics string from curl -w
# Returns: curl exit code
check_target_via_iface() {
  local url="$1" iface="$2" body_out="${3:-/dev/null}"
  local curl_fmt='{"code":%{http_code},"time_total":%{time_total},"time_connect":%{time_connect},"time_namelookup":%{time_namelookup},"time_appconnect":%{time_appconnect},"time_starttfb":%{time_starttransfer},"redirect_url":"%{redirect_url}","ssl_verify":%{ssl_verify_result},"size_download":%{size_download},"num_redirects":%{num_redirects}}'

  curl -sS --interface "$iface" \
    --connect-timeout "$CONNECT_TIMEOUT" --max-time "$HTTP_TIMEOUT" \
    -o "$body_out" \
    -w "$curl_fmt" \
    -H "User-Agent: $CURL_UA" \
    -b "" \
    -L --max-redirs "${MAX_REDIRS:-10}" \
    "$url" 2>/dev/null
}

# Shared HTTP probe: fetch URL per interface, return code + size + curl exit.
# Used by CDN probe to avoid duplicate code.
# Args: $1 - url, $2 - interface, $3 - extra curl flags (optional)
# stdout: "http_code size_download curl_exit" (space-separated, 3 fields)
# Returns: curl exit code
http_probe() {
  local url="$1" iface="$2" extra="${3:-}"
  local _out _exit=0
  # shellcheck disable=SC2086
  _out=$(curl -sS --interface "$iface" \
    --connect-timeout "$CONNECT_TIMEOUT" --max-time "$HTTP_TIMEOUT" \
    -o /dev/null -w '%{http_code} %{size_download}' \
    -H "User-Agent: $CURL_UA" \
    -b "" \
    -L --max-redirs "${MAX_REDIRS:-10}" \
    $extra \
    "$url" 2>/dev/null) || _exit=$?
  if [ -n "$_out" ]; then
    printf '%s %s' "$_out" "$_exit"
  else
    printf '000 0 %s' "$_exit"
  fi
  return "$_exit"
}

# Parse curl -w JSON metrics into variables (single awk, BusyBox-safe).
# Args: $1 - curl -w output JSON string
# Sets: _cm_code, _cm_ssl, _cm_redirect, _cm_num_redirects,
#        _cm_time_connect, _cm_time_starttfb, _cm_time_dns, _cm_time_app, _cm_time_total
parse_curl_metrics() {
  eval "$(printf '%s' "$1" | awk '
  function extract(s, key,   p, v, q) {
    p = index(s, "\"" key "\":")
    if (p == 0) return ""
    v = substr(s, p + length(key) + 3)
    if (substr(v,1,1) == "\"") {
      v = substr(v, 2)
      q = index(v, "\"")
      if (q > 0) v = substr(v, 1, q-1)
    } else {
      gsub(/[,}\r\n].*/, "", v)
    }
    return v
  }
  {
    s = $0
    v = extract(s, "code");            if (v != "") printf "_cm_code=%s\n", v
    v = extract(s, "ssl_verify");      if (v != "") printf "_cm_ssl=%s\n", v
    v = extract(s, "redirect_url");    if (v != "") printf "_cm_redirect='"'"'%s'"'"'\n", v
    v = extract(s, "num_redirects");   if (v != "") printf "_cm_num_redirects=%s\n", v
    v = extract(s, "time_connect");    if (v != "") printf "_cm_time_connect=%s\n", v
    v = extract(s, "time_starttfb");   if (v != "") printf "_cm_time_starttfb=%s\n", v
    v = extract(s, "time_namelookup"); if (v != "") printf "_cm_time_dns=%s\n", v
    v = extract(s, "time_appconnect"); if (v != "") printf "_cm_time_app=%s\n", v
    v = extract(s, "time_total");      if (v != "") printf "_cm_time_total=%s\n", v
  }')"
  _cm_code="${_cm_code:-0}"
  _cm_ssl="${_cm_ssl:-1}"
  _cm_redirect="${_cm_redirect:-}"
  _cm_num_redirects="${_cm_num_redirects:-0}"
  _cm_time_connect="${_cm_time_connect:-0}"
  _cm_time_starttfb="${_cm_time_starttfb:-0}"
}

# Check issuer against known national/regional CA allowlist.
# Used by TLS check to distinguish national CAs from MITM proxies.
# Args: $1 - full issuer string
# stdout: matched marker or empty
# Returns: 0 if known CA found, 1 if not
_check_known_ca() {
  local _issuer="$1"
  [ -z "$_issuer" ] && return 1
  [ ! -f "${KNOWN_CAS_FILE:-}" ] && return 1

  local _marker
  while IFS= read -r _marker; do
    case "$_marker" in
      "#"*|"") continue ;;
    esac
    # Case-insensitive match
    if printf '%s' "$_issuer" | grep -qi "$_marker" 2>/dev/null; then
      printf '%s' "$_marker"
      return 0
    fi
  done < "$KNOWN_CAS_FILE"
  return 1
}

# ─── Utilities ────────────────────────────────────────────────────────────────

# Extract host from URL for display.
# Args: $1 - URL
# stdout: hostname
url_to_host() {
  printf '%s' "$1" | sed 's|https\{0,1\}://||; s|/.*||'
}

# Convert float seconds to integer milliseconds (pure shell, no fork).
# Args: $1 - float time (e.g. "0.145", "1.23", "0")
# stdout: integer ms
to_ms() {
  local _v="${1:-0}"
  case "$_v" in
    *.*)
      local _int="${_v%%.*}"
      local _frac="${_v#*.}"
      # Pad fraction to at least 3 digits
      while [ "${#_frac}" -lt 3 ]; do _frac="${_frac}0"; done
      # Trim to exactly 3 digits
      _frac="${_frac%"${_frac#???}"}"
      # Strip leading zeros to avoid octal interpretation
      while [ "${#_frac}" -gt 1 ] && [ "${_frac#0}" != "$_frac" ]; do
        _frac="${_frac#0}"
      done
      printf '%d' "$(( ${_int:-0} * 1000 + _frac ))"
      ;;
    *) printf '%d' "$(( _v * 1000 ))" ;;
  esac
}

# Format byte size for human display.
# Args: $1 - bytes
# stdout: "123K" or "45B"
format_size_bytes() {
  local _b="${1:-0}"
  if [ "$_b" -ge 1024 ] 2>/dev/null; then
    awk "BEGIN{printf \"%.0fK\", ${_b}/1024}"
  else
    printf '%dB' "$_b"
  fi
}
