# net-check: DNS check — zone resolution verification + ISP blocking detection.
# Resolves all domains from check-targets.conf via system DNS (:53) and ISP DNS.
# Geolocates resolved IPs, auto-classifies zone/intl, detects ISP filtering.
# Single table: one line per domain.
#
# Dependencies: lib/output.sh (emit_error, emit_warn, color_status, status_mark, is_quiet,
#     section_title, tbl_header, tbl_row, tbl_cell),
#   lib/wan.sh (get_wan_interfaces, iface_type, geo_cached_cc),
#   lib/geoip.sh (geolocate_ip),
#   lib/ip.sh (detect_dns_port, is_tunnel_iface),
#   lib/common.sh (json_kv, json_kv_bool, json_kv_num, require_cmd),
#   lib/geo.sh (resolve_geo_zone — optional, for zone classification)
# Globals used: OUTPUT_JSON, VERBOSITY, _EXIT_CODE,
#   DNS_TIMEOUT, CURL_UA, _CONFIG_DIR,
#   DNS_PROVIDERS_FILE, DNS_CACHE_TTL, KEENETIC_DNS_CONF, SMARTDNS_PORT,
#   C_GREEN, C_RED, C_YELLOW, C_DIM, C_RST, C_BOLD, C_CYAN
# shellcheck disable=SC3043,SC1091

# ─── Helpers ──────────────────────────────────────────────────────────────────

# Identify DNS provider by server IP address.
# Reads patterns from $DNS_PROVIDERS_FILE (format: glob_prefix|name).
# Args: $1 - IP address
# stdout: provider name or empty
identify_dns_provider() {
  local ip="$1" prefix name
  [ -z "$ip" ] && return 1
  [ ! -f "$DNS_PROVIDERS_FILE" ] && return 1
  while IFS='|' read -r prefix name; do
    case "$prefix" in \#*|"") continue ;; esac
    # shellcheck disable=SC2254
    case "$ip" in $prefix) printf '%s' "$name"; return 0 ;; esac
  done < "$DNS_PROVIDERS_FILE"
  return 1
}

# Resolve domain to first A record.
# Args: $1 - domain, $2 - DNS server (optional; omit for system resolver),
#        $3 - timeout (optional)
# stdout: IPv4 address or empty
_resolve_a() {
  local domain="$1" server="${2:-}" timeout="${3:-$DNS_TIMEOUT}"
  if [ -n "$server" ]; then
    dig +short "$domain" @"$server" A \
      +time="$timeout" +tries=1 2>/dev/null
  else
    dig +short "$domain" A \
      +time="$timeout" +tries=1 2>/dev/null
  fi | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

# Cached DNS resolution via system resolver.
# File cache: ${DATA_DIR}/dns-<domain>, TTL=60s.
# Shared across sections (dns, compare, tls, cdn).
# For non-system server queries: no cache (ISP DNS check needs fresh results).
# Args: $1 - domain
# stdout: IPv4 address or empty
# Side effect: creates ${_RUN_DIR}/dns-hit-<domain> on cache hit (for cache markers).
_resolve_a_cached() {
  local domain="$1"
  local _cf="${DATA_DIR}/dns-${domain}"
  if is_cache_fresh "$_cf" "$DNS_CACHE_TTL"; then
    cat "$_cf"
    [ -n "${_RUN_DIR:-}" ] && touch "${_RUN_DIR}/dns-hit-${domain}" 2>/dev/null
    return 0
  fi
  local _ip
  _ip=$(_resolve_a "$domain") || _ip=""
  if [ -n "$_ip" ]; then
    printf '%s' "$_ip" > "${_cf}.$$"
    mv -f "${_cf}.$$" "$_cf" 2>/dev/null || true
  fi
  printf '%s' "$_ip"
}

# Get ISP upstream DNS IPs from Keenetic ndnproxymain.conf.
# Filters out SmartDNS-forwarding entries (:6053) and loopback.
# stdout: space-separated IPs (up to 2)
_get_isp_dns() {
  if [ -f "$KEENETIC_DNS_CONF" ]; then
    grep '^dns_server' "$KEENETIC_DNS_CONF" 2>/dev/null | \
      awk '{print $3}' | grep -v ":${SMARTDNS_PORT}" | sed 's/:.*//' | \
      grep -v '^127\.' | head -2 | tr '\n' ' ' | sed 's/ $//'
  fi
}

# Check if an IP is a bogon/redirect (ISP blocking pattern).
# Returns 0 if bogon, 1 otherwise.
_is_bogon() {
  case "$1" in
    0.0.0.0|127.*|10.*|192.168.*|169.254.*) return 0 ;;
    *) return 1 ;;
  esac
}

