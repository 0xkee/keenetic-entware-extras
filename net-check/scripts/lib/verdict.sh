# net-check: Verdict — failure classification, reason labels, overall verdict.
# Dependencies: check_anomaly_markers, check_fingerprint from http-core.sh;
#   iface_type from wan.sh
# Globals used: DEGRADED_TTFB_RATIO
# shellcheck disable=SC3043

# ─── Failure Classification ───────────────────────────────────────────────────

# Classify failure reason from curl metrics.
# Args: $1 - http_code, $2 - ssl_verify, $3 - redirect_url,
#        $4 - curl_exit, $5 - time_connect, $6 - (reserved),
#        $7 - body_file (optional), $8 - expected_string (optional)
# stdout: failure reason string
classify_failure() {
  local http_code="$1" ssl_verify="$2" redirect_url="$3"
  local curl_exit="$4" time_connect="$5"
  local body_file="${7:-}" expected_string="${8:-}"

  # DNS resolution failure — domain does not resolve
  if [ "$curl_exit" = "6" ]; then
    printf 'DNS resolution failed'
    return 0
  fi

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
  # Sub-classify by ssl_verify_result (X509_V_ERR_* code):
  #   10 = cert expired, 18/19/20/21 = untrusted CA chain,
  #   23 = cert revoked, 62 = hostname mismatch, others = possible MITM
  if [ "$curl_exit" = "60" ] || [ "$ssl_verify" != "0" ]; then
    # curl_exit=60 with ssl_verify=0 means caller didn't capture the verify code
    # (e.g. CDN probe via http_probe). Default to Untrusted CA — the most common
    # cause of exit 60 — instead of false-positive "MITM detected".
    if [ "$curl_exit" = "60" ] && [ "$ssl_verify" = "0" ]; then
      printf 'Untrusted CA'
      return 0
    fi
    case "$ssl_verify" in
      10)          printf 'Cert expired' ;;
      18|19|20|21) printf 'Untrusted CA' ;;
      23)          printf 'Cert revoked' ;;
      62)          printf 'Hostname mismatch' ;;
      *)           printf 'MITM detected' ;;
    esac
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

  # Server errors — not a network/filtering issue
  if [ "$http_code" -ge 500 ] 2>/dev/null && [ "$http_code" -le 599 ] 2>/dev/null; then
    printf 'Server error (%s)' "$http_code"
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

  # Empty response — server connected but returned nothing
  if [ "$curl_exit" = "52" ]; then
    printf 'Empty response'
    return 0
  fi

  # Partial transfer — connection interrupted mid-stream
  if [ "$curl_exit" = "18" ]; then
    printf 'Partial transfer'
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

# ─── Reason Labels ────────────────────────────────────────────────────────────

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
    "Untrusted CA") printf 'UNTCA' ;;
    "Cert expired") printf 'EXPRD' ;;
    "Cert revoked") printf 'REVKD' ;;
    "Hostname mismatch") printf 'SSLNM' ;;
    "DNS resolution failed") printf 'DNSFL' ;;
    "Geo-restricted") printf 'GEO' ;;
    Filtered) printf 'FILTR' ;;
    Redirect*) printf 'REDIR' ;;
    "Connection refused") printf 'REFSD' ;;
    "TCP RST (DPI anomaly)") printf 'RST' ;;
    "Too many redirects") printf 'REDIR' ;;
    "HTTP/2 protocol error") printf 'H2ERR' ;;
    "Empty response") printf 'EMPTY' ;;
    "Partial transfer") printf 'PARTL' ;;
    "Server error"*) printf 'SVERR' ;;
    "Connection error"*) printf 'ERR' ;;
    "Content anomaly"*) printf 'ANOML' ;;
    "Content mismatch") printf 'MISMT' ;;
    *) printf 'FAIL' ;;
  esac
}

# Expand short failure tag back to human-readable reason.
# Inverse of short_reason(). Used by CDN verdict display.
# Args: $1 - short tag from short_reason() or numeric HTTP code
# stdout: descriptive reason string
long_reason() {
  case "$1" in
    ok)    printf 'ok' ;;
    TMOUT) printf 'Timeout / Filtered or shaped' ;;
    DPI)   printf 'DPI/SNI anomaly' ;;
    TLS)   printf 'TLS anomaly' ;;
    MITM)  printf 'MITM detected' ;;
    UNTCA) printf 'Untrusted CA' ;;
    EXPRD) printf 'Cert expired' ;;
    REVKD) printf 'Cert revoked' ;;
    SSLNM) printf 'Hostname mismatch' ;;
    DNSFL) printf 'DNS resolution failed' ;;
    GEO)   printf 'Geo-restricted' ;;
    FILTR) printf 'Filtered' ;;
    REDIR) printf 'Redirect' ;;
    REFSD) printf 'Connection refused' ;;
    RST)   printf 'TCP RST' ;;
    H2ERR) printf 'HTTP/2 protocol error' ;;
    EMPTY) printf 'Empty response' ;;
    PARTL) printf 'Partial transfer' ;;
    SVERR) printf 'Server error' ;;
    ERR)   printf 'Connection error' ;;
    ANOML) printf 'Content anomaly' ;;
    MISMT) printf 'Content mismatch' ;;
    FAIL)  printf 'Failed' ;;
    *)     printf '%s' "$1" ;;
  esac
}

# ─── Overall Verdict ──────────────────────────────────────────────────────────

# Determine overall verdict from per-interface results.
# Extended format: "iface:ok_or_fail:ttfb_ms:reason" (reason optional, backward-compat).
# Sub-classifies all_fail into cert_issue / dns_issue / server_down when all paths
# fail with the same non-blocking reason (distinguishes infra issues from filtering).
# Args: results via stdin
# stdout: verdict string
determine_verdict() {
  local has_tunnel_ok=0 has_isp_ok=0
  local tunnel_ttfb=0 isp_ttfb=0
  local iface status ttfb reason itype
  local _fail_reasons="" _n_fail=0

  while IFS=: read -r iface status ttfb reason; do
    itype=$(iface_type "$iface")
    if [ "$status" = "ok" ]; then
      if [ "$itype" = "tunnel" ]; then
        has_tunnel_ok=1
        tunnel_ttfb="$ttfb"
      else
        has_isp_ok=1
        isp_ttfb="$ttfb"
      fi
    else
      _n_fail=$((_n_fail + 1))
      # Collect unique failure reasons for sub-classification
      if [ -n "$reason" ]; then
        case "$_fail_reasons" in
          *"$reason"*) ;;
          "") _fail_reasons="$reason" ;;
          *) _fail_reasons="${_fail_reasons}|${reason}" ;;
        esac
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
    # all_fail — sub-classify by reason when single unique reason across all paths
    if [ "$_n_fail" -gt 0 ] && [ -n "$_fail_reasons" ]; then
      case "$_fail_reasons" in
        *"|"*) ;; # Multiple distinct reasons → generic all_fail
        "Untrusted CA"|"Cert expired"|"Cert revoked"|"Hostname mismatch")
          printf 'cert_issue'; return 0 ;;
        "DNS resolution failed")
          printf 'dns_issue'; return 0 ;;
        "Server error"*)
          printf 'server_down'; return 0 ;;
      esac
    fi
    printf 'all_fail'
  fi
}
