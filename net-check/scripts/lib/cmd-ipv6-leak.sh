# net-check: IPv6 leak test — detect IPv6 traffic bypassing VPN tunnel.
# Queries IPv6-only endpoint per WAN interface.
# If ISP interface responds with IPv6 while tunnel is active → leak.
# If no interface has IPv6 → reports "IPv6 disabled" without table.
#
# Dependencies: lib/output.sh (emit_error, section_title, tbl_header, tbl_row, tbl_cell,
#     status_mark, is_quiet),
#   lib/wan.sh (get_wan_interfaces, iface_type, geo_cached_cc),
#   lib/ip.sh (is_tunnel_iface),
#   lib/common.sh (json_kv, json_kv_bool)
# Globals used: OUTPUT_JSON, VERBOSITY, _EXIT_CODE, CURL_UA, IPV6_CHECK_URL,
#   C_GREEN, C_RED, C_DIM, C_RST
# shellcheck disable=SC3043

cmd_ipv6_leak() {
  local ifaces
  ifaces=$(require_wan_ifaces) || return 1

  local json_results=""

  # ── Phase 1: detect tunnel presence ──
  local iface has_tunnel=0
  for iface in $ifaces; do
    is_tunnel_iface "$iface" && has_tunnel=1
  done

  # ── Phase 2: probe IPv6 on each interface — parallel ──
  (
  trap 'kill 0 2>/dev/null; exit 130' INT TERM
  for iface in $ifaces; do
    (
      _addr=$(curl -6 -sS --interface "$iface" \
        --connect-timeout "$PROBE_TIMEOUT" --max-time "$PROBE_TIMEOUT" \
        -H "User-Agent: $CURL_UA" \
        "$IPV6_CHECK_URL" 2>/dev/null) || _addr=""
      _itype=$(iface_type "$iface")
      _cc=$(geo_cached_cc "$iface")
      [ -z "$_cc" ] && _cc="—"
      printf '%s\t%s\t%s\n' "$_itype" "$_cc" "$_addr" \
        > "${_RUN_DIR}/ipv6-${iface}"
    ) &
  done
  wait
  )

  # Collect parallel results (in iface order for stable output)
  local _collected="" any_ipv6=0 ipv6_on_isp=0
  for iface in $ifaces; do
    local ipv6_addr="" ipv6_status="no IPv6"
    local itype="" cc=""
    local _pf="${_RUN_DIR}/ipv6-${iface}"
    if [ -f "$_pf" ]; then
      itype=$(cut -f1 "$_pf")
      cc=$(cut -f2 "$_pf")
      ipv6_addr=$(cut -f3 "$_pf")
      rm -f "$_pf"
    else
      itype=$(iface_type "$iface")
      cc=$(geo_cached_cc "$iface")
      [ -z "$cc" ] && cc="—"
    fi

    if [ -n "$ipv6_addr" ]; then
      any_ipv6=1
      if [ "$itype" = "isp" ] && [ "$has_tunnel" = 1 ]; then
        ipv6_status="LEAK"
        ipv6_on_isp=1
      else
        ipv6_status="ok"
      fi
    fi

    # Store per-interface data for phase 3
    _collected="${_collected}${iface}|${itype}|${cc}|${ipv6_addr}|${ipv6_status}
"

    # JSON results are always collected regardless of any_ipv6
    if [ "$OUTPUT_JSON" = 1 ]; then
      local entry_json
      entry_json=$(printf '{%s,%s,%s,%s,%s}' \
        "$(json_kv "dev" "$iface")" \
        "$(json_kv "type" "$itype")" \
        "$(json_kv "cc" "$cc")" \
        "$(json_kv "ipv6" "${ipv6_addr:-none}")" \
        "$(json_kv "status" "$ipv6_status")")
      json_arr_add json_results "$entry_json"
    fi
  done

  # ── Phase 3: output ──
  section_title "$_TITLE_IPV6"
  if [ "$OUTPUT_JSON" = 0 ] && ! is_quiet; then
    printf 'Checks if IPv6 traffic bypasses tunnel by querying IPv6-only endpoint.\n'
    printf 'ISP interface responding with IPv6 while tunnel is active → IPv6 leak.\n\n'
  fi

  if [ "$OUTPUT_JSON" = 0 ]; then
    if [ "$any_ipv6" = 0 ]; then
      # No IPv6 on any interface — skip table, show concise message
      if ! is_quiet; then
        printf '%sIPv6 disabled on all interfaces.%s\n' "$C_DIM" "$C_RST"
        printf '→ %sNo IPv6 leak%s %s\n' "$C_GREEN" "$C_RST" "$(status_mark ok)"
      else
        printf 'ipv6-leak: no leak %s\n' "$(status_mark ok)"
      fi
    else
      # At least one interface has IPv6 — show full table
      tbl_header "Path:14" "CC:4" "IPv6:8" "Address:18" "Status"

      printf '%s' "$_collected" | while IFS='|' read -r _r_iface _r_itype _r_cc _r_addr _r_status; do
        [ -z "$_r_iface" ] && continue
        local _st="dim"
        if [ -n "$_r_addr" ]; then
          if [ "$_r_status" = "LEAK" ]; then
            _st="warn"
          else
            _st="ok"
          fi
        fi
        tbl_row "$_r_iface" "$_r_cc" \
          "$(tbl_cell 8 "$([ -n "$_r_addr" ] && printf 'yes' || printf 'no')" "$_st")" \
          "${_r_addr:-—}" \
          "$(status_mark "$_st")"
      done

      if is_quiet; then
        if [ "$ipv6_on_isp" = 1 ]; then
          printf 'ipv6-leak: %s IPv6 leak on ISP while tunnel active\n' "$(status_mark warn)"
        else
          printf 'ipv6-leak: no leak %s\n' "$(status_mark ok)"
        fi
      else
        if [ "$ipv6_on_isp" = 1 ]; then
          printf '→ %s%s IPv6 leak detected on ISP interface while tunnel is active%s\n' \
            "$C_RED" "$(status_mark warn)" "$C_RST"
          [ "$_EXIT_CODE" -lt 1 ] && _EXIT_CODE=1
        else
          printf '→ %sNo IPv6 leak%s %s\n' "$C_GREEN" "$C_RST" "$(status_mark ok)"
        fi
      fi
    fi
  fi

  if [ "$OUTPUT_JSON" = 1 ]; then
    local ok_val=0
    [ "$ipv6_on_isp" = 1 ] && ok_val=1
    printf '{%s,%s,"results":[%s]}\n' \
      "$(json_kv_bool "ok" "$ok_val")" \
      "$(json_kv_bool "ipv6_enabled" "$([ "$any_ipv6" = 1 ] && printf '0' || printf '1')")" \
      "$json_results"
  fi
}
