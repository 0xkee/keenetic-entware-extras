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

# Load previous compare results from cache file.
# Sets: _prev_cache_data (raw file content)
load_prev_cache() {
  _prev_cache_data=""
  [ -f "$CACHE_FILE" ] || return 0
  _prev_cache_data=$(cat "$CACHE_FILE" 2>/dev/null) || _prev_cache_data=""
}

# Lookup previous verdict for target+iface from cached JSON.
# Args: $1 - target host, $2 - iface name
# stdout: previous verdict or empty
prev_verdict_for() {
  local _target="$1" _iface="$2"
  [ -z "$_prev_cache_data" ] && return 0
  # Parse flat: extract target→dev→verdict from JSON text
  printf '%s' "$_prev_cache_data" | tr '{' '\n' | awk -F'"' -v t="$_target" -v d="$_iface" '
    /"target":/ {
      for (i=1;i<=NF;i++) if ($i=="target") { tgt=$(i+2); break }
    }
    /"dev":/ && /"verdict":/ {
      dev=""; vrd=""
      for (i=1;i<=NF;i++) {
        if ($i=="dev" && dev=="") dev=$(i+2)
        if ($i=="verdict" && vrd=="") { vrd=$(i+2); break }
      }
      if (tgt==t && dev==d) { print vrd; exit }
    }
  '
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

    # Collect verdict input
    verdict_input="${verdict_input}${iface}:${path_ok}:${ttfb_ms}
"

    if [ "$OUTPUT_JSON" = 1 ]; then
      local path_json
      path_json=$(printf '{%s,%s,%s,%s,%s,%s,%s}' \
        "$(json_kv "dev" "$iface")" \
        "$(json_kv "type" "$itype")" \
        "$(json_kv "cc" "$cc")" \
        "$(json_kv_num "http_code" "$http_code")" \
        "$(json_kv_bool "tls_ok" "$([ "$tls_ok" = "true" ] && echo 0 || echo 1)")" \
        "$(json_kv_num "ttfb_ms" "$ttfb_ms")" \
        "$(json_kv "verdict" "$reason")")
      json_arr_add json_paths "$path_json"
    else
      local _st="fail"
      [ "$path_ok" = "ok" ] && _st="ok"
      local _tls_st="fail"
      [ "$tls_ok" = "true" ] && _tls_st="ok"
      tbl_row "$iface" "$cc" \
        "$(tbl_cell 5 "$http_code" "$_st")" \
        "$(tbl_cell 5 "$([ "$_tls_st" = ok ] && printf 'ok' || printf 'FAIL')" "$_tls_st")" \
        "$(tbl_cell 8 "${dns_ms}ms" "$_st")" \
        "$(tbl_cell 8 "${ttfb_ms}ms" "$_st")" \
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
  local targets_file="$_CONFIG_DIR/check-targets.conf"
  if [ ! -f "$targets_file" ]; then
    emit_error "Targets file not found: $targets_file"
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
  done < "$targets_file"

  [ "$OUTPUT_JSON" = 1 ] && printf ']\n'
  return 0
}

# ─── Command: compare (table + diff) ─────────────────────────────────────────

cmd_compare() {
  local targets_file="$_CONFIG_DIR/check-targets.conf"
  if [ $# -eq 0 ] && [ ! -f "$targets_file" ]; then
    emit_error "Targets file not found: $targets_file"
    return 1
  fi

  local ifaces
  ifaces=$(require_wan_ifaces) || return 1

  # Load previous cache for historical diff
  load_prev_cache

  # Load geo-zone context for route verification
  load_zone_context

  # Warm geo cache for accurate CC in comparison table headers
  if [ -z "$_GEO_EXT_IPS" ]; then
    local _saved_exit="$_EXIT_CODE"
    cmd_geo > /dev/null 2>&1 || true
    _EXIT_CODE="$_saved_exit"
  fi

  # Check if we need body content
  local need_body=0
  [ -f "$ANOMALY_MARKERS_FILE" ] && need_body=1

  # Build header
  section_title "$_TITLE_COMPARE"
  if [ "$OUTPUT_JSON" = 0 ] && ! is_quiet; then
    printf 'HTTP reachability across all paths. Detects middlebox anomalies (DPI/SNI), MITM, geo-restrictions.\n\n'
  fi
  cmp_header "Resource" "$ifaces"

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
    # Default: load from check-targets.conf
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
    done < "$targets_file"
  fi

  # ── Phase 2: Batched parallel curls (3 targets at a time to avoid bandwidth contention) ──
  local _batch_n=0 _batch_hosts=""
  for host in $_tgt_hosts; do
    _batch_hosts="${_batch_hosts} ${host}"
    _batch_n=$((_batch_n + 1))
    if [ "$_batch_n" -ge "$PARALLEL_BATCH_SIZE" ]; then
      (
      trap 'kill 0 2>/dev/null; exit 130' INT TERM
      for _bh in $_batch_hosts; do
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
      wait
      )
      _batch_n=0; _batch_hosts=""
    fi
  done
  # Flush remaining batch
  if [ -n "$_batch_hosts" ]; then
    (
    trap 'kill 0 2>/dev/null; exit 130' INT TERM
    for _bh in $_batch_hosts; do
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
    wait
    )
  fi

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
    local _target_all_ok=1 _fail_reasons=""

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
      elif [ -n "$_warning" ]; then
        case "$_fail_reasons" in
          *"$_warning"*) ;;
          "") _fail_reasons="$_warning" ;;
          *) _fail_reasons="${_fail_reasons}, ${_warning}" ;;
        esac
      fi

      verdict_input="${verdict_input}${iface}:${path_ok}:${ttfb_ms}
