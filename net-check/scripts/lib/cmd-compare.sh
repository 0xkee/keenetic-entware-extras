# net-check: HTTP target checks — single target, domains list, comparison table with historical diff.
# Dependencies: lib/output.sh (emit_error, color_status, status_mark, summary_line, is_quiet, is_verbose),
#   lib/wan.sh (get_wan_interfaces, iface_type, geo_cached_cc),
#   lib/http-core.sh (check_target_via_iface, classify_failure, short_reason, determine_verdict, url_to_host, to_ms),
#   lib/common.sh (json_kv, json_kv_num, json_kv_bool)
# Globals used: OUTPUT_JSON, VERBOSITY, _EXIT_CODE,
#   ANOMALY_MARKERS_FILE, DATA_DIR, _CONFIG_DIR, CACHE_FILE,
#   CONNECT_TIMEOUT, HTTP_TIMEOUT, CURL_UA, PARALLEL_BATCH_SIZE, MAX_REDIRECT_WARN,
#   C_GREEN, C_RED, C_YELLOW, C_DIM, C_RST, C_BOLD, C_CYAN
# shellcheck disable=SC3043,SC2154

# ─── Historical Diff Helpers ──────────────────────────────────────────────────

# Load previous compare results from cache file + pre-parse for O(1) lookup.
# Sets: _prev_cache_data (raw file content), _pv_TARGET_IFACE vars
load_prev_cache() {
  _prev_cache_data=""
  [ -f "$CACHE_FILE" ] || return 0
  _prev_cache_data=$(cat "$CACHE_FILE" 2>/dev/null) || _prev_cache_data=""
  [ -z "$_prev_cache_data" ] && return 0
  # Pre-parse into _pv_HOST_IFACE variables for O(1) lookup
  eval "$(printf '%s' "$_prev_cache_data" | tr '{' '\n' | awk -F'"' '
    /"target":/ {
      for (i=1;i<=NF;i++) if ($i=="target") { tgt=$(i+2); break }
    }
    /"dev":/ && /"verdict":/ {
      dev=""; vrd=""
      for (i=1;i<=NF;i++) {
        if ($i=="dev" && dev=="") dev=$(i+2)
        if ($i=="verdict" && vrd=="") { vrd=$(i+2); break }
      }
      if (tgt != "" && dev != "") {
        gsub(/[^a-zA-Z0-9]/, "_", tgt)
        gsub(/[^a-zA-Z0-9]/, "_", dev)
        printf "_pv_%s_%s='"'"'%s'"'"'\n", tgt, dev, vrd
      }
    }
  ')"
}

# Lookup previous verdict from pre-parsed cache (1 fork vs 4 original).
# Args: $1 - target host, $2 - iface name
# stdout: previous verdict or empty
prev_verdict_for() {
  [ -z "$_prev_cache_data" ] && return 0
  local _pvk
  _pvk=$(printf '%s_%s' "$1" "$2" | tr -c 'a-zA-Z0-9\n' '_')
  eval "printf '%s' \"\${_pv_${_pvk}:-}\""
}

# Compute diff marker by comparing current and previous verdicts.
# Args: $1 - current verdict, $2 - previous verdict
# stdout: "" (no change), "NEW_FAIL", "RECOVERED"
diff_marker() {
  local curr="$1" prev="$2"
  [ -z "$prev" ] && return 0  # no previous data
  if [ "$curr" = "ok" ] && [ "$prev" != "ok" ]; then
    printf 'RECOVERED'
  elif [ "$curr" != "ok" ] && [ "$prev" = "ok" ]; then
    printf 'NEW_FAIL'
  fi
}

# ─── Single Target Helpers ────────────────────────────────────────────────────

