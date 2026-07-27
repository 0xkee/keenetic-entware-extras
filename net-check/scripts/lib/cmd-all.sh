# net-check: Full diagnostics orchestrator — runs all checks in sequence.
# Dependencies: lib/output.sh (emit_error, section_banner, start_spinner, stop_spinner, is_quiet),
#   lib/wan.sh (get_wan_interfaces), lib/cmd-geo.sh (cmd_geo), lib/cmd-connectivity.sh (cmd_connectivity),
#   lib/cmd-dns.sh (cmd_dns), lib/cmd-dns-leak.sh (cmd_dns_leak), lib/cmd-ipv6-leak.sh (cmd_ipv6_leak),
#   lib/cmd-targets.sh (cmd_compare),
#   lib/cmd-cdn.sh (cmd_cdn_all), lib/cmd-tls.sh (cmd_tls_check_targets),
#   lib/cmd-speed.sh (cmd_speed), lib/common.sh (json_kv_bool, json_kv_num)
# Globals used: OUTPUT_JSON, VERBOSITY, _EXIT_CODE, CHECK_INTERFACES, _GEO_EXT_IPS,
#   DATA_DIR, CACHE_FILE, C_CYAN, C_RST, C_BOLD, C_GREEN, C_RED, C_YELLOW, C_DIM
# shellcheck disable=SC3043

# ─── Command: all (full diagnostics) ─────────────────────────────────────────

cmd_all() {
  _IN_BATCH=1
  local ifaces _saved_check_interfaces
  ifaces=$(require_wan_ifaces) || return 1

  _saved_check_interfaces="$CHECK_INTERFACES"

  local _steps=9 _step_ok=0 _step_fail=0
  local _t_start _tmpout
  _t_start=$(date +%s)
  _tmpout="${_RUN_DIR}/all-out.tmp"

  # JSON mode: collect sub-results into sections
  local _json_geo="" _json_conn="" _json_dns="" _json_dns_leak=""
  local _json_ipv6="" _json_compare="" _json_cdn="" _json_tls="" _json_speed=""

  # ── Zone header (once before all sections) ──
  print_zone_header_once

  # ── Step 1: Egress Point Verification (special: fail-fast after) ──
  if [ "$OUTPUT_JSON" = 0 ] && ! is_quiet; then
    section_banner 1 "$_steps" "$_TITLE_GEO"
  fi
  start_spinner "Checking egress points..."
  if cmd_geo > "$_tmpout" 2>&1; then _step_ok=$((_step_ok + 1)); else _step_fail=$((_step_fail + 1)); fi
  stop_spinner
  if [ "$OUTPUT_JSON" = 1 ]; then
    _json_geo=$(_out_section < "$_tmpout")
  else
    _out_section < "$_tmpout"
  fi

  # ── Fail-fast: filter out unreachable interfaces ──
  if [ -n "$_GEO_EXT_IPS" ]; then
    local alive_ifaces="" dead_ifaces="" _dev _found
    for _dev in $ifaces; do
      _found=$(printf '%s' "$_GEO_EXT_IPS" | grep -c "^${_dev}:" 2>/dev/null) || _found=0
      if [ "$_found" -gt 0 ]; then
        alive_ifaces="${alive_ifaces:+${alive_ifaces} }${_dev}"
      else
        dead_ifaces="${dead_ifaces:+${dead_ifaces} }${_dev}"
      fi
    done
    if [ -n "$dead_ifaces" ] && [ "$OUTPUT_JSON" = 0 ] && ! is_quiet; then
      printf '\n%s⚠️  Unreachable interfaces (skipped): %s%s\n' "$C_YELLOW" "$dead_ifaces" "$C_RST"
    fi
    if [ -n "$alive_ifaces" ]; then
      CHECK_INTERFACES="$alive_ifaces"
    fi
  fi

  # ── Steps 2-8: data-driven loop ──
  # Format: step_num|json_key|title_var|spinner_msg|command
  local _sn _sk _tv _sm _sf _step_json_val _banner_title
  while IFS='|' read -r _sn _sk _tv _sm _sf; do
    eval "_banner_title=\"\$$_tv\""
    if [ "$OUTPUT_JSON" = 0 ] && ! is_quiet; then
      printf '\n'
      section_banner "$_sn" "$_steps" "$_banner_title"
    fi
    start_spinner "$_sm"
    if "$_sf" > "$_tmpout" 2>&1; then _step_ok=$((_step_ok + 1)); else _step_fail=$((_step_fail + 1)); fi
    stop_spinner
    if [ "$OUTPUT_JSON" = 1 ]; then
      _step_json_val=$(_out_section < "$_tmpout")
      eval "_json_${_sk}=\"\$_step_json_val\""
    else
      _out_section < "$_tmpout"
    fi
  done <<'_STEPS_EOF'
2|conn|_TITLE_CONN|Testing TCP/TLS connectivity...|cmd_connectivity
3|ipv6|_TITLE_IPV6|Checking IPv6 leaks...|cmd_ipv6_leak
4|dns|_TITLE_DNS|Checking DNS resolution...|cmd_dns
5|dns_leak|_TITLE_DNS_LEAK|Checking DNS resolvers...|cmd_dns_leak
6|compare|_TITLE_COMPARE|Checking HTTP targets...|cmd_compare
7|cdn|_TITLE_CDN|Analyzing CDN steering...|cmd_cdn_all
8|tls|_TITLE_TLS|Checking TLS certificates...|cmd_tls_check_targets
9|speed|_TITLE_SPEED|Measuring throughput...|cmd_speed
_STEPS_EOF

  rm -f "$_tmpout"

  # Restore original CHECK_INTERFACES
  CHECK_INTERFACES="$_saved_check_interfaces"

  local _elapsed=$(( $(date +%s) - _t_start ))

  if [ "$OUTPUT_JSON" = 1 ]; then
    # JSON envelope wrapping all sections
    local _all_ok=0
    [ "$_step_fail" -gt 0 ] && _all_ok=1
    printf '{%s,%s,%s,%s,"sections":{' \
      "$(json_kv_bool "ok" "$_all_ok")" \
      "$(json_kv_num "elapsed_s" "$_elapsed")" \
      "$(json_kv_num "steps_ok" "$_step_ok")" \
      "$(json_kv_num "steps_fail" "$_step_fail")"
    printf '"geo":%s,' "$_json_geo"
    printf '"connectivity":%s,' "$_json_conn"
    printf '"dns":%s,' "$_json_dns"
    printf '"dns_leak":%s,' "$_json_dns_leak"
    printf '"ipv6_leak":%s,' "$_json_ipv6"
    printf '"compare":%s,' "$_json_compare"
    printf '"cdn":%s,' "$_json_cdn"
    printf '"tls":%s,' "$_json_tls"
    printf '"speed":%s' "$_json_speed"
    printf '}}\n'
  else
    print_summary_footer "$_elapsed" "$_step_ok" "$_steps"
  fi

  # Set exit code based on step results
  if [ "$_step_fail" -gt 0 ]; then
    if [ "$_step_ok" -eq 0 ]; then
      _EXIT_CODE=2
    else
      [ "$_EXIT_CODE" -lt 1 ] && _EXIT_CODE=1
    fi
  fi
}
