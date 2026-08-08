# net-check: CDN geo-steering analysis - per-interface CDN edge country via ECS.
# Supports custom headers/cookies from cdn-domains.conf extended format.
# Dependencies: lib/output.sh (emit_error, color_status, status_mark, is_quiet),
#   lib/wan.sh (get_wan_interfaces, iface_type, geo_cached_ip, geo_cached_cc),
#   lib/geoip.sh (geolocate_ip),
#   lib/http-core.sh (http_probe, format_size_bytes, classify_failure, short_reason),
#   lib/common.sh (json_kv, json_kv_bool, require_cmd)
# Globals used: OUTPUT_JSON, VERBOSITY, _EXIT_CODE,
#   CDN_ECS_RESOLVER, DNS_TIMEOUT, CONNECT_TIMEOUT, HTTP_TIMEOUT,
#   CURL_UA, DATA_DIR, _GEO_EXT_IPS, _CONFIG_DIR,
#   DNS_PROBE_PORTS, LAN_BRIDGE, PROBE_TIMEOUT, CDN_BATCH_SIZE, GEO_SERVICES,
#   C_GREEN, C_RED, C_YELLOW, C_DIM, C_RST, C_BOLD, C_CYAN
# shellcheck disable=SC3043

# ─── CDN Helpers ──────────────────────────────────────────────────────────────

# Expand short CDN http tag back to descriptive reason for verdict display.
# Mirrors classify_failure() descriptions from http-core.sh.
# Args: $1 - short tag or numeric HTTP code
# stdout: human-readable reason
_cdn_long_reason() {
  case "$1" in
    TMOUT) printf 'Timeout / Filtered or shaped' ;;
    DPI)   printf 'DPI/SNI anomaly' ;;
    TLS)   printf 'TLS anomaly' ;;
    MITM)  printf 'MITM detected' ;;
    GEO)   printf 'Geo-restricted' ;;
    FILTR) printf 'Filtered' ;;
    REDIR) printf 'Redirect' ;;
    REFSD) printf 'Connection refused' ;;
    RST)   printf 'TCP RST' ;;
    ERR)   printf 'Connection error' ;;
    ANOML) printf 'Content anomaly' ;;
    MISMT) printf 'Content mismatch' ;;
    FAIL)  printf 'Failed' ;;
    *)     printf '%s' "$1" ;;
  esac
}

# ─── CDN Probe Helper ────────────────────────────────────────────────────────