# Parse hostnames + categories from check-targets.conf (skip geo and comment lines).
# Preserves config order for category group separators; deduplicates by hostname.
# stdout: lines of "hostname|category" (one per line)
_load_check_domains() {
  local _f="${_CONFIG_DIR}/check-targets.conf"
  [ -f "$_f" ] || return 0
  awk -F'|' '
    /^#/ || /^$/ || $2 == "geo" { next }
    {
      host = $1
      sub(/^https?:\/\//, "", host)
      sub(/\/.*/, "", host)
      sub(/:.*/, "", host)
      cat = ($3 != "" ? $3 : "global")
      if (host != "" && !seen[host]++) print host "|" cat
    }
  ' "$_f"
}

# ─── Command: dns ─────────────────────────────────────────────────────────────

# DNS check: resolve all check-targets domains, geolocate IPs,
# auto-classify zone/intl, detect ISP DNS filtering for every domain.
cmd_dns() {
  require_cmd dig

  # Detect resolver
  local dns_source _dns_info
  _dns_info=$(detect_dns_port 2>/dev/null) || _dns_info=""
  case "$_dns_info" in
    6053*|6153*) dns_source="SmartDNS (via :53)" ;;
    *)           dns_source="system DNS (:53)" ;;
  esac

  section_title "$_TITLE_DNS"
  if [ "$OUTPUT_JSON" = 0 ] && ! is_quiet; then
    printf 'DNS resolution & geolocation for all check-targets domains.\n'
    printf 'Detects DNS leaks (wrong geo) and ISP DNS filtering (middlebox interference).\n\n'
  fi

  # ── Detect active DNS zone for auto-classification ──
  load_zone_context
  # shellcheck disable=SC2153  # _ZONE_LABEL/_ZONE_CC_LIST set by load_zone_context()
  local _zone_label="$_ZONE_LABEL" _zone_cc_list="$_ZONE_CC_LIST"

  # ISP DNS for blocking detection
  local isp_dns isp_dns_first="" isp_label=""
  isp_dns=$(_get_isp_dns)
  if [ -n "$isp_dns" ]; then
    isp_dns_first="${isp_dns%% *}"
    local isp_provider
    isp_provider=$(identify_dns_provider "$isp_dns_first")
    if [ -n "$isp_provider" ]; then
      isp_label="$isp_provider ($isp_dns_first)"
    else
      isp_label="$isp_dns_first"
    fi
  fi

  # Load domains (from arguments or check-targets.conf)
  local all_domains="" _dline _ddomain _dcat
  if [ $# -gt 0 ]; then
    # Deep check mode: use passed domains
    for _ddomain in "$@"; do
      _ddomain=$(url_to_host "$_ddomain")
      [ -z "$_ddomain" ] && continue
      all_domains="${all_domains} ${_ddomain}"
      printf '%s' "check" > "${_RUN_DIR}/dns-cat-${_ddomain}"
    done
  else
    # Default: load from check-targets.conf
    while IFS='|' read -r _ddomain _dcat; do
      [ -z "$_ddomain" ] && continue
      all_domains="${all_domains} ${_ddomain}"
      printf '%s' "${_dcat:-global}" > "${_RUN_DIR}/dns-cat-${_ddomain}"
    done <<EOF
$(_load_check_domains)
EOF
  fi
  all_domains="${all_domains# }"
  if [ -z "$all_domains" ]; then
    emit_error "No domains in check-targets.conf"
    return 1
  fi

  # Header
  if [ "$OUTPUT_JSON" = 0 ] && ! is_quiet; then
    printf 'Resolver: %s%s%s\n' "$C_BOLD" "$dns_source" "$C_RST"
    if [ -n "$isp_label" ]; then
      printf 'ISP DNS:  %s\n' "$isp_label"
    fi
    printf '\n'
  fi

  tbl_header "Domain:22" "Resolved IP:18" "CC:4" "Type:8" "Status"
  tbl_group_reset

  local json_results="" json_first=1
  local _dns_ok=0 _dns_warn=0 _dns_total=0
  local _zone_ok=0 _isp_filtered=0
  local domain

  # ── Batched parallel DNS probes (PARALLEL_BATCH_SIZE domains at a time) ──
  local _dns_bn=0 _dns_batch=""
  for domain in $all_domains; do
    _dns_batch="${_dns_batch} ${domain}"
    _dns_bn=$((_dns_bn + 1))
    if [ "$_dns_bn" -ge "$PARALLEL_BATCH_SIZE" ]; then
      (
      trap 'kill 0 2>/dev/null; exit 130' INT TERM
      for _bd in $_dns_batch; do
        (
          _rip=$(_resolve_a_cached "$_bd") || _rip=""
          _iip="" _iblk=0
          if [ -n "$isp_dns_first" ]; then
            _iip=$(_resolve_a "$_bd" "$isp_dns_first") || _iip=""
            if [ -z "$_iip" ]; then _iblk=1
            elif _is_bogon "$_iip"; then _iblk=1
            fi
          fi
          _rcc=""
          [ -n "$_rip" ] && _rcc=$(geolocate_ip "$_rip" 2>/dev/null) || _rcc="??"
          printf '%s\t%s\t%s\t%s\n' "${_rip:-}" "$_rcc" "${_iip:-}" "$_iblk" \
            > "${_RUN_DIR}/dns-${_bd}"
        ) &
      done
      wait
      )
      _dns_bn=0; _dns_batch=""
    fi
  done
  # Flush remaining batch
  if [ -n "$_dns_batch" ]; then
    (
    trap 'kill 0 2>/dev/null; exit 130' INT TERM
    for _bd in $_dns_batch; do
      (
        _rip=$(_resolve_a_cached "$_bd") || _rip=""
        _iip="" _iblk=0
        if [ -n "$isp_dns_first" ]; then
          _iip=$(_resolve_a "$_bd" "$isp_dns_first") || _iip=""
          if [ -z "$_iip" ]; then _iblk=1
          elif _is_bogon "$_iip"; then _iblk=1
          fi
        fi
        _rcc=""
        [ -n "$_rip" ] && _rcc=$(geolocate_ip "$_rip" 2>/dev/null) || _rcc="??"
        printf '%s\t%s\t%s\t%s\n' "${_rip:-}" "$_rcc" "${_iip:-}" "$_iblk" \
          > "${_RUN_DIR}/dns-${_bd}"
      ) &
    done
    wait
    )
  fi

  # ── Collect parallel results (in domain order for stable output) ──
  for domain in $all_domains; do
    # Category group separator (reads category saved during domain loading)
    local _dns_cat="global"
    if [ -f "${_RUN_DIR}/dns-cat-${domain}" ]; then
      _dns_cat=$(cat "${_RUN_DIR}/dns-cat-${domain}")
      rm -f "${_RUN_DIR}/dns-cat-${domain}"
    fi
    tbl_group_sep "$_dns_cat"

    local resolved_ip="" resolved_cc="" dns_type=""
    local status_val="" status_label=""
    local _isp_ip="" _isp_blocked=0
    _dns_total=$((_dns_total + 1))

    local _pf="${_RUN_DIR}/dns-${domain}"
    if [ -f "$_pf" ]; then
      resolved_ip=$(cut -f1 "$_pf")
      resolved_cc=$(cut -f2 "$_pf")
      _isp_ip=$(cut -f3 "$_pf")
      _isp_blocked=$(cut -f4 "$_pf")
      rm -f "$_pf"
    fi

    if [ -n "$resolved_ip" ]; then
      # Auto-classify zone/intl based on GeoIP
      if [ -n "$_zone_cc_list" ] && [ "$resolved_cc" != "??" ]; then
        local _cc_lower
        _cc_lower=$(printf '%s' "$resolved_cc" | tr '[:upper:]' '[:lower:]')
        case " $_zone_cc_list " in
          *" $_cc_lower "*)
            dns_type="zone"
            _zone_ok=$((_zone_ok + 1))
            ;;
          *)
            dns_type="intl"
            ;;
        esac
      else
        dns_type="—"
      fi

      # Determine status
      if [ "$_isp_blocked" = 1 ]; then
        if [ "$dns_type" = "zone" ]; then
          status_val="warn"; status_label="zone ok, ISP filt"
        else
          status_val="warn"; status_label="ISP filtered"
        fi
        _isp_filtered=$((_isp_filtered + 1))
      else
        if [ "$dns_type" = "zone" ]; then
          status_val="ok"; status_label="zone ok"
        else
          status_val="ok"; status_label="ok"
        fi
      fi
      _dns_ok=$((_dns_ok + 1))
    else
      # Resolution failed
      resolved_ip="NXDOMAIN"
      resolved_cc="—"
      dns_type="—"
      if [ "$_isp_blocked" = 1 ]; then
        status_val="warn"; status_label="NXDOMAIN + ISP"
      else
        status_val="warn"; status_label="NXDOMAIN"
      fi
      _dns_warn=$((_dns_warn + 1))
    fi

    # Output
    if [ "$OUTPUT_JSON" = 1 ]; then
      local _in_zone="null"
      if [ "$dns_type" = "zone" ]; then
        _in_zone="true"
      elif [ "$dns_type" = "intl" ]; then
        _in_zone="false"
      fi
      local _isp_json=""
      if [ -n "$isp_dns_first" ]; then
        local _bf=1
        [ "$_isp_blocked" = 1 ] && _bf=0
        _isp_json=$(printf ',"isp_dns":{%s,%s}' \
          "$(json_kv "resolved_ip" "${_isp_ip:-NXDOMAIN}")" \
          "$(json_kv_bool "filtered" "$_bf")")
      fi
      local ej
      ej=$(printf '{%s,%s,%s,%s,%s%s}' \
        "$(json_kv "domain" "$domain")" \
        "$(json_kv "resolved_ip" "$resolved_ip")" \
        "$(json_kv "cc" "$resolved_cc")" \
        "$(json_kv "type" "$dns_type")" \
        "\"in_zone\":${_in_zone}" \
        "$_isp_json")
      if [ "$json_first" = 1 ]; then
        json_results="$ej"
        json_first=0
      else
        json_results="${json_results},${ej}"
      fi
    else
      # Check DNS cache hit marker from parallel phase
      local _dns_cm=""
      if [ -f "${_RUN_DIR}/dns-hit-${domain}" ]; then
        _dns_cm=" $(cache_mark)"
        rm -f "${_RUN_DIR}/dns-hit-${domain}"
      fi
      tbl_row "$domain" \
        "$(tbl_cell 18 "$resolved_ip" "$status_val")" \
        "$(tbl_cell 4 "$resolved_cc" "$status_val")" \
        "$dns_type" \
        "$(status_mark "$status_val") ${status_label}${_dns_cm}"
    fi
  done

  # ── Summary ──
  if [ "$OUTPUT_JSON" = 0 ]; then
    if is_quiet; then
      if [ "$_dns_warn" -gt 0 ]; then
        printf 'dns: %s %s/%s failed' "$(status_mark warn)" "$_dns_warn" "$_dns_total"
      else
        printf 'dns: %s/%s resolved %s' "$_dns_ok" "$_dns_total" "$(status_mark ok)"
      fi
      [ "$_zone_ok" -gt 0 ] && printf ' (%s zone)' "$_zone_ok"
      printf '\n'
      if [ "$_isp_filtered" -gt 0 ]; then
        printf 'dns: %s ISP filters %s domain(s)\n' "$(status_mark warn)" "$_isp_filtered"
      fi
    else
      if [ "$_dns_warn" -gt 0 ]; then
        printf '→ %s%s %s/%s DNS resolutions failed%s\n' \
          "$C_YELLOW" "$(status_mark warn)" "$_dns_warn" "$_dns_total" "$C_RST"
        [ "$_EXIT_CODE" -lt 1 ] && _EXIT_CODE=1
      else
        printf '→ %s%s/%s resolved%s' "$C_GREEN" "$_dns_ok" "$_dns_total" "$C_RST"
        [ "$_zone_ok" -gt 0 ] && printf ' (%s zone)' "$_zone_ok"
        printf ' %s\n' "$(status_mark ok)"
      fi
      if [ "$_isp_filtered" -gt 0 ]; then
        printf '→ %s%s ISP DNS filtering: %s domain(s) blocked%s\n' \
          "$C_YELLOW" "$(status_mark warn)" "$_isp_filtered" "$C_RST"
        printf '  %s(Expected — blocked domains resolve via SmartDNS/tunnel)%s\n' \
          "$C_DIM" "$C_RST"
      elif [ -n "$isp_dns_first" ]; then
        printf '→ %sNo ISP DNS filtering%s %s\n' \
          "$C_GREEN" "$C_RST" "$(status_mark ok)"
      fi
    fi
  fi

  # ── JSON output ──
  if [ "$OUTPUT_JSON" = 1 ]; then
    local dns_ok_val=0
    [ "$_dns_warn" -gt 0 ] && dns_ok_val=1

    printf '{%s,%s' \
      "$(json_kv_bool "ok" "$dns_ok_val")" \
      "$(json_kv "resolver" "$dns_source")"

    if [ -n "$_zone_label" ]; then
      printf ',%s,%s' \
        "$(json_kv "dns_zone" "$_zone_label")" \
        "$(json_kv "zone_countries" "$_zone_cc_list")"
    fi

    printf ',"stats":{%s,%s,%s,%s}' \
      "$(json_kv_num "total" "$_dns_total")" \
      "$(json_kv_num "resolved" "$_dns_ok")" \
      "$(json_kv_num "zone_ok" "$_zone_ok")" \
      "$(json_kv_num "isp_filtered" "$_isp_filtered")"

    if [ -n "$isp_dns_first" ]; then
      printf ',%s' "$(json_kv "isp_dns" "$isp_dns_first")"
    fi

    printf ',"results":[%s]}\n' "$json_results"
  fi
}

