# net-check: DNS check — zone resolution verification + ISP blocking detection.
# Resolves all domains from check-targets.conf via active resolver and ISP DNS.
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

# Active resolver args for dig (set by _dns_detect_resolver at runtime).
# When SmartDNS detected: "@127.0.0.1 -p 6053"; empty = system resolver (:53).
_DNS_RESOLVER_ARGS=""

# Resolve domain to first A record.
# Args: $1 - domain, $2 - DNS server (optional; omit for active resolver),
#        $3 - timeout (optional)
# When $2 is omitted: uses SmartDNS directly if _DNS_RESOLVER_ARGS is set
# (populated by _dns_detect_resolver), otherwise system resolver (:53).
# stdout: IPv4 address or empty
_resolve_a() {
  local domain="$1" server="${2:-}" timeout="${3:-$DNS_TIMEOUT}"
  if [ -n "$server" ]; then
    dig +short "$domain" @"$server" A \
      +time="$timeout" +tries=1 2>/dev/null
  else
    # shellcheck disable=SC2086
    dig +short "$domain" ${_DNS_RESOLVER_ARGS:-} A \
      +time="$timeout" +tries=1 2>/dev/null
  fi | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

# Cached DNS resolution via active resolver (SmartDNS or system :53).
# File cache: ${DATA_DIR}/dns-<domain>, TTL=60s.
# Shared across sections (dns, compare, tls, cdn).
# For explicit server queries: no cache (ISP DNS check needs fresh results).
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

# Get ISP upstream DNS IPs.
# Primary: Keenetic ndnproxymain.conf (filters SmartDNS-forwarding and loopback).
# Fallback: /etc/resolv.conf nameservers (for non-Keenetic routers).
# stdout: space-separated IPs (up to 2)
_get_isp_dns() {
  local _result=""
  if [ -f "$KEENETIC_DNS_CONF" ]; then
    _result=$(grep '^dns_server' "$KEENETIC_DNS_CONF" 2>/dev/null | \
      awk '{print $3}' | grep -v ":${SMARTDNS_PORT}" | sed 's/:.*//' | \
      grep -v '^127\.' | head -2 | tr '\n' ' ' | sed 's/ $//')
  fi
  # Fallback: /etc/resolv.conf (non-Keenetic systems)
  if [ -z "$_result" ] && [ -f /etc/resolv.conf ]; then
    _result=$(grep '^nameserver' /etc/resolv.conf 2>/dev/null | \
      awk '{print $2}' | grep -v '^127\.' | grep -v '^::' | \
      head -2 | tr '\n' ' ' | sed 's/ $//')
  fi
  printf '%s' "$_result"
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
  [ -f "$_CONFIG_DIR/check-targets.conf" ] || return 0
  _cat_config check-targets | awk -F'|' '
    /^#/ || /^$/ || $2 == "geo" { next }
    {
      host = $1
      sub(/^https?:\/\//, "", host)
      sub(/\/.*/, "", host)
      sub(/:.*/, "", host)
      cat = ($3 != "" ? $3 : "global")
      if (host != "" && !seen[host]++) print host "|" cat
    }
  '
}

# ─── DNS Setup Helpers (shared by cmd_dns and _dns_check_single) ─────────────

# Detect active DNS resolver (SmartDNS or system).
# Sets: _dns_source, _DNS_RESOLVER_ARGS
_dns_detect_resolver() {
  local _dns_info _dns_port
  _dns_info=$(detect_dns_port main 2>/dev/null) || _dns_info=""
  _dns_port="${_dns_info%% *}"
  case "$_dns_port" in
    6053|6153)
      _dns_source="SmartDNS (:${_dns_port})"
      _DNS_RESOLVER_ARGS="@127.0.0.1 -p ${_dns_port}"
      ;;
    *)
      _dns_source="system DNS (:53)"
      _DNS_RESOLVER_ARGS=""
      ;;
  esac
}

# Detect ISP upstream DNS for filtering detection.
# Sets: _dns_isp_first, _dns_isp_label
_dns_detect_isp() {
  local isp_dns
  _dns_isp_first=""
  _dns_isp_label=""
  isp_dns=$(_get_isp_dns)
  if [ -n "$isp_dns" ]; then
    _dns_isp_first="${isp_dns%% *}"
    local isp_provider
    isp_provider=$(identify_dns_provider "$_dns_isp_first") || isp_provider=""
    if [ -n "$isp_provider" ]; then
      _dns_isp_label="$isp_provider ($_dns_isp_first)"
    else
      _dns_isp_label="$_dns_isp_first"
    fi
  fi
}