# Probe one interface for cmd_check_target: curl + classify.
# Args: $1 - url, $2 - iface, $3 - need_body, $4 - expected_string
# Sets: _ct_path_ok, _ct_reason, _ct_http_code, _ct_tls_ok,
#       _ct_ttfb_ms, _ct_dns_ms, _ct_cc, _ct_itype
_check_target_probe_iface() {
  local url="$1" iface="$2" need_body="$3" expected_string="${4:-}"
  local curl_out curl_exit=0 body_file=""

  if [ "$need_body" = 1 ]; then
    body_file="${_RUN_DIR}/body-single-${iface}"
    curl_out=$(check_target_via_iface "$url" "$iface" "$body_file") || curl_exit=$?
  else
    curl_out=$(check_target_via_iface "$url" "$iface") || curl_exit=$?
  fi

  parse_curl_metrics "$curl_out"
  _ct_http_code="$_cm_code"
  local ssl_verify="$_cm_ssl" redirect_url="$_cm_redirect"
  local time_connect="$_cm_time_connect" time_starttfb="$_cm_time_starttfb"

  _ct_ttfb_ms=$(to_ms "$time_starttfb")
  _ct_dns_ms=$(to_ms "${_cm_time_dns:-0}")

  _ct_reason=$(classify_failure "$_ct_http_code" "$ssl_verify" "$redirect_url" \
    "$curl_exit" "$time_connect" "http" "$body_file" "$expected_string")

  rm -f "$body_file" 2>/dev/null

  if [ "$ssl_verify" = "0" ]; then _ct_tls_ok="true"; else _ct_tls_ok="false"; fi

  _ct_itype=$(iface_type "$iface")
  _ct_cc=$(geo_cached_cc "$iface")
  [ -z "$_ct_cc" ] && _ct_cc="—"

  _ct_path_ok="fail"
  if [ "$_ct_reason" = "ok" ]; then
    if [ "$_ct_http_code" -ge 200 ] 2>/dev/null && [ "$_ct_http_code" -lt 400 ] 2>/dev/null; then
      _ct_path_ok="ok"
    elif [ "$_ct_http_code" = "403" ]; then
      _ct_path_ok="ok"
    fi
  fi
}

# Compute and output overall verdict for cmd_check_target.
# Args: $1 - host, $2 - verdict_input, $3 - json_paths
_check_target_verdict() {
  local host="$1" verdict_input="$2" json_paths="$3"

  local verdict
  verdict=$(printf '%s' "$verdict_input" | determine_verdict)

  if [ "$OUTPUT_JSON" = 1 ]; then
    local ok_bool=1
    [ "$verdict" = "all_ok" ] && ok_bool=0
    printf '{%s,%s,"paths":[%s],%s}\n' \
      "$(json_kv_bool "ok" "$ok_bool")" \
      "$(json_kv "target" "$host")" \
      "$json_paths" \
      "$(json_kv "verdict" "$verdict")"
  elif is_quiet; then
    local _qst
    _qst="$(status_mark ok)"
    [ "$verdict" != "all_ok" ] && _qst="$(status_mark fail)"
    printf '%s %s: %s\n' "$_qst" "$host" "$verdict"
  else
    local _vst="ok"
    case "$verdict" in
      all_ok) _vst="ok" ;;
      all_fail) _vst="fail" ;;
      *) _vst="warn" ;;
    esac
    printf '→ Verdict: %s\n' "$(color_status "$_vst" "$verdict")"
  fi

  case "$verdict" in
    all_ok) ;;
    all_fail) _EXIT_CODE=2 ;;
    *) [ "$_EXIT_CODE" -lt 1 ] && _EXIT_CODE=1 ;;
  esac
}

# ─── Command: check single target ────────────────────────────────────────────

cmd_check_target() {
  local url="$1"
  local host
  host=$(url_to_host "$url")

  # Ensure URL has scheme
  case "$url" in
    http://*|https://*) ;;
    *) url="https://${url}" ;;
  esac

  local ifaces
  ifaces=$(require_wan_ifaces) || return 1

  local verdict_input="" json_paths=""
  local need_body=0 expected_string=""

  # Check if we need body content (anomaly markers exist)
  [ -f "$ANOMALY_MARKERS_FILE" ] && need_body=1

  section_title "$host — $_TITLE_COMPARE"
  tbl_header "Path:14" "CC:4" "HTTP:5" "TLS:5" "DNS:8" "TTFB:8" "Verdict"

  local iface
  for iface in $ifaces; do
    _check_target_probe_iface "$url" "$iface" "$need_body" "$expected_string"

    # Collect verdict input (extended format: iface:status:ttfb:reason)
    verdict_input="${verdict_input}${iface}:${_ct_path_ok}:${_ct_ttfb_ms}:${_ct_reason}