# Run CDN ECS resolve + HTTP probe for one domain/iface.
# Args: $1 - domain, $2 - iface, $3 - extra_curl flags, $4 - output file
# Output file format (TSV): cdn_ip cdn_cc rtt ext_ip http_code http_size cc_cached
_cdn_probe_iface() {
  local _domain="$1" _iface="$2" _extra_curl="${3:-}" _out="$4"
  local _ext_ip _cdn_ip="-" _cdn_cc="??" _rtt="-"
  local _http_code="-" _http_size="-" _cc_cached=0

  _ext_ip=$(geo_cached_ip "$_iface")
  if [ -z "$_ext_ip" ]; then
    # Extract first GEO_SERVICES URL for fallback
    _fallback_geo_url=$(printf '%s' "$GEO_SERVICES" | awk '{print $1}' | cut -d'|' -f1)
    _ext_ip=$(curl -sS --interface "$_iface" \
      --connect-timeout "$CONNECT_TIMEOUT" --max-time "$HTTP_TIMEOUT" \
      -H "User-Agent: $CURL_UA" \
      "$_fallback_geo_url" 2>/dev/null) || _ext_ip=""
  fi

  if [ -n "$_ext_ip" ]; then
    _cdn_ip=$(dig @"$CDN_ECS_RESOLVER" "+subnet=${_ext_ip}/24" "$_domain" A \
      +short +tries=1 +time="$DNS_TIMEOUT" 2>/dev/null \
      | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    _cdn_ip="${_cdn_ip:--}"
    # NOTE: geolocate_ip moved to sequential collection phase (avoids API
    # rate-limit when many parallel subshells call geoIP simultaneously).
    if [ "$_cdn_ip" != "-" ]; then
      local _ping_out
      _ping_out=$(ping -c 1 -W "$PROBE_TIMEOUT" -I "$_iface" "$_cdn_ip" 2>/dev/null | \
        sed -n 's/.*time=\([0-9.]*\).*/\1/p') || true
      [ -n "$_ping_out" ] && _rtt="$(awk "BEGIN{printf \"%d\", ${_ping_out}}")ms"
    fi
  fi

  local _probe_out=""
  _probe_out=$(http_probe "https://${_domain}" "$_iface" "$_extra_curl" 2>/dev/null) || true
  if [ -n "$_probe_out" ]; then
    _http_code=$(printf '%s' "$_probe_out" | awk '{print $1}')
    local _raw_size _curl_exit
    _raw_size=$(printf '%s' "$_probe_out" | awk '{print $2}')
    _curl_exit=$(printf '%s' "$_probe_out" | awk '{print $3}')
    _http_size=$(format_size_bytes "$_raw_size")
    # Replace generic code with descriptive tag on curl failure
    if [ "${_curl_exit:-0}" != "0" ]; then
      local _reason
      _reason=$(classify_failure "$_http_code" "0" "" "$_curl_exit" "0")
      _http_code=$(short_reason "$_reason")
    fi
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$_cdn_ip" "$_cdn_cc" "$_rtt" "${_ext_ip:--}" "$_http_code" "$_http_size" "$_cc_cached" \
    > "$_out"
}

# ─── Command: cdn (CDN geo-steering analysis) ────────────────────────────────

# Analyze CDN geo-steering for a domain.
# Phase 1: resolve via local DNS (actual result clients get).
# Phase 2: EDNS Client Subnet per WAN interface (optimal CDN edge per path).
# Phase 3: geolocate resolved IPs → country code per path.
# Args: $1 - domain, $2 - optional extra curl flags (custom headers)
# Args: $1 - domain, $2 - optional extra curl flags, $3 - "no_header" to skip title/description
cmd_cdn() {
  local domain="${1:-}"
  local extra_curl="${2:-}"
  local _skip_hdr="${3:-}"
  if [ -z "$domain" ]; then
    emit_error "Usage: net-check.sh cdn <domain>"
    return 1
  fi

  require_cmd dig

  local ifaces
  ifaces=$(require_wan_ifaces) || return 1

  # Phase 1: Local DNS resolution (what clients actually get)
  local local_ip="" local_cc=""
  local _dns_port="53"
  for _p in $DNS_PROBE_PORTS; do
    local_ip=$(dig @127.0.0.1 -p "$_p" "$domain" A +short +tries=1 +time="$DNS_TIMEOUT" 2>/dev/null \
      | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    if [ -n "$local_ip" ]; then
      _dns_port="$_p"
      break
    fi
  done
  local_ip="${local_ip:--}"
  local_cc=$(geolocate_ip "$local_ip")

  # Phase 1b: Determine which interface local DNS IP routes through
  local route_dev=""
  if [ "$local_ip" != "-" ]; then
    local _iif="$LAN_BRIDGE"
    local _fake_src
    _fake_src=$(ip -4 addr show "$_iif" 2>/dev/null | \
      awk '/inet /{split($2,a,"/"); split(a[1],b,"."); printf "%s.%s.%s.%d", b[1],b[2],b[3],(b[4]%254)+1; exit}')
    local _route_out=""
    if [ -n "$_fake_src" ]; then
      _route_out=$(ip route get "$local_ip" from "$_fake_src" iif "$_iif" 2>/dev/null) || _route_out=""
    fi
    [ -z "$_route_out" ] && _route_out=$(ip route get "$local_ip" 2>/dev/null) || true
    route_dev=$(printf '%s' "$_route_out" | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1)
  fi

  # Phase 2: ECS per interface - parallel
  (
  trap 'kill 0 2>/dev/null; exit 130' INT TERM
  for iface in $ifaces; do
    ( _cdn_probe_iface "$domain" "$iface" "$extra_curl" \
        "${_RUN_DIR}/cdn-iface-${iface}" ) &
  done
  wait
  )

  # Phase 3: Output results
  local json_paths=""
  local _all_cc="" _active_cc=""

  if [ "$_skip_hdr" != "no_header" ]; then
    section_title "${_TITLE_CDN}: $domain"
  fi
  if [ "$OUTPUT_JSON" = 0 ] && ! is_quiet; then
    if [ "$_skip_hdr" = "no_header" ]; then
      printf '%s%s%s%s\n' "$C_BOLD" "$C_CYAN" "$domain" "$C_RST"
    else
      printf 'Per-interface CDN edge country via EDNS Client Subnet.\n'
    fi
    if [ -n "$route_dev" ]; then
      printf 'Local DNS (:%-4s) → %s (%s) → routes via %s\n\n' "$_dns_port" "$local_ip" "$local_cc" "$route_dev"
    else
      printf 'Local DNS (:%-4s) → %s (%s)\n\n' "$_dns_port" "$local_ip" "$local_cc"
    fi
  fi
  tbl_header "Path:14" "CC:4" "CDN Edge IP:18" "Edge:4" "RTT:10" "HTTP:5" "Size:8" "Match"

  for iface in $ifaces; do
    local _par_f="${_RUN_DIR}/cdn-iface-${iface}"
    local cdn_ip="-" cdn_cc="??" rtt="-" ext_ip="-" http_code="-" http_size="-" cc_cached="0"
    if [ -f "$_par_f" ]; then
      cdn_ip=$(cut -f1 "$_par_f")
      rtt=$(cut -f3 "$_par_f")
      ext_ip=$(cut -f4 "$_par_f")
      http_code=$(cut -f5 "$_par_f")
      http_size=$(cut -f6 "$_par_f")
      rm -f "$_par_f"
    fi
    # Sequential geolocate (moved out of parallel _cdn_probe_iface to avoid
    # API rate-limits; also maximises cache hits for duplicate CDN edge IPs).
    if [ "$cdn_ip" != "-" ]; then
      if is_cache_fresh "$(ipgeo_cache_file "$cdn_ip")" "${IPGEO_CACHE_TTL:-86400}"; then
        cc_cached=1
      fi
      cdn_cc=$(geolocate_ip "$cdn_ip")
    fi

    local itype cc
    itype=$(iface_type "$iface")
    cc=$(geo_cached_cc "$iface")
    [ -z "$cc" ] && cc="-"

    # Is this the active routing path?
    local is_active=0
    [ "$iface" = "$route_dev" ] && is_active=1
    [ "$is_active" = 1 ] && _active_cc="$cdn_cc"

    # Track unique country codes for summary
    case " $_all_cc " in
      *" $cdn_cc "*) ;;
      *) _all_cc="${_all_cc:+${_all_cc} }${cdn_cc}" ;;
    esac

    if [ "$OUTPUT_JSON" = 1 ]; then
      local path_json
      path_json=$(printf '{%s,%s,%s,%s,%s,%s,%s,%s,%s,%s}' \
        "$(json_kv "dev" "$iface")" \
        "$(json_kv "type" "$itype")" \
        "$(json_kv "cc" "$cc")" \
        "$(json_kv "cdn_ip" "$cdn_ip")" \
        "$(json_kv "edge_cc" "$cdn_cc")" \
        "$(json_kv "rtt" "$rtt")" \
        "$(json_kv "ext_ip" "$ext_ip")" \
        "$(json_kv "http_code" "$http_code")" \
        "$(json_kv "http_size" "$http_size")" \
        "$(json_kv_bool "active" "$([ "$is_active" = 1 ] && echo 0 || echo 1)")")
      json_arr_add json_paths "$path_json"
    else
      local _st="ok"
      [ "$cdn_ip" = "-" ] && _st="fail"
      local active_mark=""
      [ "$is_active" = 1 ] && active_mark="active"
      # Color HTTP code: any non-2xx numeric + REDIR = warn;
      # curl failure tags (TMOUT, RST, etc.) = fail
      local _http_st="ok"
      case "$http_code" in
        2[0-9][0-9])              _http_st="ok" ;;
        0|-)                      _http_st="dim" ;;
        [0-9][0-9][0-9]|REDIR)   _http_st="warn" ;;
        *)                        _http_st="fail" ;;
      esac
      # CC color = worst of DNS resolution + HTTP status
      local _cc_st="$_st"
      if [ "$_cc_st" = "ok" ]; then
        case "$_http_st" in
          warn) _cc_st="warn" ;;
          fail) _cc_st="fail" ;;
        esac
      fi
      local _match_cell=""
      [ -n "$active_mark" ] && _match_cell="$(color_status ok "$active_mark")"
      [ "$cc_cached" = "1" ] && _match_cell="${_match_cell}${_match_cell:+ }$(cache_mark)"
      tbl_row "$iface" "$cc" \
        "$(tbl_cell 18 "$cdn_ip" "$_st")" \
        "$(tbl_cell 4 "$cdn_cc" "$_cc_st")" "$rtt" \
        "$(tbl_cell 5 "$http_code" "$_http_st")" "$http_size" \
        "$_match_cell"
    fi
  done

  # Verdict
  local _cc_count steering verdict
  _cc_count=$(printf '%s' "$_all_cc" | wc -w | tr -d ' ')
  steering="same_edge"
  [ "$_cc_count" -gt 1 ] && steering="different_edges"

  verdict="optimal"
  if [ -n "$_active_cc" ] && [ "$_active_cc" != "??" ] && [ "$local_cc" != "??" ]; then
    if [ "$local_cc" != "$_active_cc" ]; then
      verdict="suboptimal"
    fi
  fi

  if [ "$OUTPUT_JSON" = 0 ]; then
    if is_quiet; then
      printf 'cdn %s: %s (%s)\n' "$domain" "$verdict" "$_all_cc"
    else
      if [ "$verdict" = "suboptimal" ]; then
        printf '→ %s⚠️  DNS→%s, but %s path expects %s%s\n' \
          "$C_YELLOW" "$local_cc" "${route_dev:-?}" "$_active_cc" "$C_RST"
      elif [ "$_cc_count" -gt 1 ]; then
        printf '→ %sGeo-steering active%s (%s)\n' "$C_GREEN" "$C_RST" "$_all_cc"
      else
        printf '→ All paths: %s edge\n' "${_all_cc:-?}"
      fi
    fi
  fi

  if [ "$OUTPUT_JSON" = 1 ]; then
    printf '{%s,%s,%s,%s,%s,%s,"paths":[%s],%s}\n' \
      "$(json_kv_bool "ok" 0)" \
      "$(json_kv "domain" "$domain")" \
      "$(json_kv "local_ip" "$local_ip")" \
      "$(json_kv "local_cc" "$local_cc")" \
      "$(json_kv "route_dev" "${route_dev:-}")" \
      "$(json_kv "verdict" "$verdict")" \
      "$json_paths" \
      "$(json_kv "steering" "$steering")"
  fi
}