# ─── cmd_dns Helpers ──────────────────────────────────────────────────────────

# Load domains from arguments or check-targets.conf.
# Args: $@ - optional domain list
# Sets: _dns_all_domains
# Creates: _RUN_DIR/dns-cat-* files
_dns_load_domains() {
  _dns_all_domains=""
  local _ddomain _dcat
  if [ $# -gt 0 ]; then
    # Deep check mode: use passed domains
    for _ddomain in "$@"; do
      _ddomain=$(url_to_host "$_ddomain")
      [ -z "$_ddomain" ] && continue
      _dns_all_domains="${_dns_all_domains} ${_ddomain}"
      printf '%s' "check" > "${_RUN_DIR}/dns-cat-${_ddomain}"
    done
  else
    # Default: load from check-targets.conf
    while IFS='|' read -r _ddomain _dcat; do
      [ -z "$_ddomain" ] && continue
      _dns_all_domains="${_dns_all_domains} ${_ddomain}"
      printf '%s' "${_dcat:-global}" > "${_RUN_DIR}/dns-cat-${_ddomain}"
    done <<EOF
$(_load_check_domains)
EOF
  fi
  _dns_all_domains="${_dns_all_domains# }"
}

# Batch callback: parallel DNS probes for all domains.
# Args: $1 - space-separated domain list (batch subset)
# Uses: _dns_isp_first (from caller scope)
# shellcheck disable=SC2329
_dns_run_batch() {
  local _domains="$1"
  local _bd
  for _bd in $_domains; do
    (
      _rip=$(_resolve_a_cached "$_bd") || _rip=""
      _iip="" _iblk=0
      if [ -n "$_dns_isp_first" ]; then
        _iip=$(_resolve_a "$_bd" "$_dns_isp_first") || _iip=""
        if [ -z "$_iip" ]; then _iblk=1
        elif _is_bogon "$_iip"; then _iblk=1
        fi
      fi
      # NOTE: geolocate_ip moved to sequential collection phase
      # to avoid API rate-limits from parallel subshells.
      printf '%s\t%s\t%s\n' "${_rip:-}" "${_iip:-}" "$_iblk" \
        > "${_RUN_DIR}/dns-${_bd}"
    ) &
  done
}

# Classify one DNS domain: read parallel result, geolocate, determine zone/intl + status.
# Args: $1 - domain
# Uses: _ZONE_CC_LIST (from load_zone_context)
# Sets: _dd_resolved (0/1), _dd_resolved_ip, _dd_resolved_cc, _dd_dns_type,
#       _dd_status_val, _dd_status_label, _dd_isp_ip, _dd_isp_blocked, _dd_cc_cached
_dns_classify_domain() {
  local domain="$1"
  local _pf="${_RUN_DIR}/dns-${domain}"

  _dd_resolved=0
  _dd_resolved_ip=""
  _dd_resolved_cc=""
  _dd_dns_type=""
  _dd_status_val=""
  _dd_status_label=""
  _dd_isp_ip=""
  _dd_isp_blocked=0
  _dd_cc_cached=0

  if [ -f "$_pf" ]; then
    _dd_resolved_ip=$(cut -f1 "$_pf")
    _dd_isp_ip=$(cut -f2 "$_pf")
    _dd_isp_blocked=$(cut -f3 "$_pf")
    rm -f "$_pf"
  fi

  # Sequential geolocate (moved out of parallel to avoid API rate-limits;
  # also maximises cache hits when multiple domains resolve to same IP).
  if [ -n "$_dd_resolved_ip" ]; then
    _dd_resolved=1
    if is_cache_fresh "$(ipgeo_cache_file "$_dd_resolved_ip")" "${IPGEO_CACHE_TTL:-86400}"; then
      _dd_cc_cached=1
    fi
    _dd_resolved_cc=$(geolocate_ip "$_dd_resolved_ip" 2>/dev/null) || _dd_resolved_cc="??"
  fi

  if [ "$_dd_resolved" = 1 ]; then
    # Auto-classify zone/intl based on GeoIP
    if [ -n "$_ZONE_CC_LIST" ] && [ "$_dd_resolved_cc" != "??" ]; then
      local _cc_lower
      _cc_lower=$(printf '%s' "$_dd_resolved_cc" | tr '[:upper:]' '[:lower:]')
      case " $_ZONE_CC_LIST " in
        *" $_cc_lower "*)
          _dd_dns_type="zone"
          ;;
        *)
          _dd_dns_type="intl"
          ;;
      esac
    else
      _dd_dns_type="—"
    fi

    # Determine status
    if [ "$_dd_isp_blocked" = 1 ]; then
      if [ "$_dd_dns_type" = "zone" ]; then
        _dd_status_val="warn"; _dd_status_label="zone ok, ISP filt"
      else
        _dd_status_val="warn"; _dd_status_label="ISP filtered"
      fi
    else
      if [ "$_dd_dns_type" = "zone" ]; then
        _dd_status_val="ok"; _dd_status_label="zone ok"
      else
        _dd_status_val="ok"; _dd_status_label="ok"
      fi
    fi
  else
    # Resolution failed
    _dd_resolved_ip="NXDOMAIN"
    _dd_resolved_cc="—"
    _dd_dns_type="—"
    if [ "$_dd_isp_blocked" = 1 ]; then
      _dd_status_val="warn"; _dd_status_label="NXDOMAIN + ISP"
    else
      _dd_status_val="warn"; _dd_status_label="NXDOMAIN"
    fi
  fi
}