"

    if [ "$OUTPUT_JSON" = 1 ]; then
      local path_json _tls_jv="false"
      [ "$_ct_tls_ok" = "true" ] && _tls_jv="true"
      path_json=$(printf '{"dev":"%s","type":"%s","cc":"%s","http_code":%s,"tls_ok":%s,"ttfb_ms":%s,"verdict":"%s"}' \
        "$iface" "$_ct_itype" "$_ct_cc" "$_ct_http_code" "$_tls_jv" "$_ct_ttfb_ms" "$_ct_reason")
      json_arr_add json_paths "$path_json"
    else
      local _st="fail"
      [ "$_ct_path_ok" = "ok" ] && _st="ok"
      local _tls_st="fail"
      [ "$_ct_tls_ok" = "true" ] && _tls_st="ok"
      local _tls_label="FAIL"
      [ "$_tls_st" = "ok" ] && _tls_label="ok"
      tbl_cell_v 5 "$_ct_http_code" "$_st"; local _c1="$_CELL"
      tbl_cell_v 5 "$_tls_label" "$_tls_st"; local _c2="$_CELL"
      tbl_cell_v 8 "${_ct_dns_ms}ms" "$_st"; local _c3="$_CELL"
      tbl_cell_v 8 "${_ct_ttfb_ms}ms" "$_st"; local _c4="$_CELL"
      tbl_row "$iface" "$_ct_cc" "$_c1" "$_c2" "$_c3" "$_c4" \
        "$(color_status "$_st" "$_ct_reason")"
    fi
  done

  # Overall verdict
  _check_target_verdict "$host" "$verdict_input" "$json_paths"
}

# ─── Command: domains (HTTP targets from config) ─────────────────────────────

cmd_domains() {
  if [ ! -f "$_CONFIG_DIR/check-targets.conf" ]; then
    emit_error "Targets file not found: check-targets.conf"
    return 1
  fi

  local first_result=1
  [ "$OUTPUT_JSON" = 1 ] && printf '['

  while IFS='|' read -r url check_type _category _description _expected; do
    # Skip comments and empty lines
    case "$url" in
      "#"*|"") continue ;;
    esac
    [ "$check_type" = "geo" ] && continue

    if [ "$OUTPUT_JSON" = 0 ]; then
      [ "$first_result" = 0 ] && printf '\n'
    else
      [ "$first_result" = 0 ] && printf ','
    fi
    first_result=0

    cmd_check_target "$url"
  done <<EOF
$(_cat_config check-targets)
EOF

  [ "$OUTPUT_JSON" = 1 ] && printf ']\n'
  return 0
}

# ─── Compare Helpers ──────────────────────────────────────────────────────────

