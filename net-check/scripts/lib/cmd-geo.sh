# net-check: Egress point (external IP, country, ASN) verification per WAN interface.
# Dependencies: lib/output.sh (emit_error, emit_warn, color_status, status_mark, summary_line, is_quiet),
#   lib/wan.sh (get_wan_interfaces, iface_type),
#   lib/geo-cache.sh (geo_read_cache, geo_write_cache, geo_read_stale),
#   lib/geoip.sh (geolocate_ip, geoip_read_full),
#   lib/common.sh (json_kv, json_kv_bool)
# Globals used: OUTPUT_JSON, VERBOSITY, _GEO_EXT_IPS, _EXIT_CODE,
#   GEO_SERVICES, CONNECT_TIMEOUT, HTTP_TIMEOUT, CURL_UA, DATA_DIR,
#   C_GREEN, C_RED, C_YELLOW, C_DIM, C_RST
# shellcheck disable=SC3043,SC2154

# ─── Command: geo (egress point verification) ────────────────────────────────

cmd_geo() {
  local ifaces
  ifaces=$(require_wan_ifaces) || return 1

  # Load geo-zone context for zone/intl annotation
  load_zone_context

  local json_paths=""
  local _ok_count=0 _total_count=0

  section_title "$_TITLE_GEO"
  if [ "$OUTPUT_JSON" = 0 ] && ! is_quiet; then
    printf 'External IP, country and ISP per WAN path. Verifies tunnel egress identity.\n\n'
  fi
  tbl_header "Path:14" "External IP:18" "CC:4" "City:18" "ASN:10" "Org:40" "Status"

  # ── Parallel GeoIP probe per interface ──
  (
  trap 'kill 0 2>/dev/null; exit 130' INT TERM
  for iface in $ifaces; do
    (
      _ext_ip="" _country="" _city="" _asn="" _org="" _geo_ok=0 _from_cache=0

      # Try file-based geo cache first
      _cached_json=$(geo_read_cache "$iface" 2>/dev/null) || _cached_json=""
      if [ -n "$_cached_json" ]; then
        parse_geo_json "$_cached_json"
        _ext_ip="$_geo_ip"; _country="$_geo_country"; _city="$_geo_city"
        _asn="$_geo_asn"; _org="$_geo_org"
        if [ -n "$_ext_ip" ]; then
          _geo_ok=1; _from_cache=1
        fi
      fi

      # Cache miss → query GeoIP services
      if [ "$_geo_ok" = 0 ]; then
        for _svc_entry in $GEO_SERVICES; do
          _svc_url="${_svc_entry%%|*}"
          _svc_type="${_svc_entry##*|}"
          _hcg=""
          _tmpgeo="${_RUN_DIR}/geo-resp-${iface}"
          _hcg=$(curl -sS --interface "$iface" \
            --connect-timeout "$CONNECT_TIMEOUT" --max-time "$HTTP_TIMEOUT" \
            -o "$_tmpgeo" -w '%{http_code}' \
            -H "User-Agent: $CURL_UA" \
            "$_svc_url" 2>/dev/null) || _hcg="000"

          if [ "$_hcg" = "429" ]; then
            rm -f "$_tmpgeo"
            # Try stale cache on rate limit
            _stale=$(geo_read_stale "$iface" 2>/dev/null) || _stale=""
            if [ -n "$_stale" ]; then
              parse_geo_json "$_stale"
              _ext_ip="$_geo_ip"; _country="$_geo_country"; _city="$_geo_city"
              _asn="$_geo_asn"; _org="$_geo_org"
              [ -n "$_ext_ip" ] && _geo_ok=1
            fi
            break
          fi
          if [ "$_hcg" != "200" ]; then rm -f "$_tmpgeo"; continue; fi

          _resp=$(cat "$_tmpgeo" 2>/dev/null | tr -d '\n\r' | sed 's/\\"/§/g') || _resp=""
          rm -f "$_tmpgeo"
          [ -z "$_resp" ] && continue

          case "$_svc_type" in
            plain) [ -z "$_ext_ip" ] && _ext_ip="$_resp" ;;
            json_full)
              _jip=$(printf '%s' "$_resp" | sed -n 's/.*"ip"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
              if [ -n "$_jip" ]; then
                # If plain service already got a per-interface IP, only use
                # json_full geo data when IPs match (ipinfo.io/json may route
                # through a different path and return the wrong egress IP).
                if [ -n "$_ext_ip" ] && [ "$_jip" != "$_ext_ip" ]; then
                  continue
                fi
                _ext_ip="$_jip"
                _country=$(printf '%s' "$_resp" | sed -n 's/.*"country"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
                _city=$(printf '%s' "$_resp" | sed -n 's/.*"city"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
                _raw_org=$(printf '%s' "$_resp" | sed -n 's/.*"org"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
                _asn=$(printf '%s' "$_raw_org" | sed -n 's/^\(AS[0-9]*\).*/\1/p')
                _org=$(printf '%s' "$_raw_org" | sed 's/^AS[0-9]* *//; s/§/"/g')
                _geo_ok=1
              fi ;;
          esac
          [ "$_geo_ok" = 1 ] && break
        done

        # Fallback: geolocate_ip() for CC + unified cache enrichment
        if [ "$_geo_ok" = 0 ] && [ -n "$_ext_ip" ]; then
          # geolocate_ip uses ip-api.com/json → caches CC+city+ASN+org
          _country=$(geolocate_ip "$_ext_ip" 2>/dev/null) || _country=""
          _geo_ok=1
          # Read enrichment from unified ipgeo cache (populated by geolocate_ip)
          if geoip_read_full "$_ext_ip" 2>/dev/null; then
            [ -z "$_city" ] && _city="$_enrich_city"
            [ -z "$_asn" ] && _asn="$_enrich_asn"
            [ -z "$_org" ] && _org="$_enrich_org"
          fi
        fi

        # Write per-interface geo cache only with complete data (city non-empty)
        if [ "$_geo_ok" = 1 ] && [ -n "$_ext_ip" ] && [ -n "$_city" ]; then
          _cj=$(printf '{"ip":"%s","country":"%s","city":"%s","asn":"%s","org":"%s"}' \
            "$_ext_ip" "${_country:-}" "${_city:-}" "${_asn:-}" \
            "$(printf '%s' "${_org:-}" | sed 's/"/\\"/g')")
          geo_write_cache "$iface" "$_cj"
        fi
      fi

      # Write result to temp file (TSV: geo_ok|from_cache|ip|country|city|asn|org)
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$_geo_ok" "$_from_cache" "${_ext_ip:-}" "${_country:-}" \
        "${_city:-}" "${_asn:-}" "${_org:-}" \
        > "${_RUN_DIR}/geo-result-${iface}"
    ) &
  done
  wait
  )

  # ── Collect parallel results (in iface order for stable output) ──
  local iface
  for iface in $ifaces; do
    local ext_ip="" country="" city="" asn="" org="" geo_ok=0 _from_cache=0
    _total_count=$((_total_count + 1))

    local _pf="${_RUN_DIR}/geo-result-${iface}"
    if [ -f "$_pf" ]; then
      geo_ok=$(cut -f1 "$_pf")
      _from_cache=$(cut -f2 "$_pf")
      ext_ip=$(cut -f3 "$_pf")
      country=$(cut -f4 "$_pf")
      city=$(cut -f5 "$_pf")
      asn=$(cut -f6 "$_pf")
      org=$(cut -f7 "$_pf")
      rm -f "$_pf"
    fi

    # Populate in-memory cache for cdn ECS reuse
    if [ -n "$ext_ip" ]; then
      _GEO_EXT_IPS="${_GEO_EXT_IPS}${iface}:${ext_ip}
"
    fi

    [ "$geo_ok" = 1 ] && _ok_count=$((_ok_count + 1))

    local itype
    itype=$(iface_type "$iface")

    if [ "$OUTPUT_JSON" = 1 ]; then
      local path_json
      path_json=$(printf '{%s,%s,%s,%s,%s,%s,%s}' \
        "$(json_kv "dev" "$iface")" \
        "$(json_kv "type" "$itype")" \
        "$(json_kv "ip" "${ext_ip:-unknown}")" \
        "$(json_kv "country" "${country:-}")" \
        "$(json_kv "city" "${city:-}")" \
        "$(json_kv "asn" "${asn:-}")" \
        "$(json_kv "org" "${org:-}")")
      json_arr_add json_paths "$path_json"
    elif is_quiet; then
      : # quiet mode — skip rows, show summary only
    else
      local _status_cell
      if [ "$geo_ok" = 1 ]; then
        _status_cell="$(status_mark ok)"
        [ "$_from_cache" = 1 ] && _status_cell="${_status_cell} $(cache_mark)"
        tbl_row "$iface" "$(tbl_cell 18 "${ext_ip:-—}" ok)" \
          "${country:-—}" "${city:-—}" "${asn:-—}" "${org:-—}" \
          "$_status_cell"
      else
        tbl_row "$iface" "$(tbl_cell 18 "—" fail)" "—" "—" "—" \
          "unreachable" "$(status_mark fail)"
      fi
    fi
  done

  if [ "$OUTPUT_JSON" = 1 ]; then
    printf '{%s,"paths":[%s]}\n' \
      "$(json_kv_bool "ok" 0)" \
      "$json_paths"
  else
    if is_quiet; then
      printf 'geo: %s/%s paths ok\n' "$_ok_count" "$_total_count"
    else
      summary_line "$_ok_count" "$_total_count" "paths"
    fi
  fi

  update_exit_code "$_ok_count" "$_total_count"
}