# Render summary for cmd_dns (text + JSON).
# Uses: _dns_ok, _dns_warn, _dns_total, _zone_ok, _isp_filtered,
#       _dns_json_results, _dns_source, _dns_isp_first, _dns_isp_label,
#       _ZONE_LABEL, _ZONE_CC_LIST
_dns_render_summary() {
  # ── Text Summary ──
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
        printf '→ %s%s ISP DNS filtering: %s domain(s) filtered%s\n' \
          "$C_YELLOW" "$(status_mark warn)" "$_isp_filtered" "$C_RST"
        printf '  %s(Expected — filtered domains resolve via SmartDNS/tunnel)%s\n' \
          "$C_DIM" "$C_RST"
      elif [ -n "$_dns_isp_first" ]; then
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
      "$(json_kv "resolver" "$_dns_source")"

    if [ -n "$_ZONE_LABEL" ]; then
      printf ',%s,%s' \
        "$(json_kv "dns_zone" "$_ZONE_LABEL")" \
        "$(json_kv "zone_countries" "$_ZONE_CC_LIST")"
    fi

    printf ',"stats":{%s,%s,%s,%s}' \
      "$(json_kv_num "total" "$_dns_total")" \
      "$(json_kv_num "resolved" "$_dns_ok")" \
      "$(json_kv_num "zone_ok" "$_zone_ok")" \
      "$(json_kv_num "isp_filtered" "$_isp_filtered")"

    if [ -n "$_dns_isp_first" ]; then
      printf ',%s' "$(json_kv "isp_dns" "$_dns_isp_first")"
    fi

    printf ',"results":[%s]}\n' "$_dns_json_results"
  fi
}