# Phase 1: Read all targets into indexed config files.
# Args: $1 - need_body, rest - optional domain list
# Sets: _cmp_tgt_hosts, _cmp_total_targets
# Creates: _RUN_DIR/tgtcfg-* files
_compare_load_targets() {
  local need_body="$1"; shift
  _cmp_tgt_hosts=""
  _cmp_total_targets=0

  if [ $# -gt 0 ]; then
    # Deep check mode: use passed domains
    local _ad
    for _ad in "$@"; do
      case "$_ad" in http://*|https://*) ;; *) _ad="https://${_ad}" ;; esac
      local host
      host=$(url_to_host "$_ad")
      _cmp_total_targets=$((_cmp_total_targets + 1))
      printf '%s\t%s\t%s\t%s\t%s\n' "$_ad" "$host" "$need_body" "" "check" \
        > "${_RUN_DIR}/tgtcfg-${host}"
      _cmp_tgt_hosts="${_cmp_tgt_hosts} ${host}"
    done
  else
    # Default: load from check-targets.conf (zone-filtered by _cat_config)
    local url check_type _category _description expected_string
    while IFS='|' read -r url check_type _category _description expected_string; do
      case "$url" in
        "#"*|"") continue ;;
      esac
      [ "$check_type" = "geo" ] && continue
      case "$url" in
        http://*|https://*) ;;
        *) url="https://${url}" ;;
      esac
      local host
      host=$(url_to_host "$url")
      _cmp_total_targets=$((_cmp_total_targets + 1))
      expected_string=$(printf '%s' "${expected_string:-}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      local target_need_body="$need_body"
      [ -n "$expected_string" ] && target_need_body=1
      printf '%s\t%s\t%s\t%s\t%s\n' "$url" "$host" "$target_need_body" "$expected_string" "${_category:-global}" \
        > "${_RUN_DIR}/tgtcfg-${host}"
      _cmp_tgt_hosts="${_cmp_tgt_hosts} ${host}"
    done <<EOF
$(_cat_config check-targets)
EOF
  fi
}

# Batch callback: parallel curls for all targets × all interfaces.
# Args: $1 - space-separated host list (batch subset)
# Uses: ifaces (from caller scope)
# shellcheck disable=SC2329
_compare_run_batch() {
  local _hosts="$1"
  local _bh _tcf _turl _tnb
  for _bh in $_hosts; do
    _tcf="${_RUN_DIR}/tgtcfg-${_bh}"
    [ -f "$_tcf" ] || continue
    _turl=$(cut -f1 "$_tcf"); _tnb=$(cut -f3 "$_tcf")
    for iface in $ifaces; do
      ( _ce=0
        if [ "$_tnb" = 1 ]; then _bf="${_RUN_DIR}/body-${_bh}-${iface}"; _co=$(check_target_via_iface "$_turl" "$iface" "$_bf") || _ce=$?
        else _co=$(check_target_via_iface "$_turl" "$iface") || _ce=$?; _bf=""; fi
        printf '%s\n%s\n%s' "$_ce" "$_bf" "$_co" > "${_RUN_DIR}/par-${_bh}-${iface}"
      ) &
    done
  done
}

# Pre-scan parallel results for a host: determine active route and recommended dev.
# Args: $1 - host, $2 - tgt_category
# Uses: ifaces (from caller scope)
# Sets: _cmp_active_route_dev, _cmp_recommended_dev, _cmp_resolved_ip
_compare_prescan_host() {
  local host="$1" tgt_category="$2"

  # Determine active route device
  _cmp_resolved_ip=""
  _cmp_resolved_ip=$(_resolve_a_cached "$host" 2>/dev/null) || _cmp_resolved_ip=""
  _cmp_active_route_dev=$(active_dev_for_target "$_cmp_resolved_ip" "${tgt_category:-}")

  # Pre-scan: pick recommended iface (best OK path by TTFB)
  _cmp_recommended_dev=""
  local _rec_best_ttfb=999999 _ri
  for _ri in $ifaces; do
    local _rpf="${_RUN_DIR}/par-${host}-${_ri}"
    [ -f "$_rpf" ] || continue
    local _r_exit _r_out _r_code _r_ttfb_raw _r_ttfb_ms
    _r_exit=$(sed -n '1p' "$_rpf")
    [ "$_r_exit" != "0" ] && continue
    _r_out=$(sed -n '3p' "$_rpf")
    _r_code=$(printf '%s' "$_r_out" | sed -n 's/.*"code":\([0-9]*\).*/\1/p')
    _r_code="${_r_code:-0}"
    case "$_r_code" in [23][0-9][0-9]|403) ;; *) continue ;; esac
    _r_ttfb_raw=$(printf '%s' "$_r_out" | sed -n 's/.*"time_starttfb":\([0-9.]*\).*/\1/p')
    _r_ttfb_ms=$(to_ms "${_r_ttfb_raw:-0}")
    if [ "$_r_ttfb_ms" -lt "$_rec_best_ttfb" ]; then
      _rec_best_ttfb="$_r_ttfb_ms"
      _cmp_recommended_dev="$_ri"
    fi
  done
  # No ★ when single iface (no choice to show)
  local _n_ifc
  _n_ifc=$(printf '%s' "$ifaces" | wc -w | tr -d ' ')
  [ "$_n_ifc" -le 1 ] && _cmp_recommended_dev=""
}

