# net-check: TCP/TLS connectivity test (Level A) + packet loss + MTU discovery.
# Dependencies: lib/output.sh (emit_error, color_status, status_mark, summary_line, is_quiet, is_verbose),
#   lib/wan.sh (get_wan_interfaces, iface_type, geo_cached_cc),
#   lib/http-core.sh (to_ms), lib/common.sh (json_kv, json_kv_bool, json_kv_num)
# Globals used: OUTPUT_JSON, VERBOSITY, _EXIT_CODE,
#   CONNECT_TIMEOUT, HTTP_TIMEOUT, CURL_UA, DATA_DIR,
#   CONNECTIVITY_URL, TRACEROUTE_MAX_HOPS, PING_COUNT,
#   C_GREEN, C_RED, C_YELLOW, C_DIM, C_RST, C_BOLD, C_CYAN
# shellcheck disable=SC3043

# ─── Connectivity Helpers ─────────────────────────────────────────────────────

# Phase 1: Parallel curl per interface — TCP connect, TLS, latency timing.
# Uses: ifaces, CONNECTIVITY_URL, CONNECT_TIMEOUT, HTTP_TIMEOUT, CURL_UA (from caller scope)
# Creates: _RUN_DIR/conn-curl-* files
_conn_phase1_curl() {
  (
  trap 'kill 0 2>/dev/null; exit 130' INT TERM
  local _conn_url="$CONNECTIVITY_URL"
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
}

# Phase 2: Parallel probes — traceroute, ping loss/jitter, MTU discovery.
# Only probes reachable interfaces (from Phase 1 results).
# Uses: ifaces, has_traceroute, has_ping, TRACEROUTE_MAX_HOPS, PROBE_TIMEOUT,
#       PING_COUNT, CONNECTIVITY_TARGET (from caller scope)
# Creates: _RUN_DIR/conn-tr-*, conn-pl-*, conn-mt-* files
_conn_phase2_probes() {
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

    # Packet loss / jitter (ping -c N)
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
}

# Merge curl timing + probe results into final result files.
# Uses: ifaces (from caller scope)
# Creates: _RUN_DIR/conn-* files (merged)
_conn_merge_results() {
  local iface
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
}

# Read merged result file for one interface + compute MTU hint.
# Args: $1 - iface
# Sets: _ci_reach, _ci_tcp_ms, _ci_tls_ms, _ci_total_ms, _ci_hops,
#       _ci_loss, _ci_jitter, _ci_mtu, _ci_itype, _ci_dns_t, _ci_cc,
#       _ci_mtu_hint
_conn_classify_iface() {
  local iface="$1"
  local _par_f="${_RUN_DIR}/conn-${iface}"

  _ci_reach="fail"; _ci_tcp_ms="—"; _ci_tls_ms="—"; _ci_total_ms="—"
  _ci_hops="—"; _ci_loss="—"; _ci_jitter="—"; _ci_mtu="—"
  _ci_itype=""; _ci_dns_t="0"; _ci_mtu_hint=""

  _ci_cc=$(geo_cached_cc "$iface")
  [ -z "$_ci_cc" ] && _ci_cc="—"

  if [ -f "$_par_f" ]; then
    _ci_reach=$(cut -f1 "$_par_f")
    _ci_tcp_ms=$(cut -f2 "$_par_f")
    _ci_tls_ms=$(cut -f3 "$_par_f")
    _ci_total_ms=$(cut -f4 "$_par_f")
    _ci_hops=$(cut -f5 "$_par_f")
    _ci_loss=$(cut -f6 "$_par_f")
    _ci_jitter=$(cut -f7 "$_par_f")
    _ci_mtu=$(cut -f8 "$_par_f")
    _ci_itype=$(cut -f9 "$_par_f")
    _ci_dns_t=$(cut -f10 "$_par_f")
    rm -f "$_par_f"
  fi

  # Compute MTU overhead and estimated encapsulation layers
  _ci_mtu_hint=""
  if [ "$_ci_mtu" != "—" ] && [ "$_ci_mtu" != "1500" ]; then
    local mtu_overhead encap_layers
    mtu_overhead=$((1500 - _ci_mtu))
    encap_layers=$((mtu_overhead / 60))
    if [ "$_ci_itype" = "tunnel" ]; then
      _ci_mtu_hint=" (+${mtu_overhead}b, ~${encap_layers})"
    fi
  fi
}

# Render one interface result (JSON, quiet, or text table row).
# Args: $1 - iface
# Uses: _ci_*, has_traceroute, _conn_json_results
_conn_render_iface() {
  local iface="$1"

  if [ "$OUTPUT_JSON" = 1 ]; then
    local mtu_overhead="—" encap_layers="—"
    if [ "$_ci_mtu" != "—" ] && [ "$_ci_mtu" != "1500" ]; then
      mtu_overhead=$((1500 - _ci_mtu))
      encap_layers=$((mtu_overhead / 60))
    fi
    local entry_json
    entry_json=$(printf '{%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s}' \
      "$(json_kv "dev" "$iface")" \
      "$(json_kv "type" "$_ci_itype")" \
      "$(json_kv "cc" "$_ci_cc")" \
      "$(json_kv "reach" "$_ci_reach")" \
      "$(json_kv "tcp_ms" "$_ci_tcp_ms")" \
      "$(json_kv "tls_ms" "$_ci_tls_ms")" \
      "$(json_kv "total_ms" "$_ci_total_ms")" \
      "$(json_kv "hops" "$_ci_hops")" \
      "$(json_kv "loss" "$_ci_loss")" \
      "$(json_kv "jitter" "$_ci_jitter")" \
      "$(json_kv "mtu" "$_ci_mtu")" \
      "$(json_kv "mtu_overhead" "$mtu_overhead")" \
      "$(json_kv "encap_layers" "$encap_layers")")
    json_arr_add _conn_json_results "$entry_json"
    return 0
  fi

  is_quiet && return 0

  local _st="fail" dns_ms="—"
  [ "$_ci_reach" = "ok" ] && _st="ok"
  [ "$_ci_reach" = "ok" ] && dns_ms=$(to_ms "$_ci_dns_t")

  # Determine loss/MTU/jitter color status
  local _loss_st="" _mtu_st="" _jit_st=""
  case "$_ci_loss" in
    0%|—) _loss_st="ok" ;;
    [1-9]%|1[0-9]%|20%) _loss_st="warn" ;;
    *) _loss_st="fail" ;;
  esac
  case "$_ci_mtu" in
    1500) _mtu_st="ok" ;;
    —)    _mtu_st="" ;;
    *)    _mtu_st="warn" ;;
  esac
  case "$_ci_jitter" in
    —)                              _jit_st="" ;;
    [0-9]|[0-9].[0-9]*)            _jit_st="ok" ;;
    [1-9][0-9]|[1-9][0-9].[0-9]*)  _jit_st="warn" ;;
    *)                              _jit_st="warn" ;;
  esac

  local _mtu_display="${_ci_mtu}${_ci_mtu_hint}"
  if [ "$has_traceroute" = 1 ]; then
    tbl_row "$iface" "$_ci_cc" \
      "$_ci_hops" "$(tbl_cell 19 "$_mtu_display" "$_mtu_st")" \
      "$(tbl_cell 9 "$dns_ms" "$_st")" \
      "$(tbl_cell 9 "$_ci_tcp_ms" "$_st")" \
      "$(tbl_cell 9 "$_ci_tls_ms" "$_st")" \
      "$(tbl_cell 9 "$_ci_total_ms" "$_st")" \
      "$(tbl_cell 8 "$_ci_loss" "$_loss_st")" \
      "$(tbl_cell 7 "$_ci_jitter" "$_jit_st")" \
      "$(status_mark "$_st")"
  else
    tbl_row "$iface" "$_ci_cc" \
      "$(tbl_cell 19 "$_mtu_display" "$_mtu_st")" \
      "$(tbl_cell 9 "$dns_ms" "$_st")" \
      "$(tbl_cell 9 "$_ci_tcp_ms" "$_st")" \
      "$(tbl_cell 9 "$_ci_tls_ms" "$_st")" \
      "$(tbl_cell 9 "$_ci_total_ms" "$_st")" \
      "$(tbl_cell 8 "$_ci_loss" "$_loss_st")" \
      "$(tbl_cell 7 "$_ci_jitter" "$_jit_st")" \
      "$(status_mark "$_st")"
  fi
}