# Process one domain in the collect loop: category sep, classify, counters, render.
# Args: $1 - domain
# Uses: _dns_isp_first, _dd_* globals
# Updates: _dns_total, _dns_ok, _dns_warn, _zone_ok, _isp_filtered,
#          _dns_json_results, _dns_json_first
_dns_process_domain() {
  local domain="$1"

  # Category group separator
  local _dns_cat="global"
  if [ -f "${_RUN_DIR}/dns-cat-${domain}" ]; then
    _dns_cat=$(cat "${_RUN_DIR}/dns-cat-${domain}")
    rm -f "${_RUN_DIR}/dns-cat-${domain}"
  fi
  tbl_group_sep "$_dns_cat"

  _dns_classify_domain "$domain"
  _dns_total=$((_dns_total + 1))

  # Update counters
  if [ "$_dd_resolved" = 1 ]; then
    _dns_ok=$((_dns_ok + 1))
    [ "$_dd_dns_type" = "zone" ] && _zone_ok=$((_zone_ok + 1))
    [ "$_dd_isp_blocked" = 1 ] && _isp_filtered=$((_isp_filtered + 1))
  else
    _dns_warn=$((_dns_warn + 1))
  fi

  # Output
  if [ "$OUTPUT_JSON" = 1 ]; then
    local _in_zone="null"
    if [ "$_dd_dns_type" = "zone" ]; then
      _in_zone="true"
    elif [ "$_dd_dns_type" = "intl" ]; then
      _in_zone="false"
    fi
    local _isp_json=""
    if [ -n "$_dns_isp_first" ]; then
      local _filt_jv="false"
      [ "$_dd_isp_blocked" = 1 ] && _filt_jv="true"
      _isp_json=$(printf ',"isp_dns":{"resolved_ip":"%s","filtered":%s}' \
        "${_dd_isp_ip:-NXDOMAIN}" "$_filt_jv")
    fi
    local ej
    ej=$(printf '{"domain":"%s","resolved_ip":"%s","cc":"%s","type":"%s","in_zone":%s%s}' \
      "$domain" "$_dd_resolved_ip" "$_dd_resolved_cc" "$_dd_dns_type" "$_in_zone" "$_isp_json")
    if [ "$_dns_json_first" = 1 ]; then
      _dns_json_results="$ej"
      _dns_json_first=0
    else
      _dns_json_results="${_dns_json_results},${ej}"
    fi
  else
    # Cache marker: DNS resolution cache hit (60s) or GeoIP cache hit (24h)
    local _dns_cm=""
    if [ -f "${_RUN_DIR}/dns-hit-${domain}" ]; then
      _dns_cm=" $(cache_mark)"
      rm -f "${_RUN_DIR}/dns-hit-${domain}"
    elif [ "$_dd_cc_cached" = 1 ]; then
      _dns_cm=" $(cache_mark)"
    fi
    tbl_cell_v 24 "$_dd_resolved_ip" "$_dd_status_val"; local _c1="$_CELL"
    tbl_cell_v 4 "$_dd_resolved_cc" "$_dd_status_val"; local _c2="$_CELL"
    tbl_cell_v 8 "$_dd_dns_type"; local _c3="$_CELL"
    tbl_row "$domain" "$_c1" "$_c2" "$_c3" \
      "$(status_mark "$_dd_status_val") ${_dd_status_label}${_dns_cm}"
  fi
}

# ─── Command: dns ─────────────────────────────────────────────────────────────

# DNS check: resolve all check-targets domains, geolocate IPs,
# auto-classify zone/intl, detect ISP DNS filtering for every domain.
cmd_dns() {
  require_cmd dig

  # ── Setup: detect resolver, zone context, ISP DNS ──
  _dns_detect_resolver
  load_zone_context
  # shellcheck disable=SC2153  # _ZONE_LABEL/_ZONE_CC_LIST set by load_zone_context()
  _dns_detect_isp

  section_title "$_TITLE_DNS"
  if [ "$OUTPUT_JSON" = 0 ] && ! is_quiet; then
    printf 'DNS resolution & geolocation for all check-targets domains.\n'
    printf 'Detects wrong-zone routing and ISP DNS filtering (middlebox interference).\n\n'
  fi

  # ── Load domains ──
  _dns_load_domains "$@"
  if [ -z "$_dns_all_domains" ]; then
    emit_error "No domains in check-targets.conf"
    return 1
  fi

  # Header
  if [ "$OUTPUT_JSON" = 0 ] && ! is_quiet; then
    printf 'Resolver: %s%s%s\n' "$C_BOLD" "$_dns_source" "$C_RST"
    if [ -n "$_dns_isp_label" ]; then
      printf 'ISP DNS:  %s\n' "$_dns_isp_label"
    fi
    printf '\n'
  fi

  # Auto-width Domain column (min 22, max 32)
  local _domain_w
  _domain_w=$(auto_label_width "$_dns_all_domains" 22 32)
  tbl_header "Domain:${_domain_w}" "Resolved IP:24" "CC:4" "Type:8" "Status"
  tbl_group_reset

  local _dns_json_results="" _dns_json_first=1
  local _dns_ok=0 _dns_warn=0 _dns_total=0
  local _zone_ok=0 _isp_filtered=0

  # ── Batched parallel DNS probes ──
  batch_run_parallel "DNS" "$PARALLEL_BATCH_SIZE" "$_dns_all_domains" _dns_run_batch

  # ── Pre-warm GeoIP cache for all resolved IPs ──
  local _dns_ips="" _pw_domain _pw_pf _pw_ip
  for _pw_domain in $_dns_all_domains; do
    _pw_pf="${_RUN_DIR}/dns-${_pw_domain}"
    [ -f "$_pw_pf" ] || continue
    _pw_ip=$(cut -f1 "$_pw_pf")
    [ -n "$_pw_ip" ] && _dns_ips="${_dns_ips} ${_pw_ip}"
  done
  geoip_batch_prewarm "$_dns_ips"

  # ── Collect parallel results (in domain order for stable output) ──
  local domain
  for domain in $_dns_all_domains; do
    _dns_process_domain "$domain"
  done

  # ── Summary ──
  _dns_render_summary
}