# Parse one parallel result file and classify the path.
# Args: $1 - host, $2 - iface, $3 - check_type, $4 - expected_string
# Sets: _cp_path_ok, _cp_reason, _cp_ttfb_ms, _cp_http_code,
#       _cp_tls_ok, _cp_itype, _cp_warning
_compare_classify_path() {
  local host="$1" iface="$2" check_type="$3" expected_string="$4"

  local par_file="${_RUN_DIR}/par-${host}-${iface}"
  local curl_exit="" body_file="" curl_out=""
  if [ -f "$par_file" ]; then
    curl_exit=$(sed -n '1p' "$par_file")
    body_file=$(sed -n '2p' "$par_file")
    curl_out=$(sed -n '3p' "$par_file")
    rm -f "$par_file"
  else
    curl_exit="1"
    curl_out=""
  fi

  parse_curl_metrics "$curl_out"
  _cp_http_code="$_cm_code"
  local ssl_verify="$_cm_ssl" redirect_url="$_cm_redirect"
  local time_connect="$_cm_time_connect" time_starttfb="$_cm_time_starttfb"

  _cp_ttfb_ms=$(to_ms "$time_starttfb")
  _cp_reason=$(classify_failure "$_cp_http_code" "$ssl_verify" "${redirect_url:-}" \
    "$curl_exit" "$time_connect" "${check_type:-http}" "$body_file" "$expected_string")

  # Many-redirect warning: ok but >3 hops
  _cp_warning=""
  if [ "$_cp_reason" = "ok" ] && [ "${_cm_num_redirects:-0}" -gt "$MAX_REDIRECT_WARN" ] 2>/dev/null; then
    _cp_warning="Many redirects"
  fi

  # Clean up body file
  [ -n "$body_file" ] && rm -f "$body_file" 2>/dev/null

  if [ "$ssl_verify" = "0" ]; then _cp_tls_ok="true"; else _cp_tls_ok="false"; fi
  _cp_itype=$(iface_type "$iface")

  _cp_path_ok="fail"
  if [ "$_cp_reason" = "ok" ]; then
    if [ "$_cp_http_code" -ge 200 ] 2>/dev/null && [ "$_cp_http_code" -lt 400 ] 2>/dev/null; then
      _cp_path_ok="ok"
    elif [ "$_cp_http_code" = "403" ]; then
      # 403 + ok reason = WAF/anti-bot, still reachable
      _cp_path_ok="ok"
    fi
  fi
}

# Collect per-path results into accumulators and build JSON entry.
# Args: $1 - iface
# Uses: _cp_path_ok, _cp_reason, _cp_ttfb_ms, _cp_http_code, _cp_tls_ok,
#       _cp_itype, _cp_warning, _cmp_active_route_dev
# Updates: _cmp_verdict_input, _cmp_json_paths, _cmp_target_all_ok,
#          _cmp_fail_reasons, _cmp_active_reason
_compare_collect_path() {
  local iface="$1"

  [ "$_cp_path_ok" != "ok" ] && _cmp_target_all_ok=0

  # Collect unique failure/warning reasons for display
  if [ "$_cp_path_ok" != "ok" ] && [ "$_cp_reason" != "ok" ]; then
    case "$_cmp_fail_reasons" in
      *"$_cp_reason"*) ;;
      "") _cmp_fail_reasons="$_cp_reason" ;;
      *) _cmp_fail_reasons="${_cmp_fail_reasons}, ${_cp_reason}" ;;
    esac
    # Track active route failure for ► marker in verdict
    [ "$iface" = "$_cmp_active_route_dev" ] && _cmp_active_reason="$_cp_reason"
  elif [ -n "$_cp_warning" ]; then
    case "$_cmp_fail_reasons" in
      *"$_cp_warning"*) ;;
      "") _cmp_fail_reasons="$_cp_warning" ;;
      *) _cmp_fail_reasons="${_cmp_fail_reasons}, ${_cp_warning}" ;;
    esac
    [ "$iface" = "$_cmp_active_route_dev" ] && _cmp_active_reason="$_cp_warning"
  fi

  _cmp_verdict_input="${_cmp_verdict_input}${iface}:${_cp_path_ok}:${_cp_ttfb_ms}:${_cp_reason}
