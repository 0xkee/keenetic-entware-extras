# net-check: TCP/TLS connectivity test (Level A) + packet loss + MTU discovery.
# Dependencies: lib/output.sh (emit_error, color_status, status_mark, summary_line, is_quiet, is_verbose),
#   lib/wan.sh (get_wan_interfaces, iface_type, geo_cached_cc),
#   lib/http-core.sh (to_ms), lib/common.sh (json_kv, json_kv_bool, json_kv_num)
# Globals used: OUTPUT_JSON, VERBOSITY, _EXIT_CODE,
#   CONNECT_TIMEOUT, HTTP_TIMEOUT, CURL_UA, DATA_DIR,
#   CONNECTIVITY_URL, TRACEROUTE_MAX_HOPS, PING_COUNT,
#   C_GREEN, C_RED, C_YELLOW, C_DIM, C_RST, C_BOLD, C_CYAN
# shellcheck disable=SC3043

# ─── Command: connectivity (Level A — TCP connect, TLS, latency, loss, MTU) ──

cmd_connectivity() {
  local ifaces
  ifaces=$(require_wan_ifaces) || return 1

  # Load geo-zone context for zone header
  load_zone_context

  # Ensure geo cache is populated for CC column
  ensure_geo_cache

  local json_results=""
  local has_traceroute=0 has_ping=0
  local _ok_count=0 _total_count=0
  command -v traceroute >/dev/null 2>&1 && has_traceroute=1
  command -v ping >/dev/null 2>&1 && has_ping=1

  section_title "$_TITLE_CONN"
  if [ "$OUTPUT_JSON" = 0 ] && ! is_quiet; then
    printf 'TCP connect + TLS handshake timing per WAN path. Detects unreachable paths.\n'
    printf 'Target: %s%s%s\n\n' "$C_DIM" "$CONNECTIVITY_URL" "$C_RST"
  fi
  if [ "$has_traceroute" = 1 ]; then
    tbl_header "Path:14" "CC:4" "Hops:5" "MTU (OH, Enc):19" "DNS ms:9" "TCP ms:9" "TLS ms:9" "Total ms:9" "Loss:8" "Jit ms:7" "Status"
  else
    tbl_header "Path:14" "CC:4" "MTU (OH, Enc):19" "DNS ms:9" "TCP ms:9" "TLS ms:9" "Total ms:9" "Loss:8" "Jit ms:7" "Status"
  fi

  # Pre-warm SmartDNS cache: resolve connectivity host once before parallel curls.
  # This ensures all 5 parallel curls hit warm DNS cache (1-2ms) instead of queuing.
  local _conn_url="$CONNECTIVITY_URL"
  local _conn_host
  _conn_host=$(url_to_host "$_conn_url")
  dig +short "$_conn_host" A +time=2 +tries=1 >/dev/null 2>&1 || true

  # ── Phase 1: Parallel curl per interface (DNS hits warm cache) ──
  (
  trap 'kill 0 2>/dev/null; exit 130' INT TERM
  for iface in $ifaces; do
    (
      _reach="fail"; _tcp_ms="—"; _tls_ms="—"; _total_ms="—"
      _dns_t="0"; _itype=$(iface_type "$iface")
      _curl_fmt='%{time_namelookup} %{time_connect} %{time_appconnect} %{time_starttransfer} %{time_total} %{http_code}'
      _curl_out=$(curl -sS --interface "$iface" \
        --connect-timeout "$CONNECT_TIMEOUT" --max-time "$HTTP_TIMEOUT" \
        -o /dev/null -w "$_curl_fmt" \
        -H "User-Agent: $CURL_UA" \
        "$_conn_url" 2>/dev/null) || _curl_out=""
      if [ -n "$_curl_out" ]; then
        _dns_t=$(printf '%s' "$_curl_out" | awk '{print $1}')
        _conn_t=$(printf '%s' "$_curl_out" | awk '{print $2}')
        _app_t=$(printf '%s' "$_curl_out" | awk '{print $3}')
        _tot_t=$(printf '%s' "$_curl_out" | awk '{print $5}')
        _hc=$(printf '%s' "$_curl_out" | awk '{print $6}')
        if [ "$_hc" = "204" ] || [ "$_hc" = "200" ]; then
          _reach="ok"; _tcp_ms=$(to_ms "$_conn_t"); _tls_ms=$(to_ms "$_app_t"); _total_ms=$(to_ms "$_tot_t")
        fi
      fi
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$_reach" "$_tcp_ms" "$_tls_ms" "$_total_ms" "$_itype" "$_dns_t" \
        > "${_RUN_DIR}/conn-curl-${iface}"
    ) &
  done
  wait
  )

  # ── Phase 2: All probes in parallel (traceroute + ping-loss + MTU × all reachable ifaces) ──
  (
  trap 'kill 0 2>/dev/null; exit 130' INT TERM
  for iface in $ifaces; do
    # Only probe reachable interfaces
    _cf="${_RUN_DIR}/conn-curl-${iface}"
    [ -f "$_cf" ] || continue
    _r=$(cut -f1 "$_cf")
    [ "$_r" != "ok" ] && continue

    # Traceroute (1 probe per hop for speed)
    if [ "$has_traceroute" = 1 ]; then
      ( _tr=$(traceroute -i "$iface" -n -q 1 -m "$TRACEROUTE_MAX_HOPS" -w "$PROBE_TIMEOUT" "$CONNECTIVITY_TARGET" 2>/dev/null | \
          tail -1 | awk '{print $1}') || _tr=""
        printf '%s' "${_tr:-—}" > "${_RUN_DIR}/conn-tr-${iface}"
      ) &
    fi

    # Packet loss / jitter (ping -c 5)
    if [ "$has_ping" = 1 ]; then
      ( _po=$(ping -c "$PING_COUNT" -W "$PROBE_TIMEOUT" -I "$iface" "$CONNECTIVITY_TARGET" 2>/dev/null) || _po=""
        _pl="—"; _pj="—"
        if [ -n "$_po" ]; then
          _pl=$(printf '%s' "$_po" | sed -n 's/.* \([0-9]*\)% packet loss.*/\1%/p')
          _pj=$(printf '%s' "$_po" | sed -n 's|.*/\([0-9.]*\) ms|\1|p')
        fi
        printf '%s\t%s' "${_pl:-—}" "${_pj:-—}" > "${_RUN_DIR}/conn-pl-${iface}"
      ) &
    fi

    # MTU discovery (fast-path typical values + binary search)
    if [ "$has_ping" = 1 ]; then
      ( _mt="—"
        if ping -M "do" -s 1472 -c 1 -W "$PROBE_TIMEOUT" -I "$iface" "$CONNECTIVITY_TARGET" >/dev/null 2>&1; then
          _mt="1500"
        elif ! ping -M "do" -s 548 -c 1 -W "$PROBE_TIMEOUT" -I "$iface" "$CONNECTIVITY_TARGET" >/dev/null 2>&1; then
          _mt="—"
        elif ping -M "do" -s 1392 -c 1 -W "$PROBE_TIMEOUT" -I "$iface" "$CONNECTIVITY_TARGET" >/dev/null 2>&1; then
          _lo=1392; _hi=1472
          while [ $((_hi - _lo)) -gt 1 ]; do _mid=$(( (_lo + _hi) / 2 ))
            if ping -M "do" -s "$_mid" -c 1 -W "$PROBE_TIMEOUT" -I "$iface" "$CONNECTIVITY_TARGET" >/dev/null 2>&1; then _lo="$_mid"; else _hi="$_mid"; fi
          done; _mt=$((_lo + 28))
        elif ping -M "do" -s 1352 -c 1 -W "$PROBE_TIMEOUT" -I "$iface" "$CONNECTIVITY_TARGET" >/dev/null 2>&1; then
          _lo=1352; _hi=1392
          while [ $((_hi - _lo)) -gt 1 ]; do _mid=$(( (_lo + _hi) / 2 ))
            if ping -M "do" -s "$_mid" -c 1 -W "$PROBE_TIMEOUT" -I "$iface" "$CONNECTIVITY_TARGET" >/dev/null 2>&1; then _lo="$_mid"; else _hi="$_mid"; fi
          done; _mt=$((_lo + 28))
        else
          _lo=548; _hi=1352
          while [ $((_hi - _lo)) -gt 1 ]; do _mid=$(( (_lo + _hi) / 2 ))
            if ping -M "do" -s "$_mid" -c 1 -W "$PROBE_TIMEOUT" -I "$iface" "$CONNECTIVITY_TARGET" >/dev/null 2>&1; then _lo="$_mid"; else _hi="$_mid"; fi
          done; _mt=$((_lo + 28))
        fi
        printf '%s' "$_mt" > "${_RUN_DIR}/conn-mt-${iface}"
      ) &
    fi
  done
  wait
  )

  # ── Merge curl timing + probe results into final result files ──
  for iface in $ifaces; do
    local _cf="${_RUN_DIR}/conn-curl-${iface}"
    [ -f "$_cf" ] || continue
    local _reach _tcp_ms _tls_ms _total_ms _itype _dns_t _hops="—" _loss="—" _jitter="—" _mtu="—"
    _reach=$(cut -f1 "$_cf"); _tcp_ms=$(cut -f2 "$_cf"); _tls_ms=$(cut -f3 "$_cf")
    _total_ms=$(cut -f4 "$_cf"); _itype=$(cut -f5 "$_cf"); _dns_t=$(cut -f6 "$_cf")
    rm -f "$_cf"
    [ -f "${_RUN_DIR}/conn-tr-${iface}" ] && { _hops=$(cat "${_RUN_DIR}/conn-tr-${iface}"); rm -f "${_RUN_DIR}/conn-tr-${iface}"; }
    if [ -f "${_RUN_DIR}/conn-pl-${iface}" ]; then
      _loss=$(cut -f1 "${_RUN_DIR}/conn-pl-${iface}"); _jitter=$(cut -f2 "${_RUN_DIR}/conn-pl-${iface}")
      rm -f "${_RUN_DIR}/conn-pl-${iface}"
    fi
    [ -f "${_RUN_DIR}/conn-mt-${iface}" ] && { _mtu=$(cat "${_RUN_DIR}/conn-mt-${iface}"); rm -f "${_RUN_DIR}/conn-mt-${iface}"; }
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$_reach" "$_tcp_ms" "$_tls_ms" "$_total_ms" "$_hops" "$_loss" "$_jitter" "$_mtu" "$_itype" "$_dns_t" \
      > "${_RUN_DIR}/conn-${iface}"
  done

  # Collect parallel results (in iface order for stable output)
  for iface in $ifaces; do
    local _par_f="${_RUN_DIR}/conn-${iface}"
    local reach="fail" tcp_ms="—" tls_ms="—" total_ms="—" hops="—"
    local loss="—" jitter="—" mtu="—" itype="" dns_t="0"
    local cc=""
    cc=$(geo_cached_cc "$iface")
    [ -z "$cc" ] && cc="—"
    _total_count=$((_total_count + 1))

    if [ -f "$_par_f" ]; then
      reach=$(cut -f1 "$_par_f")
      tcp_ms=$(cut -f2 "$_par_f")
      tls_ms=$(cut -f3 "$_par_f")
      total_ms=$(cut -f4 "$_par_f")
      hops=$(cut -f5 "$_par_f")
      loss=$(cut -f6 "$_par_f")
      jitter=$(cut -f7 "$_par_f")
      mtu=$(cut -f8 "$_par_f")
      itype=$(cut -f9 "$_par_f")
      dns_t=$(cut -f10 "$_par_f")
      rm -f "$_par_f"
    fi

    [ "$reach" = "ok" ] && _ok_count=$((_ok_count + 1))

    # Compute MTU overhead and estimated encapsulation layers.
    # Overhead = 1500 - measured_mtu (bytes consumed by encapsulation headers).
    # ~Encap = floor(overhead / 60): rough estimate based on avg tunnel overhead.
    # Only meaningful for tunnel interfaces; ISP MTU < 1500 is usually PPPoE/CGNAT.
    local mtu_overhead="—" encap_layers="—" mtu_hint=""
    if [ "$mtu" != "—" ] && [ "$mtu" != "1500" ]; then
      mtu_overhead=$((1500 - mtu))
      encap_layers=$((mtu_overhead / 60))
      if [ "$itype" = "tunnel" ]; then
        mtu_hint=" (+${mtu_overhead}b, ~${encap_layers})"
      fi
    fi

    if [ "$OUTPUT_JSON" = 1 ]; then
      local entry_json
      entry_json=$(printf '{%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s}' \
        "$(json_kv "dev" "$iface")" \
        "$(json_kv "type" "$itype")" \
        "$(json_kv "cc" "$cc")" \
        "$(json_kv "reach" "$reach")" \
        "$(json_kv "tcp_ms" "$tcp_ms")" \
        "$(json_kv "tls_ms" "$tls_ms")" \
        "$(json_kv "total_ms" "$total_ms")" \
        "$(json_kv "hops" "$hops")" \
        "$(json_kv "loss" "$loss")" \
        "$(json_kv "jitter" "$jitter")" \
        "$(json_kv "mtu" "$mtu")" \
        "$(json_kv "mtu_overhead" "$mtu_overhead")" \
        "$(json_kv "encap_layers" "$encap_layers")")
      json_arr_add json_results "$entry_json"
    elif is_quiet; then
      : # skip rows
    else
      local _st="fail" dns_ms="—"
      [ "$reach" = "ok" ] && _st="ok"
      [ "$reach" = "ok" ] && dns_ms=$(to_ms "$dns_t")
      # Determine loss/MTU color status
      local _loss_st="" _mtu_st=""
      case "$loss" in
        0%|—) _loss_st="ok" ;;
        [1-9]%|1[0-9]%|20%) _loss_st="warn" ;;
        *) _loss_st="fail" ;;
      esac
      case "$mtu" in
        1500) _mtu_st="ok" ;;
        —)    _mtu_st="" ;;
        *)    _mtu_st="warn" ;;
      esac
      # Jitter color status
      local _jit_st=""
      case "$jitter" in
        —)                              _jit_st="" ;;
        [0-9]|[0-9].[0-9]*)            _jit_st="ok" ;;
        [1-9][0-9]|[1-9][0-9].[0-9]*)  _jit_st="warn" ;;
        *)                              _jit_st="warn" ;;
      esac

      local _mtu_display="${mtu}${mtu_hint}"
      if [ "$has_traceroute" = 1 ]; then
        tbl_row "$iface" "$cc" \
          "$hops" "$(tbl_cell 19 "$_mtu_display" "$_mtu_st")" \
          "$(tbl_cell 9 "$dns_ms" "$_st")" \
          "$(tbl_cell 9 "$tcp_ms" "$_st")" \
          "$(tbl_cell 9 "$tls_ms" "$_st")" \
          "$(tbl_cell 9 "$total_ms" "$_st")" \
          "$(tbl_cell 8 "$loss" "$_loss_st")" \
          "$(tbl_cell 7 "$jitter" "$_jit_st")" \
          "$(status_mark "$_st")"
      else
        tbl_row "$iface" "$cc" \
          "$(tbl_cell 19 "$_mtu_display" "$_mtu_st")" \
          "$(tbl_cell 9 "$dns_ms" "$_st")" \
          "$(tbl_cell 9 "$tcp_ms" "$_st")" \
          "$(tbl_cell 9 "$tls_ms" "$_st")" \
          "$(tbl_cell 9 "$total_ms" "$_st")" \
          "$(tbl_cell 8 "$loss" "$_loss_st")" \
          "$(tbl_cell 7 "$jitter" "$_jit_st")" \
          "$(status_mark "$_st")"
      fi
    fi
  done

  if [ "$OUTPUT_JSON" = 1 ]; then
    printf '{%s,"results":[%s]}\n' \
      "$(json_kv_bool "ok" 0)" \
      "$json_results"
  else
    if is_quiet; then
      printf 'connectivity: %s/%s paths reachable\n' "$_ok_count" "$_total_count"
    else
      summary_line "$_ok_count" "$_total_count" "paths"
    fi
  fi

  update_exit_code "$_ok_count" "$_total_count"
}