# ─── Single-domain DNS check (for deep check mode) ────────────────────────────

# Run DNS resolution check for a single domain.
# Resolves via system DNS (cached) and ISP DNS, geolocates the result,
# classifies zone/intl, detects ISP filtering.
# Used by cmd_check() for deep single-resource analysis.
# Args: $1 - domain to check
# Globals: OUTPUT_JSON, C_GREEN, C_YELLOW, C_BOLD, C_CYAN, C_DIM, C_RST,
#          _EXIT_CODE, _ZONE_LABEL, _ZONE_CC_LIST
# Returns: 0 on success, 1 on missing argument
_dns_check_single() {
  local domain="${1:-}"
  if [ -z "$domain" ]; then
    emit_error "_dns_check_single: domain argument required"
    return 1
  fi

  require_cmd dig

  # ── Detect resolver ──
  local dns_source _dns_info
  _dns_info=$(detect_dns_port 2>/dev/null) || _dns_info=""
  case "$_dns_info" in
    6053*|6153*) dns_source="SmartDNS (via :53)" ;;
    *)           dns_source="system DNS (:53)" ;;
  esac

  # ── Zone context for auto-classification ──
  load_zone_context
  local _zone_label="$_ZONE_LABEL" _zone_cc_list="$_ZONE_CC_LIST"

  # ── ISP DNS for filtering detection ──
  local isp_dns isp_dns_first="" isp_label=""
  isp_dns=$(_get_isp_dns)
  if [ -n "$isp_dns" ]; then
    isp_dns_first="${isp_dns%% *}"
    local isp_provider
    isp_provider=$(identify_dns_provider "$isp_dns_first") || isp_provider=""
    if [ -n "$isp_provider" ]; then
      isp_label="$isp_provider ($isp_dns_first)"
    else
      isp_label="$isp_dns_first"
    fi
  fi

  # ── Resolve via system DNS (cached) ──
  local resolved_ip resolved_cc
  resolved_ip=$(_resolve_a_cached "$domain") || resolved_ip=""
  resolved_cc=""
  if [ -n "$resolved_ip" ]; then
    resolved_cc=$(geolocate_ip "$resolved_ip" 2>/dev/null) || resolved_cc="??"
  fi

  # ── Resolve via ISP DNS (fresh, no cache) ──
  local isp_ip="" isp_blocked=0
  if [ -n "$isp_dns_first" ]; then
    isp_ip=$(_resolve_a "$domain" "$isp_dns_first") || isp_ip=""
    if [ -z "$isp_ip" ]; then
      isp_blocked=1
    elif _is_bogon "$isp_ip"; then
      isp_blocked=1
    fi
  fi

  # ── Classify zone/intl ──
  local dns_type="" status_val="" status_label="" in_zone="null"

  if [ -n "$resolved_ip" ]; then
    if [ -n "$_zone_cc_list" ] && [ "$resolved_cc" != "??" ]; then
      local _cc_lower
      _cc_lower=$(printf '%s' "$resolved_cc" | tr '[:upper:]' '[:lower:]')
      case " $_zone_cc_list " in
        *" $_cc_lower "*) dns_type="zone"; in_zone="true" ;;
        *)                dns_type="intl"; in_zone="false" ;;
      esac
    else
      dns_type="—"
    fi

    # Status
    if [ "$isp_blocked" = 1 ]; then
      if [ "$dns_type" = "zone" ]; then
        status_val="warn"; status_label="zone ok, ISP filt"
      else
        status_val="warn"; status_label="ISP filtered"
      fi
    else
      if [ "$dns_type" = "zone" ]; then
        status_val="ok"; status_label="zone ok"
      else
        status_val="ok"; status_label="ok"
      fi
    fi
  else
    # Resolution failed
    resolved_ip="NXDOMAIN"
    resolved_cc="—"
    dns_type="—"
    if [ "$isp_blocked" = 1 ]; then
      status_val="warn"; status_label="NXDOMAIN + ISP"
    else
      status_val="warn"; status_label="NXDOMAIN"
    fi
  fi

  # ── Output ──
  if [ "$OUTPUT_JSON" = 1 ]; then
    local _isp_json=""
    if [ -n "$isp_dns_first" ]; then
      local _bf=1
      [ "$isp_blocked" = 1 ] && _bf=0
      _isp_json=$(printf ',"isp_dns":{%s,%s}' \
        "$(json_kv "resolved_ip" "${isp_ip:-NXDOMAIN}")" \
        "$(json_kv_bool "filtered" "$_bf")")
    fi

    printf '{%s,%s,%s,%s,%s,%s,"in_zone":%s%s}\n' \
      "$(json_kv_bool "ok" "$([ "$status_val" = "ok" ] && echo 0 || echo 1)")" \
      "$(json_kv "resolver" "$dns_source")" \
      "$(json_kv "domain" "$domain")" \
      "$(json_kv "resolved_ip" "$resolved_ip")" \
      "$(json_kv "cc" "$resolved_cc")" \
      "$(json_kv "type" "$dns_type")" \
      "$in_zone" \
      "$_isp_json"
  else
    section_title "DNS Resolution"
    if ! is_quiet; then
      printf 'Resolver: %s%s%s\n' "$C_BOLD" "$dns_source" "$C_RST"
      if [ -n "$_zone_label" ]; then
        printf 'DNS zone: %s%s%s (%s)\n' "$C_CYAN" "$_zone_label" "$C_RST" "$_zone_cc_list"
      fi
      printf '\n'

      tbl_header "Domain:22" "Resolved IP:18" "CC:4" "Type:8" "Status"

      local _dns_cm=""
      if [ -f "${_RUN_DIR:-/tmp}/dns-hit-${domain}" ]; then
        _dns_cm=" $(cache_mark)"
        rm -f "${_RUN_DIR:-/tmp}/dns-hit-${domain}"
      fi
      tbl_row "$domain" \
        "$(tbl_cell 18 "$resolved_ip" "$status_val")" \
        "$(tbl_cell 4 "$resolved_cc" "$status_val")" \
        "$dns_type" \
        "$(status_mark "$status_val") ${status_label}${_dns_cm}"

      # ISP filtering summary
      if [ "$isp_blocked" = 1 ]; then
        printf '→ %s%s ISP DNS filtering detected%s' \
          "$C_YELLOW" "$(status_mark warn)" "$C_RST"
        if [ -n "$isp_label" ]; then
          printf ' %s(%s → %s)%s' \
            "$C_DIM" "$isp_label" "${isp_ip:-NXDOMAIN}" "$C_RST"
        fi
        printf '\n'
      elif [ -n "$isp_dns_first" ]; then
        printf '→ %sNo ISP DNS filtering%s %s\n' \
          "$C_GREEN" "$C_RST" "$(status_mark ok)"
      fi

      # Flag exit code on failures
      if [ "$status_val" = "warn" ]; then
        [ "$_EXIT_CODE" -lt 1 ] && _EXIT_CODE=1
      fi
    else
      # Quiet mode: single-line summary
      printf 'dns: %s %s → %s (%s) %s\n' \
        "$(status_mark "$status_val")" \
        "$domain" "$resolved_ip" "$resolved_cc" "$status_label"
    fi
  fi
}