"

  # Build JSON for cache (inline printf, 0 forks)
  local path_json _tls_jv="false"
  [ "$_cp_tls_ok" = "true" ] && _tls_jv="true"
  path_json=$(printf '{"dev":"%s","type":"%s","http_code":%s,"tls_ok":%s,"ttfb_ms":%s,"verdict":"%s"}' \
    "$iface" "$_cp_itype" "$_cp_http_code" "$_tls_jv" "$_cp_ttfb_ms" "$_cp_reason")
  json_arr_add _cmp_json_paths "$path_json"
}

# Render one comparison table cell (text mode only).
# Args: $1 - host, $2 - iface
# Uses: _cp_path_ok, _cp_reason, _cp_ttfb_ms, _cp_http_code, _cp_warning,
#       _cmp_active_route_dev, _cmp_recommended_dev
_compare_render_cell() {
  local host="$1" iface="$2"

  [ "$OUTPUT_JSON" = 1 ] && return 0
  is_quiet && return 0

  local _st="fail"
  [ "$_cp_path_ok" = "ok" ] && _st="ok"
  # Override display for warnings (path still ok for verdict)
  if [ "$_cp_path_ok" = "ok" ] && [ -n "$_cp_warning" ]; then
    _st="warn"
  fi

  # Historical diff marker (computed first to reserve column space)
  local _diff_mark=""
  local _prev_v=""
  _prev_v=$(prev_verdict_for "$host" "$iface")
  if [ -n "$_prev_v" ]; then
    _diff_mark=$(diff_marker "$_cp_reason" "$_prev_v")
  fi

  # Reserve 2 chars for diff marker so ▲/▼ don't shift columns
  local _diff_extra=0
  [ -n "$_diff_mark" ] && _diff_extra=2

  local _cell="" _short_tag _ttfb_part
  _short_tag=$(short_reason "$_cp_reason")
  if [ -n "$_cp_warning" ]; then
    _short_tag="REDIR"
  fi
  if [ "$_st" != "ok" ] && [ "$_cp_ttfb_ms" = "0" ]; then
    # em-dash is 3 bytes UTF-8 but 1 visual char; +2 compensates
    _ttfb_part=$(printf '%*s' "$((_CMP_COL_W - 8 - _diff_extra))" "—")
  else
    _ttfb_part=$(printf '%*sms' "$((_CMP_COL_W - 12 - _diff_extra))" "$_cp_ttfb_ms")
  fi
  tbl_cell_v 3 "$_cp_http_code" "$_st"; local _c1="$_CELL"
  tbl_cell_v 5 "$_short_tag" "$_st"; local _c2="$_CELL"
  _cell=$(printf '%s %s %s' "$_c1" "$_c2" "$_ttfb_part")

  # Append diff marker if present
  if [ "$_diff_mark" = "NEW_FAIL" ]; then
    _cell="${_cell} ${C_RED}▼${C_RST}"
  elif [ "$_diff_mark" = "RECOVERED" ]; then
    _cell="${_cell} ${C_GREEN}▲${C_RST}"
  fi

  local _is_active=0 _is_recommended=0
  [ "$iface" = "$_cmp_active_route_dev" ] && _is_active=1
  [ "$iface" = "$_cmp_recommended_dev" ] && _is_recommended=1
  cmp_cell "$_cell" "$_is_active" "$_is_recommended"
}