# ─── Single-domain DNS Helpers ─────────────────────────────────────────────────

# Resolve and classify a single domain: active resolver + ISP DNS + geolocate.
# Args: $1 - domain
# Uses: _dns_isp_first
# Sets: _dd_resolved_ip, _dd_resolved_cc, _dd_dns_type, _dd_status_val,
#       _dd_status_label, _dd_isp_ip, _dd_isp_blocked, _dd_in_zone, _dd_cc_cached
_dns_single_classify() {
  local domain="$1"

  # ── Resolve via active resolver (cached) ──
  _dd_resolved_ip=""
  _dd_resolved_cc=""
  _dd_cc_cached=0
  _dd_resolved_ip=$(_resolve_a_cached "$domain") || _dd_resolved_ip=""
  if [ -n "$_dd_resolved_ip" ]; then
    if is_cache_fresh "$(ipgeo_cache_file "$_dd_resolved_ip")" "${IPGEO_CACHE_TTL:-86400}"; then
      _dd_cc_cached=1
    fi
    _dd_resolved_cc=$(geolocate_ip "$_dd_resolved_ip" 2>/dev/null) || _dd_resolved_cc="??"
  fi

  # ── Resolve via ISP DNS (fresh, no cache) ──
  _dd_isp_ip=""
  _dd_isp_blocked=0
  if [ -n "$_dns_isp_first" ]; then
    _dd_isp_ip=$(_resolve_a "$domain" "$_dns_isp_first") || _dd_isp_ip=""
    if [ -z "$_dd_isp_ip" ]; then
      _dd_isp_blocked=1
    elif _is_bogon "$_dd_isp_ip"; then
      _dd_isp_blocked=1
    fi
  fi

  # ── Classify zone/intl ──
  _dd_dns_type=""
  _dd_status_val=""
  _dd_status_label=""
  _dd_in_zone="null"

  if [ -n "$_dd_resolved_ip" ]; then
    if [ -n "$_ZONE_CC_LIST" ] && [ "$_dd_resolved_cc" != "??" ]; then
      local _cc_lower
      _cc_lower=$(printf '%s' "$_dd_resolved_cc" | tr '[:upper:]' '[:lower:]')
      case " $_ZONE_CC_LIST " in
        *" $_cc_lower "*) _dd_dns_type="zone"; _dd_in_zone="true" ;;
        *)                _dd_dns_type="intl"; _dd_in_zone="false" ;;
      esac
    else
      _dd_dns_type="—"
    fi

    # Status
    if [ "$_dd_isp_blocked" = 1 ]; then
      if [ "$_dd_dns_type" = "zone" ]; then
        _dd_status_val="warn"; _dd_status_label="zone ok, ISP filt"
      else
        _dd_status_val="warn"; _dd_status_label="ISP filtered"
      fi
    else
      if [ "$_dd_dns_type" = "zone" ]; then
        _dd_status_val="ok"; _dd_status_label="zone ok"
      else
        _dd_status_val="ok"; _dd_status_label="ok"
      fi
    fi
  else
    # Resolution failed
    _dd_resolved_ip="NXDOMAIN"
    _dd_resolved_cc="—"
    _dd_dns_type="—"
    if [ "$_dd_isp_blocked" = 1 ]; then
      _dd_status_val="warn"; _dd_status_label="NXDOMAIN + ISP"
    else
      _dd_status_val="warn"; _dd_status_label="NXDOMAIN"
    fi
  fi
}

