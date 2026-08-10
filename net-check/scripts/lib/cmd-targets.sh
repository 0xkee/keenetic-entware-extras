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
  local iface curl_out curl_exit http_code ssl_verify redirect_url
  local time_connect time_starttfb reason ttfb_ms tls_ok itype
  local need_body=0 body_file="" expected_string=""

  # Check if we need body content (anomaly markers exist)
  [ -f "$ANOMALY_MARKERS_FILE" ] && need_body=1

  section_title "$host — $_TITLE_COMPARE"
  tbl_header "Path:14" "CC:4" "HTTP:5" "TLS:5" "DNS:8" "TTFB:8" "Verdict"

  for iface in $ifaces; do
    curl_exit=0
    if [ "$need_body" = 1 ]; then
      body_file="${_RUN_DIR}/body-single-${iface}"
      curl_out=$(check_target_via_iface "$url" "$iface" "$body_file") || curl_exit=$?
    else
      curl_out=$(check_target_via_iface "$url" "$iface") || curl_exit=$?
    fi

    # Parse curl JSON output
    parse_curl_metrics "$curl_out"
    http_code="$_cm_code"; ssl_verify="$_cm_ssl"; redirect_url="$_cm_redirect"
    time_connect="$_cm_time_connect"; time_starttfb="$_cm_time_starttfb"

    local time_dns=""
    time_dns="$_cm_time_dns"

    ttfb_ms=$(to_ms "$time_starttfb")
    local dns_ms
    dns_ms=$(to_ms "${time_dns:-0}")

    # Classify
    reason=$(classify_failure "$http_code" "$ssl_verify" "$redirect_url" \
      "$curl_exit" "$time_connect" "http" "$body_file" "$expected_string")

    rm -f "$body_file" 2>/dev/null

    if [ "$ssl_verify" = "0" ]; then
      tls_ok="true"
    else
      tls_ok="false"
    fi

    itype=$(iface_type "$iface")
    local cc
    cc=$(geo_cached_cc "$iface")
    [ -z "$cc" ] && cc="—"

    # Determine per-path status
    local path_ok="fail"
    if [ "$reason" = "ok" ]; then
      if [ "$http_code" -ge 200 ] 2>/dev/null && [ "$http_code" -lt 400 ] 2>/dev/null; then
        path_ok="ok"
      elif [ "$http_code" = "403" ]; then
        # 403 + ok reason = WAF/anti-bot, still reachable
        path_ok="ok"
      fi
    fi

    # Collect verdict input (extended format: iface:status:ttfb:reason)
    verdict_input="${verdict_input}${iface}:${path_ok}:${ttfb_ms}:${reason}
"

    if [ "$OUTPUT_JSON" = 1 ]; then
      local path_json _tls_jv="false"
      [ "$tls_ok" = "true" ] && _tls_jv="true"
      path_json=$(printf '{"dev":"%s","type":"%s","cc":"%s","http_code":%s,"tls_ok":%s,"ttfb_ms":%s,"verdict":"%s"}' \
        "$iface" "$itype" "$cc" "$http_code" "$_tls_jv" "$ttfb_ms" "$reason")
      json_arr_add json_paths "$path_json"
    else
      local _st="fail"
      [ "$path_ok" = "ok" ] && _st="ok"
      local _tls_st="fail"
      [ "$tls_ok" = "true" ] && _tls_st="ok"
      local _tls_label="FAIL"
      [ "$_tls_st" = "ok" ] && _tls_label="ok"
      tbl_cell_v 5 "$http_code" "$_st"; local _c1="$_CELL"
      tbl_cell_v 5 "$_tls_label" "$_tls_st"; local _c2="$_CELL"
      tbl_cell_v 8 "${dns_ms}ms" "$_st"; local _c3="$_CELL"
      tbl_cell_v 8 "${ttfb_ms}ms" "$_st"; local _c4="$_CELL"
      tbl_row "$iface" "$cc" "$_c1" "$_c2" "$_c3" "$_c4" \
        "$(color_status "$_st" "$reason")"
    fi
  done

  # Overall verdict
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

  # Update exit code
  case "$verdict" in
    all_ok) ;;
    all_fail) _EXIT_CODE=2 ;;
    *) [ "$_EXIT_CODE" -lt 1 ] && _EXIT_CODE=1 ;;
  esac
}

# ─── Command: domains (HTTP targets from config) ─────────────────────────────