# Compute per-host verdict, route verification, build JSON, render row end.
# Args: $1 - host
# Uses: _cmp_verdict_input, _cmp_json_paths, _cmp_target_all_ok,
#       _cmp_fail_reasons, _cmp_active_reason, _cmp_active_route_dev,
#       _cmp_resolved_ip, _cmp_tgt_category
# Updates: _cmp_ok_targets, _cmp_json_results
_compare_host_verdict() {
  local host="$1"

  local verdict
  verdict=$(printf '%s' "$_cmp_verdict_input" | determine_verdict)

  [ "$_cmp_target_all_ok" = 1 ] && _cmp_ok_targets=$((_cmp_ok_targets + 1))

  # Route verification: check where LAN traffic actually goes for this target
  local _route_info="" _route_json=""
  local _vst="ok"
  case "$verdict" in
    all_ok) _vst="ok" ;;
    all_fail) _vst="fail" ;;
    cert_issue|dns_issue|server_down) _vst="warn" ;;
    *) _vst="warn" ;;
  esac
  if [ -n "$_ZONE_LABEL" ] && [ -n "$_cmp_resolved_ip" ] && [ -n "$_cmp_active_route_dev" ]; then
    local _expected_rt _actual_rt
    _expected_rt=$(expected_route_type "${_cmp_tgt_category:-global}")
    if [ "$_expected_rt" != "any" ]; then
      _actual_rt=$(iface_type "$_cmp_active_route_dev")
      if [ "$_actual_rt" = "$_expected_rt" ]; then
        : # route matches expectation — no display noise
      else
        _route_info=$(printf ' %s⚠route:%s(exp %s)%s' "$C_YELLOW" "$_cmp_active_route_dev" "$_expected_rt" "$C_RST")
        [ "$_vst" = "ok" ] && _vst="warn"
      fi
      _route_json=$(printf ',"route_dev":"%s","route_type":"%s","route_expected":"%s"' \
        "$_cmp_active_route_dev" "$_actual_rt" "$_expected_rt")
    fi
  fi

  local ok_bool=1
  [ "$verdict" = "all_ok" ] && ok_bool=0
  local result_json _ok_jv="false"
  [ "$ok_bool" = 0 ] && _ok_jv="true"
  if [ -n "$_cmp_fail_reasons" ]; then
    result_json=$(printf '{"ok":%s,"target":"%s","category":"%s","paths":[%s],"verdict":"%s","fail_reason":"%s"%s}' \
      "$_ok_jv" "$host" "${_cmp_tgt_category:-global}" \
      "$_cmp_json_paths" "$verdict" "$_cmp_fail_reasons" "$_route_json")
  else
    result_json=$(printf '{"ok":%s,"target":"%s","category":"%s","paths":[%s],"verdict":"%s"%s}' \
      "$_ok_jv" "$host" "${_cmp_tgt_category:-global}" \
      "$_cmp_json_paths" "$verdict" "$_route_json")
  fi
  json_arr_add _cmp_json_results "$result_json"

  # Render verdict text
  local _verdict_text
  if [ -n "$_cmp_fail_reasons" ]; then
    # Prefix active route's failure reason with grey ► in display
    local _display_reasons="$_cmp_fail_reasons"
    if [ -n "$_cmp_active_reason" ]; then
      local _before="${_display_reasons%%"$_cmp_active_reason"*}"
      local _after="${_display_reasons#*"$_cmp_active_reason"}"
      _display_reasons="${_before}► ${_cmp_active_reason}${_after}"
    fi
    _verdict_text=$(printf '%s %s(%s)%s%s' "$(color_status "$_vst" "$verdict")" "$C_DIM" "$_display_reasons" "$C_RST" "$_route_info")
  else
    _verdict_text=$(printf '%s%s' "$(color_status "$_vst" "$verdict")" "$_route_info")
  fi
  cmp_row_end "$_verdict_text"
}

