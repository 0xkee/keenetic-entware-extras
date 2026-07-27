# net-check: Download/upload throughput (speed) test per WAN interface.
# Dependencies: lib/output.sh (emit_error, color_status, status_mark, summary_line, is_quiet),
#   lib/wan.sh (get_wan_interfaces, iface_type, geo_cached_cc),
#   lib/http-core.sh (to_ms), lib/common.sh (json_kv, json_kv_num, json_kv_bool)
# Globals used: OUTPUT_JSON, VERBOSITY, _EXIT_CODE,
#   CONNECT_TIMEOUT, CURL_UA, SPEED_TEST_BYTES, DATA_DIR,
#   SPEED_DL_URL, SPEED_UL_URL, SPEED_TIMEOUT,
#   C_GREEN, C_RED, C_YELLOW, C_DIM, C_RST, C_BOLD, C_CYAN
# shellcheck disable=SC3043

# Format speed (bytes/sec) for human display.
# Args: $1 - bytes per second (float)
# stdout: "X.X MB/s" or "X KB/s"
format_speed() {
  awk "BEGIN {
    s = ${1:-0}
    if (s >= 1048576) printf \"%.1f MB/s\", s/1048576
    else if (s >= 1024) printf \"%.0f KB/s\", s/1024
    else printf \"%.0f B/s\", s
  }"
}

# Format download/upload speed pair for combined 2-column display.
# Always shows units per value: "1.2MB / 962KB".
# Args: $1 - dl bytes/sec, $2 - ul bytes/sec
# stdout: combined speed string (e.g. "1.2MB / 962KB")
format_speed_pair() {
  awk "BEGIN {
    dl = ${1:-0}; ul = ${2:-0}
    if (dl >= 1048576) printf \"%.1fMB\", dl/1048576
    else if (dl >= 1024) printf \"%.0fKB\", dl/1024
    else printf \"%.0fB\", dl
    printf \" / \"
    if (ul >= 1048576) printf \"%.1fMB\", ul/1048576
    else if (ul >= 1024) printf \"%.0fKB\", ul/1024
    else printf \"%.0fB\", ul
  }"
}

# Render speed bar using Unicode block characters with percentage.
# DL and UL bars separated by "/", scaled to a single shared maximum
# so bars are visually comparable within each row.
# Block levels: ▂ ▄ ▆ █ (4 levels, 4-char width per bar).
# Empty positions use · (middle dot) as filler.
# NOTE: Output is NOT printf %-Ns safe (multi-byte Unicode chars).
#   Use raw output, not tbl_cell with padding.
# Args: $1 - dl bytes/sec, $2 - ul bytes/sec, $3 - shared max speed
# stdout: "▂▄▆█ 100% / ▂▄·· 57%" (21 visual chars)
speed_bar() {
  local _dl="${1:-0}" _ul="${2:-0}" _max="${3:-0}"
  local _dlbar _ulbar
  _dlbar=$(_speed_half_bar "$_dl" "$_max")
  _ulbar=$(_speed_half_bar "$_ul" "$_max")
  printf '%s / %s' "$_dlbar" "$_ulbar"
}