# Render JSON output for _dns_check_single.
# Args: $1 - domain
# Uses: _dd_*, _dns_source, _dns_isp_first
_dns_single_render_json() {
  local domain="$1"

  local _isp_json=""
  if [ -n "$_dns_isp_first" ]; then
    local _bf=1
    [ "$_dd_isp_blocked" = 1 ] && _bf=0
    _isp_json=$(printf ',"isp_dns":{%s,%s}' \
      "$(json_kv "resolved_ip" "${_dd_isp_ip:-NXDOMAIN}")" \
      "$(json_kv_bool "filtered" "$_bf")")
  fi

  printf '{%s,%s,%s,%s,%s,%s,"in_zone":%s%s}\n' \
    "$(json_kv_bool "ok" "$([ "$_dd_status_val" = "ok" ] && echo 0 || echo 1)")" \
    "$(json_kv "resolver" "$_dns_source")" \
    "$(json_kv "domain" "$domain")" \
    "$(json_kv "resolved_ip" "$_dd_resolved_ip")" \
    "$(json_kv "cc" "$_dd_resolved_cc")" \
    "$(json_kv "type" "$_dd_dns_type")" \
    "$_dd_in_zone" \
    "$_isp_json"
}

# Render text output for _dns_check_single.
# Args: $1 - domain
# Uses: _dd_*, _dns_source, _dns_isp_first, _dns_isp_label, _ZONE_LABEL, _ZONE_CC_LIST
_dns_single_render_text() {
  local domain="$1"

  section_title "DNS Resolution"
  if ! is_quiet; then
    printf 'Resolver: %s%s%s\n' "$C_BOLD" "$_dns_source" "$C_RST"
    if [ -n "$_ZONE_LABEL" ]; then
      printf 'DNS zone: %s%s%s (%s)\n' "$C_CYAN" "$_ZONE_LABEL" "$C_RST" "$_ZONE_CC_LIST"
    fi
    printf '\n'

    tbl_header "Domain:22" "Resolved IP:24" "CC:4" "Type:8" "Status"

    local _dns_cm=""
    if [ -f "${_RUN_DIR:-/tmp}/dns-hit-${domain}" ]; then
      _dns_cm=" $(cache_mark)"
      rm -f "${_RUN_DIR:-/tmp}/dns-hit-${domain}"
    elif [ "$_dd_cc_cached" = 1 ]; then
      _dns_cm=" $(cache_mark)"
    fi
    tbl_row "$domain" \
      "$(tbl_cell 24 "$_dd_resolved_ip" "$_dd_status_val")" \
      "$(tbl_cell 4 "$_dd_resolved_cc" "$_dd_status_val")" \
      "$(tbl_cell 8 "$_dd_dns_type")" \
      "$(status_mark "$_dd_status_val") ${_dd_status_label}${_dns_cm}"

    # ISP filtering summary
    if [ "$_dd_isp_blocked" = 1 ]; then
      printf '→ %s%s ISP DNS filtering detected%s' \
        "$C_YELLOW" "$(status_mark warn)" "$C_RST"
      if [ -n "$_dns_isp_label" ]; then
        printf ' %s(%s → %s)%s' \
          "$C_DIM" "$_dns_isp_label" "${_dd_isp_ip:-NXDOMAIN}" "$C_RST"
      fi
      printf '\n'
    elif [ -n "$_dns_isp_first" ]; then
      printf '→ %sNo ISP DNS filtering%s %s\n' \
        "$C_GREEN" "$C_RST" "$(status_mark ok)"
    fi

    # Flag exit code on failures
    if [ "$_dd_status_val" = "warn" ]; then
      [ "$_EXIT_CODE" -lt 1 ] && _EXIT_CODE=1
    fi
  else
    # Quiet mode: single-line summary
    printf 'dns: %s %s → %s (%s) %s\n' \
      "$(status_mark "$_dd_status_val")" \
      "$domain" "$_dd_resolved_ip" "$_dd_resolved_cc" "$_dd_status_label"
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

  # ── Setup ──
  _dns_detect_resolver
  load_zone_context
  _dns_detect_isp

  # ── Resolve + classify ──
  _dns_single_classify "$domain"

  # ── Output ──
  if [ "$OUTPUT_JSON" = 1 ]; then
    _dns_single_render_json "$domain"
  else
    _dns_single_render_text "$domain"
  fi
}