cmd_domains() {
  if [ ! -f "$_CONFIG_DIR/check-targets.conf" ]; then
    emit_error "Targets file not found: check-targets.conf"
    return 1
  fi

  local json_results="" first_result=1
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

  local json_results=""
  local _total_targets=0 _ok_targets=0

  # ── Phase 1: Read all targets into indexed config files ──
  local _tgt_hosts=""
  if [ $# -gt 0 ]; then
    # Deep check mode: use passed domains
    local _ad
    for _ad in "$@"; do
      case "$_ad" in http://*|https://*) ;; *) _ad="https://${_ad}" ;; esac
      local host
      host=$(url_to_host "$_ad")
      _total_targets=$((_total_targets + 1))
      # Store target config for phase 2+3 (5 fields: url, host, need_body, expected, category)
      printf '%s\t%s\t%s\t%s\t%s\n' "$_ad" "$host" "$need_body" "" "check" \
        > "${_RUN_DIR}/tgtcfg-${host}"
      _tgt_hosts="${_tgt_hosts} ${host}"
    done
  else
    # Default: load from check-targets.conf (zone-filtered by _cat_config)
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
      _total_targets=$((_total_targets + 1))
      expected_string=$(printf '%s' "${expected_string:-}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      local target_need_body="$need_body"
      [ -n "$expected_string" ] && target_need_body=1
      # Store target config for phase 2+3 (5 fields: url, host, need_body, expected, category)
      printf '%s\t%s\t%s\t%s\t%s\n' "$url" "$host" "$target_need_body" "$expected_string" "${_category:-global}" \
        > "${_RUN_DIR}/tgtcfg-${host}"
      _tgt_hosts="${_tgt_hosts} ${host}"
    done <<EOF
$(_cat_config check-targets)
EOF
  fi

  # Auto-width first column
  local _label_w
  _label_w=$(auto_label_width "$_tgt_hosts")
  cmp_header "Resource" "$ifaces" "" "$_label_w"

  # ── Phase 2: Batched parallel curls ──
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
  batch_run_parallel "HTTP" "$PARALLEL_BATCH_SIZE" "$_tgt_hosts" _compare_run_batch

  # ── Phase 3: Collect results and render table (in original target order) ──
  tbl_group_reset
  for host in $_tgt_hosts; do
    local _tcf="${_RUN_DIR}/tgtcfg-${host}"
    [ -f "$_tcf" ] || continue
    local url check_type expected_string _tgt_category
    url=$(cut -f1 "$_tcf")
    expected_string=$(cut -f4 "$_tcf")
    _tgt_category=$(cut -f5 "$_tcf")
    check_type="http"
    rm -f "$_tcf"

    # Subsection separator between category groups (global/zone/intl)
    tbl_group_sep "${_tgt_category:-global}"

    local verdict_input="" json_paths=""
    local _target_all_ok=1 _fail_reasons="" _active_reason=""

    # Determine active route device for this domain (for cell marker).
    # Uses category-aware logic: zone resources → geo-split dev,
    # non-geo → enumerated VPN segments (falling back to kernel FIB).
    local _active_route_dev=""
    local _resolved_ip=""
    _resolved_ip=$(_resolve_a_cached "$host" 2>/dev/null) || _resolved_ip=""
    _active_route_dev=$(active_dev_for_target "$_resolved_ip" "${_tgt_category:-}")

    # Pre-scan: pick recommended iface (best OK path by TTFB)
    local _recommended_dev="" _rec_best_ttfb=999999 _rec_ok_n=0 _ri
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
      _rec_ok_n=$((_rec_ok_n + 1))
      _r_ttfb_raw=$(printf '%s' "$_r_out" | sed -n 's/.*"time_starttfb":\([0-9.]*\).*/\1/p')
      _r_ttfb_ms=$(to_ms "${_r_ttfb_raw:-0}")
      if [ "$_r_ttfb_ms" -lt "$_rec_best_ttfb" ]; then
        _rec_best_ttfb="$_r_ttfb_ms"
        _recommended_dev="$_ri"
      fi
    done
    # No ★ when single iface (no choice to show)
    local _n_ifc
    _n_ifc=$(printf '%s' "$ifaces" | wc -w | tr -d ' ')
    [ "$_n_ifc" -le 1 ] && _recommended_dev=""

    cmp_row_start "$host"

    for iface in $ifaces; do
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
      local http_code="$_cm_code" ssl_verify="$_cm_ssl" redirect_url="$_cm_redirect"
      local time_connect="$_cm_time_connect" time_starttfb="$_cm_time_starttfb"

      local ttfb_ms reason tls_ok itype path_ok
      ttfb_ms=$(to_ms "$time_starttfb")
      reason=$(classify_failure "$http_code" "$ssl_verify" "${redirect_url:-}" \
        "$curl_exit" "$time_connect" "${check_type:-http}" "$body_file" "$expected_string")

      # Many-redirect warning: ok but >3 hops
      local _warning=""
      if [ "$reason" = "ok" ] && [ "${_cm_num_redirects:-0}" -gt "$MAX_REDIRECT_WARN" ] 2>/dev/null; then
        _warning="Many redirects"
      fi

      # Clean up body file
      [ -n "$body_file" ] && rm -f "$body_file" 2>/dev/null

      if [ "$ssl_verify" = "0" ]; then tls_ok="true"; else tls_ok="false"; fi
      itype=$(iface_type "$iface")

      path_ok="fail"
      if [ "$reason" = "ok" ]; then
        if [ "$http_code" -ge 200 ] 2>/dev/null && [ "$http_code" -lt 400 ] 2>/dev/null; then
          path_ok="ok"
        elif [ "$http_code" = "403" ]; then
          # 403 + ok reason = WAF/anti-bot, still reachable
          path_ok="ok"
        fi
      fi

      [ "$path_ok" != "ok" ] && _target_all_ok=0

      # Collect unique failure/warning reasons for display
      if [ "$path_ok" != "ok" ] && [ "$reason" != "ok" ]; then
        case "$_fail_reasons" in
          *"$reason"*) ;;
          "") _fail_reasons="$reason" ;;
          *) _fail_reasons="${_fail_reasons}, ${reason}" ;;
        esac
        # Track active route failure for ► marker in verdict
        [ "$iface" = "$_active_route_dev" ] && _active_reason="$reason"
      elif [ -n "$_warning" ]; then
        case "$_fail_reasons" in
          *"$_warning"*) ;;
          "") _fail_reasons="$_warning" ;;
          *) _fail_reasons="${_fail_reasons}, ${_warning}" ;;
        esac
        [ "$iface" = "$_active_route_dev" ] && _active_reason="$_warning"
      fi

      verdict_input="${verdict_input}${iface}:${path_ok}:${ttfb_ms}:${reason}