"

      # Build JSON for cache
      local path_json
      path_json=$(printf '{%s,%s,%s,%s,%s,%s}' \
        "$(json_kv "dev" "$iface")" \
        "$(json_kv "type" "$itype")" \
        "$(json_kv_num "http_code" "$http_code")" \
        "$(json_kv_bool "tls_ok" "$([ "$tls_ok" = "true" ] && echo 0 || echo 1)")" \
        "$(json_kv_num "ttfb_ms" "$ttfb_ms")" \
        "$(json_kv "verdict" "$reason")")
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
        _cell=$(printf '%s %s %s' \
          "$(tbl_cell 3 "$http_code" "$_st")" \
          "$(tbl_cell 5 "$_short_tag" "$_st")" \
          "$_ttfb_part")

        # Append diff marker if present
        if [ "$_diff_mark" = "NEW_FAIL" ]; then
          _cell="${_cell} ${C_RED}▼${C_RST}"
        elif [ "$_diff_mark" = "RECOVERED" ]; then
          _cell="${_cell} ${C_GREEN}▲${C_RST}"
        fi

        cmp_cell "$_cell"
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
      *) _vst="warn" ;;
    esac
    if [ -n "$_ZONE_LABEL" ]; then
      local _resolved_ip _actual_route_dev _expected_rt _actual_rt _route_st
      _resolved_ip=$(_resolve_a_cached "$host" 2>/dev/null) || _resolved_ip=""
      if [ -n "$_resolved_ip" ]; then
        _actual_route_dev=$(route_dev_for_ip "$_resolved_ip")
        _expected_rt=$(expected_route_type "${_tgt_category:-global}")
        if [ "$_expected_rt" != "any" ] && [ -n "$_actual_route_dev" ]; then
          _actual_rt=$(iface_type "$_actual_route_dev")
          if [ "$_actual_rt" = "$_expected_rt" ]; then
            : # route matches expectation — no display noise
          else
            _route_info=$(printf ' %s⚠route:%s(exp %s)%s' "$C_YELLOW" "$_actual_route_dev" "$_expected_rt" "$C_RST")
            [ "$_vst" = "ok" ] && _vst="warn"
          fi
          _route_json=$(printf ',%s,%s,%s' \
            "$(json_kv "route_dev" "$_actual_route_dev")" \
            "$(json_kv "route_type" "$_actual_rt")" \
            "$(json_kv "route_expected" "$_expected_rt")")
        fi
      fi
    fi

    local ok_bool=1
    [ "$verdict" = "all_ok" ] && ok_bool=0
    local result_json
    if [ -n "$_fail_reasons" ]; then
      result_json=$(printf '{%s,%s,%s,"paths":[%s],%s,%s%s}' \
        "$(json_kv_bool "ok" "$ok_bool")" \
        "$(json_kv "target" "$host")" \
        "$(json_kv "category" "${_tgt_category:-global}")" \
        "$json_paths" \
        "$(json_kv "verdict" "$verdict")" \
        "$(json_kv "fail_reason" "$_fail_reasons")" \
        "$_route_json")
    else
      result_json=$(printf '{%s,%s,%s,"paths":[%s],%s%s}' \
        "$(json_kv_bool "ok" "$ok_bool")" \
        "$(json_kv "target" "$host")" \
        "$(json_kv "category" "${_tgt_category:-global}")" \
        "$json_paths" \
        "$(json_kv "verdict" "$verdict")" \
        "$_route_json")
    fi
    json_arr_add json_results "$result_json"

    local _verdict_text
    if [ -n "$_fail_reasons" ]; then
      _verdict_text=$(printf '%s %s(%s)%s%s' "$(color_status "$_vst" "$verdict")" "$C_DIM" "$_fail_reasons" "$C_RST" "$_route_info")
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
