# net-check: HTTP check core — content verification, curl wrapper, failure classification, verdict.
# Dependencies: json_kv, json_kv_num, json_kv_bool from lib/common.sh; iface_type from lib/wan.sh;
#   verbose_timing, to_ms from lib/output.sh
# Globals used: ANOMALY_MARKERS_FILE, CONNECT_TIMEOUT, HTTP_TIMEOUT, MAX_REDIRS, CURL_UA, DATA_DIR, VERBOSITY,
#   DEGRADED_TTFB_RATIO
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

# Parse curl -w JSON metrics into variables.
# Args: $1 - curl -w output JSON string
# Sets: _cm_code, _cm_ssl, _cm_redirect, _cm_num_redirects,
#        _cm_time_connect, _cm_time_starttfb, _cm_time_dns, _cm_time_app, _cm_time_total
parse_curl_metrics() {
  local _j="$1"
  _cm_code=$(printf '%s' "$_j" | sed -n 's/.*"code":\([0-9]*\).*/\1/p')
  _cm_ssl=$(printf '%s' "$_j" | sed -n 's/.*"ssl_verify":\([0-9]*\).*/\1/p')
  _cm_redirect=$(printf '%s' "$_j" | sed -n 's/.*"redirect_url":"\([^"]*\)".*/\1/p')
  _cm_num_redirects=$(printf '%s' "$_j" | sed -n 's/.*"num_redirects":\([0-9]*\).*/\1/p')
  _cm_time_connect=$(printf '%s' "$_j" | sed -n 's/.*"time_connect":\([0-9.]*\).*/\1/p')
  _cm_time_starttfb=$(printf '%s' "$_j" | sed -n 's/.*"time_starttfb":\([0-9.]*\).*/\1/p')
  _cm_time_dns=$(printf '%s' "$_j" | sed -n 's/.*"time_namelookup":\([0-9.]*\).*/\1/p')
  _cm_time_app=$(printf '%s' "$_j" | sed -n 's/.*"time_appconnect":\([0-9.]*\).*/\1/p')
  _cm_time_total=$(printf '%s' "$_j" | sed -n 's/.*"time_total":\([0-9.]*\).*/\1/p')
  # Defaults
  _cm_code="${_cm_code:-0}"
  _cm_ssl="${_cm_ssl:-1}"
  _cm_redirect="${_cm_redirect:-}"
  _cm_num_redirects="${_cm_num_redirects:-0}"
  _cm_time_connect="${_cm_time_connect:-0}"
  _cm_time_starttfb="${_cm_time_starttfb:-0}"
}

# Classify failure reason from curl metrics.
# Args: $1 - http_code, $2 - ssl_verify, $3 - redirect_url,
#        $4 - curl_exit, $5 - time_connect, $6 - (reserved),
#        $7 - body_file (optional), $8 - expected_string (optional)
# stdout: failure reason string
classify_failure() {
  local http_code="$1" ssl_verify="$2" redirect_url="$3"
  local curl_exit="$4" time_connect="$5"
  local body_file="${7:-}" expected_string="${8:-}"

  # Timeout with no TCP connect → network unreachable / filtered
  if [ "$curl_exit" = "28" ]; then
    if [ "$time_connect" = "0.000000" ] || [ "$time_connect" = "0" ]; then
      printf 'Timeout / Filtered or shaped'
    else
      printf 'DPI/SNI anomaly suspected'
    fi
    return 0
  fi

  # SSL/TLS errors
  if [ "$curl_exit" = "35" ]; then
    printf 'TLS anomaly'
    return 0
  fi
  if [ "$curl_exit" = "60" ] || [ "$ssl_verify" != "0" ]; then
    printf 'MITM detected'
    return 0
  fi

  # HTTP status codes
  if [ "$http_code" = "451" ]; then
    printf 'Geo-restricted'
    return 0
  fi

  # 403 handling: WAF/anti-bot vs real filtering
  # 403 + valid TLS = origin server (WAF/Cloudflare/anti-bot), not ISP block.
  # ISP blocks manifest as RST/timeout/MITM/redirect — never as 403 with valid cert.
  if [ "$http_code" = "403" ]; then
    if [ "$ssl_verify" = "0" ]; then
      printf 'ok'
      return 0
    fi
    printf 'Filtered'
    return 0
  fi

  # Redirect injection detection
  if [ "$http_code" = "301" ] || [ "$http_code" = "302" ]; then
    if [ -n "$redirect_url" ]; then
      printf 'Redirect (→ %s)' "$redirect_url"
      return 0
    fi
  fi

  # Connection reset / refused / redirect loop
  if [ "$curl_exit" = "7" ]; then
    printf 'Connection refused'
    return 0
  fi
  if [ "$curl_exit" = "56" ]; then
    printf 'TCP RST (DPI anomaly)'
    return 0
  fi
  if [ "$curl_exit" = "47" ]; then
    printf 'Too many redirects'
    return 0
  fi
  if [ "$curl_exit" = "92" ]; then
    printf 'HTTP/2 protocol error'
    return 0
  fi

  # Generic error
  if [ "$curl_exit" != "0" ]; then
    printf 'Connection error (exit %s)' "$curl_exit"
    return 0
  fi

  # Content verification (only if body was saved)
  if [ -n "$body_file" ] && [ -s "$body_file" ]; then
    # Check anomaly markers first (bad content)
    local anomaly_match=""
    anomaly_match=$(check_anomaly_markers "$body_file") || true
    if [ -n "$anomaly_match" ]; then
      printf 'Content anomaly (%s)' "$anomaly_match"
      return 0
    fi
    # Check expected fingerprint (good content missing)
    if [ -n "$expected_string" ]; then
      if ! check_fingerprint "$body_file" "$expected_string"; then
        printf 'Content mismatch'
        return 0
      fi
    fi
  fi

  printf 'ok'
}