# Render one half (DL or UL) bar: "▂▄▆█ 100%" (9 visual chars).
# Args: $1 - speed bytes/sec, $2 - max speed bytes/sec
# stdout: bar + space + right-aligned percentage (9 visual chars)
_speed_half_bar() {
  local _s="${1:-0}" _m="${2:-0}"
  if [ "$_m" = "0" ] || [ "$_s" = "0" ]; then
    printf '····  ---'
    return 0
  fi
  # Compute bar blocks and percentage
  awk "BEGIN {
    s = ${_s}; m = ${_m}; w = 4
    split(\"▂ ▄ ▆ █\", blk, \" \")
    pct = int(s / m * 100 + 0.5)
    filled = int((s / m) * w + 0.5)
    if (filled < 1) filled = 1
    if (filled > w) filled = w
    bar = \"\"
    for (i = 1; i <= w; i++) {
      if (i <= filled) {
        lvl = int((i / w) * 4 + 0.5)
        if (lvl < 1) lvl = 1; if (lvl > 4) lvl = 4
        bar = bar blk[lvl]
      } else { bar = bar \"·\" }
    }
    printf \"%s %3d%%\", bar, pct
  }"
}

# ─── Command: speed (throughput test) ─────────────────────────────────────────

cmd_speed() {
  local ifaces
  ifaces=$(require_wan_ifaces) || return 1

  # Ensure geo cache is populated for CC column
  ensure_geo_cache

  local json_results=""
  local _ok_count=0 _total_count=0
  local dl_url="$SPEED_DL_URL"
  local ul_url="$SPEED_UL_URL"

  local size_label
  size_label=$(awk "BEGIN { printf \"%.1f MB\", ${SPEED_TEST_BYTES} / 1000000 }")
  section_title "$_TITLE_SPEED"
  if [ "$OUTPUT_JSON" = 0 ] && ! is_quiet; then
    printf 'Download/upload speed per WAN interface via Cloudflare (%s payload).\n\n' "$size_label"
  fi

  # ── Phase 1: Sequential speed tests (parallel would skew throughput) ──
  local iface
  for iface in $ifaces; do
    local dl_speed="0" dl_time="—" dl_status="fail"
    local ul_speed="0" ul_time="—" ul_status="skip"
    local itype cc
    itype=$(iface_type "$iface")
    cc=$(geo_cached_cc "$iface")
    [ -z "$cc" ] && cc="—"
    _total_count=$((_total_count + 1))

    # Download test
    local curl_fmt='%{speed_download} %{time_total} %{http_code}'
    local curl_out
    curl_out=$(curl -sS --interface "$iface" \
      --connect-timeout "$CONNECT_TIMEOUT" --max-time "$SPEED_TIMEOUT" \
      -o /dev/null -w "$curl_fmt" \
      -H "User-Agent: $CURL_UA" \
      "$dl_url" 2>/dev/null) || curl_out=""

    if [ -n "$curl_out" ]; then
      local _speed _time _hc
      _speed=$(printf '%s' "$curl_out" | awk '{print $1}')
      _time=$(printf '%s' "$curl_out" | awk '{print $2}')
      _hc=$(printf '%s' "$curl_out" | awk '{print $3}')
      if [ "$_hc" = "200" ] && [ -n "$_speed" ]; then
        dl_status="ok"
        dl_speed="$_speed"
        dl_time=$(to_ms "$_time")
      fi
    fi

    # Upload test (only if download succeeded)
    if [ "$dl_status" = "ok" ]; then
      local ul_out
      ul_out=$(dd if=/dev/zero bs=1024 count=$((SPEED_TEST_BYTES / 1024)) 2>/dev/null | \
        curl -sS --interface "$iface" \
          --connect-timeout "$CONNECT_TIMEOUT" --max-time "$SPEED_TIMEOUT" \
          -X POST --data-binary @- \
          -o /dev/null -w '%{speed_upload} %{time_total} %{http_code}' \
          -H "User-Agent: $CURL_UA" \
          -H "Content-Type: application/octet-stream" \
          "$ul_url" 2>/dev/null) || ul_out=""
      if [ -n "$ul_out" ]; then
        local _ul_speed _ul_time _ul_hc
        _ul_speed=$(printf '%s' "$ul_out" | awk '{print $1}')
        _ul_time=$(printf '%s' "$ul_out" | awk '{print $2}')
        _ul_hc=$(printf '%s' "$ul_out" | awk '{print $3}')
        if [ "$_ul_hc" = "200" ] && [ -n "$_ul_speed" ]; then
          ul_status="ok"
          ul_speed="$_ul_speed"
          ul_time=$(to_ms "$_ul_time")
        else
          ul_status="fail"
        fi
      else
        ul_status="fail"
      fi
    fi

    [ "$dl_status" = "ok" ] && _ok_count=$((_ok_count + 1))

    # Save result to temp file for 2-pass rendering
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$dl_status" "$dl_speed" "$dl_time" \
      "$ul_status" "$ul_speed" "$ul_time" \
      "$itype" "$cc" "$iface" \
      > "${_RUN_DIR}/speed-${iface}"
  done

  # ── Phase 2: Find single max speed across all DL+UL for bar scaling ──
  local _max_speed=0
  for iface in $ifaces; do
    local _sf="${_RUN_DIR}/speed-${iface}"
    [ -f "$_sf" ] || continue
    local _ds _us
    _ds=$(cut -f2 "$_sf")
    _us=$(cut -f5 "$_sf")
    _max_speed=$(awk "BEGIN { m=${_max_speed}; d=${_ds:-0}; u=${_us:-0}; if(d>m) m=d; if(u>m) m=u; print m }")
  done

  # ── Phase 3: Render table with bars ──
  tbl_header "Path:14" "CC:4" "Down / Up:20" "Time, ms:14" "Speed:21" "Status"

  for iface in $ifaces; do
    local _sf="${_RUN_DIR}/speed-${iface}"
    local dl_status="fail" dl_speed="0" dl_time="—"
    local ul_status="skip" ul_speed="0" ul_time="—"
    local itype="" cc="—"

    if [ -f "$_sf" ]; then
      dl_status=$(cut -f1 "$_sf")
      dl_speed=$(cut -f2 "$_sf")
      dl_time=$(cut -f3 "$_sf")
      ul_status=$(cut -f4 "$_sf")
      ul_speed=$(cut -f5 "$_sf")
      ul_time=$(cut -f6 "$_sf")
      itype=$(cut -f7 "$_sf")
      cc=$(cut -f8 "$_sf")
      rm -f "$_sf"
    fi

    if [ "$OUTPUT_JSON" = 1 ]; then
      local entry_json
      entry_json=$(printf '{%s,%s,%s,%s,%s,%s,%s,%s}' \
        "$(json_kv "dev" "$iface")" \
        "$(json_kv "type" "$itype")" \
        "$(json_kv "cc" "$cc")" \
        "$(json_kv_num "dl_speed_bps" "${dl_speed:-0}")" \
        "$(json_kv "dl_time_ms" "$dl_time")" \
        "$(json_kv_num "ul_speed_bps" "${ul_speed:-0}")" \
        "$(json_kv "ul_time_ms" "$ul_time")" \
        "$(json_kv "status" "$dl_status")")
      json_arr_add json_results "$entry_json"
    elif is_quiet; then
      : # skip rows
    else
      local _st="fail"
      [ "$dl_status" = "ok" ] && _st="ok"
      local _ul_st="fail" _combined_st _speed_pair _time_pair _bar
      [ "$ul_status" = "ok" ] && _ul_st="ok"
      # Combined status: ok only if both ok; warn if mixed; fail if both fail
      if [ "$_st" = "ok" ] && [ "$_ul_st" = "ok" ]; then
        _combined_st="ok"
      elif [ "$_st" = "fail" ] && [ "$_ul_st" = "fail" ]; then
        _combined_st="fail"
      else
        _combined_st="warn"
      fi
      if [ "$_st" = "ok" ]; then
        _speed_pair=$(format_speed_pair "$dl_speed" "$ul_speed")
        _time_pair="${dl_time} / ${ul_time}"
        _bar=$(speed_bar "$dl_speed" "$ul_speed" "$_max_speed")
      else
        _speed_pair="— / —"
        _time_pair="— / —"
        _bar=$(speed_bar 0 0 0)
      fi
      tbl_row "$iface" "$cc" \
        "$(tbl_cell 20 "$_speed_pair" "$_combined_st")" \
        "$(tbl_cell 14 "$_time_pair" "$_combined_st")" \
        "$(tbl_cell 21 "$_bar" "$_combined_st")" \
        "$(status_mark "$_combined_st")"
    fi
  done

  if [ "$OUTPUT_JSON" = 1 ]; then
    local _spd_ok_val=0
    [ "$_ok_count" -lt "$_total_count" ] && _spd_ok_val=1
    printf '{%s,%s,"results":[%s]}\n' \
      "$(json_kv_bool "ok" "$_spd_ok_val")" \
      "$(json_kv_num "test_bytes" "$SPEED_TEST_BYTES")" \
      "$json_results"
  else
    if is_quiet; then
      printf 'speed: %s/%s paths tested ok\n' "$_ok_count" "$_total_count"
    else
      summary_line "$_ok_count" "$_total_count" "paths"
    fi
  fi

  if [ "$_ok_count" -eq 0 ] && [ "$_total_count" -gt 0 ]; then
    [ "$_EXIT_CODE" -lt 1 ] && _EXIT_CODE=1
  fi
}