# Save cache and render final summary for cmd_compare.
# Args: $1 - whether args were passed (0=config mode, 1=args mode)
# Uses: _cmp_json_results, _cmp_ok_targets, _cmp_total_targets
_compare_render_summary() {
  local _args_mode="$1"

  # Save results to cache for status.sh (only for config-based runs)
  if [ "$_args_mode" = 0 ]; then
    printf '[%s]\n' "$_cmp_json_results" > "${CACHE_FILE}.$$"
    mv -f "${CACHE_FILE}.$$" "$CACHE_FILE" 2>/dev/null || true
  fi

  if [ "$OUTPUT_JSON" = 1 ]; then
    if [ "$_args_mode" = 0 ] && [ -f "$CACHE_FILE" ]; then
      cat "$CACHE_FILE"
    else
      printf '[%s]\n' "$_cmp_json_results"
    fi
  else
    if is_quiet; then
      printf 'compare: %s/%s targets all_ok\n' "$_cmp_ok_targets" "$_cmp_total_targets"
    else
      summary_line "$_cmp_ok_targets" "$_cmp_total_targets" "targets"
    fi
  fi

  update_exit_code "$_cmp_ok_targets" "$_cmp_total_targets"
}

# ─── Command: compare (table + diff) ─────────────────────────────────────────

cmd_compare() {
  if [ $# -eq 0 ] && [ ! -f "$_CONFIG_DIR/check-targets.conf" ]; then
    emit_error "Targets file not found: check-targets.conf"
    return 1
  fi

  local ifaces
  ifaces=$(require_wan_ifaces) || return 1

  # Load previous cache for historical diff
  load_prev_cache

  # Load geo-zone context for route verification
  load_zone_context

  # Warm geo cache for accurate CC in comparison table headers
  ensure_geo_cache
  precache_geo_cc

  # Check if we need body content
  local need_body=0
  [ -f "$ANOMALY_MARKERS_FILE" ] && need_body=1

  # Build header
  section_title "$_TITLE_COMPARE"
  if [ "$OUTPUT_JSON" = 0 ] && ! is_quiet; then
    printf 'HTTP reachability across all paths. Detects middlebox anomalies (DPI/SNI), MITM, geo-restrictions.\n\n'
  fi

  # ── Phase 1: Read all targets into indexed config files ──
  _compare_load_targets "$need_body" "$@"

  # Auto-width first column
  local _label_w
  _label_w=$(auto_label_width "$_cmp_tgt_hosts")
  cmp_header "Resource" "$ifaces" "" "$_label_w"

  # ── Phase 2: Batched parallel curls ──
  batch_run_parallel "HTTP" "$PARALLEL_BATCH_SIZE" "$_cmp_tgt_hosts" _compare_run_batch

  # ── Phase 3: Collect results and render table (in original target order) ──
  _cmp_json_results=""
  _cmp_ok_targets=0
  tbl_group_reset

  local host
  for host in $_cmp_tgt_hosts; do
    local _tcf="${_RUN_DIR}/tgtcfg-${host}"
    [ -f "$_tcf" ] || continue
    local url expected_string
    url=$(cut -f1 "$_tcf")
    expected_string=$(cut -f4 "$_tcf")
    _cmp_tgt_category=$(cut -f5 "$_tcf")
    rm -f "$_tcf"

    # Subsection separator between category groups (global/zone/intl)
    tbl_group_sep "${_cmp_tgt_category:-global}"

    _compare_prescan_host "$host" "$_cmp_tgt_category"

    # Reset per-host accumulators
    _cmp_verdict_input=""
    _cmp_json_paths=""
    _cmp_target_all_ok=1
    _cmp_fail_reasons=""
    _cmp_active_reason=""

    cmp_row_start "$host"

    local iface
    for iface in $ifaces; do
      _compare_classify_path "$host" "$iface" "http" "$expected_string"
      _compare_collect_path "$iface"
      _compare_render_cell "$host" "$iface"
    done

    _compare_host_verdict "$host"
  done

  # ── Summary ──
  local _args_mode=0
  [ $# -gt 0 ] && _args_mode=1
  _compare_render_summary "$_args_mode"
}