# ─── Command: cdn-all (CDN analysis for all configured domains) ──────────────

# Build extra curl flags from custom headers field in cdn-domains.conf.
# Args: $1 - semicolon-separated headers (e.g., "H1: v1;H2: v2")
# stdout: curl -H flags string
_cdn_build_extra_curl() {
  local _hdrs="$1" _out="" _old_ifs _hdr
  _hdrs=$(printf '%s' "$_hdrs" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [ -z "$_hdrs" ] && return 0
  _old_ifs="$IFS"
  IFS=";"
  for _hdr in $_hdrs; do
    _hdr=$(printf '%s' "$_hdr" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -n "$_hdr" ] && _out="${_out} -H '${_hdr}'"
  done
  IFS="$_old_ifs"
  printf '%s' "$_out"
}

# Format one CDN comparison cell: "CC HTTP RTT" padded to _CMP_COL_W.
# Args: $1 - edge_cc, $2 - http_code, $3 - rtt, $4 - cdn_ip
# stdout: formatted cell string
_cdn_format_cell() {
  local _cc="$1" _http="$2" _rtt="$3" _cdn_ip="$4"
  local _dns_st="ok" _http_st="ok"
  [ "$_cdn_ip" = "-" ] && _dns_st="fail"
  # Any non-2xx numeric + REDIR = warn; curl failure tags = fail
  case "$_http" in
    2[0-9][0-9])              _http_st="ok" ;;
    0|-)                      _http_st="dim" ;;
    [0-9][0-9][0-9]|REDIR)   _http_st="warn" ;;
    *)                        _http_st="fail" ;;
  esac
  # CC color = worst of DNS + HTTP status
  local _cc_st="$_dns_st"
  if [ "$_cc_st" = "ok" ]; then
    case "$_http_st" in
      warn) _cc_st="warn" ;;
      fail) _cc_st="fail" ;;
    esac
  fi
  printf '%s %s %s' \
    "$(tbl_cell 2 "$_cc" "$_cc_st")" \
    "$(tbl_cell 5 "$_http" "$_http_st")" \
    "$(printf '%*s' "$((_CMP_COL_W - 9))" "$_rtt")"
}