# Shorten failure reason to compact tag for table display.
# Args: $1 - full reason from classify_failure()
# stdout: short tag (max 5 chars)
short_reason() {
  case "$1" in
    ok) printf 'ok' ;;
    "Timeout / Filtered or shaped") printf 'TMOUT' ;;
    "DPI/SNI anomaly suspected") printf 'DPI' ;;
    "TLS anomaly") printf 'TLS' ;;
    "MITM detected") printf 'MITM' ;;
    "Geo-restricted") printf 'GEO' ;;
    Filtered) printf 'FILTR' ;;
    Redirect*) printf 'REDIR' ;;
    "Connection refused") printf 'REFSD' ;;
    "TCP RST (DPI anomaly)") printf 'RST' ;;
    "Too many redirects") printf 'REDIR' ;;
    "HTTP/2 protocol error") printf 'H2ERR' ;;
    "Connection error"*) printf 'ERR' ;;
    "Content anomaly"*) printf 'ANOML' ;;
    "Content mismatch") printf 'MISMT' ;;
    *) printf 'FAIL' ;;
  esac
}

# Determine overall verdict from per-interface results.
# Args: results as "iface:ok_or_fail:ttfb_ms" lines via stdin
# stdout: verdict string
determine_verdict() {
  local has_tunnel_ok=0 has_isp_ok=0
  local tunnel_ttfb=0 isp_ttfb=0
  local iface status ttfb itype

  while IFS=: read -r iface status ttfb; do
    itype=$(iface_type "$iface")
    if [ "$status" = "ok" ]; then
      if [ "$itype" = "tunnel" ]; then
        has_tunnel_ok=1
        tunnel_ttfb="$ttfb"
      else
        has_isp_ok=1
        isp_ttfb="$ttfb"
      fi
    fi
  done

  if [ "$has_tunnel_ok" = 1 ] && [ "$has_isp_ok" = 1 ]; then
    # Check for degradation: TTFB ratio > 3x
    if [ "$tunnel_ttfb" -gt 0 ] && [ "$isp_ttfb" -gt 0 ]; then
      local ratio=1
      if [ "$tunnel_ttfb" -gt "$isp_ttfb" ]; then
        ratio=$((tunnel_ttfb / isp_ttfb))
      else
        ratio=$((isp_ttfb / tunnel_ttfb))
      fi
      if [ "$ratio" -ge "$DEGRADED_TTFB_RATIO" ]; then
        printf 'degraded'
        return 0
      fi
    fi
    printf 'all_ok'
  elif [ "$has_tunnel_ok" = 1 ] && [ "$has_isp_ok" = 0 ]; then
    printf 'reachable_alt'
  elif [ "$has_isp_ok" = 1 ] && [ "$has_tunnel_ok" = 0 ]; then
    printf 'reachable_primary'
  else
    printf 'all_fail'
  fi
}

# Extract host from URL for display.
# Args: $1 - URL
# stdout: hostname
url_to_host() {
  printf '%s' "$1" | sed 's|https\{0,1\}://||; s|/.*||'
}

# Convert float seconds to integer milliseconds.
# Args: $1 - float time (e.g. "0.145")
# stdout: integer ms
to_ms() {
  awk "BEGIN { printf \"%d\", ${1:-0} * 1000 }"
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