# ─── Command: connectivity (Level A — TCP connect, TLS, latency, loss, MTU) ──

cmd_connectivity() {
  local ifaces
  ifaces=$(require_wan_ifaces) || return 1

  # Load geo-zone context for zone header
  load_zone_context

  # Ensure geo cache is populated for CC column
  ensure_geo_cache

  local _conn_json_results=""
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

  # Pre-warm SmartDNS cache: resolve connectivity host once before parallel curls
  local _conn_host
  _conn_host=$(url_to_host "$CONNECTIVITY_URL")
  dig +short "$_conn_host" A +time=2 +tries=1 >/dev/null 2>&1 || true

  # ── Phase 1: Parallel curl per interface ──
  _conn_phase1_curl

  # ── Phase 2: Parallel probes (traceroute + ping-loss + MTU) ──
  _conn_phase2_probes

  # ── Merge results ──
  _conn_merge_results

  # ── Collect and render ──
  local iface
  for iface in $ifaces; do
    _conn_classify_iface "$iface"
    _total_count=$((_total_count + 1))
    [ "$_ci_reach" = "ok" ] && _ok_count=$((_ok_count + 1))
    _conn_render_iface "$iface"
  done

  # ── Summary ──
  if [ "$OUTPUT_JSON" = 1 ]; then
    printf '{%s,"results":[%s]}\n' \
      "$(json_kv_bool "ok" 0)" \
      "$_conn_json_results"
  else
    if is_quiet; then
      printf 'connectivity: %s/%s paths reachable\n' "$_ok_count" "$_total_count"
    else
      summary_line "$_ok_count" "$_total_count" "paths"
    fi
  fi

  update_exit_code "$_ok_count" "$_total_count"
}