cmd_cdn_all() {
  if [ $# -eq 0 ] && [ ! -f "$_CONFIG_DIR/cdn-domains.conf" ]; then
    emit_error "CDN domains file not found: cdn-domains.conf"
    return 1
  fi

  require_cmd dig

  local ifaces
  ifaces=$(require_wan_ifaces) || return 1

  # Load geo-zone context for zone header
  load_zone_context

  # Warm geo cache for accurate CC in comparison table headers
  ensure_geo_cache

  section_title "$_TITLE_CDN"
  if [ "$OUTPUT_JSON" = 0 ] && ! is_quiet; then
    printf 'Per-interface CDN edge country via EDNS Client Subnet.\n\n'
  fi
  cmp_header "Domain" "$ifaces"

  local json_results=""
  local _cdn_total=0 _cdn_geo_steer=0 _cdn_same=0 _cdn_error=0

  # ── Phase 1: Read all domains + build extra curl flags ──
  local _cdn_domains=""
  if [ $# -gt 0 ]; then
    # Deep check mode: use passed domains
    local _cd _cdh
    for _cd in "$@"; do
      _cdh=$(url_to_host "$_cd")
      [ -z "$_cdh" ] && continue
      printf '' > "${_RUN_DIR}/cdncurl-${_cdh}"
      _cdn_domains="${_cdn_domains} ${_cdh}"
    done
  else
    # Default: load from cdn-domains.conf (zone-filtered by _cat_config)
    while IFS='|' read -r domain _category _description _custom_headers; do
      case "$domain" in "#"*|"") continue ;; esac
      local extra_curl=""
      extra_curl=$(_cdn_build_extra_curl "${_custom_headers:-}")
      printf '%s' "$extra_curl" > "${_RUN_DIR}/cdncurl-${domain}"
      _cdn_domains="${_cdn_domains} ${domain}"
    done <<EOF
$(_cat_config cdn-domains)
EOF
  fi

  # ── Phase 2: Batched parallel probes (2 domains at a time to avoid geoIP rate-limit) ──
  local _cdn_bn=0 _cdn_batch=""
  for domain in $_cdn_domains; do
    _cdn_batch="${_cdn_batch} ${domain}"
    _cdn_bn=$((_cdn_bn + 1))
    if [ "$_cdn_bn" -ge "$CDN_BATCH_SIZE" ]; then
      (
      trap 'kill 0 2>/dev/null; exit 130' INT TERM
      for _bd in $_cdn_batch; do
        _ec=$(cat "${_RUN_DIR}/cdncurl-${_bd}" 2>/dev/null) || _ec=""
        for iface in $ifaces; do
          ( _cdn_probe_iface "$_bd" "$iface" "$_ec" \
              "${_RUN_DIR}/cdnall-${_bd}-${iface}" ) &
        done
      done
      wait
      )
      _cdn_bn=0; _cdn_batch=""
    fi
  done
  if [ -n "$_cdn_batch" ]; then
    (
    trap 'kill 0 2>/dev/null; exit 130' INT TERM
    for _bd in $_cdn_batch; do
      _ec=$(cat "${_RUN_DIR}/cdncurl-${_bd}" 2>/dev/null) || _ec=""
      for iface in $ifaces; do
        ( _cdn_probe_iface "$_bd" "$iface" "$_ec" \
            "${_RUN_DIR}/cdnall-${_bd}-${iface}" ) &
      done
    done
    wait
    )
  fi

  # ── Phase 3: Collect results and render table (in original domain order) ──
  for domain in $_cdn_domains; do
    rm -f "${_RUN_DIR}/cdncurl-${domain}" 2>/dev/null

    local _all_cc="" _error_reasons="" _warn_reasons="" json_paths=""
    local _has_error=0 _has_warn=0 _active_reason=""

    # Determine active route device for this domain (for cell marker).
    # CDN domains don't carry check-targets category — falls back to kernel FIB.
    local _active_route_dev=""
    local _resolved_ip=""
    _resolved_ip=$(_resolve_a_cached "$domain" 2>/dev/null) || _resolved_ip=""
    _active_route_dev=$(active_dev_for_target "$_resolved_ip" "")

    # Pre-scan: pick recommended iface (best OK path by RTT)
    local _recommended_dev="" _rec_best_rtt=999999 _rec_ok_n=0 _ri
    for _ri in $ifaces; do
      local _rpf="${_RUN_DIR}/cdnall-${domain}-${_ri}"
      [ -f "$_rpf" ] || continue
      local _r_ip _r_http _r_rtt_raw _r_rtt_ms
      _r_ip=$(cut -f1 "$_rpf")
      [ "$_r_ip" = "-" ] && continue
      _r_http=$(cut -f5 "$_rpf")
      # Accept any numeric HTTP code or REDIR (server responded);
      # reject curl failure tags: TMOUT, TLS, ERR, RST, REFSD, etc.
      case "$_r_http" in [1-9][0-9][0-9]|REDIR) ;; *) continue ;; esac
      _rec_ok_n=$((_rec_ok_n + 1))
      _r_rtt_raw=$(cut -f3 "$_rpf")
      _r_rtt_ms=$(printf '%s' "$_r_rtt_raw" | sed 's/ms$//')
      case "$_r_rtt_ms" in ''|'-') continue ;; esac
      if [ "$_r_rtt_ms" -lt "$_rec_best_rtt" ] 2>/dev/null; then
        _rec_best_rtt="$_r_rtt_ms"
        _recommended_dev="$_ri"
      fi
    done
    # No ★ when single iface (no choice to show)
    local _n_ifc
    _n_ifc=$(printf '%s' "$ifaces" | wc -w | tr -d ' ')
    [ "$_n_ifc" -le 1 ] && _recommended_dev=""

    cmp_row_start "$domain"

    for iface in $ifaces; do
      local _pf="${_RUN_DIR}/cdnall-${domain}-${iface}"
      local cdn_ip="-" cdn_cc="??" rtt="-" ext_ip="-"
      local http_code="-" http_size="-" cc_cached="0"
      if [ -f "$_pf" ]; then
        cdn_ip=$(cut -f1 "$_pf")
        rtt=$(cut -f3 "$_pf"); ext_ip=$(cut -f4 "$_pf")
        http_code=$(cut -f5 "$_pf"); http_size=$(cut -f6 "$_pf")
        rm -f "$_pf"
      fi
      # Sequential geolocate (moved out of parallel probe — same reason as cmd_cdn)
      if [ "$cdn_ip" != "-" ]; then
        if is_cache_fresh "$(ipgeo_cache_file "$cdn_ip")" "${IPGEO_CACHE_TTL:-86400}"; then
          cc_cached=1
        fi
        cdn_cc=$(geolocate_ip "$cdn_ip")
      fi

      case " $_all_cc " in
        *" $cdn_cc "*) ;;
        *) _all_cc="${_all_cc:+${_all_cc} }${cdn_cc}" ;;
      esac

      # Track DNS resolution failures
      if [ "$cdn_ip" = "-" ]; then
        _has_error=1
        case "$_error_reasons" in
          *"no_resolve"*) ;;
          "") _error_reasons="no_resolve" ;;
          *) _error_reasons="${_error_reasons}, no_resolve" ;;
        esac
        [ "$iface" = "$_active_route_dev" ] && _active_reason="no_resolve"
      fi

      # Classify HTTP: non-2xx numeric + REDIR → warn;
      # curl failure tags (TMOUT, RST, etc.) → error
      case "$http_code" in
        2[0-9][0-9]|-) ;;  # ok or no data - skip
        [0-9][0-9][0-9]|REDIR)
          _has_warn=1
          local _long_w
          _long_w=$(_cdn_long_reason "$http_code")
          case "$_warn_reasons" in
            *"$_long_w"*) ;;
            "") _warn_reasons="$_long_w" ;;
            *) _warn_reasons="${_warn_reasons}, ${_long_w}" ;;
          esac
          [ "$iface" = "$_active_route_dev" ] && _active_reason="$_long_w"
          ;;
        *)
          _has_error=1
          local _long_e
          _long_e=$(_cdn_long_reason "$http_code")
          case "$_error_reasons" in
            *"$_long_e"*) ;;
            "") _error_reasons="$_long_e" ;;
            *) _error_reasons="${_error_reasons}, ${_long_e}" ;;
          esac
          [ "$iface" = "$_active_route_dev" ] && _active_reason="$_long_e"
          ;;
      esac

      local _is_active=0 _is_recommended=0
      [ "$iface" = "$_active_route_dev" ] && _is_active=1
      [ "$iface" = "$_recommended_dev" ] && _is_recommended=1
      cmp_cell "$(_cdn_format_cell "$cdn_cc" "$http_code" "$rtt" "$cdn_ip")" "$_is_active" "$_is_recommended"

      local _itype
      _itype=$(iface_type "$iface")
      local _pj
      _pj=$(printf '{%s,%s,%s,%s,%s,%s,%s,%s}' \
        "$(json_kv "dev" "$iface")" \
        "$(json_kv "type" "$_itype")" \
        "$(json_kv "cdn_ip" "$cdn_ip")" \
        "$(json_kv "edge_cc" "$cdn_cc")" \
        "$(json_kv "rtt" "$rtt")" \
        "$(json_kv "ext_ip" "$ext_ip")" \
        "$(json_kv "http_code" "$http_code")" \
        "$(json_kv "http_size" "$http_size")")
      json_arr_add json_paths "$_pj"
    done

    # Verdict: combine geo-steering info with error/warning status
    local _cc_count _verdict="same_edge" _vst="dim"
    _cc_count=$(printf '%s' "$_all_cc" | wc -w | tr -d ' ')
    _cdn_total=$((_cdn_total + 1))
    if [ "$_has_error" = 1 ] && [ "$_cc_count" -le 1 ] && [ "$_cc_count" -eq 0 ] 2>/dev/null; then
      _cdn_error=$((_cdn_error + 1))
    elif [ "$_cc_count" -gt 1 ]; then
      _verdict="geo_steering"; _vst="ok"
      _cdn_geo_steer=$((_cdn_geo_steer + 1))
    elif [ "$_has_error" = 1 ]; then
      _cdn_error=$((_cdn_error + 1))
    else
      _cdn_same=$((_cdn_same + 1))
    fi
    # Keep original verdict colors: same_edge=dim, geo_steering=ok
    # Reasons shown in dim (like HTTP Target Comparison)
    local _verdict_text _cc_list _reasons_text=""
    _cc_list=$(printf '%s' "$_all_cc" | tr ' ' ',')
    if [ -n "$_error_reasons" ] && [ -n "$_warn_reasons" ]; then
      _reasons_text="${_error_reasons}, ${_warn_reasons}"
    elif [ -n "$_error_reasons" ]; then
      _reasons_text="$_error_reasons"
    elif [ -n "$_warn_reasons" ]; then
      _reasons_text="$_warn_reasons"
    fi
    if [ -n "$_reasons_text" ]; then
      # Prefix active route's failure reason with grey ► in display
      local _display_reasons="$_reasons_text"
      if [ -n "$_active_reason" ]; then
        local _before="${_display_reasons%%"$_active_reason"*}"
        local _after="${_display_reasons#*"$_active_reason"}"
        _display_reasons="${_before}► ${_active_reason}${_after}"
      fi
      _verdict_text=$(printf '%s %s %s(%s)%s' "$(color_status "$_vst" "$_verdict")" "$_cc_list" "$C_DIM" "$_display_reasons" "$C_RST")
    else
      _verdict_text=$(printf '%s %s' "$(color_status "$_vst" "$_verdict")" "$_cc_list")
    fi
    cmp_row_end "$_verdict_text"

    local _dom_ok=0
    [ "$_has_error" = 0 ] && _dom_ok=0 || _dom_ok=1
    local _dj
    _dj=$(printf '{%s,%s,%s,"paths":[%s]}' \
      "$(json_kv_bool "ok" "$_dom_ok")" \
      "$(json_kv "domain" "$domain")" \
      "$(json_kv "verdict" "$_verdict")" \
      "$json_paths")
    json_arr_add json_results "$_dj"
  done

  if [ "$OUTPUT_JSON" = 1 ]; then
    printf '[%s]\n' "$json_results"
  else
    if is_quiet; then
      if [ "$_cdn_error" -gt 0 ]; then
        printf 'cdn-all: %s/%s geo-steering, %s same edge, %s failed\n' \
          "$_cdn_geo_steer" "$_cdn_total" "$_cdn_same" "$_cdn_error"
      else
        printf 'cdn-all: %s/%s geo-steering, %s same edge\n' \
          "$_cdn_geo_steer" "$_cdn_total" "$_cdn_same"
      fi
    else
      if [ "$_cdn_error" -gt 0 ]; then
        printf '→ %s/%s domains geo-steering, %s same edge, %s%s failed%s\n' \
          "$_cdn_geo_steer" "$_cdn_total" "$_cdn_same" \
          "$C_RED" "$_cdn_error" "$C_RST"
      else
        printf '→ %s/%s domains geo-steering, %s same edge %s\n' \
          "$_cdn_geo_steer" "$_cdn_total" "$_cdn_same" \
          "$(status_mark ok)"
      fi
    fi
  fi
  # Only actual errors (DNS fail / HTTP error) affect exit code; same_edge is normal
  if [ "$_cdn_error" -gt 0 ]; then
    update_exit_code "$((_cdn_total - _cdn_error))" "$_cdn_total"
  fi
  return 0
}