"

      # Build JSON for cache (inline printf, 0 forks)
      local path_json _tls_jv="false"
      [ "$tls_ok" = "true" ] && _tls_jv="true"
      path_json=$(printf '{"dev":"%s","type":"%s","http_code":%s,"tls_ok":%s,"ttfb_ms":%s,"verdict":"%s"}' \
        "$iface" "$itype" "$http_code" "$_tls_jv" "$ttfb_ms" "$reason")
      json_arr_add json_paths "$path_json"

      if [ "$OUTPUT_JSON" = 0 ] && ! is_quiet; then
        local _st="fail"
        [ "$path_ok" = "ok" ] && _st="ok"
        # Override display for warnings (path still ok for verdict)
        if [ "$path_ok" = "ok" ] && [ -n "$_warning" ]; then
          _st="warn"
        fi

        # Historical diff marker (computed first to reserve column space)
        local _diff_mark=""
        local _prev_v=""
        _prev_v=$(prev_verdict_for "$host" "$iface")
        if [ -n "$_prev_v" ]; then
          _diff_mark=$(diff_marker "$reason" "$_prev_v")
        fi

        # Reserve 2 chars for diff marker so ▲/▼ don't shift columns
        local _diff_extra=0
        [ -n "$_diff_mark" ] && _diff_extra=2

        local _cell="" _short_tag _ttfb_part
        _short_tag=$(short_reason "$reason")
        if [ -n "$_warning" ]; then
          _short_tag="REDIR"
        fi
        if [ "$_st" != "ok" ] && [ "$ttfb_ms" = "0" ]; then
          # em-dash is 3 bytes UTF-8 but 1 visual char; +2 compensates
          _ttfb_part=$(printf '%*s' "$((_CMP_COL_W - 8 - _diff_extra))" "—")
        else
          _ttfb_part=$(printf '%*sms' "$((_CMP_COL_W - 12 - _diff_extra))" "$ttfb_ms")
        fi
        tbl_cell_v 3 "$http_code" "$_st"; local _c1="$_CELL"
        tbl_cell_v 5 "$_short_tag" "$_st"; local _c2="$_CELL"
        _cell=$(printf '%s %s %s' "$_c1" "$_c2" "$_ttfb_part")

        # Append diff marker if present
        if [ "$_diff_mark" = "NEW_FAIL" ]; then
          _cell="${_cell} ${C_RED}▼${C_RST}"
        elif [ "$_diff_mark" = "RECOVERED" ]; then
          _cell="${_cell} ${C_GREEN}▲${C_RST}"
        fi

        local _is_active=0 _is_recommended=0
        [ "$iface" = "$_active_route_dev" ] && _is_active=1
        [ "$iface" = "$_recommended_dev" ] && _is_recommended=1
        cmp_cell "$_cell" "$_is_active" "$_is_recommended"
      fi
    done

    local verdict
    verdict=$(printf '%s' "$verdict_input" | determine_verdict)

    [ "$_target_all_ok" = 1 ] && _ok_targets=$((_ok_targets + 1))

    # Route verification: check where LAN traffic actually goes for this target
    local _route_info="" _route_json=""
    local _vst="ok"
    case "$verdict" in
      all_ok) _vst="ok" ;;
      all_fail) _vst="fail" ;;
      cert_issue|dns_issue|server_down) _vst="warn" ;;
      *) _vst="warn" ;;
    esac
    if [ -n "$_ZONE_LABEL" ] && [ -n "$_resolved_ip" ] && [ -n "$_active_route_dev" ]; then
      local _expected_rt _actual_rt
      _expected_rt=$(expected_route_type "${_tgt_category:-global}")
      if [ "$_expected_rt" != "any" ]; then
        _actual_rt=$(iface_type "$_active_route_dev")
        if [ "$_actual_rt" = "$_expected_rt" ]; then
          : # route matches expectation — no display noise
        else
          _route_info=$(printf ' %s⚠route:%s(exp %s)%s' "$C_YELLOW" "$_active_route_dev" "$_expected_rt" "$C_RST")
          [ "$_vst" = "ok" ] && _vst="warn"
        fi
        _route_json=$(printf ',"route_dev":"%s","route_type":"%s","route_expected":"%s"' \
          "$_active_route_dev" "$_actual_rt" "$_expected_rt")
      fi
    fi

    local ok_bool=1
    [ "$verdict" = "all_ok" ] && ok_bool=0
    local result_json _ok_jv="false"
    [ "$ok_bool" = 0 ] && _ok_jv="true"
    if [ -n "$_fail_reasons" ]; then
      result_json=$(printf '{"ok":%s,"target":"%s","category":"%s","paths":[%s],"verdict":"%s","fail_reason":"%s"%s}' \
        "$_ok_jv" "$host" "${_tgt_category:-global}" \
        "$json_paths" "$verdict" "$_fail_reasons" "$_route_json")
    else
      result_json=$(printf '{"ok":%s,"target":"%s","category":"%s","paths":[%s],"verdict":"%s"%s}' \
        "$_ok_jv" "$host" "${_tgt_category:-global}" \
        "$json_paths" "$verdict" "$_route_json")
    fi
    json_arr_add json_results "$result_json"

    local _verdict_text
    if [ -n "$_fail_reasons" ]; then
      # Prefix active route's failure reason with grey ► in display
      local _display_reasons="$_fail_reasons"
      if [ -n "$_active_reason" ]; then
        local _before="${_display_reasons%%"$_active_reason"*}"
        local _after="${_display_reasons#*"$_active_reason"}"
        _display_reasons="${_before}► ${_active_reason}${_after}"
      fi
      _verdict_text=$(printf '%s %s(%s)%s%s' "$(color_status "$_vst" "$verdict")" "$C_DIM" "$_display_reasons" "$C_RST" "$_route_info")
    else
      _verdict_text=$(printf '%s%s' "$(color_status "$_vst" "$verdict")" "$_route_info")
    fi
    cmp_row_end "$_verdict_text"
  done

  # Save results to cache for status.sh (only for config-based runs)
  if [ $# -eq 0 ]; then
    printf '[%s]\n' "$json_results" > "${CACHE_FILE}.$$"
    mv -f "${CACHE_FILE}.$$" "$CACHE_FILE" 2>/dev/null || true
  fi

  if [ "$OUTPUT_JSON" = 1 ]; then
    if [ $# -eq 0 ] && [ -f "$CACHE_FILE" ]; then
      cat "$CACHE_FILE"
    else
      printf '[%s]\n' "$json_results"
    fi
  else
    if is_quiet; then
      printf 'compare: %s/%s targets all_ok\n' "$_ok_targets" "$_total_targets"
    else
      summary_line "$_ok_targets" "$_total_targets" "targets"
    fi
  fi

  update_exit_code "$_ok_targets" "$_total_targets"
}
